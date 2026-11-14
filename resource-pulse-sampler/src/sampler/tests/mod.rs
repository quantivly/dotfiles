//! The rows of `gnome-shell/tests/service-sampler.test.js`, on the fixture roots under
//! `gnome-shell/tests/fixtures/` and on in-memory trees, with the helpers that file builds them with.
//! A row's inputs and expected values are the gjs row's; a listener's snapshot and appended history
//! are `run_tick`'s returned `Publish`. A test that is not a gjs row says where its expected values
//! came from.

mod fast_sample;

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Component, Path, PathBuf};
use std::rc::Rc;

use super::{Publish, Sampler, SamplerPorts};
use crate::ports::{
    Clock, DirectoryLister, FileReader, FileSystemLister, FileSystemReader, ReadFailure,
};

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
/// The last tick `make_sampler_past_its_warm_up` runs: ticks 0 (first scan), 1 (warm-up scan), 2
/// and 3 (no scan).
const WARM_UP_SETUP_LAST_TICK: u64 = 3;

/// The absolute path of a fixture root.
fn fixture_root(root_name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../gnome-shell/tests/fixtures")
        .join(root_name)
}

/// A clock whose time the row sets and whose label comes from the row.
struct TestClock {
    now_usec: Rc<Cell<u64>>,
    clock_label: Box<dyn Fn() -> Result<String, String>>,
}

impl Clock for TestClock {
    fn monotonic_usec(&self) -> u64 {
        self.now_usec.get()
    }

    fn clock_label(&self) -> Result<String, String> {
        (self.clock_label)()
    }
}

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
    resolve_app_name: Box<dyn FnMut(&str) -> Option<String>>,
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

    fn with_reader(self, reader: impl FileReader + 'static) -> SamplerSetup {
        SamplerSetup {
            reader: Box::new(reader),
            ..self
        }
    }

    fn with_lister(self, lister: impl DirectoryLister + 'static) -> SamplerSetup {
        SamplerSetup {
            lister: Box::new(lister),
            ..self
        }
    }

    fn with_clock_label(
        self,
        clock_label: Box<dyn Fn() -> Result<String, String>>,
    ) -> SamplerSetup {
        SamplerSetup {
            clock_label,
            ..self
        }
    }

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
            clock: Box::new(TestClock {
                now_usec: Rc::clone(&now_usec),
                clock_label: self.clock_label,
            }),
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

    fn write_file(&self, relative_path: &str, text: &str) {
        self.0
            .borrow_mut()
            .text_by_path
            .insert(Self::absolute_path_of(relative_path), text.to_string());
    }

    fn fail_with(&self, relative_path: &str, failure: ReadFailure) {
        self.0
            .borrow_mut()
            .failure_by_path
            .insert(Self::absolute_path_of(relative_path), failure);
    }

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
