//! The sampler, ported from `service/sampler.js`'s `ServiceSampler`: each tick reads `/proc` and
//! `/sys` for CPU, memory, swap and pressure, scans the cgroup tree for the app rankings when
//! `lib/cadence.js` says one is due, and publishes one snapshot carrying this tick's ranking. A watch
//! start scans at once, outside the tick, and publishes again.
//!
//! It has no timer and no listeners: [`Sampler::run_tick`] and [`Sampler::set_detail_watched`]
//! return what the gjs sampler hands its listeners, and the program's tick loop calls them.
//!
//! - **A fault costs one field or one tick, never the process.** Where the gjs sampler catches a
//!   throw, this catches a panic (a port that panics stands for one that throws): around the fast
//!   sample, which then publishes no data; around the app scan, which then drops its ranking; and
//!   around each app-name lookup, which then is a miss. The rate-limited log catches a panicking
//!   clock or writer. Everything else is arithmetic and bookkeeping that cannot panic, so neither
//!   public call panics outward.
//! - **Everything that can fail is worked out before any state changes,** as in gjs, so a caught
//!   failure leaves nothing half-written; the state a caught panic leaves is gjs's after the same
//!   throw.
//! - **Every failure is logged rate-limited by a stable template key,** with gjs's text, so a failure
//!   whose text varies still logs once per `ERROR_LOG_REPEAT_INTERVAL_USEC`.
//! - **Numbers are the gjs sampler's doubles:** every integer read becomes `f64` before the first
//!   arithmetic on it, in the order the JavaScript writes it, and no difference of two readings or
//!   two tick numbers is an unsigned subtraction.

mod app_names;
mod app_scan;
mod cadence_bookkeeping;
mod caught_panic;
mod cgroup_readings;
mod cgroup_tree;
mod cluster_map_reading;
mod fast_sample;
mod logged_reads;
mod paths;
mod publishing;
mod snapshot;
mod watch_start;

use std::num::NonZeroUsize;
use std::path::PathBuf;

use crate::apps::AppRanking;
use crate::cadence::ScanReason;
use crate::constants::CARD_HISTORY_SAMPLES;
use crate::cpu::ClusterMap;
use crate::history::RingBuffer;
use crate::parsers::proc::{parse_uid, ProcStat};
use crate::ports::{Clock, DirectoryLister, FileReader};
use crate::rate_limited_log::RateLimitedLog;
use app_names::AppNameCache;
use app_scan::AppScanReadings;
use cadence_bookkeeping::CadenceBookkeeping;
use caught_panic::catching_panic;
use fast_sample::parse_usable_proc_stat;
use paths::{join_under, PROC_SELF_STATUS_PATH, PROC_STAT_PATH};

pub use snapshot::{AppendedHistory, ClusterPercents, PressureAvg10, Publish, Snapshot};

#[cfg(test)]
mod tests;

/// The history capacity were [`CARD_HISTORY_SAMPLES`] not a usable `NonZeroUsize`, which it always
/// is (150): a `u64` of 150 fits every `usize`, and only 0 is refused. Named so that the fallback is a
/// choice on the page, not a panic; it keeps one sample.
const FALLBACK_HISTORY_CAPACITY: NonZeroUsize = NonZeroUsize::MIN;

/// The template key of a failed sample's journal line.
const SAMPLE_FAILURE_LOG_KEY: &str = "sample failed";

/// The name of a `.desktop` id, `None` for an unknown one: the `resolve_app_name` port.
pub type ResolveAppName = Box<dyn FnMut(&str) -> Option<String>>;

/// What the sampler reads, tells time and logs through, and how it names apps.
pub struct SamplerPorts {
    pub reader: Box<dyn FileReader>,
    pub lister: Box<dyn DirectoryLister>,
    pub clock: Box<dyn Clock>,
    /// The name of a `.desktop` id, `None` for an unknown one. A panic counts as gjs's throw: logged,
    /// and a miss.
    pub resolve_app_name: ResolveAppName,
    /// Where the rate-limited journal lines go.
    pub log: Box<dyn FnMut(&str)>,
}

/// Samples CPU, memory, swap and pressure each tick, and scans apps on `lib/cadence.js`'s cadence.
pub struct Sampler {
    /// The root under which `proc/` and `sys/` are read.
    fs_root: PathBuf,
    reader: Box<dyn FileReader>,
    lister: Box<dyn DirectoryLister>,
    clock: Box<dyn Clock>,
    error_log: RateLimitedLog,
    /// App names by desktop id, looked up through the `resolve_app_name` port.
    app_names: AppNameCache,
    /// The uid whose user manager's slices are scanned; `None` when unknown.
    uid: Option<u32>,
    /// CPUs counted as 100% of the machine: the per-CPU lines of the latest `/proc/stat`.
    cpu_count: Option<u64>,
    /// Which CPUs are performance and which efficiency cores; `None` on a single-cluster machine.
    cluster_map: Option<ClusterMap>,
    /// The latest `/proc/stat`, the next CPU baseline.
    previous_proc_stat: Option<ProcStat>,
    /// The latest app scan's readings, the next scan's baseline; `None` before the first and after a
    /// scan that failed.
    previous_app_scan: Option<AppScanReadings>,
    /// The latest app scan's ranking; `None` before the first and after a scan that failed.
    latest_app_ranking: Option<AppRanking>,
    latest_snapshot: Option<Snapshot>,
    /// `HH:MM` of the last snapshot with CPU or memory data.
    last_good_clock_label: Option<String>,
    cpu_history: RingBuffer,
    memory_history: RingBuffer,
    /// Whether the latest snapshot is a no-data one (its sample failed): a watch start then
    /// publishes nothing.
    is_latest_snapshot_no_data: bool,
    /// What `lib/cadence.js` reads to decide a scan.
    cadence: CadenceBookkeeping,
}

impl Sampler {
    /// A sampler that has read nothing, under `fs_root` (`/` in the program). Does no I/O.
    pub fn new(fs_root: PathBuf, ports: SamplerPorts) -> Sampler {
        let history_capacity = usize::try_from(CARD_HISTORY_SAMPLES)
            .ok()
            .and_then(NonZeroUsize::new)
            .unwrap_or(FALLBACK_HISTORY_CAPACITY);
        Sampler {
            fs_root,
            reader: ports.reader,
            lister: ports.lister,
            clock: ports.clock,
            error_log: RateLimitedLog::new(ports.log),
            app_names: AppNameCache::new(ports.resolve_app_name),
            uid: None,
            cpu_count: None,
            cluster_map: None,
            previous_proc_stat: None,
            previous_app_scan: None,
            latest_app_ranking: None,
            latest_snapshot: None,
            last_good_clock_label: None,
            cpu_history: RingBuffer::new(history_capacity),
            memory_history: RingBuffer::new(history_capacity),
            is_latest_snapshot_no_data: false,
            cadence: CadenceBookkeeping::default(),
        }
    }

    /// Reads what does not change while the program runs: the uid, the CPU count and the cluster
    /// map. A read or parse failure is logged and leaves its value unknown. The CPU count is the
    /// number of per-CPU lines in `/proc/stat`; every later good sample refreshes it, so a failed read
    /// here recovers on its own.
    pub fn initialize(&mut self) {
        let fs_root = self.fs_root.clone();
        self.uid = self.read_and_parse(&join_under(&fs_root, PROC_SELF_STATUS_PATH), parse_uid);
        let proc_stat = self.read_and_parse(
            &join_under(&fs_root, PROC_STAT_PATH),
            parse_usable_proc_stat,
        );
        if let Some(proc_stat) = proc_stat {
            self.record_cpu_count(&proc_stat);
        }
        self.cluster_map = self.read_cluster_map(&fs_root);
    }

    /// One tick: a fast sample, a scan when due, one publish. Never panics outward.
    ///
    /// A sample that fails (its clock label could not be read, or a port panicked) publishes no data
    /// and skips the scan; a scan that fails drops the ranking.
    ///
    /// Parameters
    /// ----------
    /// tick_number
    ///     The tick count, rising by one per tick: the cadence counts ticks as the difference of two
    ///     tick numbers.
    pub fn run_tick(&mut self, tick_number: u64) -> Publish {
        self.cadence.latest_tick_number = Some(tick_number);
        let fast_sample = match catching_panic(|| self.take_fast_sample()) {
            Ok(Ok(fast_sample)) => fast_sample,
            Ok(Err(failure_text)) | Err(failure_text) => {
                return self.publish_no_data_snapshot(&format!("sample failed: {failure_text}"));
            }
        };
        if let Some(proc_stat) = fast_sample.proc_stat {
            self.record_proc_stat(proc_stat);
        }
        self.scan_apps_if_due(tick_number, &fast_sample.snapshot_without_apps);
        self.is_latest_snapshot_no_data = false;
        let snapshot = Snapshot {
            apps: self.latest_app_ranking.clone(),
            ..fast_sample.snapshot_without_apps
        };
        self.publish_tick_snapshot(snapshot)
    }

    /// A watch starting or ending (whether any client holds a detail watch), which sets the scan
    /// cadence. A watch that starts scans at once, outside the tick, and returns the reveal: a
    /// snapshot of the latest tick's values with the new ranking, appending nothing to the histories
    /// (`Some(publish)`). It does not scan inside the reveal cooldown, nor less than
    /// `MIN_CPU_RANKING_WINDOW_SECONDS` after the last scan, and reveals nothing after a tick that had
    /// no data. A watch that ends only changes the cadence: the ranking stays. Never panics outward.
    pub fn set_detail_watched(&mut self, is_watched: bool) -> Option<Publish> {
        let is_watch_starting = is_watched && !self.cadence.is_detail_watched;
        self.cadence.is_detail_watched = is_watched;
        if is_watch_starting {
            self.scan_for_watch_start()
        } else {
            None
        }
    }

    /// Changes the root the sampler reads under, and nothing else: no state is reset, as assigning
    /// the gjs sampler's public `fsRoot` resets nothing. The program never calls it; the rows and the
    /// golden scenarios do, to read a different fixture root at each tick.
    pub fn set_fs_root(&mut self, fs_root: PathBuf) {
        self.fs_root = fs_root;
    }

    /// The most recent snapshot, `None` before the first.
    pub fn latest_snapshot(&self) -> Option<&Snapshot> {
        self.latest_snapshot.as_ref()
    }

    /// CPU busy fractions, 0 to 1, `None` for no data, oldest first: one per fast tick.
    pub fn cpu_history(&self) -> &RingBuffer {
        &self.cpu_history
    }

    /// Memory used fractions, 0 to 1, `None` for no data, oldest first: one per fast tick.
    pub fn memory_history(&self) -> &RingBuffer {
        &self.memory_history
    }

    /// `HH:MM` of the last snapshot with CPU or memory data, `None` before one. Nothing in the
    /// protocol carries it (the client keeps its own); the rows and diagnosis read it.
    pub fn last_good_clock_label(&self) -> Option<&str> {
        self.last_good_clock_label.as_deref()
    }

    /// Why the latest app scan ran, `None` before the first. Nothing in the protocol carries it; the
    /// rows and diagnosis read it.
    pub fn last_app_scan_reason(&self) -> Option<ScanReason> {
        self.cadence.last_app_scan_reason
    }

    /// Keeps a `/proc/stat` reading as the next CPU baseline and refreshes the CPU count from it.
    fn record_proc_stat(&mut self, proc_stat: ProcStat) {
        self.record_cpu_count(&proc_stat);
        self.previous_proc_stat = Some(proc_stat);
    }

    /// The CPU count from a reading's per-CPU lines, when it has any.
    fn record_cpu_count(&mut self, proc_stat: &ProcStat) {
        if !proc_stat.per_cpu.is_empty() {
            self.cpu_count = u64::try_from(proc_stat.per_cpu.len()).ok();
        }
    }
}
