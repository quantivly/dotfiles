//! The rows of `gnome-shell/tests/service-sampler.test.js`, on the fixture roots under
//! `gnome-shell/tests/fixtures/` and on in-memory trees, with the helpers that file builds them with.
//! A row's inputs and expected values are the gjs row's; a listener's snapshot and appended history
//! are `run_tick`'s returned `Publish`. A test that is not a gjs row says where its expected values
//! came from.

mod app_scan;
mod cadence;
mod cgroup_tree;
mod fast_sample;
mod watch;

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Component, Path, PathBuf};
use std::rc::Rc;

use super::{Publish, ResolveAppName, Sampler, SamplerPorts, Snapshot};
use crate::apps::CpuRankEntry;
use crate::ports::{DirectoryLister, FileReader, FileSystemLister, FileSystemReader, ReadFailure};
use crate::test_support::{fixture_root, SettableClock};

/// The clock label every row's clock gives unless the row says otherwise.
const FIXTURE_CLOCK_LABEL: &str = "14:02";
/// A second label, for a row that tells two samples apart.
const LATER_CLOCK_LABEL: &str = "14:04";
/// Two fast ticks apart.
const SAMPLE_SPACING_USEC: u64 = 2_000_000;
/// Two app scans apart in the fixture rows.
const APP_SCAN_SPACING_USEC: u64 = 6_000_000;
/// Where the in-memory tree pretends to live; nothing is ever read from there.
const FAKE_ROOT_PATH: &str = "/resource-pulse-fake-root";
/// The cgroup v2 root, relative to the fs root.
const CGROUP_ROOT_RELATIVE_PATH: &str = "sys/fs/cgroup";
/// The end of the root cgroup's cpu.stat path: read once per app scan, so a read of it marks a scan.
const ROOT_CGROUP_CPU_STAT_SUFFIX: &str = "/sys/fs/cgroup/cpu.stat";
/// root-a's files that `initialize` and the fast tick read, copied into an in-memory tree so it
/// initializes cleanly and its ticks read complete samples.
const SAMPLE_FIXTURE_FILES: [&str; 10] = [
    "proc/stat",
    "proc/meminfo",
    "proc/swaps",
    "proc/pressure/cpu",
    "proc/pressure/memory",
    "proc/pressure/io",
    "proc/self/status",
    "sys/block/zram0/mm_stat",
    "sys/devices/cpu_core/cpus",
    "sys/devices/cpu_atom/cpus",
];
/// The tick of the first interval scan with no watch held: the warm-up at tick 1, then 30 ticks.
const FIRST_UNWATCHED_INTERVAL_SCAN_TICK: u64 = 31;

/// A label source that always gives the fixture's label.
fn fixture_clock_label() -> Box<dyn Fn() -> Result<String, String>> {
    Box::new(|| Ok(FIXTURE_CLOCK_LABEL.to_string()))
}

/// A label source that fails with `clock exploded` while the flag is set (the gjs rows' broken
/// clock), and gives the fixture's label otherwise.
fn breakable_clock_label(
    is_clock_broken: &Rc<Cell<bool>>,
) -> Box<dyn Fn() -> Result<String, String>> {
    let is_clock_broken = Rc::clone(is_clock_broken);
    Box::new(move || {
        if is_clock_broken.get() {
            Err("clock exploded".to_string())
        } else {
            Ok(FIXTURE_CLOCK_LABEL.to_string())
        }
    })
}

/// A sampler under test and its spies (gjs `makeSamplerAt`'s `{sampler, clock, logged}`).
struct TestSampler {
    sampler: Sampler,
    now_usec: Rc<Cell<u64>>,
    logged: Rc<RefCell<Vec<String>>>,
}

impl TestSampler {
    /// Moves the clock on.
    fn advance_clock(&self, usec: u64) {
        self.now_usec.set(self.now_usec.get() + usec);
    }

    /// What has been logged so far.
    fn logged(&self) -> Vec<String> {
        self.logged.borrow().clone()
    }
}

/// What a row hands a sampler: by default the real reader and lister, the fixture's label and no
/// name lookup (gjs `makeSamplerAt`'s defaults), each replaceable.
struct SamplerSetup {
    fs_root: PathBuf,
    reader: Box<dyn FileReader>,
    lister: Box<dyn DirectoryLister>,
    clock_label: Box<dyn Fn() -> Result<String, String>>,
    resolve_app_name: ResolveAppName,
}

impl SamplerSetup {
    /// A sampler on a fixture root (gjs `makeSampler`).
    fn at_fixture(root_name: &str) -> SamplerSetup {
        SamplerSetup {
            fs_root: fixture_root(root_name),
            reader: Box::new(FileSystemReader),
            lister: Box::new(FileSystemLister),
            clock_label: fixture_clock_label(),
            resolve_app_name: Box::new(|_| None),
        }
    }

    /// A sampler on an in-memory tree (gjs `makeTreeSampler`).
    fn on_tree(tree: &FakeFileTree) -> SamplerSetup {
        SamplerSetup {
            fs_root: PathBuf::from(FAKE_ROOT_PATH),
            reader: Box::new(tree.clone()),
            lister: Box::new(tree.clone()),
            ..SamplerSetup::at_fixture("root-a")
        }
    }

    /// The same setup with another reader.
    fn with_reader(self, reader: impl FileReader + 'static) -> SamplerSetup {
        SamplerSetup {
            reader: Box::new(reader),
            ..self
        }
    }

    /// The same setup with another lister.
    fn with_lister(self, lister: impl DirectoryLister + 'static) -> SamplerSetup {
        SamplerSetup {
            lister: Box::new(lister),
            ..self
        }
    }

    /// The same setup with another clock label source.
    fn with_clock_label(
        self,
        clock_label: Box<dyn Fn() -> Result<String, String>>,
    ) -> SamplerSetup {
        SamplerSetup {
            clock_label,
            ..self
        }
    }

    /// The same setup with another name lookup.
    fn with_resolve_app_name(
        self,
        resolve_app_name: impl FnMut(&str) -> Option<String> + 'static,
    ) -> SamplerSetup {
        SamplerSetup {
            resolve_app_name: Box::new(resolve_app_name),
            ..self
        }
    }

    /// The sampler, its clock at 0, logging into a list.
    fn build(self) -> TestSampler {
        let now_usec = Rc::new(Cell::new(0));
        let logged = Rc::new(RefCell::new(Vec::new()));
        let log_sink = Rc::clone(&logged);
        let ports = SamplerPorts {
            reader: self.reader,
            lister: self.lister,
            clock: Box::new(SettableClock::new(Rc::clone(&now_usec), self.clock_label)),
            resolve_app_name: self.resolve_app_name,
            log: Box::new(move |line| log_sink.borrow_mut().push(line.to_string())),
        };
        TestSampler {
            sampler: Sampler::new(self.fs_root, ports),
            now_usec,
            logged,
        }
    }
}

/// The real reader, counting the app scans as they read the root cgroup's cpu.stat (gjs
/// `makeScanSpottingReader`).
struct ScanSpottingReader {
    scan_count: Rc<Cell<u64>>,
}

impl FileReader for ScanSpottingReader {
    /// Counts a scan when the path is the root cgroup's cpu.stat, then reads as the real reader.
    fn read_to_text(&self, path: &Path) -> Result<String, ReadFailure> {
        if path
            .to_string_lossy()
            .ends_with(ROOT_CGROUP_CPU_STAT_SUFFIX)
        {
            self.scan_count.set(self.scan_count.get() + 1);
        }
        FileSystemReader.read_to_text(path)
    }
}

/// What the in-memory tree holds.
#[derive(Default)]
struct FakeTreeState {
    text_by_path: BTreeMap<PathBuf, String>,
    failure_by_path: HashMap<PathBuf, ReadFailure>,
    read_paths: Vec<PathBuf>,
}

/// An in-memory file tree under [`FAKE_ROOT_PATH`], standing in for the reader and the lister (gjs
/// `makeFakeFileTree`). A directory exists while a file lies somewhere under it; a path can be made
/// to fail with any failure. Clones share one tree.
#[derive(Clone, Default)]
struct FakeFileTree(Rc<RefCell<FakeTreeState>>);

impl FakeFileTree {
    /// The absolute path of a path relative to the tree's root.
    fn absolute_path_of(relative_path: &str) -> PathBuf {
        Path::new(FAKE_ROOT_PATH).join(relative_path)
    }

    /// Puts a file in the tree, replacing any there.
    fn write_file(&self, relative_path: &str, text: &str) {
        self.0
            .borrow_mut()
            .text_by_path
            .insert(Self::absolute_path_of(relative_path), text.to_string());
    }

    /// Makes a read or a listing of the path fail as given.
    fn fail_with(&self, relative_path: &str, failure: ReadFailure) {
        self.0
            .borrow_mut()
            .failure_by_path
            .insert(Self::absolute_path_of(relative_path), failure);
    }

    /// Lets the path be read or listed again.
    fn clear_failure(&self, relative_path: &str) {
        self.0
            .borrow_mut()
            .failure_by_path
            .remove(&Self::absolute_path_of(relative_path));
    }

    /// Every path read, oldest first.
    fn read_paths(&self) -> Vec<PathBuf> {
        self.0.borrow().read_paths.clone()
    }
}

impl FileReader for FakeFileTree {
    /// Records the read, then gives the failure set for the path, its text, or `NotFound`.
    fn read_to_text(&self, path: &Path) -> Result<String, ReadFailure> {
        let mut state = self.0.borrow_mut();
        state.read_paths.push(path.to_path_buf());
        if let Some(failure) = state.failure_by_path.get(path) {
            return Err(failure.clone());
        }
        state
            .text_by_path
            .get(path)
            .cloned()
            .ok_or(ReadFailure::NotFound)
    }
}

impl DirectoryLister for FakeFileTree {
    /// The first component of every file's path below the directory that has more below it,
    /// once each, in name order; `NotFound` when nothing lies below it.
    fn subdirectory_names(&self, path: &Path) -> Result<Vec<String>, ReadFailure> {
        let state = self.0.borrow();
        if let Some(failure) = state.failure_by_path.get(path) {
            return Err(failure.clone());
        }
        let descendant_paths: Vec<&Path> = state
            .text_by_path
            .keys()
            .filter_map(|file_path| file_path.strip_prefix(path).ok())
            .filter(|relative_path| relative_path.components().next().is_some())
            .collect();
        if descendant_paths.is_empty() {
            return Err(ReadFailure::NotFound);
        }
        let subdirectory_names: BTreeSet<String> = descendant_paths
            .iter()
            .filter(|relative_path| relative_path.components().count() > 1)
            .filter_map(|relative_path| match relative_path.components().next() {
                Some(Component::Normal(name)) => Some(name.to_string_lossy().into_owned()),
                _ => None,
            })
            .collect();
        Ok(subdirectory_names.into_iter().collect())
    }
}

/// An in-memory tree holding root-a's sample files, so its sampler logs nothing of its own (gjs
/// `makeFakeTreeWithSampleFiles`).
fn fake_tree_with_sample_files() -> FakeFileTree {
    let tree = FakeFileTree::default();
    for relative_path in SAMPLE_FIXTURE_FILES {
        let text = std::fs::read_to_string(fixture_root("root-a").join(relative_path)).unwrap();
        tree.write_file(relative_path, &text);
    }
    tree
}

/// Runs ticks `0..=last_tick_number` two seconds apart, as the gjs rows' loops do.
fn run_ticks(
    test_sampler: &mut TestSampler,
    tick_numbers: std::ops::RangeInclusive<u64>,
) -> Vec<Publish> {
    let mut publishes = Vec::new();
    for tick_number in tick_numbers {
        test_sampler.advance_clock(SAMPLE_SPACING_USEC);
        publishes.push(test_sampler.sampler.run_tick(tick_number));
    }
    publishes
}

const USER_SERVICE_PATH: &str = "user.slice/user-1000.slice/user@1000.service";
const APP_SLICE: &str = "user.slice/user-1000.slice/user@1000.service/app.slice";
const SESSION_SLICE: &str = "user.slice/user-1000.slice/user@1000.service/session.slice";
const BACKGROUND_SLICE: &str = "user.slice/user-1000.slice/user@1000.service/background.slice";
const SYSTEM_SLICE: &str = "system.slice";
/// The slice every user's session lives in, and this user's: never scanned parents themselves
/// (ruling R22).
const USER_SLICE: &str = "user.slice";
const USER_1000_SLICE: &str = "user.slice/user-1000.slice";
/// Where systemd-machined puts VMs and containers, a top-level slice like system.slice.
const MACHINE_SLICE: &str = "machine.slice";
/// A libvirt VM's scope, named as machined escapes it.
const VM_LEAF: &str = "machine.slice/machine-qemu\\x2d1\\x2dwin11.scope";
/// The name the VM's scope ranks under.
const VM_NAME: &str = "machine-qemu-1-win11";
/// The slice a `systemd-run --user --slice=build` job runs in, beside app.slice, and the job's unit.
const BUILD_SLICE: &str = "user.slice/user-1000.slice/user@1000.service/build.slice";
const BUILD_JOB_LEAF: &str =
    "user.slice/user-1000.slice/user@1000.service/build.slice/run-u42.service";
const BUILD_JOB_NAME: &str = "run-u42";
const EDITOR_LEAF: &str =
    "user.slice/user-1000.slice/user@1000.service/app.slice/app-org.example.Editor-1.scope";
const BUILDER_LEAF: &str =
    "user.slice/user-1000.slice/user@1000.service/app.slice/app-org.example.Builder-7.scope";
const SHELL_LEAF: &str =
    "user.slice/user-1000.slice/user@1000.service/session.slice/org.gnome.Shell@ubuntu.service";
const DAEMON_LEAF: &str = "system.slice/example-daemon.service";
/// The root cgroup's key in a set of counters: its path relative to the cgroup root.
const ROOT_CGROUP_KEY: &str = "";
const SLICE_SUFFIX: &str = ".slice";
/// The memory.current of every leaf `write_cgroup_counters` writes.
const LEAF_MEMORY_BYTES: u64 = 1_000_000;
/// The parents' 1,000,000 µs of `STEADY_DELTAS_USEC`, in all.
const STEADY_PARENTS_DELTA_USEC: u64 = 1_000_000;
/// What the root spends beyond every parent in the R22 rows: kernel, at 2.5%.
const KERNEL_ONLY_DELTA_USEC: u64 = 100_000;
/// What the VM under machine.slice spends between the scans: 40% of the machine.
const VM_DELTA_USEC: u64 = 1_600_000;
/// What the job under build.slice spends between the scans: 30% of the machine.
const BUILD_JOB_DELTA_USEC: u64 = 1_200_000;
/// What user.slice and user-1000.slice spend between the scans: the user's slices' 700,000 µs and
/// a login's 50,000.
const USER_SLICE_DELTA_USEC: u64 = 750_000;
/// A new app leaf's whole usage, and what its parent spends with it: Editor 300,000, Builder this,
/// short 100,000.
const BUILDER_USAGE_USEC: u64 = 1_500_000;
const APP_SLICE_DELTA_WITH_BUILDER_USEC: u64 = 1_900_000;
/// An hour of CPU: a long-lived leaf's usage_usec, which no scan may ever count as one interval's.
const LONG_LIVED_LEAF_USAGE_USEC: u64 = 3_600_000_000;
/// The text of the in-memory tree's "permission denied" for a directory.
const DIRECTORY_DENIED_TEXT: &str = "Error opening directory: Permission denied";
/// The text of the in-memory tree's "permission denied" for a file.
const FILE_DENIED_TEXT: &str = "Error opening file: Permission denied";

/// usage_usec by cgroup path relative to the cgroup root (the gjs rows' counter objects).
type CounterSet = BTreeMap<String, u64>;

/// A counter set from pairs.
fn counters(pairs: &[(&str, u64)]) -> CounterSet {
    pairs
        .iter()
        .map(|(cgroup_path, usage_usec)| (cgroup_path.to_string(), *usage_usec))
        .collect()
}

/// Counters of the first of two scans in the in-memory tree; the second adds a row's deltas.
fn first_scan_counters_usec() -> CounterSet {
    counters(&[
        (ROOT_CGROUP_KEY, 10_000_000),
        (APP_SLICE, 1_000_000),
        (SESSION_SLICE, 1_000_000),
        (BACKGROUND_SLICE, 1_000_000),
        (SYSTEM_SLICE, 1_000_000),
        (EDITOR_LEAF, 500_000),
        (SHELL_LEAF, 500_000),
        (DAEMON_LEAF, 500_000),
    ])
}

/// What each parent and leaf spends between the two scans (2 s on 2 CPUs: 4,000,000 µs is the
/// whole machine). The parents spend 1,000,000 in all, 400,000 of it beyond their leaves: 100,000
/// in app.slice, 100,000 in a background.slice with no leaf, and 200,000 in system.slice. That is
/// short jobs at 10%.
fn steady_deltas_usec() -> CounterSet {
    counters(&[
        (APP_SLICE, 400_000),
        (EDITOR_LEAF, 300_000),
        (SESSION_SLICE, 200_000),
        (SHELL_LEAF, 200_000),
        (BACKGROUND_SLICE, 100_000),
        (SYSTEM_SLICE, 300_000),
        (DAEMON_LEAF, 100_000),
    ])
}

/// A counter set with more pairs set (gjs `{...base, [key]: value}`).
fn with_counters(base: &CounterSet, pairs: &[(&str, u64)]) -> CounterSet {
    let mut combined = base.clone();
    combined.extend(counters(pairs));
    combined
}

/// Writes cgroup counters into an in-memory tree: a cpu.stat for each cgroup, and a memory.current
/// for each one that is neither the root nor a slice (a leaf).
fn write_cgroup_counters(tree: &FakeFileTree, usage_usec_by_cgroup: &CounterSet) {
    for (cgroup_path, usage_usec) in usage_usec_by_cgroup {
        let cgroup_directory = cgroup_relative_path(cgroup_path);
        tree.write_file(
            &format!("{cgroup_directory}/cpu.stat"),
            &format!("usage_usec {usage_usec}\n"),
        );
        let is_leaf = cgroup_path != ROOT_CGROUP_KEY && !cgroup_path.ends_with(SLICE_SUFFIX);
        if is_leaf {
            tree.write_file(
                &format!("{cgroup_directory}/memory.current"),
                &format!("{LEAF_MEMORY_BYTES}\n"),
            );
        }
    }
}

/// A cgroup's directory relative to the fs root.
fn cgroup_relative_path(cgroup_path: &str) -> String {
    if cgroup_path.is_empty() {
        CGROUP_ROOT_RELATIVE_PATH.to_string()
    } else {
        format!("{CGROUP_ROOT_RELATIVE_PATH}/{cgroup_path}")
    }
}

/// Adds deltas to counters; a cgroup with no earlier count starts from 0 (a new leaf).
fn counters_after(counters_usec: &CounterSet, deltas_usec: &CounterSet) -> CounterSet {
    let mut later_counters_usec = counters_usec.clone();
    for (cgroup_path, delta_usec) in deltas_usec {
        *later_counters_usec.entry(cgroup_path.clone()).or_insert(0) += delta_usec;
    }
    later_counters_usec
}

/// Counters or deltas without one cgroup, as if it did not exist.
fn without_cgroup(usec_by_cgroup: &CounterSet, cgroup_path: &str) -> CounterSet {
    let mut remaining_usec_by_cgroup = usec_by_cgroup.clone();
    remaining_usec_by_cgroup.remove(cgroup_path);
    remaining_usec_by_cgroup
}

/// A change made to the in-memory tree at one point of `top_cpu_after_two_scans`.
type TreeChange = Box<dyn FnOnce(&FakeFileTree)>;

/// What `top_cpu_after_two_scans` changes, and the first scan's counters.
struct TwoScanOptions {
    first_scan_counters_usec: CounterSet,
    before_initialize: TreeChange,
    before_first_scan: TreeChange,
    before_second_scan: TreeChange,
}

impl Default for TwoScanOptions {
    /// The first scan's usual counters, and no change to the tree.
    fn default() -> Self {
        TwoScanOptions {
            first_scan_counters_usec: first_scan_counters_usec(),
            before_initialize: Box::new(|_| {}),
            before_first_scan: Box::new(|_| {}),
            before_second_scan: Box::new(|_| {}),
        }
    }
}

/// Scans an in-memory tree twice, two seconds apart (the first tick, then the warm-up tick): the
/// first scan's counters, then those plus the deltas (gjs `topCpuAfterTwoScans`). Returns the second
/// scan's top CPU entry, what was logged, and the tree.
fn top_cpu_after_two_scans(
    deltas_usec: &CounterSet,
    options: TwoScanOptions,
) -> (Option<CpuRankEntry>, Vec<String>, FakeFileTree) {
    let tree = fake_tree_with_sample_files();
    write_cgroup_counters(&tree, &options.first_scan_counters_usec);
    let mut test_sampler = SamplerSetup::on_tree(&tree).build();
    (options.before_initialize)(&tree);
    test_sampler.sampler.initialize();
    (options.before_first_scan)(&tree);
    test_sampler.sampler.run_tick(0);
    test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    write_cgroup_counters(
        &tree,
        &counters_after(&options.first_scan_counters_usec, deltas_usec),
    );
    (options.before_second_scan)(&tree);
    test_sampler.sampler.run_tick(1);
    let top_cpu = test_sampler
        .sampler
        .latest_snapshot()
        .and_then(|snapshot| snapshot.apps.as_ref())
        .and_then(|apps| apps.top_cpu.clone());
    (top_cpu, test_sampler.logged(), tree)
}

/// A CPU ranking entry.
fn cpu_entry(group_key: &str, name: &str, cpu_percent: f64) -> CpuRankEntry {
    CpuRankEntry {
        group_key: group_key.to_string(),
        name: name.to_string(),
        cpu_percent,
    }
}

/// A line as the sampler logs it.
fn logged_line(message: &str) -> String {
    format!("{} {message}", crate::constants::LOG_PREFIX)
}

/// Runs two app scans six seconds apart through the cadence: the first tick's scan on root-a, then
/// the warm-up tick's on the given root (gjs `scanTwice`). Returns the second tick's two winners and
/// what was logged.
fn scan_twice(
    second_root_name: &str,
) -> (
    Option<CpuRankEntry>,
    Option<crate::apps::MemoryRankEntry>,
    Vec<String>,
) {
    let mut test_sampler = SamplerSetup::at_fixture("root-a").build();
    test_sampler.sampler.initialize();
    test_sampler.sampler.run_tick(0);
    test_sampler.advance_clock(APP_SCAN_SPACING_USEC);
    test_sampler
        .sampler
        .set_fs_root(fixture_root(second_root_name));
    test_sampler.sampler.run_tick(1);
    let apps = test_sampler
        .sampler
        .latest_snapshot()
        .and_then(|snapshot| snapshot.apps.clone())
        .unwrap();
    (apps.top_cpu, apps.top_memory, test_sampler.logged())
}

/// An in-memory tree's lister, except that one cgroup lists its children in a given order, as a real
/// directory may (gjs `listingChildrenInOrder`).
struct ListingChildrenInOrder {
    tree: FakeFileTree,
    directory_path: PathBuf,
    child_names: Vec<String>,
}

impl ListingChildrenInOrder {
    /// A lister over the tree whose one directory lists the given names, in that order.
    fn new(tree: &FakeFileTree, directory_relative_path: &str, child_names: &[&str]) -> Self {
        ListingChildrenInOrder {
            tree: tree.clone(),
            directory_path: Path::new(FAKE_ROOT_PATH)
                .join(CGROUP_ROOT_RELATIVE_PATH)
                .join(directory_relative_path),
            child_names: child_names.iter().map(|name| name.to_string()).collect(),
        }
    }
}

impl DirectoryLister for ListingChildrenInOrder {
    /// The given names for that directory; the tree's listing for any other.
    fn subdirectory_names(&self, path: &Path) -> Result<Vec<String>, ReadFailure> {
        if path == self.directory_path {
            return Ok(self.child_names.clone());
        }
        self.tree.subdirectory_names(path)
    }
}
