// Every word a cockpit card and its tooltip draw, every icon and state class, which tooltip goes with which row, and
// how wide a row's bar is, decided here as pure functions so the St glue only assigns finished values. Nothing here
// imports Gio, GLib or Shell. A source is assumed reader-valid (see cockpitProtocol.js); a source never received is
// the glue's to draw as "no data".
import {
    APPS_CARD_ROW_LIMIT, COCKPIT_ICON_NAMES, COCKPIT_REDACTED_NAME, CONNECTIONS_CARD_ROW_LIMIT, SECONDS_PER_DAY,
    SECONDS_PER_HOUR, SECONDS_PER_MINUTE, SESSION_IDLE_DIM_SECONDS, SESSIONS_CARD_ROW_LIMIT,
} from './constants.js';
import {SESSION_STATES} from './cockpitProtocol.js';
import {noDataSinceLabel} from './cockpitStaleness.js';
import {formatGibibytes, formatWholePercent, noDataSince} from './format.js';

const MEBIBYTES_PER_GIBIBYTE = 1024;
const BYTES_PER_MEBIBYTE = 1024 * 1024;
const NO_VALUE_TEXT = COCKPIT_REDACTED_NAME;
const MEMORY_TOOLTIP_NOTE = 'memory: process only; MCP servers and tool shells not counted';
const PROCESS_AGE_MARK = '*';
const STATES_THAT_DIM_WHEN_LONG_IDLE = ['idle', 'done'];
/** A session state's word where the spec's differs from herdr's enum word; any other state reads as herdr's word. */
const SESSION_STATE_WORD_BY_STATE = Object.freeze({blocked: 'waiting on you'});
const CONNECTIVITY_UNKNOWN = 'unknown';
const SEPARATOR = ' · ';
/** NetworkManager's connectivity verdicts that reach the internet only in part: named after the link's kind. */
const PARTIAL_CONNECTIVITY_STATES = ['limited', 'portal'];
/** NetworkManager's connectivity verdicts that reach the internet, fully or in part. */
const REACHABLE_CONNECTIVITY_STATES = ['full', ...PARTIAL_CONNECTIVITY_STATES];
/** What a wired or Wi-Fi uplink says, after its kind, when NetworkManager finds no route to the internet. */
const NO_INTERNET_TEXT = 'no internet';
/** What an uplink that is neither wired nor Wi-Fi says while it reaches the internet. */
const ONLINE_TEXT = 'online';
const OFFLINE_TEXT = 'offline';
/** What the uplink row says when nothing is known of it (no NetworkManager on the system bus). */
const UPLINK_UNKNOWN_TEXT = 'uplink unknown';
/** The uplink tooltip's line for a primary connection that is neither wired nor Wi-Fi (a VPN, a tethered phone). */
const OTHER_PRIMARY_CONNECTION_NOTE = 'primary connection: neither wired nor Wi-Fi';
/** What the sessions card says when herdr is not running. */
export const herdrNotRunningText = 'herdr not running';
/** The apps card's title. */
export const appsCardTitle = 'APPS';
/** The connections card's title. */
export const connectionsCardTitle = 'CONNECTIONS';
/** The sessions card's title, which leads its header. */
export const sessionsCardTitle = 'SESSIONS';

/**
 * Formats a memory size: GiB with one decimal from what rounds to 1024 MiB up, whole MiB below.
 *
 * @param {number|null} bytes - Size in bytes.
 * @returns {string} '1.2G', '340M', or '—' when unknown; never '1024M'.
 */
function memoryText(bytes) {
    if (bytes === null)
        return NO_VALUE_TEXT;
    const roundedMebibytes = Math.round(bytes / BYTES_PER_MEBIBYTE);
    if (roundedMebibytes >= MEBIBYTES_PER_GIBIBYTE)
        return `${formatGibibytes(bytes)}G`;
    return `${roundedMebibytes}M`;
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
 * Whether a value was given at all: neither null nor undefined.
 *
 * @param {*} value - A source, or a part of one.
 * @returns {boolean} True when it is present.
 */
function isPresent(value) {
    return value !== null && value !== undefined;
}

/**
 * The line under a card's rows that says how many rows did not fit.
 *
 * @param {number} hiddenCount - Rows left out.
 * @returns {string|null} '+N more', or null when nothing was left out.
 */
function overflowLine(hiddenCount) {
    return hiddenCount > 0 ? `+${hiddenCount} more` : null;
}

/**
 * How wide a row's faint bar is drawn: its fraction of the bar's track, clamped to the track, in whole pixels.
 *
 * @param {number|null|undefined} fraction - The row's fraction, normally 0–1; null (or anything not a finite number)
 *     for a row with no bar.
 * @param {number} trackWidthPx - The track's width.
 * @returns {number} The bar's width, 0 to trackWidthPx; 0 for no bar.
 */
export function rowBarWidthPx(fraction, trackWidthPx) {
    const shownFraction = Number.isFinite(fraction) ? Math.min(1, Math.max(0, fraction)) : 0;
    return Math.round(shownFraction * trackWidthPx);
}

/**
 * Whether the apps card can draw a snapshot's apps: a snapshot from a sampler before the rankings, or none yet, has
 * none. A null ranking inside is drawn as an empty list (appsRows).
 *
 * @param {object|null|undefined} apps - A pulse snapshot's apps.
 * @returns {boolean} True unless the apps are missing.
 */
export function canDrawApps(apps) {
    return isPresent(apps);
}

/**
 * Whether the sessions card can draw a sessions source: it needs the rows and a count for every state. The reader
 * keeps a source whose part is mistyped, that part null (cockpitProtocol.js); the card draws it as no data, never as a
 * crash or a "null".
 *
 * @param {object|null|undefined} sessions - A sessions source.
 * @returns {boolean} True when sessionsHeader and sessionRows can draw it.
 */
export function canDrawSessions(sessions) {
    return isPresent(sessions) && isPresent(sessions.rows) && isPresent(sessions.counts) &&
        SESSION_STATES.every(state => isPresent(sessions.counts[state]));
}

/**
 * Whether the connections card can draw: it needs both sources, the network's uplink and VPN, and the mounts' rows.
 * An unknown ssh master count is drawn as such (connectionsRows).
 *
 * @param {object|null|undefined} network - A network source.
 * @param {object|null|undefined} mounts - A mounts source.
 * @returns {boolean} True when connectionsRows can draw them.
 */
export function canDrawConnections(network, mounts) {
    return isPresent(network) && isPresent(mounts) && isPresent(network.uplink) && isPresent(network.vpn) &&
        isPresent(mounts.rows);
}

/**
 * The header of the sessions card.
 *
 * @param {object} sessions - A sessions source.
 * @returns {{title: string, count: string, counts: Array<{state: string, count: string}>, totalMemory: string}}
 *   `counts` in SESSION_STATES order, zero counts included, each written as text; `count` is the number of rows.
 */
export function sessionsHeader(sessions) {
    return {
        title: sessionsCardTitle,
        count: String(sessions.rows.length),
        counts: SESSION_STATES.map(state => ({state, count: String(sessions.counts[state])})),
        totalMemory: memoryText(sessions.totalMemoryBytes),
    };
}

/**
 * The visible rows of the sessions card, in the order the service published them. Each row carries its state's icon
 * and class and the tooltip built from its own source row, so nothing has to pair a drawn row with a source row later.
 *
 * @param {object} sessions - A sessions source.
 * @returns {{rows: Array<{id: string, state: string, iconName: string, iconStyleClass: string, name: string,
 *   idleText: string, isLongIdle: boolean, memoryText: string, memoryFraction: number, isWaiting: boolean,
 *   tooltip: string[]}>, overflowText: string|null}} At most SESSIONS_CARD_ROW_LIMIT rows; `overflowText` is
 *   '+N more' for the rows beyond, else null.
 */
export function sessionRows(sessions) {
    const largestMemoryBytes = Math.max(0, ...sessions.rows.map(row => row.memoryBytes ?? 0));
    const rows = sessions.rows.slice(0, SESSIONS_CARD_ROW_LIMIT).map(row => ({
        id: row.id,
        state: row.state,
        iconName: stateIconName(row.state),
        iconStyleClass: stateStyleClass(row.state),
        name: row.name,
        idleText: idleText(row.idleSeconds, row.idleFromProcessAge),
        isLongIdle: row.idleSeconds !== null && row.idleSeconds >= SESSION_IDLE_DIM_SECONDS &&
            STATES_THAT_DIM_WHEN_LONG_IDLE.includes(row.state),
        memoryText: memoryText(row.memoryBytes),
        memoryFraction: shareOfLargest(row.memoryBytes, largestMemoryBytes),
        isWaiting: row.state === 'blocked',
        tooltip: sessionTooltip(row, row),
    }));
    return {rows, overflowText: overflowLine(sessions.rows.length - rows.length)};
}

/**
 * The tooltip of one session row. A detail the source does not know (a pane id too long to publish, say) gets no
 * line, never a "null".
 *
 * @param {{state: string}} row - A session row.
 * @param {{account: string|null, contextPercent: number|null, paneId: string|null}} details - What the source
 *     published.
 * @returns {string[]} The state's word (sessionStateWord), the pane, the account and context when known, and the
 *     memory caveat.
 */
export function sessionTooltip(row, {account, contextPercent, paneId}) {
    const lines = [sessionStateWord(row.state)];
    if (isPresent(paneId))
        lines.push(`pane ${paneId}`);
    if (isPresent(account))
        lines.push(`account ${account}`);
    if (isPresent(contextPercent))
        lines.push(`context ${formatWholePercent(contextPercent)}`);
    lines.push(MEMORY_TOOLTIP_NOTE);
    return lines;
}

/**
 * The rows of the apps card's two rankings. Each row carries its own entry's group key as its tooltip.
 *
 * @param {{cpuRanking: Array|null, memoryRanking: Array|null}} apps - The sampler's apps rankings.
 * @param {{limit: number}} [options] - The most rows per ranking.
 * @returns {{cpu: Array<{name: string, cpuText: string, cpuFraction: number, tooltip: string[]}>,
 *   memory: Array<{name: string, memoryText: string, memoryFraction: number, tooltip: string[]}>}} Empty lists for a
 *   null ranking.
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
            tooltip: [entry.groupKey],
        })),
        memory: memoryRanking.map(entry => ({
            name: entry.name,
            memoryText: memoryText(entry.memoryBytes),
            memoryFraction: shareOfLargest(entry.memoryBytes, largestMemoryBytes),
            tooltip: [entry.groupKey],
        })),
    };
}

/**
 * How a wired or Wi-Fi uplink looks, from its kind and NetworkManager's connectivity verdict: full (or no verdict) is
 * the kind alone, docked reading 'wired · wifi off'; limited and portal keep the kind's icon and name the verdict after
 * it; none is the offline icon and '<kind> · no internet'.
 *
 * @param {{kind: string, connectivity: string|null, wifiEnabled: boolean|null}} uplink - A wired or Wi-Fi uplink.
 * @returns {{icon: string, text: string, tooltipNote: null}} The row's icon and words; no tooltip note.
 */
function linkedUplinkLook(uplink) {
    const kindIcon = uplink.kind === 'wired' ? COCKPIT_ICON_NAMES.wired : COCKPIT_ICON_NAMES.wifi;
    if (uplink.connectivity === 'none') {
        const noInternetText = `${uplink.kind}${SEPARATOR}${NO_INTERNET_TEXT}`;
        return {icon: COCKPIT_ICON_NAMES.offline, text: noInternetText, tooltipNote: null};
    }
    if (PARTIAL_CONNECTIVITY_STATES.includes(uplink.connectivity))
        return {icon: kindIcon, text: `${uplink.kind}${SEPARATOR}${uplink.connectivity}`, tooltipNote: null};
    const isDockedWithWifiOff = uplink.kind === 'wired' && uplink.wifiEnabled === false;
    return {icon: kindIcon, text: isDockedWithWifiOff ? `wired${SEPARATOR}wifi off` : uplink.kind, tooltipNote: null};
}

/**
 * How an uplink that is neither wired nor Wi-Fi looks (kind none: a VPN on a full tunnel, a tethered phone; or a
 * kind the reader did not know): 'online' while the verdict says the internet is reachable, the part named when it is
 * limited or portal, and offline otherwise, which is a verdict of none (with no verdict, null or 'unknown', it reads
 * 'uplink unknown' before it comes here: isUplinkUnknown).
 *
 * @param {{kind: string|null, connectivity: string|null}} uplink - The uplink.
 * @returns {{icon: string, text: string, tooltipNote: string|null}} The row's icon and words, and the tooltip line
 *     that says the primary connection is neither wired nor Wi-Fi (kind none, online only).
 */
function otherUplinkLook(uplink) {
    if (!REACHABLE_CONNECTIVITY_STATES.includes(uplink.connectivity))
        return {icon: COCKPIT_ICON_NAMES.offline, text: OFFLINE_TEXT, tooltipNote: null};
    const isPartial = PARTIAL_CONNECTIVITY_STATES.includes(uplink.connectivity);
    const text = isPartial ? `${ONLINE_TEXT}${SEPARATOR}${uplink.connectivity}` : ONLINE_TEXT;
    const tooltipNote = uplink.kind === 'none' ? OTHER_PRIMARY_CONNECTION_NOTE : null;
    return {icon: COCKPIT_ICON_NAMES.online, text, tooltipNote};
}

/**
 * Whether the uplink says nothing of the internet: a primary connection neither wired nor Wi-Fi (kind none, or no
 * kind: NetworkManager absent) with no verdict from NetworkManager (connectivity null, or 'unknown': checks off or not
 * run yet). Neither names a link that is known to be down, so neither is "offline"; that word is kept for a verdict
 * of none. A wired or Wi-Fi link with no verdict reads its kind (linkedUplinkLook).
 *
 * @param {{kind: string|null, connectivity: string|null}} uplink - The uplink.
 * @returns {boolean} True when the row reads 'uplink unknown'.
 */
function isUplinkUnknown(uplink) {
    const isWiredOrWifi = uplink.kind === 'wired' || uplink.kind === 'wifi';
    const hasNoVerdict = uplink.connectivity === null || uplink.connectivity === CONNECTIVITY_UNKNOWN;
    return !isWiredOrWifi && hasNoVerdict;
}

/**
 * The uplink row: what kind of link it is and whether the internet is reachable over it (linkedUplinkLook,
 * otherUplinkLook), or 'uplink unknown' when it says nothing of the internet (isUplinkUnknown); NetworkManager's
 * verdict in the tooltip.
 *
 * @param {{kind: string|null, connectivity: string|null, wifiEnabled: boolean|null}} uplink - The uplink.
 * @returns {object} A connections row of kind 'uplink'.
 */
function uplinkRow(uplink) {
    const connectivityWord = uplink.connectivity ?? CONNECTIVITY_UNKNOWN;
    const tooltip = [`internet: ${connectivityWord}`];
    if (isUplinkUnknown(uplink)) {
        return {
            kind: 'uplink', icon: COCKPIT_ICON_NAMES.unknown, text: UPLINK_UNKNOWN_TEXT, tooltip, fraction: null,
            iconStyleClass: null,
        };
    }
    const isWiredOrWifi = uplink.kind === 'wired' || uplink.kind === 'wifi';
    const {icon, text, tooltipNote} = isWiredOrWifi ? linkedUplinkLook(uplink) : otherUplinkLook(uplink);
    if (tooltipNote !== null)
        tooltip.push(tooltipNote);
    return {kind: 'uplink', icon, text, tooltip, fraction: null, iconStyleClass: null};
}

/**
 * The VPN row. Its icon carries a state's class, so up and down differ by more than their words: the working state's
 * while the tunnel is up, the idle state's while it is down or unknown.
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
    const iconStyleClass = stateStyleClass(vpn.isUp === true ? 'working' : 'idle');
    return {kind: 'vpn', icon: COCKPIT_ICON_NAMES.vpn, text, tooltip: [text], fraction: null, iconStyleClass};
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
    return {kind: 'ssh', icon: COCKPIT_ICON_NAMES.ssh, text, tooltip: [text], fraction: null, iconStyleClass: null};
}

/**
 * One mount's row: label and free space, the used share as its fraction. The tooltip gives the mount point, the
 * filesystem type when known, and the sizes when known.
 *
 * @param {object} mount - A mount row of a mounts source.
 * @returns {object} A connections row of kind 'mount'.
 */
function mountRow(mount) {
    const areSizesKnown = mount.freeBytes !== null && mount.totalBytes !== null && mount.totalBytes > 0;
    const freeText = mount.freeBytes === null ? null : `${formatGibibytes(mount.freeBytes)}G`;
    const tooltip = [mount.mountPoint];
    if (isPresent(mount.filesystemType))
        tooltip.push(mount.filesystemType);
    if (areSizesKnown)
        tooltip.push(`${freeText} free of ${formatGibibytes(mount.totalBytes)}G`);
    return {
        kind: 'mount',
        icon: mount.kind === 'network' ? COCKPIT_ICON_NAMES.mountNetwork : COCKPIT_ICON_NAMES.mountRemovable,
        text: freeText === null ? mount.label : `${mount.label}${SEPARATOR}${freeText} free`,
        tooltip,
        fraction: areSizesKnown ? (mount.totalBytes - mount.freeBytes) / mount.totalBytes : null,
        iconStyleClass: null,
    };
}

/**
 * The visible rows of the connections card: uplink, VPN, ssh masters, then the mounts as published, at most `limit`
 * rows. The first three always come first, so only mounts are ever left out, and `overflowText` says how many.
 *
 * @param {object} network - A network source.
 * @param {object} mounts - A mounts source.
 * @param {{limit: number}} [options] - The most rows the card draws.
 * @returns {{rows: Array<{kind: string, icon: string, text: string, tooltip: string[], fraction: number|null,
 *   iconStyleClass: string|null}>, overflowText: string|null}} The rows, each with the state class its icon carries
 *   (the VPN row's; null for the others); `overflowText` is '+N more' for the rows beyond, else null.
 */
export function connectionsRows(network, mounts, {limit = CONNECTIONS_CARD_ROW_LIMIT} = {}) {
    const allRows = [
        uplinkRow(network.uplink),
        vpnRow(network.vpn),
        sshRow(network.sshMasterCount),
        ...mounts.rows.map(mountRow),
    ];
    const rows = allRows.slice(0, limit);
    return {rows, overflowText: overflowLine(allRows.length - rows.length)};
}

/**
 * What the apps card says with no apps to draw: the system card's words (lib/format.js), from the same clock label,
 * the pulse client's last snapshot with data, so the two cards side by side agree.
 *
 * @param {string|null} lastGoodClockLabel - 'HH:MM' of the last snapshot with data, or null before any.
 * @returns {string} 'no data since HH:MM', or 'no data'.
 */
export function appsNoDataText(lastGoodClockLabel) {
    return noDataSince(lastGoodClockLabel);
}

/**
 * The clock label the apps card names when it has no apps, under the system card's own condition (lib/format.js
 * cardText): the pulse client's last good label while the sampler's snapshot carries neither CPU nor memory (no
 * snapshot yet, or the client no longer live), when the system card says "no data since" too; null while it carries
 * numbers, so apps missing from a live snapshot (before the sampler's first scan, or after a scan that threw) read
 * the bare "no data", not "no data since" the current minute.
 *
 * @param {{cpuBusyPercent: number|null, memory: object|null}|null} snapshot - The pulse client's latest snapshot.
 * @param {string|null} lastGoodClockLabel - 'HH:MM' of the client's last snapshot with data, or null before any.
 * @returns {string|null} The label to pass to appsNoDataText, or null for the bare "no data".
 */
export function appsNoDataSinceClockLabel(snapshot, lastGoodClockLabel) {
    const isSnapshotLive = (snapshot?.cpuBusyPercent ?? null) !== null || (snapshot?.memory ?? null) !== null;
    return isSnapshotLive ? null : lastGoodClockLabel;
}

/**
 * A group's caption as the grid draws it: upper-cased in code, since St reads no CSS text-transform.
 *
 * @param {string} caption - The layout's caption, in any case.
 * @returns {string} The caption upper-cased.
 */
export function cockpitCaptionText(caption) {
    return caption.toUpperCase();
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
 * The word a session state is told by: the spec's where it has one ('waiting on you' for blocked), herdr's otherwise.
 *
 * @param {string} state - One of SESSION_STATES.
 * @returns {string} The word, as a tooltip's first line.
 */
export function sessionStateWord(state) {
    return SESSION_STATE_WORD_BY_STATE[state] ?? state;
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
