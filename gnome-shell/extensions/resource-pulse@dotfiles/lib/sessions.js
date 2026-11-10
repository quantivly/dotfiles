// The sessions source, pure: turns herdr's agent snapshot, the hspawn registry entries, transcript mtimes and process
// facts (all read by the IO layer, service/cockpit.js) into the object parseSessionsSource in lib/cockpitProtocol.js
// rebuilds. No Gio, no GLib and no Shell import, so it runs under plain gjs.
//
// Names, ids and the mangling of a transcript path mirror `hreap` in zsh/zshrc.herdr; the sidebar tokens `acct` and
// `ctx_ok` / `ctx_warn` / `ctx_crit` are the ones claude/hooks/session-statusline.sh publishes.
import {guardDisplayName} from './nameGuard.js';
import {COCKPIT_REDACTED_NAME, MICROSECONDS_PER_SECOND} from './constants.js';
import {SESSION_STATES} from './cockpitProtocol.js';
import {isPlainObject, nonNegativeNumberOrNull, stringOrNull} from './jsonFields.js';

/** The `agent` value of the herdr snapshot entries that are Claude Code sessions. */
const CLAUDE_AGENT_NAME = 'claude';
/** The sidebar token carrying the account a session bills. */
const ACCOUNT_TOKEN_NAME = 'acct';
/** The sidebar tokens carrying the context usage, one per severity band; a session has at most one. */
const CONTEXT_TOKEN_NAMES = ['ctx_ok', 'ctx_warn', 'ctx_crit'];
/** The number in a context token's value, as the hook formats it: a bar glyph, a space and "62%". */
const CONTEXT_PERCENT_PATTERN = /(\d+(?:\.\d+)?)\s*%/;
/** Matches every `/` and `.` of a cwd, which Claude Code turns into `-` in its project directory name. */
const PROJECT_DIRECTORY_MANGLE_PATTERN = /[/.]/g;
/** Where Claude Code keeps session transcripts, under the home directory. */
const CLAUDE_PROJECTS_RELATIVE_PATH = '.claude/projects';
/** Where clauth keeps per-profile runtime directories (each holds its own `projects/`), under the home directory. */
const CLAUTH_PROFILES_RELATIVE_PATH = '.clauth/profiles';
/** The VmRSS line of /proc/<pid>/status. */
const VM_RSS_PATTERN = /^VmRSS:\s+(\d+)\s*kB\s*$/m;
/** The VmSwap line of /proc/<pid>/status. */
const VM_SWAP_PATTERN = /^VmSwap:\s+(\d+)\s*kB\s*$/m;
/** /proc/<pid>/status counts memory in kibibytes. */
const BYTES_PER_KIB = 1024;

/**
 * @param {*} agentStatus - The `agent_status` of a herdr snapshot agent; absent for an agent herdr has not classified.
 * @returns {string} The status itself when it is one of working, blocked, idle or done; otherwise 'unknown'.
 */
export function sessionStateFromAgentStatus(agentStatus) {
    const isKnownState = SESSION_STATES.includes(agentStatus) && agentStatus !== 'unknown';
    return isKnownState ? agentStatus : 'unknown';
}

/**
 * The name a session row shows: the first of the registry's slug, its branch, the workspace label and the last path
 * segment of the cwd that is a non-empty string, through guardDisplayName.
 *
 * @param {object} names - What can name the session.
 * @param {object|null} names.registryEntry - The session's hspawn registry entry (`slug`, `branch`); null when it was
 *     not spawned by hspawn.
 * @param {string|null} names.workspaceLabel - The label of the session's herdr workspace.
 * @param {string|null} names.cwd - The session's working directory.
 * @returns {string} The guarded name; COCKPIT_REDACTED_NAME when nothing names the session or the pick is rejected.
 */
export function displayNameForSession({registryEntry, workspaceLabel, cwd}) {
    const registryFields = isPlainObject(registryEntry) ? registryEntry : {};
    const candidates = [registryFields.slug, registryFields.branch, workspaceLabel, lastPathSegment(cwd)];
    const chosenName = candidates.find(candidate => typeof candidate === 'string' && candidate !== '');
    return chosenName === undefined ? COCKPIT_REDACTED_NAME : guardDisplayName(chosenName);
}

/**
 * How long a session has been idle: the age of its transcript (Claude appends to it while it works), else the age of
 * its process, which is an upper bound and so flagged.
 *
 * @param {object} times - What is known about the session's activity.
 * @param {number|null} times.transcriptMtimeUsec - The transcript's modification time, in microseconds since the
 *     epoch; null when no transcript was found.
 * @param {number|null} times.processStartedAtUsec - When the session's process started, in microseconds since the
 *     epoch; null when unknown.
 * @param {number} times.nowUsec - The current time, in microseconds since the epoch.
 * @returns {{idleSeconds: number|null, idleFromProcessAge: boolean}} Whole seconds, rounded down and at least 0;
 *     null seconds (and false) when neither time is known.
 */
export function idleAgeForSession({transcriptMtimeUsec, processStartedAtUsec, nowUsec}) {
    if (Number.isFinite(transcriptMtimeUsec))
        return {idleSeconds: secondsSince(transcriptMtimeUsec, nowUsec), idleFromProcessAge: false};
    if (Number.isFinite(processStartedAtUsec))
        return {idleSeconds: secondsSince(processStartedAtUsec, nowUsec), idleFromProcessAge: true};
    return {idleSeconds: null, idleFromProcessAge: false};
}

/**
 * Where a session's transcript may be. The IO layer checks the first entry, then searches under the two roots as
 * hreap does: every project directory of `.claude/projects`, and the `runtime-*` directories' `projects` of every
 * profile under `.clauth/profiles`, for `<sessionId>.jsonl`.
 *
 * @param {object} session - The session.
 * @param {string|null} session.cwd - The session's working directory.
 * @param {string|null} session.sessionId - The Claude session id.
 * @param {string} session.homeDirectory - The user's home directory.
 * @returns {string[]} The exact path (the cwd with every `/` and `.` replaced by `-` names the project directory),
 *     then `<home>/.claude/projects`, then `<home>/.clauth/profiles`; an empty list without a cwd or session id.
 */
export function transcriptPathCandidates({cwd, sessionId, homeDirectory}) {
    if (!cwd || !sessionId)
        return [];
    const claudeProjectsRoot = `${homeDirectory}/${CLAUDE_PROJECTS_RELATIVE_PATH}`;
    const projectDirectoryName = cwd.replace(PROJECT_DIRECTORY_MANGLE_PATTERN, '-');
    return [
        `${claudeProjectsRoot}/${projectDirectoryName}/${sessionId}.jsonl`,
        claudeProjectsRoot,
        `${homeDirectory}/${CLAUTH_PROFILES_RELATIVE_PATH}`,
    ];
}

/**
 * @param {string} text - The text of /proc/<pid>/status.
 * @returns {number|null} VmRSS plus VmSwap (when present), in bytes; null when VmRSS is absent.
 */
export function memoryBytesFromProcStatus(text) {
    const residentKib = kibFromStatusLine(text, VM_RSS_PATTERN);
    if (residentKib === null)
        return null;
    return (residentKib + (kibFromStatusLine(text, VM_SWAP_PATTERN) ?? 0)) * BYTES_PER_KIB;
}

/**
 * Reads the workspace labels out of herdr's snapshot, keyed as herdr keys them: by `workspace_id`.
 *
 * @param {*} snapshot - herdr's snapshot (the `snapshot` of session.snapshot's result).
 * @returns {Object<string, string>} Each workspace's label by its `workspace_id`; a workspace without both is left
 *     out, and a snapshot without a `workspaces` list gives none.
 */
export function workspaceLabelsByIdFromSnapshot(snapshot) {
    const workspaces = isPlainObject(snapshot) && Array.isArray(snapshot.workspaces) ? snapshot.workspaces : [];
    const workspaceLabelsById = {};
    workspaces.filter(isPlainObject).forEach(workspace => {
        const workspaceId = stringOrNull(workspace.workspace_id);
        const label = stringOrNull(workspace.label);
        if (workspaceId !== null && label !== null)
            workspaceLabelsById[workspaceId] = label;
    });
    return workspaceLabelsById;
}

/**
 * Builds the sessions source, in the shape parseSessionsSource reads back.
 *
 * @param {object} inputs - Everything the IO layer gathered.
 * @param {Array<object>} inputs.agents - The `agents` of herdr's snapshot; those whose `agent` is not 'claude' are
 *     skipped.
 * @param {Object<string, object>} inputs.registryEntriesByPaneId - hspawn registry entries by `pane_id`.
 * @param {Object<string, string>} inputs.workspaceLabelsById - herdr workspace labels by workspace id.
 * @param {Object<string, number|null>} inputs.transcriptMtimeUsecBySessionId - Transcript modification times by
 *     session id, in microseconds; a session with no transcript is missing or null.
 * @param {Object<string, {pid: number|null, startedAtUsec: number|null}>} inputs.processInfoByPaneId - The pane's
 *     Claude process, from herdr's `pane.process_info` reply: its pid and start time in microseconds since the epoch.
 * @param {Object<string, number|null>} inputs.memoryBytesByPaneId - The pane's Claude process memory in bytes; a
 *     process that vanished is missing or null.
 * @param {number} inputs.nowUsec - The current time, in microseconds since the epoch.
 * @param {number} inputs.sampledAtUsec - Copied into the source (the scheduler overwrites it).
 * @param {number} inputs.intervalSeconds - Copied into the source (the scheduler overwrites it).
 * @param {boolean} inputs.herdrRunning - Whether herdr answered.
 * @returns {object} `{sampledAtUsec, intervalSeconds, herdrRunning, totalMemoryBytes, counts, rows}`: one row per
 *     claude agent, largest memory first (unknown memory last, ties by name); `counts` per SESSION_STATES entry;
 *     `totalMemoryBytes` the sum of the known memory.
 */
export function buildSessionsSource(inputs) {
    const {agents, sampledAtUsec, intervalSeconds, herdrRunning} = inputs;
    const rows = agents
        .filter(agent => isPlainObject(agent) && agent.agent === CLAUDE_AGENT_NAME)
        .map(agent => buildSessionRow(agent, inputs))
        .sort(compareRowsByMemoryThenName);
    const knownMemoryBytes = rows.map(row => row.memoryBytes).filter(memoryBytes => memoryBytes !== null);
    return {
        sampledAtUsec,
        intervalSeconds,
        herdrRunning,
        totalMemoryBytes: knownMemoryBytes.reduce((sum, memoryBytes) => sum + memoryBytes, 0),
        counts: Object.fromEntries(SESSION_STATES.map(state => [state, rows.filter(row => row.state === state).length])),
        rows,
    };
}

/**
 * @param {object} agent - One claude agent of herdr's snapshot.
 * @param {object} inputs - The inputs of buildSessionsSource.
 * @returns {object} The agent's row.
 */
function buildSessionRow(agent, inputs) {
    const workspaceId = stringOrNull(agent.workspace_id);
    const paneId = stringOrNull(agent.pane_id);
    const sessionId = isPlainObject(agent.agent_session) ? stringOrNull(agent.agent_session.value) : null;
    const processInfo = ownValue(inputs.processInfoByPaneId, paneId);
    const idleAge = idleAgeForSession({
        transcriptMtimeUsec: ownValue(inputs.transcriptMtimeUsecBySessionId, sessionId) ?? null,
        processStartedAtUsec: isPlainObject(processInfo) ? processInfo.startedAtUsec ?? null : null,
        nowUsec: inputs.nowUsec,
    });
    return {
        id: sessionRowId(workspaceId, paneId, sessionId),
        name: displayNameForSession({
            registryEntry: ownValue(inputs.registryEntriesByPaneId, paneId) ?? null,
            workspaceLabel: ownValue(inputs.workspaceLabelsById, workspaceId) ?? null,
            cwd: stringOrNull(agent.cwd),
        }),
        state: sessionStateFromAgentStatus(agent.agent_status),
        idleSeconds: idleAge.idleSeconds,
        idleFromProcessAge: idleAge.idleFromProcessAge,
        memoryBytes: nonNegativeNumberOrNull(ownValue(inputs.memoryBytesByPaneId, paneId)),
        workspaceId,
        paneId,
        account: accountFromTokens(agent.tokens),
        contextPercent: contextPercentFromTokens(agent.tokens),
    };
}

/**
 * @param {string|null} workspaceId - The herdr workspace id.
 * @param {string|null} paneId - The herdr pane id.
 * @param {string|null} sessionId - The Claude session id.
 * @returns {string} `<workspaceId>:<paneId>`; the pane id alone without a workspace id; the session id without
 *     either; an empty string when none is known (parseSessionsSource then drops the row).
 */
function sessionRowId(workspaceId, paneId, sessionId) {
    if (paneId === null)
        return sessionId ?? '';
    return workspaceId === null ? paneId : `${workspaceId}:${paneId}`;
}

/**
 * @param {*} tokens - A snapshot agent's sidebar tokens (token name to value).
 * @param {string} tokenName - The token to read.
 * @returns {string|null} The token's value; null when absent or not text.
 */
function tokenText(tokens, tokenName) {
    return isPlainObject(tokens) ? stringOrNull(tokens[tokenName]) : null;
}

/**
 * @param {*} tokens - A snapshot agent's sidebar tokens.
 * @returns {string|null} The `acct` token through guardDisplayName; null when the agent has none.
 */
function accountFromTokens(tokens) {
    const account = tokenText(tokens, ACCOUNT_TOKEN_NAME);
    return account === null ? null : guardDisplayName(account);
}

/**
 * @param {*} tokens - A snapshot agent's sidebar tokens.
 * @returns {number|null} The percent in whichever `ctx_*` token is present, as the hook formats it ("▅ 62%"); null
 *     when none is present or its value holds no percent.
 */
function contextPercentFromTokens(tokens) {
    for (const tokenName of CONTEXT_TOKEN_NAMES) {
        const match = CONTEXT_PERCENT_PATTERN.exec(tokenText(tokens, tokenName) ?? '');
        if (match !== null)
            return Number(match[1]);
    }
    return null;
}

/**
 * @param {object} row - A session row.
 * @param {object} otherRow - Another session row.
 * @returns {number} Negative when `row` sorts first: more memory first, unknown memory last, ties by name.
 */
function compareRowsByMemoryThenName(row, otherRow) {
    const hasMemory = row.memoryBytes !== null;
    const otherHasMemory = otherRow.memoryBytes !== null;
    if (hasMemory !== otherHasMemory)
        return hasMemory ? -1 : 1;
    if (hasMemory && row.memoryBytes !== otherRow.memoryBytes)
        return otherRow.memoryBytes - row.memoryBytes;
    if (row.name === otherRow.name)
        return 0;
    return row.name < otherRow.name ? -1 : 1;
}

/**
 * @param {*} lookup - An object used as a map.
 * @param {string|null} key - The key to read.
 * @returns {*} The lookup's own value for the key; undefined when the key is null, or not an own key.
 */
function ownValue(lookup, key) {
    return key !== null && isPlainObject(lookup) && Object.hasOwn(lookup, key) ? lookup[key] : undefined;
}

/**
 * @param {*} path - A path.
 * @returns {string|null} The last non-empty segment of the path; null when it is not a path with one.
 */
function lastPathSegment(path) {
    if (typeof path !== 'string')
        return null;
    return path.split('/').filter(segment => segment !== '').pop() ?? null;
}

/**
 * @param {number} sinceUsec - A past time, in microseconds since the epoch.
 * @param {number} nowUsec - The current time, in the same unit.
 * @returns {number} Whole seconds from then to now, rounded down; 0 for a time in the future.
 */
function secondsSince(sinceUsec, nowUsec) {
    return Math.max(0, Math.floor((nowUsec - sinceUsec) / MICROSECONDS_PER_SECOND));
}

/**
 * @param {string} text - The text of /proc/<pid>/status.
 * @param {RegExp} linePattern - A pattern whose first group is a count of kibibytes.
 * @returns {number|null} The count; null when the line is absent.
 */
function kibFromStatusLine(text, linePattern) {
    const match = linePattern.exec(typeof text === 'string' ? text : '');
    return match === null ? null : Number(match[1]);
}
