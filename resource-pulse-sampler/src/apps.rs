//! Naming, grouping and ranking apps from systemd cgroup leaves, ported from `lib/apps.js`.
//! Pure logic: no file IO.
//!
//! The gjs original names a leaf with JavaScript regular expressions; each is matched here by a
//! hand-written function whose doc comment gives the pattern it stands for, so that it accepts
//! exactly the texts the pattern accepts and captures what the pattern captures. Three
//! differences between the two languages matter throughout: `.` does not match a line
//! terminator ([`is_js_line_terminator`]); `$` without the `m` flag is the end of the text and
//! nothing else; and `\d` is an ASCII digit. Strings are UTF-16 in JavaScript, which
//! [`crate::js_string`] reproduces where the gjs depends on it.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

use crate::constants::{APP_RANKING_LENGTH, KERNEL_LABEL, SHORT_JOBS_LABEL, UNIT_DISPLAY_ALIASES};
use crate::js_string::{capitalise_first_code_unit, js_string_order};
use crate::parsers::is_js_line_terminator;

#[cfg(test)]
mod tests;

/// The start of an app scope's name.
const APP_SCOPE_PREFIX: &str = "app-";
/// The launchers an app scope's name may carry after [`APP_SCOPE_PREFIX`], each followed by a hyphen.
const APP_SCOPE_LAUNCHERS: [&str; 5] = ["gnome", "flatpak", "kde", "dbus", "systemd"];
/// The end of every scope's name.
const SCOPE_SUFFIX: &str = ".scope";
/// The end of a service's name.
const SERVICE_SUFFIX: &str = ".service";
/// What a snap's name starts with, up to and including its first dot.
const SNAP_PREFIX: &str = "snap.";
/// What a docker scope's name starts with.
const DOCKER_SCOPE_PREFIX: &str = "docker-";
/// The name every docker scope is shown under and grouped by.
const DOCKER_NAME: &str = "docker";
/// What starts the instance of a templated unit (`name@instance.service`).
const UNIT_INSTANCE_MARKER: char = '@';
/// What a GNOME settings daemon's unit name starts with.
const GNOME_SETTINGS_DAEMON_PREFIX: &str = "org.gnome.SettingsDaemon.";
/// What replaces [`GNOME_SETTINGS_DAEMON_PREFIX`] in the name shown.
const SETTINGS_DAEMON_SHORT_PREFIX: &str = "gsd-";
/// A unit named like `<tld>.<vendor>.<Product>...` is reverse-DNS; the first two segments carry no information.
const REVERSE_DNS_TOP_LEVEL_DOMAINS: [&str; 4] = ["org", "com", "net", "io"];
/// How many leading segments of a reverse-DNS unit name carry no information.
const REVERSE_DNS_VENDOR_SEGMENT_COUNT: usize = 2;
/// The key of the pseudo group of the CPU no scanned parent accounts for.
const PSEUDO_KERNEL_GROUP_KEY: &str = "pseudo:kernel";
/// The key of the pseudo group of the CPU the parents spent beyond their live leaves.
const PSEUDO_SHORT_JOBS_GROUP_KEY: &str = "pseudo:short-jobs";
/// The radix of a `\xNN` escape's digits.
const HEX_RADIX: u32 = 16;
/// The percentage a whole machine's CPU capacity is.
const PERCENT_SCALE: f64 = 100.0;
/// How long a snap app's uuid suffix is, hyphen included: `-` and 8-4-4-4-12 hex digits.
const UUID_SUFFIX_GROUP_LENGTHS: [usize; 5] = [8, 4, 4, 4, 12];
/// The characters of a uuid suffix, hyphens included: `1 + 8 + 1 + 4 + 1 + 4 + 1 + 4 + 1 + 12`.
const UUID_SUFFIX_LENGTH: usize = 37;

/// What a cgroup leaf is, with the names that kind carries (the gjs `kind` and its `appId`,
/// `snapName` and `snapAppName`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CgroupKind {
    /// `app-[<launcher>-]<appId>-<digits>.scope`.
    App { app_id: String },
    /// `snap.<snap>.<app>[-<uuid>].scope|service`.
    Snap {
        snap_name: String,
        snap_app_name: String,
    },
    /// `docker-<id>.scope`.
    Docker,
    /// Any other unit.
    Unit,
}

/// A classified cgroup leaf (the gjs `describeCgroup` result).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CgroupDescription {
    pub group_key: String,
    pub kind: CgroupKind,
    pub fallback_name: String,
}

/// A map from text to a value that iterates in the order keys were first inserted, as a JavaScript
/// `Map` does: inserting a key that is present replaces its value and keeps its place.
#[derive(Debug, Clone)]
pub struct InsertionOrderedMap<Value> {
    entries: Vec<(String, Value)>,
    position_by_key: HashMap<String, usize>,
}

impl<Value> Default for InsertionOrderedMap<Value> {
    /// An empty map.
    fn default() -> Self {
        Self {
            entries: Vec::new(),
            position_by_key: HashMap::new(),
        }
    }
}

impl<Value> InsertionOrderedMap<Value> {
    /// An empty map.
    pub fn new() -> Self {
        Self::default()
    }

    /// `map.set(key, value)`.
    pub fn insert(&mut self, key: &str, value: Value) {
        match self.position_by_key.get(key) {
            Some(&position) => {
                if let Some(entry) = self.entries.get_mut(position) {
                    entry.1 = value;
                }
            }
            None => {
                self.position_by_key
                    .insert(key.to_string(), self.entries.len());
                self.entries.push((key.to_string(), value));
            }
        }
    }

    /// `map.get(key)`, `None` for `undefined`.
    pub fn get(&self, key: &str) -> Option<&Value> {
        let position = *self.position_by_key.get(key)?;
        self.entries.get(position).map(|(_, value)| value)
    }

    /// `map.get(key)` for a value that is changed in place.
    fn get_mut(&mut self, key: &str) -> Option<&mut Value> {
        let position = *self.position_by_key.get(key)?;
        self.entries.get_mut(position).map(|(_, value)| value)
    }

    /// The values in insertion order.
    fn values(&self) -> impl Iterator<Item = &Value> {
        self.entries.iter().map(|(_, value)| value)
    }

    /// The entries in insertion order.
    pub fn iter(&self) -> impl Iterator<Item = (&str, &Value)> {
        self.entries
            .iter()
            .map(|(key, value)| (key.as_str(), value))
    }

    /// `map.size`.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// `map.size === 0`.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// The group a cgroup belongs to and the name it is shown under (what the gjs `nameOfCgroup`
/// returns).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppGroup {
    pub group_key: String,
    pub name: String,
}

/// The inputs of [`rank_apps`]: the fields of the gjs `scan`, without its `nameOfCgroup`, which is
/// a parameter. Maps that the gjs iterates are [`InsertionOrderedMap`]s.
///
/// Counters stay the integers they are and become `f64` where the gjs does arithmetic on them. The
/// deltas and the elapsed time are signed integers: a counter that went backwards gives a negative
/// one. Because no field can hold a `NaN` or an infinity, no total can be one either (see
/// [`compare_largest_first`]).
#[derive(Debug, Clone, Default)]
pub struct RankingScan {
    /// `cpu.stat` `usage_usec` by cgroup path, last scan.
    pub previous_usage_usec: HashMap<String, u64>,
    /// The same, this scan; the order the leaves are counted in.
    pub current_usage_usec: InsertionOrderedMap<u64>,
    /// Non-cache memory by cgroup path; the order the leaves are counted in.
    pub memory_bytes_by_cgroup: InsertionOrderedMap<u64>,
    /// Time between the two readings, in microseconds.
    pub elapsed_usec: i64,
    /// CPUs counted as 100%.
    pub cpu_count: u64,
    /// The root cgroup's `usage_usec` delta, if known.
    pub root_cpu_delta_usec: Option<i64>,
    /// The parent slice path of each scanned leaf.
    pub parent_of_leaf: HashMap<String, String>,
    /// Parents whose leaves were listed in the previous scan.
    pub parents_listed_previously: HashSet<String>,
    /// `usage_usec` delta of each parent read in both scans; the order the parents are summed in.
    pub parent_cpu_delta_usec: InsertionOrderedMap<i64>,
}

/// One entry of the CPU ranking.
#[derive(Debug, Clone, PartialEq)]
pub struct CpuRankEntry {
    pub group_key: String,
    pub name: String,
    /// Share of the whole machine's CPU capacity, in percent.
    pub cpu_percent: f64,
}

/// One entry of the memory ranking.
#[derive(Debug, Clone, PartialEq)]
pub struct MemoryRankEntry {
    pub group_key: String,
    pub name: String,
    /// The group's summed memory, as the double the gjs sums.
    pub memory_bytes: f64,
}

/// The result of [`rank_apps`].
#[derive(Debug, Clone, PartialEq, Default)]
pub struct AppRanking {
    /// The CPU ranking's first entry; `None` when nothing has a delta.
    pub top_cpu: Option<CpuRankEntry>,
    /// The memory ranking's first entry.
    pub top_memory: Option<MemoryRankEntry>,
    /// The largest `APP_RANKING_LENGTH` groups by CPU, largest first.
    pub cpu_ranking: Vec<CpuRankEntry>,
    /// The largest `APP_RANKING_LENGTH` real apps by memory, largest first.
    pub memory_ranking: Vec<MemoryRankEntry>,
}

/// A group's running total while a scan is summed.
#[derive(Debug, Clone)]
struct GroupTotal {
    group_key: String,
    name: String,
    value: f64,
}

/// What kernel and short jobs add up to, in microseconds (the gjs `{kernelUsec, shortJobsUsec}`).
struct UnattributedCpu {
    /// `None` without a root delta.
    kernel_usec: Option<f64>,
    short_jobs_usec: f64,
}

/// `Math.max(0, value)`: `NaN` stays `NaN`, and `-0` becomes `+0` (which `f64::max` leaves open).
fn max_with_zero(value: f64) -> f64 {
    if value.is_nan() || value > 0.0 {
        value
    } else {
        0.0
    }
}

/// Adds an amount to a group's running total, creating it under the group's name on first sight.
fn add_to_group(totals: &mut InsertionOrderedMap<GroupTotal>, group: &AppGroup, amount: f64) {
    if let Some(entry) = totals.get_mut(&group.group_key) {
        entry.value += amount;
        return;
    }
    let mut entry = GroupTotal {
        group_key: group.group_key.clone(),
        name: group.name.clone(),
        value: 0.0,
    };
    entry.value += amount;
    totals.insert(&group.group_key, entry);
}

/// Orders totals largest value first; equal values go to the name that sorts first (in
/// JavaScript's string order), then to the group key.
///
/// The gjs comparator returns `second.value - first.value`, which is `NaN`, and so "equal", when a
/// value is `NaN`; and a comparator that is not a total order has no one answer. No total here can
/// be `NaN` or infinite: every one is a sum of at most a few thousand terms, each a finite
/// `u64` or `i64` converted to a double (below 2^64), or a difference of two such. So the values
/// compare as a total order and `partial_cmp` always answers; the `Equal` fallback is for the
/// compiler, not reachable, and cannot panic in `sort_by`.
fn compare_largest_first(first: &GroupTotal, second: &GroupTotal) -> Ordering {
    if first.value != second.value {
        return second
            .value
            .partial_cmp(&first.value)
            .unwrap_or(Ordering::Equal);
    }
    if first.name != second.name {
        return js_string_order(&first.name, &second.name);
    }
    js_string_order(&first.group_key, &second.group_key)
}

/// The largest `APP_RANKING_LENGTH` totals, largest first (a new list; the sort is stable).
fn largest_totals(totals: &InsertionOrderedMap<GroupTotal>) -> Vec<&GroupTotal> {
    let mut sorted: Vec<&GroupTotal> = totals.values().collect();
    sorted.sort_by(|first, second| compare_largest_first(first, second));
    let ranking_length = usize::try_from(APP_RANKING_LENGTH).unwrap_or(usize::MAX);
    sorted.truncate(ranking_length);
    sorted
}

/// Works out one leaf's CPU delta since the previous scan, in microseconds.
///
/// `None` when the leaf cannot be counted: it is new and its parent was not listed in the previous
/// scan, so it may be old and merely unlisted. A counter that went backwards is a unit recreated
/// at the same path: all of its usage is new. Both counters are compared as the doubles they are
/// in the gjs.
fn leaf_cpu_delta_usec(scan: &RankingScan, cgroup_path: &str, current_usec: u64) -> Option<f64> {
    let current_usec = current_usec as f64;
    if let Some(&previous_usec) = scan.previous_usage_usec.get(cgroup_path) {
        let previous_usec = previous_usec as f64;
        return Some(if current_usec >= previous_usec {
            current_usec - previous_usec
        } else {
            current_usec
        });
    }
    // A new leaf ran for less than one interval; it counts in full, but only when its parent's
    // listing proves the leaf did not exist before (otherwise a failed listing would turn every
    // old leaf into a full-lifetime burst).
    let is_parent_listed_previously = scan
        .parent_of_leaf
        .get(cgroup_path)
        .is_some_and(|parent_path| scan.parents_listed_previously.contains(parent_path));
    is_parent_listed_previously.then_some(current_usec)
}

/// Says whether kernel and short jobs can be computed: every parent of a scanned leaf has a delta,
/// and there is at least one. With no parents read, "root minus zero parents" would name the whole
/// machine as kernel.
fn has_complete_parent_deltas(scan: &RankingScan) -> bool {
    if scan.parent_cpu_delta_usec.is_empty() {
        return false;
    }
    scan.parent_of_leaf
        .values()
        .all(|parent_path| scan.parent_cpu_delta_usec.get(parent_path).is_some())
}

/// Computes the CPU of what no leaf accounts for, in microseconds. `None` when the parent deltas
/// are incomplete.
fn unattributed_cpu_usec(
    scan: &RankingScan,
    leaf_delta_usec_by_parent: &HashMap<&str, f64>,
) -> Option<UnattributedCpu> {
    if !has_complete_parent_deltas(scan) {
        return None;
    }
    let mut parent_delta_total_usec = 0.0;
    let mut short_jobs_usec = 0.0;
    for (parent_path, &parent_delta_usec) in scan.parent_cpu_delta_usec.iter() {
        let parent_delta_usec = parent_delta_usec as f64;
        parent_delta_total_usec += parent_delta_usec;
        let leaf_delta_usec = leaf_delta_usec_by_parent
            .get(parent_path)
            .copied()
            .unwrap_or(0.0);
        // Read skew can put the leaves above the parent; that is no negative job.
        short_jobs_usec += max_with_zero(parent_delta_usec - leaf_delta_usec);
    }
    let kernel_usec = scan
        .root_cpu_delta_usec
        .map(|root_delta_usec| max_with_zero(root_delta_usec as f64 - parent_delta_total_usec));
    Some(UnattributedCpu {
        kernel_usec,
        short_jobs_usec,
    })
}

/// Sums each counted leaf's CPU delta into its group, and into its parent's total of leaf deltas.
/// A leaf with no recorded parent is in no parent's total.
fn sum_cpu_by_group<'scan>(
    scan: &'scan RankingScan,
    name_of_cgroup: &mut dyn FnMut(&str) -> AppGroup,
) -> (InsertionOrderedMap<GroupTotal>, HashMap<&'scan str, f64>) {
    let mut cpu_delta_by_group = InsertionOrderedMap::new();
    let mut leaf_delta_usec_by_parent: HashMap<&str, f64> = HashMap::new();
    for (cgroup_path, &current_usec) in scan.current_usage_usec.iter() {
        let Some(delta_usec) = leaf_cpu_delta_usec(scan, cgroup_path, current_usec) else {
            continue;
        };
        if let Some(parent_path) = scan.parent_of_leaf.get(cgroup_path) {
            *leaf_delta_usec_by_parent
                .entry(parent_path.as_str())
                .or_insert(0.0) += delta_usec;
        }
        add_to_group(
            &mut cpu_delta_by_group,
            &name_of_cgroup(cgroup_path),
            delta_usec,
        );
    }
    (cpu_delta_by_group, leaf_delta_usec_by_parent)
}

/// Adds kernel and short jobs, when they can be computed, to the CPU totals.
fn add_unattributed_cpu(
    cpu_delta_by_group: &mut InsertionOrderedMap<GroupTotal>,
    unattributed: &UnattributedCpu,
) {
    if let Some(kernel_usec) = unattributed.kernel_usec {
        let kernel_group = AppGroup {
            group_key: PSEUDO_KERNEL_GROUP_KEY.to_string(),
            name: KERNEL_LABEL.to_string(),
        };
        add_to_group(cpu_delta_by_group, &kernel_group, kernel_usec);
    }
    let short_jobs_group = AppGroup {
        group_key: PSEUDO_SHORT_JOBS_GROUP_KEY.to_string(),
        name: SHORT_JOBS_LABEL.to_string(),
    };
    add_to_group(
        cpu_delta_by_group,
        &short_jobs_group,
        unattributed.short_jobs_usec,
    );
}

/// The CPU ranking: each group's share of the machine's capacity, in percent. Empty when the time
/// between the scans or the CPU count is not positive.
fn cpu_ranking_of(
    scan: &RankingScan,
    cpu_delta_by_group: &InsertionOrderedMap<GroupTotal>,
) -> Vec<CpuRankEntry> {
    let can_rank_cpu = scan.elapsed_usec > 0 && scan.cpu_count > 0;
    if !can_rank_cpu {
        return Vec::new();
    }
    let machine_capacity_usec = scan.elapsed_usec as f64 * scan.cpu_count as f64;
    largest_totals(cpu_delta_by_group)
        .into_iter()
        .map(|entry| CpuRankEntry {
            group_key: entry.group_key.clone(),
            name: entry.name.clone(),
            cpu_percent: entry.value / machine_capacity_usec * PERCENT_SCALE,
        })
        .collect()
}

/// Ranks apps by CPU (share of the whole machine) and by memory. "kernel" (the root cgroup's CPU
/// no scanned parent slice accounts for) and "short jobs" (what the parents spent beyond their
/// live leaves: units that started and ended between two scans) are candidates for CPU only; the
/// memory half names real apps only, by the owner's decision. Both are ranked only when every
/// parent of a scanned leaf has a delta (and at least one does).
///
/// `name_of_cgroup` is called for each leaf with a CPU delta, in the order the scan lists them, and
/// then for each leaf with a memory reading.
pub fn rank_apps(
    scan: &RankingScan,
    name_of_cgroup: &mut dyn FnMut(&str) -> AppGroup,
) -> AppRanking {
    let (mut cpu_delta_by_group, leaf_delta_usec_by_parent) =
        sum_cpu_by_group(scan, name_of_cgroup);
    let mut memory_by_group = InsertionOrderedMap::new();
    for (cgroup_path, &memory_bytes) in scan.memory_bytes_by_cgroup.iter() {
        add_to_group(
            &mut memory_by_group,
            &name_of_cgroup(cgroup_path),
            memory_bytes as f64,
        );
    }
    if let Some(unattributed) = unattributed_cpu_usec(scan, &leaf_delta_usec_by_parent) {
        add_unattributed_cpu(&mut cpu_delta_by_group, &unattributed);
    }
    let cpu_ranking = cpu_ranking_of(scan, &cpu_delta_by_group);
    let memory_ranking: Vec<MemoryRankEntry> = largest_totals(&memory_by_group)
        .into_iter()
        .map(|entry| MemoryRankEntry {
            group_key: entry.group_key.clone(),
            name: entry.name.clone(),
            memory_bytes: entry.value,
        })
        .collect();
    AppRanking {
        top_cpu: cpu_ranking.first().cloned(),
        top_memory: memory_ranking.first().cloned(),
        cpu_ranking,
        memory_ranking,
    }
}

/// Takes a `\xNN` escape from the start of `text`: the character U+00NN it stands for and the
/// text after it. `None` when `text` does not start with one.
fn take_hex_escape(text: &str) -> Option<(char, &str)> {
    let after_escape_marker = text.strip_prefix("\\x")?;
    let mut characters = after_escape_marker.chars();
    let high_digit = characters.next()?.to_digit(HEX_RADIX)?;
    let low_digit = characters.next()?.to_digit(HEX_RADIX)?;
    let byte_value = u8::try_from(high_digit * HEX_RADIX + low_digit).ok()?;
    Some((char::from(byte_value), characters.as_str()))
}

/// Turns each `\xNN` into the one character U+00NN, as String.fromCharCode does.
///
/// `/\\x([0-9a-fA-F]{2})/g`: scanning left to right, an escape that matched is not scanned again.
/// Each escape is one character, never a byte decoded as UTF-8: the two escapes of `é`'s UTF-8
/// bytes give U+00C3 U+00A9.
pub fn unescape_systemd_name(name: &str) -> String {
    let mut unescaped = String::with_capacity(name.len());
    let mut remaining = name;
    while let Some(next_character) = remaining.chars().next() {
        if let Some((decoded_character, after_escape)) = take_hex_escape(remaining) {
            unescaped.push(decoded_character);
            remaining = after_escape;
        } else {
            unescaped.push(next_character);
            remaining = remaining.strip_prefix(next_character).unwrap_or_default();
        }
    }
    unescaped
}

/// Whether `text` holds no character `.` refuses.
fn has_no_line_terminator(text: &str) -> bool {
    !text.chars().any(is_js_line_terminator)
}

/// `(.+)-\d+\.scope$` anchored at the start of `text`: the greedy capture, which is everything
/// before the last hyphen when only digits lie between that hyphen and `.scope` at the end.
/// `None` when the text does not end that way, or the capture is empty or has a line terminator.
fn app_id_before_numbered_scope_suffix(text: &str) -> Option<&str> {
    let without_scope_suffix = text.strip_suffix(SCOPE_SUFFIX)?;
    let without_digits = without_scope_suffix.trim_end_matches(|c: char| c.is_ascii_digit());
    if without_digits.len() == without_scope_suffix.len() {
        return None;
    }
    let app_id = without_digits.strip_suffix('-')?;
    (!app_id.is_empty() && has_no_line_terminator(app_id)).then_some(app_id)
}

/// `(?:gnome|flatpak|kde|dbus|systemd)-` at the start of `text`: what follows it.
fn strip_app_scope_launcher(text: &str) -> Option<&str> {
    APP_SCOPE_LAUNCHERS.iter().find_map(|launcher| {
        text.strip_prefix(launcher)
            .and_then(|after_launcher| after_launcher.strip_prefix('-'))
    })
}

/// The app id of an app scope's still-escaped leaf name.
///
/// Stands for `APP_SCOPE_LAUNCHER_PATTERN` (`^app-(?:gnome|flatpak|kde|dbus|systemd)-(.+)-\d+\.scope$`)
/// tried first and, failing that, `APP_SCOPE_PATTERN` (`^app-(?:(?:gnome|...)-)?(.+)-\d+\.scope$`).
/// The second pattern's optional launcher is tried before its absence, and that branch is the
/// first pattern, which has just failed; so only the launcherless reading is left to try.
fn app_id_of_scope(leaf_name: &str) -> Option<&str> {
    let after_app_prefix = leaf_name.strip_prefix(APP_SCOPE_PREFIX)?;
    strip_app_scope_launcher(after_app_prefix)
        .and_then(app_id_before_numbered_scope_suffix)
        .or_else(|| app_id_before_numbered_scope_suffix(after_app_prefix))
}

/// Whether `suffix` is `-` and 8-4-4-4-12 lowercase hex digits, each group after a hyphen:
/// `-[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}`.
fn is_uuid_suffix(suffix: &str) -> bool {
    let mut pieces = suffix.split('-');
    if pieces.next() != Some("") {
        return false;
    }
    let groups: Vec<&str> = pieces.collect();
    let has_group_lengths = groups.len() == UUID_SUFFIX_GROUP_LENGTHS.len()
        && groups
            .iter()
            .zip(UUID_SUFFIX_GROUP_LENGTHS)
            .all(|(group, length)| group.len() == length);
    has_group_lengths
        && groups
            .iter()
            .all(|group| group.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')))
}

/// The lazy `([^.]+?)(?:-<uuid>)?` of `SNAP_UNIT_PATTERN`, matched against the text between
/// `snap.<snap>.` and `.scope|.service`: the shortest non-empty text with no dot after which only
/// an optional uuid suffix remains. A uuid suffix is taken whenever one ends the text and leaves
/// something before it; any shorter text would leave more than a uuid suffix.
fn snap_app_name_of_unit_text(unit_text: &str) -> Option<&str> {
    if unit_text.is_empty() || unit_text.contains('.') {
        return None;
    }
    let uuid_suffix_start = unit_text.len().checked_sub(UUID_SUFFIX_LENGTH);
    let without_uuid_suffix = uuid_suffix_start.and_then(|split_at| {
        let (before, suffix) = unit_text.split_at_checked(split_at)?;
        (!before.is_empty() && is_uuid_suffix(suffix)).then_some(before)
    });
    Some(without_uuid_suffix.unwrap_or(unit_text))
}

/// `^snap\.([^.]+)\.` on an unescaped name: the snap's name and the text after the dot that ends it.
/// `[^.]` does match a line terminator.
fn split_snap_name(name: &str) -> Option<(&str, &str)> {
    let after_snap_prefix = name.strip_prefix(SNAP_PREFIX)?;
    let (snap_name, after_snap_name) = after_snap_prefix.split_once('.')?;
    (!snap_name.is_empty()).then_some((snap_name, after_snap_name))
}

/// `SNAP_UNIT_PATTERN`'s app name (`^snap\.([^.]+)\.([^.]+?)(?:-<uuid>)?\.(?:scope|service)$`) from
/// the text after `snap.<snap>.`.
fn snap_app_name_after_snap_name(after_snap_name: &str) -> Option<&str> {
    let unit_text = after_snap_name
        .strip_suffix(SCOPE_SUFFIX)
        .or_else(|| after_snap_name.strip_suffix(SERVICE_SUFFIX))?;
    snap_app_name_of_unit_text(unit_text)
}

/// `^docker-.*\.scope$` on an unescaped name.
fn is_docker_scope(name: &str) -> bool {
    name.strip_prefix(DOCKER_SCOPE_PREFIX)
        .and_then(|after_prefix| after_prefix.strip_suffix(SCOPE_SUFFIX))
        .is_some_and(has_no_line_terminator)
}

/// `UNIT_PATTERN` (`^(.+?)(?:@.*)?\.(?:service|scope)$`) on an unescaped name: its capture, or the
/// whole name when the pattern does not match.
///
/// The suffix is fixed by the end of the name. The lazy capture then stops at the first `@` that
/// is not the name's first character (it holds at least one character), or takes everything.
/// No part of the name before the suffix may be a line terminator: `.` refuses it.
fn unit_name_of(name: &str) -> &str {
    let Some(before_suffix) = name
        .strip_suffix(SERVICE_SUFFIX)
        .or_else(|| name.strip_suffix(SCOPE_SUFFIX))
    else {
        return name;
    };
    if !has_no_line_terminator(before_suffix) {
        return name;
    }
    if before_suffix.is_empty() {
        return name;
    }
    let instance_start = before_suffix
        .char_indices()
        .skip(1)
        .find(|(_, character)| *character == UNIT_INSTANCE_MARKER)
        .map(|(byte_index, _)| byte_index);
    instance_start
        .and_then(|byte_index| before_suffix.get(..byte_index))
        .unwrap_or(before_suffix)
}

/// The alias a unit is shown under, if one is configured.
fn alias_of_unit(unit_name: &str) -> Option<&'static str> {
    UNIT_DISPLAY_ALIASES
        .iter()
        .find(|(aliased_unit, _)| *aliased_unit == unit_name)
        .map(|(_, display_name)| *display_name)
}

/// Names a service unit for display: a configured alias, `gsd-<x>` for a GNOME settings daemon, the
/// name minus its first two segments for any other reverse-DNS unit, else the unit name itself.
fn display_name_of_unit(unit_name: &str) -> String {
    if let Some(alias) = alias_of_unit(unit_name) {
        return alias.to_string();
    }
    if let Some(daemon_name) = unit_name.strip_prefix(GNOME_SETTINGS_DAEMON_PREFIX) {
        return format!(
            "{SETTINGS_DAEMON_SHORT_PREFIX}{}",
            daemon_name.to_lowercase()
        );
    }
    // `split('.')` into at most three pieces: the two vendor segments and the rest, which is what
    // `segments.slice(2).join('.')` rebuilds (an empty rest is one empty segment).
    let mut segments = unit_name.splitn(REVERSE_DNS_VENDOR_SEGMENT_COUNT + 1, '.');
    let top_level_domain = segments.next().unwrap_or_default();
    let is_reverse_dns_top_level_domain = REVERSE_DNS_TOP_LEVEL_DOMAINS.contains(&top_level_domain);
    let _vendor = segments.next();
    match segments.next() {
        Some(product_segments) if is_reverse_dns_top_level_domain => product_segments.to_string(),
        _ => unit_name.to_string(),
    }
}

/// Capitalises the last dot-separated segment of an application id.
fn capitalise_last_segment(app_id: &str) -> String {
    let last_segment = app_id.rsplit('.').next().unwrap_or(app_id);
    capitalise_first_code_unit(last_segment)
}

/// Classifies a cgroup leaf and names the group it belongs to.
///
/// The app scope is matched on the still-escaped name: `app-gnome\x2dcalculator-1.scope` is the app
/// `gnome-calculator`, not the app `calculator` launched by gnome. Every other kind is matched on the
/// unescaped name.
pub fn describe_cgroup(leaf_name: &str) -> CgroupDescription {
    if let Some(escaped_app_id) = app_id_of_scope(leaf_name) {
        let app_id = unescape_systemd_name(escaped_app_id);
        return CgroupDescription {
            group_key: format!("app:{app_id}"),
            fallback_name: capitalise_last_segment(&app_id),
            kind: CgroupKind::App { app_id },
        };
    }
    let name = unescape_systemd_name(leaf_name);
    if let Some((snap_name, after_snap_name)) = split_snap_name(&name) {
        let snap_app_name = snap_app_name_after_snap_name(after_snap_name).unwrap_or(snap_name);
        return CgroupDescription {
            group_key: format!("snap:{snap_name}"),
            fallback_name: snap_name.to_string(),
            kind: CgroupKind::Snap {
                snap_name: snap_name.to_string(),
                snap_app_name: snap_app_name.to_string(),
            },
        };
    }
    if is_docker_scope(&name) {
        return CgroupDescription {
            group_key: format!("docker:{DOCKER_NAME}"),
            kind: CgroupKind::Docker,
            fallback_name: DOCKER_NAME.to_string(),
        };
    }
    let unit_name = unit_name_of(&name);
    CgroupDescription {
        group_key: format!("unit:{unit_name}"),
        kind: CgroupKind::Unit,
        fallback_name: display_name_of_unit(unit_name),
    }
}

/// Picks the name to show for a described cgroup. An app is looked up as `<appId>.desktop` and a
/// snap as `<snap>_<app>.desktop`; every other kind keeps its fallback name. An answer of `None`
/// or of the empty string (the gjs `||`) keeps the fallback name.
pub fn display_name_for(
    description: &CgroupDescription,
    resolve_app_name: &mut dyn FnMut(&str) -> Option<String>,
) -> String {
    let desktop_id = match &description.kind {
        CgroupKind::App { app_id } => format!("{app_id}.desktop"),
        CgroupKind::Snap {
            snap_name,
            snap_app_name,
        } => format!("{snap_name}_{snap_app_name}.desktop"),
        CgroupKind::Docker | CgroupKind::Unit => return description.fallback_name.clone(),
    };
    resolve_app_name(&desktop_id)
        .filter(|resolved_name| !resolved_name.is_empty())
        .unwrap_or_else(|| description.fallback_name.clone())
}
