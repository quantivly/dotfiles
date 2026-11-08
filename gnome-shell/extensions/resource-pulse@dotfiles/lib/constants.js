// Every tunable of Resource Pulse, each with its unit in the name.

/** Seconds between CPU, memory and pressure samples. */
export const SAMPLE_INTERVAL_SECONDS = 2;
/** Seconds between per-app scans (a multiple of the sample interval). */
export const APP_SCAN_INTERVAL_SECONDS = 6;
/** Sample ticks between per-app scans. */
export const APP_SCAN_EVERY_N_TICKS = 3;
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
/** Prefix of every journal line this extension writes. */
export const LOG_PREFIX = 'resource-pulse:';
