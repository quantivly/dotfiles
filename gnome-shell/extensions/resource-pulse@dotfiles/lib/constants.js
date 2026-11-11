// Every tunable of Resource Pulse, each with its unit in the name.

/** Seconds between CPU, memory and pressure samples. */
export const SAMPLE_INTERVAL_SECONDS = 2;
/**
 * Sample intervals the extension's client waits for a Sample. A Sample older than that is stale (lib/wiring.js
 * isSampleStale): both surfaces go to no data, once, rather than show its numbers as live.
 */
export const SAMPLE_STALL_TICKS = 3;
/**
 * Seconds the client waits after a failed StartUnit before asking systemd again: the first delay after the first
 * failure, the second after the second, and the last one for every failure after that. A success, or the service
 * appearing on the bus, ends the retries.
 */
export const START_RETRY_DELAYS_SECONDS = [5, 30, 300];
/**
 * Seconds an accepted StartUnit waits for the service to appear on the bus before it counts as failed. systemd answers
 * StartUnit with a job before it checks Restart= and the start limit, so a unit at its StartLimitBurst is "started"
 * and then never runs; without this wait that answer would end the retries.
 */
export const START_CONFIRMATION_TIMEOUT_SECONDS = 15;
/** Milliseconds the client waits for any D-Bus reply: GetState, WatchDetail, UnwatchDetail and StartUnit. */
export const DBUS_CALL_TIMEOUT_MS = 2000;
/**
 * Seconds between per-app scans while a detail watch is held: a whole number of SAMPLE_INTERVAL_SECONDS, since scans
 * run on fast ticks. 20 (the service design's cadence) to keep the scan inside the idle cost budget.
 */
export const APP_SCAN_INTERVAL_SECONDS = 20;
/** Seconds between per-app scans with no detail watch held: a baseline, so a reveal never starts from nothing. */
export const APP_SCAN_UNWATCHED_INTERVAL_SECONDS = 60;
/** Percentage points CPU busy must rise above its value at the last scan to set off a burst scan. */
export const BURST_CPU_RISE_POINTS = 15;
/** Ticks after a watch-start or burst scan during which no burst scan may start. */
export const BURST_COOLDOWN_TICKS = 2;
/** Ticks after a watch-start or burst scan during which a watch starting does not scan at once. */
export const REVEAL_SCAN_COOLDOWN_TICKS = 2;
/**
 * Shortest window, in seconds, a CPU ranking may cover. Over less, a scan ranks noise: a watch start that soon after
 * the last scan does not scan (the client already has that ranking), and a warm-up due that soon waits a tick.
 */
export const MIN_CPU_RANKING_WINDOW_SECONDS = 1;
/**
 * Cgroup leaves with these suffixes are left out of the app scan. Such units (mounts, sockets, swap, automounts,
 * paths, timers, devices) never host an app process, and skipping them is the scan's main cost lever: on the
 * reference laptop they were 64 of 171 leaves.
 */
export const APP_SCAN_SKIPPED_UNIT_SUFFIXES = [
    '.mount', '.socket', '.swap', '.automount', '.path', '.timer', '.device',
];
/**
 * memory.current above which an app scan also reads a cgroup's memory.stat to subtract its page cache (64 MiB).
 * A leaf at or under it ranks by memory.current as it is: too small to top the ranking, so not worth a third read.
 */
export const APP_MEMORY_STAT_MIN_BYTES = 64 * 1024 ** 2;
/** Samples kept for the top-bar sparkline. */
export const TOPBAR_HISTORY_SAMPLES = 30;
/** Samples kept for the desktop card graphs. */
export const CARD_HISTORY_SAMPLES = 150;
/** Lower bounds, in percent of PSI some avg10, of bands 1, 2 and 3 (below the first is band 0). */
export const PRESSURE_BAND_THRESHOLDS_PERCENT = [10, 25, 50];
/** A CPU whose capacity is at least this fraction of the maximum is a performance core. */
export const PERFORMANCE_CAPACITY_RATIO = 0.9;
/** Microseconds before the same error message may be logged again (10 minutes). */
export const ERROR_LOG_REPEAT_INTERVAL_USEC = 600_000_000;
/** Distance of the desktop card from the screen edge, in pixels. */
export const CARD_MARGIN_PX = 24;
/**
 * Seconds between repaints of the desktop card while it counts as covered (frozen). The cover re-check timer repaints
 * it, dimmed, from the client's latest state this often, so a card misjudged as covered shows numbers at most this
 * old, dimmed, rather than stale ones that read as live (ruling R21).
 */
export const FROZEN_REPAINT_INTERVAL_SECONDS = 30;
/** Desktop IDs of the system monitors a click may open, in order of preference. */
export const RESOURCES_APP_IDS = ['net.nokyan.Resources.desktop', 'org.gnome.SystemMonitor.desktop'];
/** Milliseconds the pointer rests on a top-bar item before its label shows. */
export const HOVER_LABEL_DELAY_MS = 300;
/** Milliseconds the hover label takes to fade in, and to fade out: the dash's own label timings (dash.js). */
export const HOVER_LABEL_FADE_IN_MS = 150;
export const HOVER_LABEL_FADE_OUT_MS = 100;
/** Pixels between a cockpit row's edge and the cockpit tooltip's nearest edge. */
export const COCKPIT_TOOLTIP_GAP_PX = 6;
/**
 * The actor opacity, of 255, of a long-idle session row: the design's 0.55. St reads no CSS `opacity`, so the
 * sessions card sets it on the row actor.
 */
export const COCKPIT_LONG_IDLE_ROW_OPACITY = 140;
/** Width of one top-bar graph's slot for a sample, in logical pixels: whole pixels keep the slots crisp. */
export const TOPBAR_GRAPH_SLOT_WIDTH_PX = 1;
/** Width of each top-bar graph, in logical pixels: one slot per sample of its history. */
export const TOPBAR_GRAPH_WIDTH_PX = TOPBAR_HISTORY_SAMPLES * TOPBAR_GRAPH_SLOT_WIDTH_PX;
/** Height of each top-bar graph, in logical pixels: the height of a panel status icon. */
export const TOPBAR_GRAPH_HEIGHT_PX = 16;
/** Width of one desktop-card CPU graph slot for a sample, in logical pixels: whole pixels keep the slots crisp. */
export const CARD_GRAPH_SLOT_WIDTH_PX = 1;
/** Width of the desktop card's CPU graph, in logical pixels: one slot per sample of its five-minute history. */
export const CARD_CPU_GRAPH_WIDTH_PX = CARD_HISTORY_SAMPLES * CARD_GRAPH_SLOT_WIDTH_PX;
/** Height of the desktop card's CPU graph, in logical pixels: a little under its row's big number. */
export const CARD_CPU_GRAPH_HEIGHT_PX = 20;
/** Width of the desktop card's memory bar, in logical pixels: the CPU graph's, so the two line up. */
export const CARD_MEMORY_BAR_WIDTH_PX = CARD_CPU_GRAPH_WIDTH_PX;
/** Height of the desktop card's memory bar, in logical pixels. */
export const CARD_MEMORY_BAR_HEIGHT_PX = 8;
/** Thickness of the faint line along the bottom of every graph, in logical pixels. */
export const GRAPH_BASELINE_THICKNESS_PX = 1;
/** Fill of the CPU graph as [red, green, blue, alpha], each 0–1: Yaru's teal accent, #2190a4. */
export const CPU_GRAPH_RGBA = [0x21 / 0xff, 0x90 / 0xff, 0xa4 / 0xff, 1];
/** Fill of the memory graph as [red, green, blue, alpha], each 0–1: Yaru's purple, #9141ac. */
export const MEMORY_GRAPH_RGBA = [0x91 / 0xff, 0x41 / 0xff, 0xac / 0xff, 1];
/** The faint line under every graph as [red, green, blue, alpha], each 0–1, so an empty graph still shows. */
export const BASELINE_RGBA = [1, 1, 1, 0.25];
/** The unused part of the desktop card's memory bar as [red, green, blue, alpha], each 0–1: a faint groove. */
export const USED_BAR_TRACK_RGBA = [1, 1, 1, 0.15];
/** Prefix of every journal line this extension writes. */
export const LOG_PREFIX = 'resource-pulse:';
/** Name of the CPU-only pseudo-entry for the root cgroup's CPU no scanned parent slice accounts for. */
export const KERNEL_LABEL = 'kernel';
/** Name of the CPU-only pseudo-entry for units that started and ended between two scans. */
export const SHORT_JOBS_LABEL = 'short jobs';
/** What the CPU half of "heaviest" reads when even the top entry is below CPU_IDLE_THRESHOLD_PERCENT. */
export const CPU_IDLE_LABEL = 'idle';
/** Below this share of the whole machine, the top CPU entry is not worth naming: the machine is idle. */
export const CPU_IDLE_THRESHOLD_PERCENT = 1;
/** Display names for service units whose own name reads badly, keyed by unit name without suffix. */
export const UNIT_DISPLAY_ALIASES = {'herdr-server': 'herdr agents', 'org.gnome.Shell': 'GNOME Shell'};
/** Bytes in one gibibyte (the memory unit shown everywhere). */
export const BYTES_PER_GIBIBYTE = 1024 ** 3;
/** Microseconds in one second: GLib's clocks and every `*Usec` value count in microseconds. */
export const MICROSECONDS_PER_SECOND = 1_000_000;
/** Number of cells in the pressure meter (one more than the number of band thresholds). */
export const PRESSURE_METER_CELLS = 3;
/** Width of one drawn pressure-meter cell, in logical pixels: whole pixels keep its edges crisp. */
export const PRESSURE_METER_CELL_WIDTH_PX = 6;
/** Space between two pressure-meter cells, in logical pixels. */
export const PRESSURE_METER_CELL_GAP_PX = 2;
/** Width of a whole pressure meter, in logical pixels: its cells and the gaps between them. */
export const PRESSURE_METER_WIDTH_PX =
    PRESSURE_METER_CELLS * PRESSURE_METER_CELL_WIDTH_PX + (PRESSURE_METER_CELLS - 1) * PRESSURE_METER_CELL_GAP_PX;
/** Height of a pressure meter, in logical pixels: about the cap height of the card's text. */
export const PRESSURE_METER_HEIGHT_PX = 10;
/** Thickness of the dash a pressure meter draws for no data, in logical pixels. */
export const PRESSURE_METER_NO_DATA_DASH_THICKNESS_PX = 2;
/** Filled pressure-meter cells as [red, green, blue, alpha], each 0–1: the card's value colour. */
export const PRESSURE_METER_FILL_RGBA = [1, 1, 1, 1];
/** Empty pressure-meter cells, and the no-data dash, as [red, green, blue, alpha], each 0–1: a visible groove. */
export const PRESSURE_METER_TRACK_RGBA = [1, 1, 1, 0.25];
/** Most apps the sampler publishes in each app ranking (by CPU, by memory): what the apps card can show. */
export const APP_RANKING_LENGTH = 10;
/**
 * A cockpit source whose sampledAtUsec is older than this many of its own intervalSeconds is stale: its card draws
 * "no data since HH:MM" rather than its numbers as live.
 */
export const COCKPIT_SOURCE_STALE_INTERVALS = 3;
/** The interval a cockpit source is judged against when it publishes none (null or 0): one sample a minute. */
export const COCKPIT_FALLBACK_INTERVAL_SECONDS = 60;
/**
 * What the extension's cockpit client (cockpitClient.js) knows of cockpit.service:
 * - STARTING: asked systemd to start it, and no state from it yet;
 * - SKIPPED: the cockpit is not configured: systemd skipped the start job for its condition (no layout file), or has
 *   no such unit (NoSuchUnit: never linked, or unloaded after a skipped job); nothing is retried until the next
 *   start();
 * - LIVE: its GetState answered, and its changes are followed;
 * - VANISHED: it left the bus after it was there; the client starts nothing (a stop stays a stop).
 */
export const CockpitClientState = Object.freeze({
    STARTING: 'starting',
    SKIPPED: 'skipped',
    LIVE: 'live',
    VANISHED: 'vanished',
});
/**
 * The `type` of each event the cockpit client tells its listeners:
 * - STATE: its CockpitClientState changed (`{type, state}`);
 * - LAYOUT: the layout or the config error changed (`{type, layout, configError}`);
 * - SOURCES: these sources changed, or a pull settled their freshness (`{type, names}`).
 */
export const CockpitClientEventType = Object.freeze({
    STATE: 'state',
    LAYOUT: 'layout',
    SOURCES: 'sources',
});
/**
 * Longest name, in characters, a cockpit source publishes (a session slug or branch, a workspace label, an account, a
 * mount label); a longer one is published as COCKPIT_REDACTED_NAME.
 */
export const COCKPIT_NAME_MAX_CHARS = 64;
/**
 * What a cockpit source publishes in place of a name it rejects: one that is empty, too long (COCKPIT_NAME_MAX_CHARS),
 * holds a control character or matches a secret shape.
 */
export const COCKPIT_REDACTED_NAME = '—';
/**
 * Longest id, in characters, a cockpit reader passes (a session row's herdr workspace and pane ids); a longer one
 * reads as null, so another program's runaway string cannot ride an id onto the bus.
 */
export const COCKPIT_ID_MAX_CHARS = 128;
/** Longest path, in characters, a cockpit reader passes (a mount row's mount point); a longer one drops its row. */
export const COCKPIT_PATH_MAX_CHARS = 1024;
/** Prefix of every journal line the cockpit service writes. */
export const COCKPIT_LOG_PREFIX = 'cockpit:';
/** The card ids a cockpit layout config may name, in the order the cockpit draws them by default. */
export const COCKPIT_CARD_IDS = ['system', 'apps', 'connections', 'sessions', 'health', 'seats', 'sol', 'work'];
/** Columns of the cockpit grid: the most the groups' `columns` may add up to. */
export const COCKPIT_GRID_COLUMNS = 4;
/** The cockpit layout config's path under the user's config home (XDG_CONFIG_HOME). */
export const COCKPIT_CONFIG_RELATIVE_PATH = 'resource-pulse/cockpit.json';
/** A session row idle at least this many seconds is drawn dimmed (the drawing side reads it). */
export const SESSION_IDLE_DIM_SECONDS = 1800;
/** Interface-name prefixes of VPN tunnels in /proc/net/route (OpenVPN tun and tap, WireGuard wg). */
export const TUNNEL_INTERFACE_PREFIXES = ['tun', 'tap', 'wg'];
/** Filesystem types of network shares, as /proc/self/mountinfo names them. */
export const NETWORK_FILESYSTEM_TYPES = ['cifs', 'smb3', 'nfs', 'nfs4', 'fuse.sshfs', 'fuse.rclone', 'davfs', 'afp'];
/** Mount-point prefixes under which removable disks are mounted. */
export const REMOVABLE_MOUNT_PREFIXES = ['/media/', '/run/media/', '/mnt/'];
/** The RTF_GATEWAY bit of a /proc/net/route `Flags` column: the route goes via a gateway. */
export const ROUTE_FLAG_GATEWAY = 0x0002;
/**
 * Milliseconds the cockpit service waits for herdr to answer one request over its socket: connect, send and the reply
 * together. A herdr that has not answered by then fails the request, so a hung herdr marks the sessions source stale
 * instead of stalling the service.
 */
export const HERDR_REQUEST_TIMEOUT_MS = 2000;
/** herdr's API socket's path under the user's config home (XDG_CONFIG_HOME). */
export const HERDR_SOCKET_RELATIVE_PATH = 'herdr/herdr.sock';
/** Where the kernel lists its processes: one directory per pid, named by the pid. */
export const PROC_ROOT_PATH = '/proc';
/** A process's stat file, under its directory in PROC_ROOT_PATH: one line, its pid, comm, state, ppid and on. */
export const PROC_PID_STAT_FILE_NAME = 'stat';
/**
 * Most entries of one process's chain of parents that lib/processTree.js follows, the process itself included: a
 * deeper chain is cut there. A herdr client's terminal is its second or third parent.
 */
export const PROCESS_ANCESTOR_MAX_DEPTH = 16;
/**
 * Most window candidates a FocusSession reply carries (the herdr clients and their parents, ruling out pid 1); a
 * reader drops any past it.
 */
export const FOCUS_WINDOW_PID_CANDIDATES_MAX = 64;
/**
 * The environment variable that puts the cockpit service in fixture mode: when it names a JSON file, the service
 * serves that file's state and focus reply instead of its sources and the config. Only the nested test harness sets
 * it; cockpit.service never does.
 */
export const COCKPIT_FIXTURE_ENVIRONMENT_VARIABLE = 'RESOURCE_PULSE_COCKPIT_FIXTURE';
/**
 * Most characters of herdr's own error text (its code and message) a rejection's message carries; the rest is cut. An
 * unknown method's message lists every method herdr has, about 2,000 characters.
 */
export const HERDR_ERROR_MESSAGE_MAX_CHARS = 200;
/**
 * Longest reply line, in bytes, the herdr client reads (8 MiB); a longer one is rejected as soon as the cap is passed,
 * so a runaway reply cannot fill the service's memory. A live session snapshot measured about 63 KB.
 */
export const HERDR_REPLY_MAX_BYTES = 8 * 1024 * 1024;
/** Seconds between samples of the sessions source while a client watches the cockpit. */
export const SESSIONS_WATCHED_INTERVAL_SECONDS = 10;
/** Seconds between samples of the sessions source while no client watches the cockpit: its standing cost. */
export const SESSIONS_UNWATCHED_INTERVAL_SECONDS = 60;
/** Seconds between samples of the network source, watched or not (NetworkManager's signals cover the rest). */
export const NETWORK_INTERVAL_SECONDS = 10;
/** Seconds between samples of the mounts source, watched or not (the mount monitor's signal covers the rest). */
export const MOUNTS_INTERVAL_SECONDS = 30;
/** Every cockpit source's interval is multiplied by this while UPower reports the machine on battery. */
export const BATTERY_CADENCE_MULTIPLIER = 3;
/**
 * Seconds after a signal-driven sample of a cockpit source during which another signal does not sample it at once;
 * signals inside it give one sample when it ends.
 */
export const SOURCE_SIGNAL_COOLDOWN_SECONDS = 2;
/**
 * Path fragments of the files the cockpit service may stat but never open (the spec's "stat, never open" list): the
 * sources' file reader (service/sources/sourceIo.js) refuses any path containing one, before opening it. Listing a
 * directory's names is not opening a file, so counting the SSH control sockets stays allowed.
 */
export const STAT_ONLY_PATH_FRAGMENTS = [
    '/.aws/', '/.ssh/', '/.credentials', '/.zshrc.local', '/.gitconfig.local', '/.backup.local',
];
/**
 * Milliseconds a mount's filesystem size query may take before it counts as failed (its sizes null), so a hung network
 * share cannot stall the mounts source.
 */
export const FILESYSTEM_QUERY_TIMEOUT_MS = 2000;
/**
 * The cockpit grid at its reference size, in logical pixels (the spec's numbers at 1920 x 1080): every length scales
 * with the cockpit monitor's work area. `columns` and `rows` are the most cells a group's block holds across and down.
 */
export const COCKPIT_GRID_REFERENCE = Object.freeze({
    widthPx: 1920, heightPx: 1080, cellWidthPx: 420, cellHeightPx: 300,
    innerGutterPx: 24, groupGapPx: 48, rowGutterPx: 24, captionHeightPx: 28, columns: 4, rows: 3,
});
/** The smallest factor the cockpit grid shrinks to, however small the monitor. */
export const COCKPIT_GRID_MIN_SCALE = 0.5;
/** The largest factor the cockpit grid grows to, however large the monitor. */
export const COCKPIT_GRID_MAX_SCALE = 2;
/** The card ids the cockpit draws; any other id in the layout still gets a cell, drawn as a placeholder. */
export const COCKPIT_DRAWN_CARD_IDS = ['system', 'apps', 'connections', 'sessions'];
/** The most session rows the sessions card draws; the rest collapse into a '+N more' line. */
export const SESSIONS_CARD_ROW_LIMIT = 6;
/** The most rows each ranking (CPU, memory) of the apps card draws. */
export const APPS_CARD_ROW_LIMIT = 6;
/**
 * The most rows the connections card draws: the uplink, the VPN and the ssh masters, then up to five mounts; the
 * mounts past it collapse into a '+N more' line. Its rows are built with the card, so no update makes an actor.
 */
export const CONNECTIONS_CARD_ROW_LIMIT = 8;
/** Size of a cockpit row's icon and of the sessions header's state icons, in logical pixels: a panel status icon's. */
export const COCKPIT_ROW_ICON_SIZE_PX = 16;
/**
 * Width of a cockpit row's bar track, as a share of its cell's width: a fixed slot at the row's end, so a bar's change
 * never moves the name beside it, and the bars of a card line up.
 */
export const COCKPIT_ROW_BAR_TRACK_SHARE_OF_CELL_WIDTH = 0.15;
/** Pixels between a state's icon and its count in the sessions header, closer than the header's other parts. */
export const COCKPIT_STATE_COUNT_SPACING_PX = 2;
/** Seconds in the units an idle time is written in; a session idle for less than the next unit up shows this one. */
export const SECONDS_PER_MINUTE = 60;
export const SECONDS_PER_HOUR = 3600;
export const SECONDS_PER_DAY = 86400;
/** Icon names (symbolic, from the stock theme) the cockpit cards draw, by session state and by connection kind. */
export const COCKPIT_ICON_NAMES = Object.freeze({
    working: 'media-playback-start-symbolic',
    blocked: 'dialog-warning-symbolic',
    idle: 'media-playback-pause-symbolic',
    done: 'emblem-ok-symbolic',
    unknown: 'dialog-question-symbolic',
    wired: 'network-wired-symbolic',
    wifi: 'network-wireless-symbolic',
    offline: 'network-offline-symbolic',
    vpn: 'network-vpn-symbolic',
    ssh: 'utilities-terminal-symbolic',
    mountRemovable: 'drive-removable-media-symbolic',
    mountNetwork: 'folder-remote-symbolic',
});
