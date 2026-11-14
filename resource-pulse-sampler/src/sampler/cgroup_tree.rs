//! Listing the cgroup tree an app scan ranks (`_listCgroupTree` and the listers it calls): the
//! scanned parents, found afresh every scan (ruling R22), and the leaves under each, in name order.

use std::collections::{HashMap, HashSet};
use std::path::Path;

use super::paths::{join_relative, join_under};
use super::Sampler;
use crate::constants::APP_SCAN_SKIPPED_UNIT_SUFFIXES;
use crate::js_string::js_string_order;

/// The top-level slice of every user's session: never a scanned parent, since its users' slices are
/// (ruling R22).
const USER_SLICE: &str = "user.slice";
/// What a slice's name ends with.
const SLICE_SUFFIX: &str = ".slice";
/// The root cgroup's path relative to the cgroup root.
pub(super) const ROOT_CGROUP_RELATIVE_PATH: &str = "";
/// How a failure line names the root cgroup, whose relative path is empty.
const ROOT_CGROUP_LOG_NAME: &str = "the cgroup root";

/// The cgroup reads and listings that failed in one app scan, logged together as one line.
#[derive(Default)]
pub(super) struct CgroupReadFailures {
    count: u64,
    /// The first failure's path relative to the cgroup root, and its text.
    first_failure: Option<(String, String)>,
}

impl CgroupReadFailures {
    /// Counts a failure, keeping the first one's path and text for the line.
    pub(super) fn note(&mut self, relative_path: &str, failure_text: String) {
        if self.first_failure.is_none() {
            self.first_failure = Some((relative_path.to_string(), failure_text));
        }
        self.count += 1;
    }

    /// The journal line for every failure counted, `None` when there was none: for example
    /// `cannot read 3 cgroups, first: system.slice/x.service: Permission denied`, the root cgroup
    /// named [`ROOT_CGROUP_LOG_NAME`].
    pub(super) fn describe(&self) -> Option<String> {
        let (first_relative_path, first_failure_text) = self.first_failure.as_ref()?;
        let first_path_text = if first_relative_path == ROOT_CGROUP_RELATIVE_PATH {
            ROOT_CGROUP_LOG_NAME
        } else {
            first_relative_path.as_str()
        };
        let count = self.count;
        Some(format!(
            "cannot read {count} cgroups, first: {first_path_text}: {first_failure_text}"
        ))
    }
}

/// One scan's listing of the tree.
pub(super) struct CgroupTree {
    /// The scanned parents, relative to the cgroup root, in the order found.
    pub(super) parent_relative_paths: Vec<String>,
    /// The leaves to rank, relative to the cgroup root, in the order listed.
    pub(super) leaf_relative_paths: Vec<String>,
    /// Each listed leaf's scanned parent.
    pub(super) parent_of_leaf: HashMap<String, String>,
    /// The parents whose listing, and every sub-slice's, succeeded.
    pub(super) fully_listed_parent_paths: HashSet<String>,
    /// Whether every parent was found and fully listed, and the uid is known.
    pub(super) is_every_parent_fully_listed: bool,
}

/// What `_listLeavesUnder` gives for one parent.
struct ParentLeaves {
    leaf_relative_paths: Vec<String>,
    is_fully_listed: bool,
}

/// Whether a leaf belongs to a unit type that can host an app (a service, a scope, or a slice too
/// deep to descend into), as opposed to a mount, socket, timer and the like.
fn can_host_app(cgroup_path: &str) -> bool {
    !APP_SCAN_SKIPPED_UNIT_SUFFIXES
        .iter()
        .any(|unit_suffix| cgroup_path.ends_with(unit_suffix))
}

/// The slices of a listing that `is_parent` accepts, added to the parents (gjs `addSlices`).
fn slices_among<'listing>(
    child_relative_paths: &'listing [String],
    is_parent: impl Fn(&str) -> bool + 'listing,
) -> impl Iterator<Item = String> + 'listing {
    child_relative_paths
        .iter()
        .filter(|child_path| child_path.ends_with(SLICE_SUFFIX))
        .filter(move |slice_path| is_parent(slice_path))
        .cloned()
}

impl Sampler {
    /// Lists the leaves to rank under each scanned parent, and which parents were listed completely.
    pub(super) fn list_cgroup_tree(
        &self,
        cgroup_root_path: &Path,
        failures: &mut CgroupReadFailures,
    ) -> CgroupTree {
        let (parent_relative_paths, is_every_parent_found) =
            self.find_app_scan_parents(cgroup_root_path, failures);
        let mut leaf_relative_paths = Vec::new();
        let mut parent_of_leaf = HashMap::new();
        let mut fully_listed_parent_paths = HashSet::new();
        for parent_relative_path in &parent_relative_paths {
            let parent_leaves =
                self.list_leaves_under(cgroup_root_path, parent_relative_path, failures);
            for leaf_relative_path in parent_leaves.leaf_relative_paths {
                // A Map set: a leaf seen again keeps its first place and takes the later parent.
                let earlier_parent =
                    parent_of_leaf.insert(leaf_relative_path.clone(), parent_relative_path.clone());
                if earlier_parent.is_none() {
                    leaf_relative_paths.push(leaf_relative_path);
                }
            }
            if parent_leaves.is_fully_listed {
                fully_listed_parent_paths.insert(parent_relative_path.clone());
            }
        }
        // Without the uid the user service's slices are not scanned at all, so "kernel" (the root
        // minus the scanned parents) would take in the whole user session: it counts as a parent that
        // could not be listed. So does a parent that may exist unfound, behind a listing of the root
        // or the user's manager that failed.
        let is_every_parent_fully_listed = self.uid.is_some()
            && is_every_parent_found
            && fully_listed_parent_paths.len() == parent_relative_paths.len();
        CgroupTree {
            parent_relative_paths,
            leaf_relative_paths,
            parent_of_leaf,
            fully_listed_parent_paths,
            is_every_parent_fully_listed,
        }
    }

    /// The cgroups whose children an app scan ranks: every slice directly under the user's manager,
    /// `user.slice/user-<uid>.slice/user@<uid>.service`, then every top-level slice but `user.slice`.
    /// Without a known uid the user's manager is not listed at all.
    ///
    /// Returns
    /// -------
    /// The parents, relative to the cgroup root, and whether both listings succeeded: when one
    /// failed, a parent may exist unfound, and its CPU would read as kernel.
    fn find_app_scan_parents(
        &self,
        cgroup_root_path: &Path,
        failures: &mut CgroupReadFailures,
    ) -> (Vec<String>, bool) {
        let mut parent_relative_paths = Vec::new();
        let mut is_every_parent_found = true;
        if let Some(uid) = self.uid {
            let user_manager_relative_path =
                format!("{USER_SLICE}/user-{uid}.slice/user@{uid}.service");
            match self.list_child_paths(cgroup_root_path, &user_manager_relative_path, failures) {
                Some(child_paths) => {
                    parent_relative_paths.extend(slices_among(&child_paths, |_| true))
                }
                None => is_every_parent_found = false,
            }
        }
        match self.list_child_paths(cgroup_root_path, ROOT_CGROUP_RELATIVE_PATH, failures) {
            Some(child_paths) => parent_relative_paths
                .extend(slices_among(&child_paths, |slice_path| {
                    slice_path != USER_SLICE
                })),
            None => is_every_parent_found = false,
        }
        (parent_relative_paths, is_every_parent_found)
    }

    /// The leaves under one scanned parent: its children, descending one level more into a child
    /// that is itself a slice. Leaves of a unit type that never hosts an app are left out at both
    /// depths, unread.
    fn list_leaves_under(
        &self,
        cgroup_root_path: &Path,
        parent_relative_path: &str,
        failures: &mut CgroupReadFailures,
    ) -> ParentLeaves {
        let Some(child_relative_paths) =
            self.list_child_paths(cgroup_root_path, parent_relative_path, failures)
        else {
            return ParentLeaves {
                leaf_relative_paths: Vec::new(),
                is_fully_listed: false,
            };
        };
        let mut leaf_relative_paths = Vec::new();
        let mut is_fully_listed = true;
        for child_relative_path in child_relative_paths {
            if !child_relative_path.ends_with(SLICE_SUFFIX) {
                if can_host_app(&child_relative_path) {
                    leaf_relative_paths.push(child_relative_path);
                }
                continue;
            }
            match self.list_child_paths(cgroup_root_path, &child_relative_path, failures) {
                Some(grandchild_relative_paths) => leaf_relative_paths.extend(
                    grandchild_relative_paths
                        .into_iter()
                        .filter(|grandchild_path| can_host_app(grandchild_path)),
                ),
                None => is_fully_listed = false,
            }
        }
        ParentLeaves {
            leaf_relative_paths,
            is_fully_listed,
        }
    }

    /// A cgroup's child cgroups, relative to the cgroup root, in JavaScript's default string order,
    /// so a group takes the name of the same first leaf in every scan (a directory lists in no
    /// defined order). A vanished cgroup has no children and is no failure: systemd removes an empty
    /// slice, and a scope can exit mid-scan. Any other failure is counted, and gives `None`.
    fn list_child_paths(
        &self,
        cgroup_root_path: &Path,
        directory_relative_path: &str,
        failures: &mut CgroupReadFailures,
    ) -> Option<Vec<String>> {
        let directory_path = join_under(cgroup_root_path, directory_relative_path);
        let mut child_names = match self.lister.subdirectory_names(&directory_path) {
            Ok(child_names) => child_names,
            Err(failure) if failure.is_vanished() => return Some(Vec::new()),
            Err(failure) => {
                failures.note(
                    directory_relative_path,
                    failure.directory_failure_text(&directory_path),
                );
                return None;
            }
        };
        child_names.sort_by(|left, right| js_string_order(left, right));
        let child_relative_paths = child_names
            .iter()
            .map(|child_name| join_relative(directory_relative_path, child_name))
            .collect();
        Some(child_relative_paths)
    }
}
