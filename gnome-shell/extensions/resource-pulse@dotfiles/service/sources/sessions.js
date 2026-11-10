// The sessions source's IO: herdr's snapshot and each claude pane's process, the hspawn registry, transcript mtimes
// and /proc, gathered for lib/sessions.js's buildSessionsSource. Every read is injectable; the defaults are the real
// ones (service/sources/sourceIo.js and service/herdrSocket.js).
//
// One sample: a `session.snapshot` request; the registry directory listed once and its `*.json` files read; then, one
// claude agent at a time (so herdr is asked one thing at a time), a `pane.process_info` request, the transcript
// stat'ed (the exact path first, then the two search roots, each directory listed at most once per sample), and
// /proc/<pid>/status read for the pane's claude process. The process start time, the idle age's fallback when no
// transcript is found, comes from /proc/<pid>/stat's starttime and /proc/stat's btime: herdr's process_info carries
// no start time.
//
// Which foreground process is the session follows `hreap` (zsh/zshrc.herdr): argv[0] (else argv0, else the name)
// whose basename is `claude` or which is a path under `/claude/versions/` (the versioned binary teammates run), or a
// process named `claude`. Its cwd, when herdr gives one, names the transcript's project directory, as in hreap.
import GLib from 'gi://GLib';

import {COCKPIT_LOG_PREFIX, HERDR_REQUEST_TIMEOUT_MS} from '../../lib/constants.js';
import {RateLimitedLogger, describeError} from '../../lib/errorLog.js';
import {isPlainObject, stringOrNull} from '../../lib/jsonFields.js';
import {buildSessionsSource, memoryBytesFromProcStatus, transcriptPathCandidates} from '../../lib/sessions.js';
import {SESSION_STATES} from '../../lib/cockpitProtocol.js';
import {HERDR_ERROR_CODES, HerdrSocketClient, herdrSocketPath} from '../herdrSocket.js';
import {isNotFoundError, listEntryNames, modificationTimeUsecOrNull, readFileRefusingSecrets} from './sourceIo.js';

/** The source's name, as COCKPIT_SOURCE_NAMES lists it. */
const SOURCE_NAME = 'sessions';
const SNAPSHOT_METHOD = 'session.snapshot';
const PROCESS_INFO_METHOD = 'pane.process_info';
/** The `agent` of the snapshot agents that are Claude Code sessions. */
const CLAUDE_AGENT_NAME = 'claude';
/** The basename of Claude Code's launcher, and the name herdr reports for it. */
const CLAUDE_PROCESS_NAME = 'claude';
/** Part of the path of the versioned binary Claude Code runs teammates as (its process name is the bare version). */
const CLAUDE_VERSIONED_BINARY_PATH_FRAGMENT = '/claude/versions/';
/** herdr rejections that mean herdr is not running: no socket at all, or nothing answering on it. */
const HERDR_NOT_RUNNING_CODES = [HERDR_ERROR_CODES.NO_SOCKET, HERDR_ERROR_CODES.CONNECT_REFUSED];
/** The hspawn registry's directory under the user's state home (XDG_STATE_HOME): one `<name>.json` per pane. */
const HSPAWN_REGISTRY_DIRECTORY_NAME = 'hspawn';
const REGISTRY_FILE_SUFFIX = '.json';
/** Under a clauth profile, the directories whose `projects` hold transcripts start with this. */
const CLAUTH_RUNTIME_DIRECTORY_PREFIX = 'runtime-';
/** Under a clauth runtime directory, where its project directories are. */
const CLAUTH_RUNTIME_PROJECTS_DIRECTORY_NAME = 'projects';
const TRANSCRIPT_FILE_SUFFIX = '.jsonl';
const PROC_ROOT = '/proc';
/** /proc/stat: its btime line is the boot time, in seconds since the epoch. */
const PROC_STAT_PATH = '/proc/stat';
const PROC_PID_STATUS_FILE_NAME = 'status';
const PROC_PID_STAT_FILE_NAME = 'stat';
const BOOT_TIME_PATTERN = /^btime\s+(\d+)\s*$/m;
/**
 * In /proc/<pid>/stat, the fields after the command's closing parenthesis start at field 3 (state); starttime is
 * field 22, so index 19 among them. The command can hold spaces and parentheses, so the fields are split after the
 * LAST closing parenthesis.
 */
const START_TIME_INDEX_AFTER_COMMAND = 19;
const PROC_PID_STAT_FIELD_SEPARATOR = /\s+/;
/** The clock ticks per second of /proc/<pid>/stat's starttime: USER_HZ, 100 on every Linux this runs on. */
const CLOCK_TICKS_PER_SECOND = 100;
const MICROSECONDS_PER_SECOND = 1e6;
/** buildSessionsSource's interval input: the scheduler stamps the effective interval over it (ruling R2). */
const PLACEHOLDER_INTERVAL_SECONDS = 0;
/** Template keys of this source's log lines, so each logs once per ERROR_LOG_REPEAT_INTERVAL_USEC whatever its text. */
const CONNECT_REFUSED_LOG_KEY = 'sessions: herdr: connect-refused';
const REGISTRY_FILE_LOG_KEY = 'sessions: registry file';
const REGISTRY_DIRECTORY_LOG_KEY = 'sessions: registry directory';

/**
 * @param {Array<object>} foregroundProcesses - process_info's `foreground_processes`.
 * @returns {object|null} The first entry that is the Claude session's process by hreap's rule; null when none is.
 */
function claudeProcessAmong(foregroundProcesses) {
    if (!Array.isArray(foregroundProcesses))
        return null;
    return foregroundProcesses.find(process => {
        if (!isPlainObject(process))
            return false;
        const argv0 = stringOrNull(Array.isArray(process.argv) ? process.argv[0] : null) ??
            stringOrNull(process.argv0) ?? stringOrNull(process.name) ?? '';
        const argv0Basename = argv0.split('/').pop();
        return argv0Basename === CLAUDE_PROCESS_NAME || argv0.includes(CLAUDE_VERSIONED_BINARY_PATH_FRAGMENT) ||
            process.name === CLAUDE_PROCESS_NAME;
    }) ?? null;
}

/**
 * @param {*} pid - A process_info entry's pid.
 * @returns {boolean} Whether it is a pid: a positive integer.
 */
function isPid(pid) {
    return Number.isInteger(pid) && pid > 0;
}

/**
 * @param {number} pid - A pid.
 * @param {string} fileName - A file under /proc/<pid>/.
 * @returns {string} Its path.
 */
function procPidPath(pid, fileName) {
    return `${PROC_ROOT}/${pid}/${fileName}`;
}

/**
 * @param {string} procStatText - The text of /proc/stat.
 * @returns {number|null} The boot time in seconds since the epoch; null when the btime line is missing.
 */
function bootTimeSecondsFrom(procStatText) {
    const match = BOOT_TIME_PATTERN.exec(procStatText);
    return match === null ? null : Number(match[1]);
}

/**
 * @param {string} pidStatText - The text of /proc/<pid>/stat.
 * @returns {number|null} The process's starttime in clock ticks after boot; null when the line is not that shape.
 */
function startTimeTicksFrom(pidStatText) {
    const commandEndIndex = pidStatText.lastIndexOf(')');
    if (commandEndIndex < 0)
        return null;
    const fieldsAfterCommand = pidStatText.slice(commandEndIndex + 1).trim().split(PROC_PID_STAT_FIELD_SEPARATOR);
    const startTimeTicks = Number(fieldsAfterCommand[START_TIME_INDEX_AFTER_COMMAND]);
    return Number.isSafeInteger(startTimeTicks) && startTimeTicks >= 0 ? startTimeTicks : null;
}

/** The sessions source: the Claude sessions herdr runs, as lib/sessions.js builds them. */
export class SessionsSource {
    /**
     * @param {object} [dependencies] - The IO; each defaults to the real one.
     * @param {string} [dependencies.configHome] - The user's config home, where herdr's socket is.
     * @param {string} [dependencies.stateHome] - The user's state home, where the hspawn registry is.
     * @param {string} [dependencies.homeDirectory] - The user's home, under which the transcripts are.
     * @param {{request: (method: string, params?: object) => Promise<object>}} [dependencies.herdrClient] - herdr's
     *     API; rejections carry a HERDR_ERROR_CODES `code`.
     * @param {(path: string) => string} [dependencies.readFile] - Reads a file; throws when it cannot.
     * @param {(path: string) => (number|null)} [dependencies.statFile] - A file's modification time in microseconds
     *     since the epoch; null when it does not exist.
     * @param {(path: string) => string[]} [dependencies.listDirectory] - A directory's entry names; throws when it
     *     cannot list it.
     * @param {() => number} [dependencies.nowUsec] - Wall-clock microseconds since the epoch (transcript mtimes are).
     * @param {(line: string) => void} [dependencies.logWriter] - Where this source's own journal lines go.
     */
    constructor({
        configHome = GLib.get_user_config_dir(),
        stateHome = GLib.get_user_state_dir(),
        homeDirectory = GLib.get_home_dir(),
        herdrClient = new HerdrSocketClient({
            socketPath: herdrSocketPath(configHome), timeoutMs: HERDR_REQUEST_TIMEOUT_MS,
        }),
        readFile = readFileRefusingSecrets,
        statFile = modificationTimeUsecOrNull,
        listDirectory = listEntryNames,
        nowUsec = () => GLib.get_real_time(),
        logWriter = line => console.warn(line),
    } = {}) {
        this._registryDirectory = `${stateHome}/${HSPAWN_REGISTRY_DIRECTORY_NAME}`;
        this._homeDirectory = homeDirectory;
        this._herdrClient = herdrClient;
        this._readFile = readFile;
        this._statFile = statFile;
        this._listDirectory = listDirectory;
        this._nowUsec = nowUsec;
        this._errorLog = new RateLimitedLogger({nowUsec, write: logWriter, prefix: COCKPIT_LOG_PREFIX});
    }

    /** @returns {string} 'sessions'. */
    get name() {
        return SOURCE_NAME;
    }

    /**
     * Samples the sessions. herdr not running (no socket, or a refused connection) is not a failure: it resolves a
     * source with herdrRunning false and no rows, and a refused connection is logged (rate-limited), since a herdr
     * that crashed leaves its socket behind.
     *
     * @returns {Promise<object>} The source in parseSessionsSource's shape; sampledAtUsec and intervalSeconds are
     *     placeholders the scheduler overwrites.
     * @throws {Error} (as a rejection) Any other herdr failure of the snapshot or a process_info request (timeout,
     *     malformed reply, closed client); a `pane.process_info` remote error (the pane closed meanwhile) only drops
     *     that pane's process facts.
     */
    async sample() {
        const nowUsec = this._nowUsec();
        let snapshot;
        try {
            ({snapshot} = await this._herdrClient.request(SNAPSHOT_METHOD, {}));
        } catch (error) {
            if (!HERDR_NOT_RUNNING_CODES.includes(error?.code))
                throw error;
            if (error.code === HERDR_ERROR_CODES.CONNECT_REFUSED) {
                this._errorLog.log(`sessions: herdr: connect-refused, read as not running: ${describeError(error)}`,
                    CONNECT_REFUSED_LOG_KEY);
            }
            return this._herdrNotRunningSource(nowUsec);
        }
        const agents = isPlainObject(snapshot) && Array.isArray(snapshot.agents) ? snapshot.agents : [];
        const claudeAgents = agents.filter(agent => isPlainObject(agent) && agent.agent === CLAUDE_AGENT_NAME);
        const sampleFacts = await this._gatherSessionFacts(claudeAgents);
        return buildSessionsSource({
            agents,
            registryEntriesByPaneId: this._readRegistryEntriesByPaneId(),
            workspaceLabelsById: workspaceLabelsByIdFrom(snapshot),
            ...sampleFacts,
            nowUsec,
            sampledAtUsec: nowUsec,
            intervalSeconds: PLACEHOLDER_INTERVAL_SECONDS,
            herdrRunning: true,
        });
    }

    /**
     * The sessions source has no signal of its own in stage one: its cadence alone drives it.
     *
     * @param {() => void} _onChange - Unused.
     * @returns {void}
     */
    watchChanges(_onChange) {}

    /**
     * Closes the herdr client, abandoning any request in flight.
     *
     * @returns {void}
     */
    destroy() {
        this._herdrClient.close?.();
    }

    /**
     * @param {number} nowUsec - When the sample started.
     * @returns {object} The source while herdr is not running: no rows, every count 0, total memory unknown.
     */
    _herdrNotRunningSource(nowUsec) {
        return {
            sampledAtUsec: nowUsec,
            intervalSeconds: PLACEHOLDER_INTERVAL_SECONDS,
            herdrRunning: false,
            totalMemoryBytes: null,
            counts: Object.fromEntries(SESSION_STATES.map(state => [state, 0])),
            rows: [],
        };
    }

    /**
     * Asks herdr for each claude pane's processes, one pane at a time, and reads the rest of each session's facts.
     *
     * @param {Array<object>} claudeAgents - The snapshot's claude agents.
     * @returns {Promise<object>} `{transcriptMtimeUsecBySessionId, processInfoByPaneId, memoryBytesByPaneId}`, as
     *     buildSessionsSource takes them.
     * @throws {Error} (as a rejection) A herdr failure other than a remote error.
     */
    async _gatherSessionFacts(claudeAgents) {
        const listingsByPath = new Map();
        const listOncePerSample = directoryPath => this._listDirectoryOnce(directoryPath, listingsByPath);
        const bootTime = {seconds: undefined};
        const transcriptMtimeUsecBySessionId = {};
        const processInfoByPaneId = {};
        const memoryBytesByPaneId = {};
        for (const agent of claudeAgents) {
            const paneId = stringOrNull(agent.pane_id);
            const sessionId = isPlainObject(agent.agent_session) ? stringOrNull(agent.agent_session.value) : null;
            // Awaited inside the loop on purpose: herdr is asked one thing at a time.
            const claudeProcess = paneId === null ? null : await this._requestClaudeProcess(paneId);
            const claudePid = isPid(claudeProcess?.pid) ? claudeProcess.pid : null;
            const cwd = stringOrNull(claudeProcess?.cwd) ?? stringOrNull(agent.cwd);
            const transcriptMtimeUsec = this._findTranscriptMtimeUsec({cwd, sessionId}, listOncePerSample);
            if (sessionId !== null)
                transcriptMtimeUsecBySessionId[sessionId] = transcriptMtimeUsec;
            if (paneId === null)
                continue;
            // The start time is only the idle age's fallback, so it is read only when no transcript was found.
            const startedAtUsec = claudePid !== null && transcriptMtimeUsec === null
                ? this._processStartedAtUsec(claudePid, bootTime) : null;
            processInfoByPaneId[paneId] = {pid: claudePid, startedAtUsec};
            memoryBytesByPaneId[paneId] = claudePid === null ? null : this._processMemoryBytes(claudePid);
        }
        return {transcriptMtimeUsecBySessionId, processInfoByPaneId, memoryBytesByPaneId};
    }

    /**
     * @param {string} paneId - A herdr pane.
     * @returns {Promise<object|null>} The pane's Claude process (a process_info foreground entry); null when herdr
     *     knows no such pane any more or none of its foreground processes is Claude.
     * @throws {Error} (as a rejection) A herdr failure other than a remote error.
     */
    async _requestClaudeProcess(paneId) {
        let processInfoResult;
        try {
            processInfoResult = await this._herdrClient.request(PROCESS_INFO_METHOD, {pane_id: paneId});
        } catch (error) {
            if (error?.code === HERDR_ERROR_CODES.REMOTE_ERROR)
                return null;
            throw error;
        }
        const processInfo = isPlainObject(processInfoResult) ? processInfoResult.process_info : null;
        return isPlainObject(processInfo) ? claudeProcessAmong(processInfo.foreground_processes) : null;
    }

    /**
     * Lists the hspawn registry once and reads each `*.json` entry in it. A file that cannot be read or parsed, or
     * that names no pane, is skipped with one rate-limited line; a missing directory (hspawn never ran) is no entries.
     *
     * @returns {Object<string, object>} Registry entries by their `pane_id`.
     */
    _readRegistryEntriesByPaneId() {
        let entryNames;
        try {
            entryNames = this._listDirectory(this._registryDirectory);
        } catch (error) {
            if (!isNotFoundError(error)) {
                const errorText = describeError(error);
                this._errorLog.log(`sessions: cannot list the registry ${this._registryDirectory}: ${errorText}`,
                    REGISTRY_DIRECTORY_LOG_KEY);
            }
            return {};
        }
        const registryEntriesByPaneId = {};
        entryNames.filter(entryName => entryName.endsWith(REGISTRY_FILE_SUFFIX)).forEach(entryName => {
            const registryFilePath = `${this._registryDirectory}/${entryName}`;
            try {
                const registryEntry = JSON.parse(this._readFile(registryFilePath));
                if (!isPlainObject(registryEntry) || stringOrNull(registryEntry.pane_id) === null)
                    throw new Error('no pane_id');
                registryEntriesByPaneId[registryEntry.pane_id] = registryEntry;
            } catch (error) {
                this._errorLog.log(`sessions: skipped registry file ${registryFilePath}: ${describeError(error)}`,
                    REGISTRY_FILE_LOG_KEY);
            }
        });
        return registryEntriesByPaneId;
    }

    /**
     * Finds a session's transcript as hreap does and stats it: the exact path first, and only when that misses,
     * `<root>/*\/<id>.jsonl` under Claude's projects, then `<root>/*\/runtime-*\/projects/*\/<id>.jsonl` under
     * clauth's profiles; the first match in name order wins.
     *
     * @param {object} session - The session.
     * @param {string|null} session.cwd - Its working directory.
     * @param {string|null} session.sessionId - Its Claude session id.
     * @param {(directoryPath: string) => string[]} listOncePerSample - Lists a directory, at most once per sample.
     * @returns {number|null} The transcript's modification time in microseconds; null when none is found.
     */
    _findTranscriptMtimeUsec({cwd, sessionId}, listOncePerSample) {
        const candidates = transcriptPathCandidates({cwd, sessionId, homeDirectory: this._homeDirectory});
        if (candidates.length === 0)
            return null;
        const [exactPath, claudeProjectsRoot, clauthProfilesRoot] = candidates;
        const exactMtimeUsec = this._statFile(exactPath);
        if (Number.isFinite(exactMtimeUsec))
            return exactMtimeUsec;
        const transcriptFileName = `${sessionId}${TRANSCRIPT_FILE_SUFFIX}`;
        const projectDirectories =
            transcriptProjectDirectories(claudeProjectsRoot, clauthProfilesRoot, listOncePerSample);
        for (const projectDirectory of projectDirectories) {
            const mtimeUsec = this._statFile(`${projectDirectory}/${transcriptFileName}`);
            if (Number.isFinite(mtimeUsec))
                return mtimeUsec;
        }
        return null;
    }

    /**
     * @param {string} directoryPath - A directory.
     * @param {Map<string, string[]>} listingsByPath - This sample's listings so far.
     * @returns {string[]} Its entry names in name order, listed on the first call of the sample and remembered for
     *     the rest of it; empty when it cannot be listed (a missing root is the common case).
     */
    _listDirectoryOnce(directoryPath, listingsByPath) {
        if (!listingsByPath.has(directoryPath)) {
            let entryNames;
            try {
                entryNames = [...this._listDirectory(directoryPath)].sort();
            } catch {
                // A directory the search cannot list holds no transcript it can find: the search goes on without it.
                entryNames = [];
            }
            listingsByPath.set(directoryPath, entryNames);
        }
        return listingsByPath.get(directoryPath);
    }

    /**
     * @param {number} pid - The Claude process.
     * @returns {number|null} Its VmRSS plus VmSwap in bytes; null when it vanished or its status cannot be read.
     */
    _processMemoryBytes(pid) {
        try {
            return memoryBytesFromProcStatus(this._readFile(procPidPath(pid, PROC_PID_STATUS_FILE_NAME)));
        } catch {
            // The process exited between herdr's answer and this read: its memory is unknown, the row stays.
            return null;
        }
    }

    /**
     * @param {number} pid - The Claude process.
     * @param {{seconds: number|null|undefined}} bootTime - This sample's boot time, read from /proc/stat on first
     *     use (undefined until then, null when it could not be read).
     * @returns {number|null} When the process started, in microseconds since the epoch; null when it vanished or a
     *     file is not the expected shape.
     */
    _processStartedAtUsec(pid, bootTime) {
        if (bootTime.seconds === undefined) {
            try {
                bootTime.seconds = bootTimeSecondsFrom(this._readFile(PROC_STAT_PATH));
            } catch {
                // Without the boot time no start time can be computed; the idle age stays unknown.
                bootTime.seconds = null;
            }
        }
        if (bootTime.seconds === null)
            return null;
        let startTimeTicks;
        try {
            startTimeTicks = startTimeTicksFrom(this._readFile(procPidPath(pid, PROC_PID_STAT_FILE_NAME)));
        } catch {
            // The process exited meanwhile: its start time is unknown.
            return null;
        }
        if (startTimeTicks === null)
            return null;
        return (bootTime.seconds + startTimeTicks / CLOCK_TICKS_PER_SECOND) * MICROSECONDS_PER_SECOND;
    }
}

/**
 * The directories a transcript search looks in, listed lazily, so a search that matches early lists no further.
 *
 * @param {string} claudeProjectsRoot - Claude's projects directory.
 * @param {string} clauthProfilesRoot - clauth's profiles directory.
 * @param {(directoryPath: string) => string[]} listOncePerSample - Lists a directory in name order, at most once per
 *     sample.
 * @yields {string} Every `<claudeProjectsRoot>/<project>`, then every
 *     `<clauthProfilesRoot>/<profile>/runtime-*\/projects/<project>`, in name order.
 */
function* transcriptProjectDirectories(claudeProjectsRoot, clauthProfilesRoot, listOncePerSample) {
    for (const projectName of listOncePerSample(claudeProjectsRoot))
        yield `${claudeProjectsRoot}/${projectName}`;
    for (const profileName of listOncePerSample(clauthProfilesRoot)) {
        const profileDirectory = `${clauthProfilesRoot}/${profileName}`;
        const runtimeNames = listOncePerSample(profileDirectory)
            .filter(entryName => entryName.startsWith(CLAUTH_RUNTIME_DIRECTORY_PREFIX));
        for (const runtimeName of runtimeNames) {
            const projectsDirectory = `${profileDirectory}/${runtimeName}/${CLAUTH_RUNTIME_PROJECTS_DIRECTORY_NAME}`;
            for (const projectName of listOncePerSample(projectsDirectory))
                yield `${projectsDirectory}/${projectName}`;
        }
    }
}

/**
 * @param {*} snapshot - herdr's snapshot.
 * @returns {Object<string, string>} Each workspace's label by its `workspace_id`; a workspace without both is left
 *     out.
 */
function workspaceLabelsByIdFrom(snapshot) {
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
