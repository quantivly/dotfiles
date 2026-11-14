//! Whether a program exists, as `g_find_program_for_path` (`glib/gutils.c`) decides it for a
//! `.desktop` file's `TryExec` and `Exec`.

use std::ffi::CString;
use std::fs;

/// What GLib searches when `PATH` is unset.
const DEFAULT_SEARCH_PATH: &str = "/bin:/usr/bin:.";
const SEARCH_PATH_SEPARATOR: char = ':';

/// Whether `program` is found: `working_dir` is the entry's `Path` (a relative program is
/// first looked for under it) and `search_path` the value of `PATH`, when set.
pub(super) fn program_exists(
    program: &str,
    working_dir: Option<&str>,
    search_path: Option<&str>,
) -> bool {
    let program_under_working_dir = match working_dir {
        Some(directory) if !is_absolute(program) => join_filename(directory, program),
        _ => program.to_owned(),
    };
    if is_absolute(&program_under_working_dir) || program.contains('/') {
        if is_executable_file(&program_under_working_dir) {
            return true;
        }
        if is_absolute(program) {
            return false;
        }
    }
    search_path
        .unwrap_or(DEFAULT_SEARCH_PATH)
        .split(SEARCH_PATH_SEPARATOR)
        .any(|directory| {
            // An empty `PATH` entry means the program as written.
            let candidate = if directory.is_empty() {
                program.to_owned()
            } else {
                format!("{directory}/{program}")
            };
            let candidate = match working_dir {
                Some(working_directory) if !is_absolute(&candidate) => {
                    join_filename(working_directory, &candidate)
                }
                _ => candidate,
            };
            is_executable_file(&candidate)
        })
}

/// `g_path_is_absolute` on Unix.
fn is_absolute(path: &str) -> bool {
    path.starts_with('/')
}

/// `g_build_filename (directory, name)`: an empty `directory` is skipped, and the separator
/// between the two is single.
fn join_filename(directory: &str, name: &str) -> String {
    if directory.is_empty() {
        return name.to_owned();
    }
    format!(
        "{}/{}",
        directory.trim_end_matches('/'),
        name.trim_start_matches('/')
    )
}

/// `g_file_test (path, G_FILE_TEST_IS_EXECUTABLE)` and not `G_FILE_TEST_IS_DIR`: `access(X_OK)`
/// succeeds, and the path is not a directory (a symlink to one included).
fn is_executable_file(path: &str) -> bool {
    let Ok(c_path) = CString::new(path) else {
        return false;
    };
    // SAFETY: `c_path` is a valid NUL-terminated string that outlives the call, and `access`
    // reads nothing else.
    let is_executable = unsafe { libc::access(c_path.as_ptr(), libc::X_OK) } == 0;
    is_executable && !fs::metadata(path).is_ok_and(|metadata| metadata.is_dir())
}
