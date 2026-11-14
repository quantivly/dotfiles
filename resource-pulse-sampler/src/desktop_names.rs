//! An app's name from its `.desktop` file, by GLib's rule, without GLib.
//!
//! The gjs sampler names an app with `GioUnix.DesktopAppInfo.new(desktopId)?.get_name() ?? null`.
//! This module is that call, written out. It is **rewritten, not ported**, so each clause below
//! names the GLib source it was read from. The source is the upstream tag `2.88.0` of the GLib
//! installed here (`libglib2.0-0t64` 2.88.0-1ubuntu0.1), files `gio/gdesktopappinfo.c` (`gdai`),
//! `glib/gkeyfile.c` (`gkf`), `glib/gcharset.c` (`gcs`), `glib/gutils.c` (`gut`),
//! `glib/gshell.c` (`gsh`) and `glib/gutf8.c`. A reference script
//! (`gnome-shell/tests/desktop-names-reference.js`) runs the installed GLib against the same
//! fixtures, and its answers are held in `tests/fixtures/desktop/expected-*.tsv`. Those files
//! are **GLib 2.88's answers**, which is the version the rules below were read from.
//!
//! # The rule
//!
//! 1. **Which directories, in order** (`gdai: desktop_file_dirs_lock`, `gut: g_get_user_data_dir`,
//!    `g_build_system_data_dirs`): the user's data directory first (`XDG_DATA_HOME`, or
//!    `$HOME/.local/share` when it is unset **or empty**), then each entry of `XDG_DATA_DIRS`
//!    in order (`/usr/local/share/:/usr/share/` when unset or empty), each with `applications`
//!    appended. Entries are split on `:` and kept as they are, an empty one included (it
//!    becomes the relative directory `applications`). The configuration directories GLib also
//!    lists hold no apps (`is_config`).
//! 2. **Which file an id names** (`gdai: get_apps_from_dir`): every entry of a directory whose
//!    name ends in `.desktop` is an app whose id is that name, directory or not, and is
//!    **not** descended into. Any other subdirectory (a symlink to one included) is descended
//!    into, its entries' ids prefixed with its name and a `-`. So `a-b-c.desktop` is
//!    `a-b-c.desktop`, `a/b-c.desktop`, `a-b/c.desktop` or `a/b/c.desktop`. An id that is not
//!    the name of a `.desktop` entry of any such path (no `.desktop` suffix, a `/` in it)
//!    is a miss.
//! 3. **The first directory that has the id wins, whether or not its file loads**
//!    (`gdai: g_desktop_app_info_new`): the search takes the first directory whose index holds
//!    the id and tries that file only; when it **does not load** (below) the search goes on to
//!    the next directory. When it loads and is `Hidden=true`, the answer is a miss, and no
//!    later directory is read: a hidden entry masks the later ones.
//! 4. **A file loads** (`gdai: g_desktop_app_info_load_file`, `load_from_keyfile`;
//!    `gkf: g_key_file_load_from_file`) when, in order:
//!    - it opens and is a regular file (`gkf: g_key_file_load_from_fd`);
//!    - **every line** is a comment (blank, or after whitespace a `#`), a group `[name]`
//!      (name non-empty, no `[`, `]` or control byte, only blanks after the `]`), or a
//!      `key=value` line whose key is a valid key name (`gkf: g_key_file_parse_line`,
//!      `is_key_name`); one other line refuses the whole file, whatever group it is in;
//!    - a `key=value` line sits under a group, and in the first group an `Encoding` key
//!      says `UTF-8` (any case) (`gkf: g_key_file_parse_key_value_pair`);
//!    - the **first group** is `Desktop Entry`, and `Type` there is `Application` exactly;
//!    - `Path`, `TryExec` and `Exec` are each absent or a good string (below). Refusing the file
//!      for a bad one is **new in GLib 2.88** (`is_invalid_key_error`): 2.80 to 2.86 load such a
//!      file and name it, so the expected files below are 2.88's and not those versions';
//!    - `TryExec`, when not empty, names a program that exists (rule 7);
//!    - `Exec`, when not empty, parses as a shell command line whose first word is a program
//!      that exists (`gsh: g_shell_parse_argv`, rule 7); a blank command line does not parse.
//! 5. **A value is read** (`gkf: g_key_file_get_string`, `parse_value_as_string`): the text
//!    after the `=` with its leading ASCII blanks dropped, up to the first NUL byte; it must
//!    be valid UTF-8 (`g_utf8_validate`, which is the standard) and its escapes are `\s` `\n`
//!    `\t` `\r` `\\` only: any other escape, or a `\` last, makes the value **bad**. Keys
//!    are matched exactly, a later line with the same key replacing an earlier one. A line
//!    ends at `\n`, and one `\r` before it goes with it.
//! 6. **The name** (`gkf: g_key_file_get_locale_string`, `gcs: g_get_language_names`): the
//!    language list is built from the first non-empty of `LANGUAGE`, `LC_ALL`, `LC_MESSAGES`,
//!    `LANG` (else `C`), split on `:`; each entry gives its variants with the codeset, territory
//!    and modifier parts present counted down as bits (`gcs: append_locale_variants`), which is
//!    **not** the order its documentation gives: `en_GB.UTF-8@euro` gives `en_GB.UTF-8@euro`,
//!    `en_GB@euro`, `en.UTF-8@euro`, `en@euro`, `en_GB.UTF-8`, `en_GB`, `en.UTF-8`, `en`
//!    (checked with `GLib.get_language_names()`); `C` is added last and ends the search. For each language in
//!    order up to the first `C`, a good `Name[language]` wins (a bad one is skipped); then
//!    a good `Name`. With none, **the name is `Unnamed`, not a miss** (`gdai:
//!    g_desktop_app_info_get_name`). A `Name=` with nothing after it is the empty name.
//! 7. **A program exists** (`gut: g_find_program_for_path`): a relative program is first
//!    looked for under the entry's `Path` when it has one; a program with a `/` in it, or an
//!    absolute one, is looked for as it is (only an absolute one that is not found stops
//!    there); otherwise each entry of `PATH` is tried (`/bin:/usr/bin:.` when `PATH` is
//!    unset), an empty entry meaning the program as written. A candidate counts when
//!    `access(X_OK)` succeeds and it is not a directory.
//!
//! # What this module does differently, on purpose
//!
//! - **No gettext catalogue.** Ubuntu's GLib also translates a name through a catalogue a
//!   file names; this reads the file's own `Name` keys only. `Unnamed` is likewise never
//!   translated.
//! - **Bounded work** (the design's "bounded" rule, not GLib's): no directory is listed and no
//!   tree is walked; at most one file is opened per data directory; and a file longer than
//!   [`MAX_DESKTOP_FILE_BYTES`] is a miss where GLib would read it all.
//! - **Bounded probes**: one lookup makes at most [`MAX_PATH_PROBES`] `stat` calls looking for
//!   the id's file, over all directories; at the bound it is a miss. GLib lists each
//!   directory once and cannot run away, but a search by id can, on symlinked directories.
//! - **Which of two files wins** when one directory holds both `a-b.desktop` and `a/b.desktop`
//!   is, in GLib, whichever its directory listing gave last. Here the file with the whole id
//!   for a name wins, then the subdirectory with the shortest prefix.
//! - **A line is cut at its first NUL**; GLib cuts every value there but keeps looking at
//!   the bytes after it when it measures a line.
//! - `locale.alias` (`gcs: unalias_lang`) is not read, so a language set to an alias such as
//!   `german` stays `german`; and a character in a key's `[locale]` counts as a letter or digit
//!   by Rust's tables where GLib's `g_unichar_isalnum` has its own.

use std::fs::{self, File};
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

mod key_file;
mod languages;
mod program;
mod shell;

use key_file::{parse_desktop_entry, DesktopEntry};
use languages::{language_names, C_LOCALE};
use program::program_exists;
use shell::first_word;

/// The most bytes of one `.desktop` file that are read; a longer file is a miss.
pub const MAX_DESKTOP_FILE_BYTES: u64 = 1024 * 1024;
/// The most `stat` calls one [`DesktopNameLookup::name_of`] call may make looking for files,
/// across all data directories. An id such as `a-b-c.desktop` needs a handful (one per dash, per
/// directory level, and GLib's layouts nest ids one or two directories deep), so 256 leaves
/// room for ids of a dozen dashes in a dozen data directories. Symlinks to a directory from
/// inside itself can make every dash a branch, which without this bound takes minutes; at the
/// bound the lookup is a miss.
const MAX_PATH_PROBES: usize = 256;
/// What GLib searches when `XDG_DATA_DIRS` is unset or empty.
const DEFAULT_SYSTEM_DATA_DIRS: &str = "/usr/local/share/:/usr/share/";
/// Where under `$HOME` the user's data directory is when `XDG_DATA_HOME` is unset or empty.
const USER_DATA_DIR_UNDER_HOME: &str = ".local/share";
const APPLICATIONS_SUBDIRECTORY: &str = "applications";
const DATA_DIRS_SEPARATOR: char = ':';
const DESKTOP_FILE_SUFFIX: &str = ".desktop";
/// What `get_name` answers when a file has no good `Name` (GLib translates it; this does not).
const UNNAMED_APP_NAME: &str = "Unnamed";
/// The most bytes of an id: a path's limit, which no id built from names can pass.
const MAX_DESKTOP_ID_BYTES: usize = 4096;

#[cfg(test)]
mod tests;

/// Where to look for `.desktop` files and in which languages to read their names.
pub struct DesktopNameLookup {
    /// The `applications` directories, in search order.
    data_directories: Vec<PathBuf>,
    /// The language list of `g_get_language_names`, ending in `C`.
    language_names: Vec<String>,
    /// The value of `PATH`, when set.
    search_path: Option<String>,
}

/// A `.desktop` file that loaded: whether it is hidden, and its name.
struct LoadedEntry {
    is_hidden: bool,
    name: String,
}

impl DesktopNameLookup {
    /// Builds a lookup from an environment, as GLib reads it (rules 1 and 6): `XDG_DATA_HOME`,
    /// `XDG_DATA_DIRS`, `PATH`, `LANGUAGE`, `LC_ALL`, `LC_MESSAGES` and `LANG`; `home` is
    /// where the user's data directory is when `XDG_DATA_HOME` is not set.
    pub fn from_environment(
        environment: &dyn Fn(&str) -> Option<String>,
        home: &Path,
    ) -> DesktopNameLookup {
        let non_empty = |name: &str| environment(name).filter(|value| !value.is_empty());
        let user_data_directory = non_empty("XDG_DATA_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(USER_DATA_DIR_UNDER_HOME));
        let system_data_directories =
            non_empty("XDG_DATA_DIRS").unwrap_or_else(|| DEFAULT_SYSTEM_DATA_DIRS.to_owned());
        let data_directories = std::iter::once(user_data_directory)
            .chain(
                system_data_directories
                    .split(DATA_DIRS_SEPARATOR)
                    .map(PathBuf::from),
            )
            .map(|data_directory| data_directory.join(APPLICATIONS_SUBDIRECTORY))
            .collect();
        DesktopNameLookup {
            data_directories,
            language_names: language_names(environment),
            search_path: environment("PATH"),
        }
    }

    /// The app's name for a `.desktop` id, or `None` for a miss (rules 2 to 7). Never panics,
    /// opens at most one file per data directory, lists and walks no directory, and holds no
    /// result from one call to the next.
    pub fn name_of(&self, desktop_id: &str) -> Option<String> {
        if !is_possible_desktop_id(desktop_id) {
            return None;
        }
        let mut probes_left = MAX_PATH_PROBES;
        for data_directory in &self.data_directories {
            let Some(file_path) = find_file_for_id(data_directory, desktop_id, &mut probes_left)
            else {
                continue;
            };
            // A file that does not load does not mask the next directory (rule 3).
            if let Some(entry) = self.load_entry(&file_path) {
                return (!entry.is_hidden).then_some(entry.name);
            }
        }
        None
    }

    /// `g_desktop_app_info_load_file`: the file's entry when it loads (rule 4).
    fn load_entry(&self, file_path: &Path) -> Option<LoadedEntry> {
        let bytes = read_bounded(file_path)?;
        let entry = parse_desktop_entry(&bytes)?;
        if !matches!(entry.string("Type").ok()?.as_deref(), Some("Application")) {
            return None;
        }
        let working_directory = entry.string("Path").ok()?.filter(|path| !path.is_empty());
        let try_exec = entry
            .string("TryExec")
            .ok()?
            .filter(|program| !program.is_empty());
        let exec = entry
            .string("Exec")
            .ok()?
            .filter(|command_line| !command_line.is_empty());
        if let Some(program) = try_exec {
            self.require_program(&program, working_directory.as_deref())?;
        }
        if let Some(command_line) = exec {
            self.require_program(&first_word(&command_line)?, working_directory.as_deref())?;
        }
        Some(LoadedEntry {
            is_hidden: entry.boolean("Hidden"),
            name: self
                .localized_name(&entry)
                .unwrap_or_else(|| UNNAMED_APP_NAME.to_owned()),
        })
    }

    /// `Some(())` when `program` exists as `PATH` and the entry's `Path` have it (rule 7).
    fn require_program(&self, program: &str, working_directory: Option<&str>) -> Option<()> {
        program_exists(program, working_directory, self.search_path.as_deref()).then_some(())
    }

    /// `g_key_file_get_locale_string` (rule 6): a good `Name[language]` for the first language
    /// that has one, else a good `Name`, else `None`.
    fn localized_name(&self, entry: &DesktopEntry) -> Option<String> {
        let translated = self
            .language_names
            .iter()
            .take_while(|language| language.as_str() != C_LOCALE)
            .find_map(|language| entry.string(&format!("Name[{language}]")).ok().flatten());
        translated.or_else(|| entry.string("Name").ok().flatten())
    }
}

/// Whether `desktop_id` can be the id of a file: a `.desktop` name with no `/` or NUL, short
/// enough to be a path.
fn is_possible_desktop_id(desktop_id: &str) -> bool {
    desktop_id.ends_with(DESKTOP_FILE_SUFFIX)
        && desktop_id.len() <= MAX_DESKTOP_ID_BYTES
        && !desktop_id.contains(['/', '\0'])
}

/// The file `remaining` names under `directory` (rule 2): an entry of that name when it ends
/// in `.desktop` (whatever it is), else the same search in each subdirectory whose name is a
/// prefix of `remaining` up to a `-`, shortest prefix first. A name ending in `.desktop` is
/// never a subdirectory to enter. Every `stat` spends one of `probes_left`; with none left the
/// search ends and finds nothing.
fn find_file_for_id(directory: &Path, remaining: &str, probes_left: &mut usize) -> Option<PathBuf> {
    let whole_name = directory.join(remaining);
    if remaining.ends_with(DESKTOP_FILE_SUFFIX) {
        spend_probe(probes_left)?;
        if fs::symlink_metadata(&whole_name).is_ok() {
            return Some(whole_name);
        }
    }
    remaining.match_indices('-').find_map(|(dash_position, _)| {
        let subdirectory_name = remaining.get(..dash_position)?;
        let rest = remaining.get(dash_position + 1..)?;
        let is_enterable = !subdirectory_name.is_empty()
            && !matches!(subdirectory_name, "." | "..")
            && !subdirectory_name.ends_with(DESKTOP_FILE_SUFFIX);
        if !is_enterable {
            return None;
        }
        let subdirectory = directory.join(subdirectory_name);
        spend_probe(probes_left)?;
        if fs::metadata(&subdirectory).is_ok_and(|metadata| metadata.is_dir()) {
            find_file_for_id(&subdirectory, rest, probes_left)
        } else {
            None
        }
    })
}

/// Takes one probe from `probes_left`; `None` when none is left.
fn spend_probe(probes_left: &mut usize) -> Option<()> {
    *probes_left = probes_left.checked_sub(1)?;
    Some(())
}

/// The bytes of a regular file of at most [`MAX_DESKTOP_FILE_BYTES`], else `None`: a file that
/// cannot be opened or read, one that is not a regular file (opened without blocking, so a
/// named pipe is refused and not waited for) and one that is too long are all a miss.
fn read_bounded(file_path: &Path) -> Option<Vec<u8>> {
    let file = File::options()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(file_path)
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > MAX_DESKTOP_FILE_BYTES {
        return None;
    }
    let mut bytes = Vec::new();
    // One byte more than the bound, so a file that grew since `metadata` is seen as too long.
    file.take(MAX_DESKTOP_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    (bytes.len() as u64 <= MAX_DESKTOP_FILE_BYTES).then_some(bytes)
}
