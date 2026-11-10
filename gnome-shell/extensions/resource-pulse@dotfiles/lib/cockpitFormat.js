// Every word a cockpit card and its tooltip draw, decided here as pure functions so the St glue draws strings and
// fractions only. Nothing here imports Gio, GLib or Shell. A source is assumed reader-valid (see cockpitProtocol.js);
// a source never received is the glue's to draw as "no data".
import {
    APPS_CARD_ROW_LIMIT, COCKPIT_ICON_NAMES, COCKPIT_REDACTED_NAME, SECONDS_PER_DAY, SECONDS_PER_HOUR,
    SECONDS_PER_MINUTE, SESSION_IDLE_DIM_SECONDS, SESSIONS_CARD_ROW_LIMIT,
} from './constants.js';
import {SESSION_STATES} from './cockpitProtocol.js';
import {noDataSinceLabel} from './cockpitStaleness.js';
import {formatGibibytes, formatWholePercent} from './format.js';

const BYTES_PER_MEBIBYTE = 1024 * 1024;
const BYTES_PER_GIBIBYTE = 1024 * BYTES_PER_MEBIBYTE;
const NO_VALUE_TEXT = COCKPIT_REDACTED_NAME;
const SESSIONS_TITLE = 'SESSIONS';
const MEMORY_TOOLTIP_NOTE = 'memory: process only; MCP servers and tool shells not counted';
const PROCESS_AGE_MARK = '*';
const STATES_THAT_DIM_WHEN_LONG_IDLE = ['idle', 'done'];
const CONNECTIVITY_UNKNOWN = 'unknown';
const SEPARATOR = ' · ';
/** What the sessions card says when herdr is not running. */
export const herdrNotRunningText = 'herdr not running';

/**
 * Formats a memory size: GiB with one decimal from 1 GiB up, whole MiB below.
 *
 * @param {number|null} bytes - Size in bytes.
 * @returns {string} '1.2G', '340M', or '—' when unknown.
 */
function memoryText(bytes) {
    if (bytes === null)
        return NO_VALUE_TEXT;
    if (bytes >= BYTES_PER_GIBIBYTE)
        return `${formatGibibytes(bytes)}G`;
    return `${Math.round(bytes / BYTES_PER_MEBIBYTE)}M`;
}

/**
 * Writes an idle time in one unit, rounded down.
 *
 * @param {number|null} idleSeconds - Seconds idle.
 * @param {boolean} isFromProcessAge - Whether the figure is the pane process's age, not a true idle time.
 * @returns {string} '45s', '12m', '2h', '3d', with a trailing '*' when from process age; '—' when unknown.
 */
function idleText(idleSeconds, isFromProcessAge) {
    if (idleSeconds === null)
        return NO_VALUE_TEXT;
    let text;
    if (idleSeconds < SECONDS_PER_MINUTE)
        text = `${Math.floor(idleSeconds)}s`;
    else if (idleSeconds < SECONDS_PER_HOUR)
        text = `${Math.floor(idleSeconds / SECONDS_PER_MINUTE)}m`;
    else if (idleSeconds < SECONDS_PER_DAY)
        text = `${Math.floor(idleSeconds / SECONDS_PER_HOUR)}h`;
    else
        text = `${Math.floor(idleSeconds / SECONDS_PER_DAY)}d`;
    return isFromProcessAge ? `${text}${PROCESS_AGE_MARK}` : text;
}

/**
 * The share of the largest value a value is; 0 when either is unknown or the largest is 0.
 *
 * @param {number|null} value - The row's value.
 * @param {number} largest - The largest value in the list.
 * @returns {number} A fraction in [0, 1].
 */
function shareOfLargest(value, largest) {
    if (value === null || !(largest > 0))
        return 0;
    return value / largest;
}

/**
 * The header of the sessions card.
 *
 * @param {object} sessions - A sessions source.
 * @returns {{title: string, count: string, counts: Array<{state: string, count: number}>, totalMemory: string}}
 *   `counts` in SESSION_STATES order, zero counts included; `count` is the number of rows.
 */
export function sessionsHeader(sessions) {
    return {
        title: SESSIONS_TITLE,
        count: String(sessions.rows.length),
        counts: SESSION_STATES.map(state => ({state, count: sessions.counts[state]})),
        totalMemory: memoryText(sessions.totalMemoryBytes),
    };
}

/**
 * The visible rows of the sessions card, in the order the service published them.
 *
 * @param {object} sessions - A sessions source.
 * @returns {{rows: Array<{id: string, state: string, name: string, idleText: string, isLongIdle: boolean,
 *   memoryText: string, memoryFraction: number, isWaiting: boolean}>, overflowText: string|null}} At most
 *   SESSIONS_CARD_ROW_LIMIT rows; `overflowText` is '+N more' for the rows beyond, else null.
 */
export function sessionRows(sessions) {
    const largestMemoryBytes = Math.max(0, ...sessions.rows.map(row => row.memoryBytes ?? 0));
    const rows = sessions.rows.slice(0, SESSIONS_CARD_ROW_LIMIT).map(row => ({
        id: row.id,
        state: row.state,
        name: row.name,
        idleText: idleText(row.idleSeconds, row.idleFromProcessAge),
        isLongIdle: row.idleSeconds !== null && row.idleSeconds >= SESSION_IDLE_DIM_SECONDS &&
            STATES_THAT_DIM_WHEN_LONG_IDLE.includes(row.state),
        memoryText: memoryText(row.memoryBytes),
        memoryFraction: shareOfLargest(row.memoryBytes, largestMemoryBytes),
        isWaiting: row.state === 'blocked',
    }));
    const hiddenCount = sessions.rows.length - rows.length;
    return {rows, overflowText: hiddenCount > 0 ? `+${hiddenCount} more` : null};
}

/**
 * The tooltip of one session row.
 *
 * @param {{state: string}} row - A session row.
 * @param {{account: string|null, contextPercent: number|null, paneId: string}} details - What the source published.
 * @returns {string[]} The state word, the pane, the account and context when known, and the memory caveat.
 */
export function sessionTooltip(row, {account, contextPercent, paneId}) {
    const lines = [row.state, `pane ${paneId}`];
    if (account !== null && account !== undefined)
        lines.push(`account ${account}`);
    if (contextPercent !== null && contextPercent !== undefined)
        lines.push(`context ${formatWholePercent(contextPercent)}`);
    lines.push(MEMORY_TOOLTIP_NOTE);
    return lines;
}

/**
 * The rows of the apps card's two rankings.
 *
 * @param {{cpuRanking: Array|null, memoryRanking: Array|null}} apps - The sampler's apps rankings.
 * @param {{limit: number}} [options] - The most rows per ranking.
 * @returns {{cpu: Array<{name: string, cpuText: string, cpuFraction: number}>,
 *   memory: Array<{name: string, memoryText: string, memoryFraction: number}>}} Empty lists for a null ranking.
 */
export function appsRows(apps, {limit = APPS_CARD_ROW_LIMIT} = {}) {
    const cpuRanking = (apps.cpuRanking ?? []).slice(0, limit);
    const memoryRanking = (apps.memoryRanking ?? []).slice(0, limit);
    const largestMemoryBytes = memoryRanking.length > 0 ? memoryRanking[0].memoryBytes : 0;
    return {
        cpu: cpuRanking.map(entry => ({
            name: entry.name,
            cpuText: formatWholePercent(entry.cpuPercent),
            cpuFraction: Math.min(1, Math.max(0, entry.cpuPercent / 100)),
        })),
        memory: memoryRanking.map(entry => ({
            name: entry.name,
            memoryText: memoryText(entry.memoryBytes),
            memoryFraction: shareOfLargest(entry.memoryBytes, largestMemoryBytes),
        })),
    };
}

/**
 * The uplink row: wired, wifi or offline, with the connectivity word in the tooltip.
 *
 * @param {{kind: string, connectivity: string|null, wifiEnabled: boolean|null}} uplink - The uplink.
 * @returns {object} A connections row of kind 'uplink'.
 */
function uplinkRow(uplink) {
    let icon = COCKPIT_ICON_NAMES.offline;
    let text = 'offline';
    if (uplink.kind === 'wired') {
        icon = COCKPIT_ICON_NAMES.wired;
        text = uplink.wifiEnabled === false ? `wired${SEPARATOR}wifi off` : 'wired';
    } else if (uplink.kind === 'wifi') {
        icon = COCKPIT_ICON_NAMES.wifi;
        text = 'wifi';
    }
    const connectivityWord = uplink.connectivity ?? CONNECTIVITY_UNKNOWN;
    return {kind: 'uplink', icon, text, tooltip: [`internet: ${connectivityWord}`], fraction: null};
}

/**
 * The VPN row.
 *
 * @param {{isUp: boolean|null, interfaceName: string|null}} vpn - The VPN state.
 * @returns {object} A connections row of kind 'vpn'.
 */
function vpnRow(vpn) {
    let text = 'VPN unknown';
    if (vpn.isUp === true)
        text = vpn.interfaceName ? `VPN up (${vpn.interfaceName})` : 'VPN up';
    else if (vpn.isUp === false)
        text = 'VPN down';
    return {kind: 'vpn', icon: COCKPIT_ICON_NAMES.vpn, text, tooltip: [text], fraction: null};
}

/**
 * The ssh control-master row.
 *
 * @param {number|null} sshMasterCount - Live ssh control masters, or null when unknown.
 * @returns {object} A connections row of kind 'ssh': 'no ssh masters', '1 live ssh master', '<N> live ssh masters',
 *   or 'ssh masters unknown'.
 */
function sshRow(sshMasterCount) {
    let text = `${sshMasterCount} live ssh masters`;
    if (sshMasterCount === null || sshMasterCount === undefined)
        text = 'ssh masters unknown';
    else if (sshMasterCount === 0)
        text = 'no ssh masters';
    else if (sshMasterCount === 1)
        text = '1 live ssh master';
    return {kind: 'ssh', icon: COCKPIT_ICON_NAMES.ssh, text, tooltip: [text], fraction: null};
}

/**
 * One mount's row: label and free space, the used share as its fraction.
 *
 * @param {object} mount - A mount row of a mounts source.
 * @returns {object} A connections row of kind 'mount'.
 */
function mountRow(mount) {
    const areSizesKnown = mount.freeBytes !== null && mount.totalBytes !== null && mount.totalBytes > 0;
    const freeText = mount.freeBytes === null ? null : `${formatGibibytes(mount.freeBytes)}G`;
    const tooltip = [mount.mountPoint, mount.filesystemType];
    if (areSizesKnown)
        tooltip.push(`${freeText} free of ${formatGibibytes(mount.totalBytes)}G`);
    return {
        kind: 'mount',
        icon: mount.kind === 'network' ? COCKPIT_ICON_NAMES.mountNetwork : COCKPIT_ICON_NAMES.mountRemovable,
        text: freeText === null ? mount.label : `${mount.label}${SEPARATOR}${freeText} free`,
        tooltip,
        fraction: areSizesKnown ? (mount.totalBytes - mount.freeBytes) / mount.totalBytes : null,
    };
}

/**
 * The rows of the connections card: uplink, VPN, ssh masters, then every mount as published.
 *
 * @param {object} network - A network source.
 * @param {object} mounts - A mounts source.
 * @returns {Array<{kind: string, icon: string, text: string, tooltip: string[], fraction: number|null}>} The rows.
 */
export function connectionsRows(network, mounts) {
    return [
        uplinkRow(network.uplink),
        vpnRow(network.vpn),
        sshRow(network.sshMasterCount),
        ...mounts.rows.map(mountRow),
    ];
}

/**
 * What a card with no fresh source says.
 *
 * @param {number|null} sampledAtUsec - When the source was last sampled, or null if never.
 * @param {function(number): string} formatClock - Writes a microsecond wall-clock stamp as a time of day.
 * @returns {string} 'no data' or 'no data since <time>'.
 */
export function noDataText(sampledAtUsec, formatClock) {
    return noDataSinceLabel(sampledAtUsec, formatClock);
}

/**
 * The icon of a session state.
 *
 * @param {string} state - One of SESSION_STATES.
 * @returns {string} A symbolic icon name.
 */
export function stateIconName(state) {
    return COCKPIT_ICON_NAMES[state];
}

/**
 * The style class of a session state.
 *
 * @param {string} state - One of SESSION_STATES.
 * @returns {string} 'rp-cockpit-state-<state>'.
 */
export function stateStyleClass(state) {
    return `rp-cockpit-state-${state}`;
}
