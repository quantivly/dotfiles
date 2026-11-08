// Every tunable of Resource Pulse, each with its unit in the name.

/** Seconds between CPU, memory and pressure samples. */
export const SAMPLE_INTERVAL_SECONDS = 2;
/**
 * Seconds between per-app scans: SAMPLE_INTERVAL_SECONDS × APP_SCAN_EVERY_N_TICKS, which a test row enforces.
 * 10 rather than the spec's first 6, to keep the scan inside the < 0.5%-of-one-core idle budget.
 */
export const APP_SCAN_INTERVAL_SECONDS = 10;
/** Sample ticks between per-app scans. */
export const APP_SCAN_EVERY_N_TICKS = 5;
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
/** Directory entries fetched per step of an asynchronous directory listing. */
export const DIRECTORY_LISTING_BATCH_ENTRIES = 64;
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
/** Longest app name shown before truncation, in characters. */
export const APP_NAME_MAX_CHARS = 18;
/** Distance of the desktop card from the screen edge, in pixels. */
export const CARD_MARGIN_PX = 24;
/** Desktop IDs of the system monitors a click may open, in order of preference. */
export const RESOURCES_APP_IDS = ['net.nokyan.Resources.desktop', 'org.gnome.SystemMonitor.desktop'];
/** Milliseconds the pointer rests on a top-bar item before its label shows. */
export const HOVER_LABEL_DELAY_MS = 300;
/** Milliseconds the hover label takes to fade in, and to fade out: the dash's own label timings (dash.js). */
export const HOVER_LABEL_FADE_IN_MS = 150;
export const HOVER_LABEL_FADE_OUT_MS = 100;
/** Width of one top-bar graph's slot for a sample, in logical pixels: whole pixels keep the slots crisp. */
export const TOPBAR_GRAPH_SLOT_WIDTH_PX = 1;
/** Width of each top-bar graph, in logical pixels: one slot per sample of its history. */
export const TOPBAR_GRAPH_WIDTH_PX = TOPBAR_HISTORY_SAMPLES * TOPBAR_GRAPH_SLOT_WIDTH_PX;
/** Height of each top-bar graph, in logical pixels: the height of a panel status icon. */
export const TOPBAR_GRAPH_HEIGHT_PX = 16;
/** Thickness of the faint line along the bottom of every graph, in logical pixels. */
export const GRAPH_BASELINE_THICKNESS_PX = 1;
/** Fill of the CPU graph as [red, green, blue, alpha], each 0–1: Yaru's teal accent, #2190a4. */
export const CPU_GRAPH_RGBA = [0x21 / 0xff, 0x90 / 0xff, 0xa4 / 0xff, 1];
/** Fill of the memory graph as [red, green, blue, alpha], each 0–1: Yaru's purple, #9141ac. */
export const MEMORY_GRAPH_RGBA = [0x91 / 0xff, 0x41 / 0xff, 0xac / 0xff, 1];
/** The faint line under every graph as [red, green, blue, alpha], each 0–1, so an empty graph still shows. */
export const BASELINE_RGBA = [1, 1, 1, 0.25];
/** Prefix of every journal line this extension writes. */
export const LOG_PREFIX = 'resource-pulse:';
/** Name of the computed pseudo-app that takes the CPU and memory no scanned cgroup accounts for. */
export const KERNEL_AND_OTHER_LABEL = 'kernel & other';
/** Display names for service units whose own name reads badly, keyed by unit name without suffix. */
export const UNIT_DISPLAY_ALIASES = {'herdr-server': 'herdr agents', 'org.gnome.Shell': 'GNOME Shell'};
/** Bytes in one gibibyte (the memory unit shown everywhere). */
export const BYTES_PER_GIBIBYTE = 1024 ** 3;
/** Filled and empty cells of the three-cell pressure meter. */
export const PRESSURE_METER_FILLED_CELL = '▮';
export const PRESSURE_METER_EMPTY_CELL = '▯';
/** Number of cells in the pressure meter (one more than the number of band thresholds). */
export const PRESSURE_METER_CELLS = 3;
/** What a pressure meter shows when its avg10 is unavailable. */
export const PRESSURE_METER_NO_DATA = '···';
