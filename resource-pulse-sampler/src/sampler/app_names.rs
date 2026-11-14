//! Naming the group a cgroup leaf belongs to, and the cache of app names by desktop id
//! (`groupOfCgroup` and `_lookUpAppName`).

use std::collections::HashMap;

use super::ResolveAppName;
use crate::apps::{describe_cgroup, display_name_for, AppGroup};
use crate::caught_panic::catching_panic;
use crate::ports::Clock;
use crate::rate_limited_log::RateLimitedLog;

/// The most desktop ids whose names the cache holds, misses included. A machine has a few hundred
/// apps at most; the bound is for a tree of thousands of leaves with an id each (containers), where
/// an unbounded cache, as the gjs one is, would grow with every id ever seen.
pub(super) const MAX_CACHED_DESKTOP_IDS: usize = 4_096;
/// The template key of a failed lookup's journal line.
const APP_NAME_LOOKUP_FAILURE_LOG_KEY: &str = "cannot look up app names";
/// What separates a cgroup path's components.
const CGROUP_PATH_SEPARATOR: char = '/';

/// Names the app a cgroup leaf belongs to and the key its scopes are summed under (gjs
/// `groupOfCgroup`): the leaf's last path component, described and named.
pub(super) fn group_of_cgroup(
    cgroup_path: &str,
    resolve_app_name: &mut dyn FnMut(&str) -> Option<String>,
) -> AppGroup {
    let leaf_name = cgroup_path
        .rsplit(CGROUP_PATH_SEPARATOR)
        .next()
        .unwrap_or(cgroup_path);
    let description = describe_cgroup(leaf_name);
    AppGroup {
        name: display_name_for(&description, resolve_app_name),
        group_key: description.group_key,
    }
}

/// App names by desktop id, misses (`None`) included, so a `.desktop` file is read once and not on
/// every scan. Each id is looked up once for as long as it stays cached. When the cache holds
/// [`MAX_CACHED_DESKTOP_IDS`] ids and a new one is looked up, every id is forgotten first: the cache
/// never holds more, and ids of leaves long gone do not stay for the life of the program.
pub(super) struct AppNameCache {
    resolve_app_name: ResolveAppName,
    app_name_by_desktop_id: HashMap<String, Option<String>>,
}

impl AppNameCache {
    /// An empty cache in front of the lookup.
    pub(super) fn new(resolve_app_name: ResolveAppName) -> AppNameCache {
        AppNameCache {
            resolve_app_name,
            app_name_by_desktop_id: HashMap::new(),
        }
    }

    /// An app's name, looked up once per desktop id while it stays cached. A lookup that panics (as
    /// gjs's throws) is logged, rate-limited, and counts as a miss, so the app keeps the name its unit
    /// gives and the scan goes on.
    pub(super) fn look_up(
        &mut self,
        desktop_id: &str,
        error_log: &mut RateLimitedLog,
        clock: &dyn Clock,
    ) -> Option<String> {
        if let Some(app_name) = self.app_name_by_desktop_id.get(desktop_id) {
            return app_name.clone();
        }
        let resolve_app_name = &mut self.resolve_app_name;
        let app_name =
            catching_panic(|| resolve_app_name(desktop_id)).unwrap_or_else(|failure_text| {
                let message = format!("cannot look up {desktop_id}: {failure_text}");
                error_log.log(clock, &message, APP_NAME_LOOKUP_FAILURE_LOG_KEY);
                None
            });
        if self.app_name_by_desktop_id.len() >= MAX_CACHED_DESKTOP_IDS {
            self.app_name_by_desktop_id.clear();
        }
        self.app_name_by_desktop_id
            .insert(desktop_id.to_string(), app_name.clone());
        app_name
    }

    /// How many ids are cached, for the row that bounds it.
    #[cfg(test)]
    pub(super) fn cached_desktop_id_count(&self) -> usize {
        self.app_name_by_desktop_id.len()
    }
}
