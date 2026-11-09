// Every tunable of Resource Pulse, each with its unit in the name.

/** Seconds between CPU, memory and pressure samples. */
export const SAMPLE_INTERVAL_SECONDS = 2;
/**
 * Sample intervals a sample may stay in flight. On the timer tick after that it counts as stalled: both surfaces
 * go to no data (once per stall) and its late result is dropped, while no second sample is queued behind it.
 */
export const SAMPLE_STALL_TICKS = 3;
/**
 * Seconds between per-app scans while a detail watch is held: SAMPLE_INTERVAL_SECONDS × APP_SCAN_EVERY_N_TICKS,
 * which a test row enforces. 20 (the service design's cadence) to keep the scan inside the idle cost budget.
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
/** Sample ticks between per-app scans. */
export const APP_SCAN_EVERY_N_TICKS = APP_SCAN_INTERVAL_SECONDS / SAMPLE_INTERVAL_SECONDS;
/**
 * Sample ticks an app scan may stay in flight: one whole scan interval, by when the next scan is overdue. On the
 * timer tick after that the scan counts as stalled (once per stall): the ranking is dropped, so "heaviest" shows
 * no data, and the scan's late result is discarded.
 */
export const APP_SCAN_STALL_TICKS = APP_SCAN_EVERY_N_TICKS;
/**
 * The tick that scans once more than the cadence would, after every baseline reset (enable, resume, the scan turned
 * back on), which restarts the tick count at 0. Tick 0's scan is only a baseline, so without this the CPU half of
 * "heaviest" would wait for tick APP_SCAN_EVERY_N_TICKS (about 12 s); with it, tick 2's snapshot has it (about 4 s).
 */
export const APP_SCAN_WARM_UP_TICK = 1;
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
/**
 * Cgroup leaves whose files an app scan reads at once. The next batch starts only when this one has settled, so a
 * scan never has more than this many leaves' reads waiting to complete on the shell's main loop (about 200 leaves,
 * 500 files and 2,000 completions in all on the reference laptop), where they would compete with redraws.
 */
export const APP_SCAN_READ_BATCH_LEAVES = 16;
/** Bytes asked for per read of a /proc, /sys or cgroup file: they report size 0, so each is read until EOF. */
export const FILE_READ_CHUNK_BYTES = 8192;
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
