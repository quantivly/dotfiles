//! One row per clause of the rule in `desktop_names.rs`'s header, against the committed
//! fixtures under `tests/fixtures/desktop/`, and the rows that hold the lookup to the reference
//! (GLib's own answers, from `gnome-shell/tests/desktop-names-reference.js`) and to its bounds.
//! None is a carried gjs row: this module is rewritten, not ported.
//!
//! Every expected value here is the answer of the GLib installed here (2.88.0) as the
//! reference printed it, which the header's clause for it explains from GLib's source.

use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use super::{DesktopNameLookup, MAX_DESKTOP_FILE_BYTES};

/// What a lookup may take, per id (the design's bound).
const LOOKUP_TIME_LIMIT: Duration = Duration::from_millis(100);
/// The size of the largest odd file: 20 MiB.
const HUGE_FILE_BYTES: u64 = 20 * 1024 * 1024;
/// The dash-separated segments of the id that probes a layout of symlinks to itself.
const SYMLINK_ID_SEGMENT_COUNT: usize = 60;
/// What `get_name` answers for a file with no usable `Name`.
const UNNAMED: &str = "Unnamed";
/// A valid file's text, to which the bound rows add bytes.
const MINIMAL_ENTRY: &str = "[Desktop Entry]\nType=Application\nName=Big\n";
/// The fixed seed of the random-bytes file.
const RANDOM_BYTES_SEED: u64 = 0x2545_F491_4F6C_DD1D;
/// The length of the random-bytes file.
const RANDOM_BYTES_LENGTH: usize = 4096;
/// The environment variables a language set fixes.
const LANGUAGE_VARIABLES: [&str; 4] = ["LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"];

/// The four language variables the reference rows set, and the expected answers they are held to.
/// `scripts/test-resource-pulse-sampler.sh` sets the same values for the reference.
struct LanguageSet {
    values: [&'static str; 4],
    expected_file: &'static str,
}

const ENGLISH: LanguageSet = LanguageSet {
    values: ["en", "en_US.UTF-8", "en_US.UTF-8", "en_US.UTF-8"],
    expected_file: "expected-english.tsv",
};
const ZZ_THEN_XX_YY: LanguageSet = LanguageSet {
    values: ["zz:xx_YY", "en_US.UTF-8", "en_US.UTF-8", "en_US.UTF-8"],
    expected_file: "expected-zz-xx-yy.tsv",
};
const XX_YY_WITH_CODESET_AND_MODIFIER: LanguageSet = LanguageSet {
    values: [
        "xx_YY.UTF-8@mod",
        "en_US.UTF-8",
        "en_US.UTF-8",
        "en_US.UTF-8",
    ],
    expected_file: "expected-xx-yy-utf8-mod.tsv",
};

/// What `PATH` is in a reference row.
#[derive(Clone, Copy)]
enum SearchPath {
    /// The fixtures' own `bin` directory.
    FixtureBin,
    /// Not set: GLib then searches `/bin:/usr/bin:.`.
    Unset,
    /// One empty entry: GLib then looks in the current directory.
    EmptyEntry,
}

/// The reference rows run with the fixtures directory as the current directory, because a
/// relative program is looked for there; the current directory is the process's, so they take
/// turns. A test of a relative program, or of a `.` or empty `PATH` entry, must take the lock.
static CURRENT_DIRECTORY_LOCK: Mutex<()> = Mutex::new(());

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/desktop")
}

/// An environment closure over a table of variables.
fn environment_of(table: HashMap<String, String>) -> impl Fn(&str) -> Option<String> {
    move |name| table.get(name).cloned()
}

/// The environment the fixtures are read under: the fixture directories, a `PATH` of the
/// fixtures' `bin`, and the language variables of `language_set`.
fn fixture_environment(
    language_set: &LanguageSet,
    search_path: SearchPath,
) -> HashMap<String, String> {
    let fixtures = fixtures();
    let mut table = HashMap::new();
    table.insert(
        "XDG_DATA_HOME".into(),
        fixtures.join("home").display().to_string(),
    );
    table.insert(
        "XDG_DATA_DIRS".into(),
        format!(
            "{}:{}",
            fixtures.join("system-a").display(),
            fixtures.join("system-b").display()
        ),
    );
    match search_path {
        SearchPath::FixtureBin => {
            table.insert("PATH".into(), fixtures.join("bin").display().to_string());
        }
        SearchPath::Unset => {}
        SearchPath::EmptyEntry => {
            table.insert("PATH".into(), ":".into());
        }
    }
    for (variable, value) in LANGUAGE_VARIABLES.iter().zip(language_set.values) {
        table.insert((*variable).into(), value.into());
    }
    table
}

fn fixture_lookup(language_set: &LanguageSet) -> DesktopNameLookup {
    fixture_lookup_with(language_set, SearchPath::FixtureBin)
}

fn fixture_lookup_with(language_set: &LanguageSet, search_path: SearchPath) -> DesktopNameLookup {
    let table = fixture_environment(language_set, search_path);
    DesktopNameLookup::from_environment(&environment_of(table), &fixtures().join("home-dir"))
}

fn english_lookup() -> DesktopNameLookup {
    fixture_lookup(&ENGLISH)
}

/// The answers of `lookup` for each id of `ids.txt`, printed as the reference prints them.
fn printed_answers(lookup: &DesktopNameLookup) -> String {
    let ids = fs::read_to_string(fixtures().join("ids.txt")).unwrap();
    let mut printed = String::new();
    for desktop_id in ids.lines() {
        match lookup.name_of(desktop_id) {
            Some(name) => {
                let quoted_name = serde_json::to_string(&name).unwrap();
                printed.push_str(&format!("{desktop_id}\t{quoted_name}\n"));
            }
            None => printed.push_str(&format!("{desktop_id}\n")),
        }
    }
    printed
}

fn assert_reference_agrees(language_set: &LanguageSet) {
    assert_reference_agrees_with(
        language_set,
        SearchPath::FixtureBin,
        language_set.expected_file,
    );
}

/// Asserts the lookup prints the file of answers, from the fixtures directory as the current one.
fn assert_reference_agrees_with(
    language_set: &LanguageSet,
    search_path: SearchPath,
    expected_file: &str,
) {
    let expected = fs::read_to_string(fixtures().join(expected_file)).unwrap();
    let _turn = CURRENT_DIRECTORY_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let original_directory = std::env::current_dir().unwrap();
    std::env::set_current_dir(fixtures()).unwrap();
    let printed = printed_answers(&fixture_lookup_with(language_set, search_path));
    std::env::set_current_dir(original_directory).unwrap();
    assert_eq!(printed, expected);
}

/// A temporary directory removed on drop, for the odd files a repository cannot hold.
struct TemporaryDirectory(PathBuf);

impl TemporaryDirectory {
    fn new(label: &str) -> TemporaryDirectory {
        let path =
            std::env::temp_dir().join(format!("desktop-names-test-{}-{label}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(path.join("data/applications")).unwrap();
        fs::create_dir_all(path.join("system/applications")).unwrap();
        TemporaryDirectory(path)
    }

    fn applications(&self) -> PathBuf {
        self.0.join("data/applications")
    }

    /// A lookup that reads this directory first and no other directory with apps.
    fn lookup(&self) -> DesktopNameLookup {
        let mut table = HashMap::new();
        table.insert(
            "XDG_DATA_HOME".into(),
            self.0.join("data").display().to_string(),
        );
        table.insert(
            "XDG_DATA_DIRS".into(),
            self.0.join("system").display().to_string(),
        );
        table.insert("PATH".into(), "/bin:/usr/bin".into());
        table.insert("LANGUAGE".into(), "en".into());
        DesktopNameLookup::from_environment(&environment_of(table), &self.0)
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        let _ = fs::set_permissions(
            self.applications().join("odd-unreadable.desktop"),
            fs::Permissions::from_mode(0o600),
        );
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Asserts that one lookup of `desktop_id` is a miss and takes less than [`LOOKUP_TIME_LIMIT`].
fn assert_miss_in_time(lookup: &DesktopNameLookup, desktop_id: &str) {
    let started = Instant::now();
    let answer = lookup.name_of(desktop_id);
    let elapsed = started.elapsed();
    assert_eq!(answer, None, "{desktop_id} must be a miss");
    assert!(elapsed < LOOKUP_TIME_LIMIT, "{desktop_id} took {elapsed:?}");
}

#[test]
fn the_user_directory_comes_first_then_each_system_directory_in_order() {
    let lookup = english_lookup();
    assert_eq!(
        lookup.name_of("order.desktop").as_deref(),
        Some("Order Home")
    );
    assert_eq!(
        lookup.name_of("plain.desktop").as_deref(),
        Some("Plain App")
    );
    assert_eq!(
        lookup.name_of("only-in-b.desktop").as_deref(),
        Some("Only In B")
    );
}

#[test]
fn the_data_directories_default_when_the_variables_are_unset_or_empty() {
    let home = Path::new("/home/someone");
    let expected = vec![
        PathBuf::from("/home/someone/.local/share/applications"),
        PathBuf::from("/usr/local/share/applications"),
        PathBuf::from("/usr/share/applications"),
    ];
    let unset = DesktopNameLookup::from_environment(&|_| None, home);
    assert_eq!(unset.data_directories, expected);
    let empty = DesktopNameLookup::from_environment(&|_| Some(String::new()), home);
    assert_eq!(empty.data_directories, expected);
    let listed = DesktopNameLookup::from_environment(
        &|name| match name {
            "XDG_DATA_HOME" => Some("/data-home".into()),
            "XDG_DATA_DIRS" => Some("/one:/two/:".into()),
            _ => None,
        },
        home,
    );
    assert_eq!(
        listed.data_directories,
        [
            PathBuf::from("/data-home/applications"),
            PathBuf::from("/one/applications"),
            PathBuf::from("/two/applications"),
            PathBuf::from("applications"),
        ]
    );
}

#[test]
fn a_hidden_entry_masks_the_same_id_in_later_directories() {
    let lookup = english_lookup();
    assert_eq!(lookup.name_of("hidden-mask.desktop"), None);
    assert_eq!(lookup.name_of("hidden-one.desktop"), None);
    assert_eq!(
        lookup.name_of("hidden-false.desktop").as_deref(),
        Some("Hidden False")
    );
    assert_eq!(
        lookup.name_of("hidden-garbage.desktop").as_deref(),
        Some("Hidden Garbage")
    );
}

#[test]
fn a_file_that_does_not_load_does_not_mask_a_later_directory() {
    let lookup = english_lookup();
    assert_eq!(
        lookup.name_of("broken-falls-through.desktop").as_deref(),
        Some("Valid Behind Broken")
    );
}

#[test]
fn ids_are_formed_from_subdirectories_that_are_not_themselves_desktop_names() {
    let lookup = english_lookup();
    assert_eq!(
        lookup.name_of("vendor-sub.desktop").as_deref(),
        Some("Vendor Sub")
    );
    assert_eq!(
        lookup.name_of("deep-one-two.desktop").as_deref(),
        Some("Deep One Two")
    );
    assert_eq!(
        lookup.name_of("mixed-name-x.desktop").as_deref(),
        Some("Mixed Name X")
    );
    assert_eq!(lookup.name_of("ghost.desktop-x.desktop"), None);
    assert_eq!(lookup.name_of("vendor-.desktop"), None);
}

#[test]
fn an_id_that_is_not_the_name_of_a_desktop_file_is_a_miss() {
    let lookup = english_lookup();
    for not_an_id in [
        "plain",
        "Plain.desktop",
        "vendor/sub.desktop",
        "../plain.desktop",
        "",
        ".desktop",
        "plain.desktop\0",
        "no-such-app.desktop",
    ] {
        assert_eq!(lookup.name_of(not_an_id), None, "{not_an_id:?}");
    }
}

#[test]
fn only_type_application_loads() {
    let lookup = english_lookup();
    assert_eq!(lookup.name_of("type-link.desktop"), None);
    assert_eq!(lookup.name_of("type-missing.desktop"), None);
    assert_eq!(lookup.name_of("type-lowercase.desktop"), None);
}

#[test]
fn tryexec_must_name_an_executable_program_or_be_empty() {
    let lookup = english_lookup();
    assert_eq!(
        lookup.name_of("tryexec-present.desktop").as_deref(),
        Some("TryExec Present")
    );
    assert_eq!(
        lookup.name_of("tryexec-empty.desktop").as_deref(),
        Some("TryExec Empty")
    );
    assert_eq!(
        lookup.name_of("tryexec-absolute.desktop").as_deref(),
        Some("TryExec Absolute")
    );
    assert_eq!(lookup.name_of("tryexec-missing.desktop"), None);
    assert_eq!(lookup.name_of("tryexec-not-executable.desktop"), None);
}

#[test]
fn exec_must_parse_and_start_with_an_executable_program_or_be_empty() {
    let lookup = english_lookup();
    assert_eq!(
        lookup.name_of("exec-present.desktop").as_deref(),
        Some("Exec Present")
    );
    assert_eq!(
        lookup.name_of("exec-quoted.desktop").as_deref(),
        Some("Exec Quoted")
    );
    assert_eq!(
        lookup.name_of("exec-empty.desktop").as_deref(),
        Some("Exec Empty")
    );
    assert_eq!(lookup.name_of("exec-missing.desktop"), None);
    assert_eq!(lookup.name_of("exec-unbalanced.desktop"), None);
}

#[test]
fn a_path_with_a_bad_escape_refuses_the_file() {
    assert_eq!(english_lookup().name_of("path-bad-escape.desktop"), None);
}

#[test]
fn a_try_exec_with_a_bad_escape_refuses_the_file() {
    assert_eq!(english_lookup().name_of("tryexec-bad-escape.desktop"), None);
}

#[test]
fn an_exec_with_a_bad_escape_refuses_the_file() {
    assert_eq!(english_lookup().name_of("exec-bad-escape.desktop"), None);
}

#[test]
fn a_file_with_no_name_is_unnamed_and_not_a_miss() {
    let lookup = english_lookup();
    assert_eq!(
        lookup.name_of("name-missing.desktop").as_deref(),
        Some(UNNAMED)
    );
    assert_eq!(
        lookup.name_of("name-other-group.desktop").as_deref(),
        Some(UNNAMED)
    );
    assert_eq!(lookup.name_of("name-empty.desktop").as_deref(), Some(""));
}

#[test]
fn a_name_is_read_with_its_escapes_and_a_bad_one_is_no_name() {
    let lookup = english_lookup();
    assert_eq!(
        lookup.name_of("name-escapes.desktop").as_deref(),
        Some("A B\\C")
    );
    assert_eq!(
        lookup.name_of("name-bad-escape.desktop").as_deref(),
        Some(UNNAMED)
    );
    assert_eq!(
        lookup.name_of("name-trailing-backslash.desktop").as_deref(),
        Some(UNNAMED)
    );
    assert_eq!(
        lookup.name_of("name-duplicate.desktop").as_deref(),
        Some("Second")
    );
    assert_eq!(
        lookup.name_of("name-spaced.desktop").as_deref(),
        Some("Spaced Out")
    );
    assert_eq!(
        lookup.name_of("name-utf8.desktop").as_deref(),
        Some("Café ☕")
    );
}

#[test]
fn a_name_that_is_not_utf8_is_no_name_and_a_nul_ends_a_value() {
    let lookup = english_lookup();
    assert_eq!(
        lookup.name_of("name-invalid-utf8.desktop").as_deref(),
        Some(UNNAMED)
    );
    assert_eq!(
        lookup.name_of("name-nul.desktop").as_deref(),
        Some("Plain Nul")
    );
}

#[test]
fn the_language_list_is_built_as_g_get_language_names_builds_it() {
    let list_for = |variables: &[(&str, &str)]| {
        let table: HashMap<String, String> = variables
            .iter()
            .map(|(name, value)| ((*name).into(), (*value).into()))
            .collect();
        DesktopNameLookup::from_environment(&environment_of(table), Path::new("/home/x"))
            .language_names
    };
    // The example in g_get_language_names's own documentation.
    assert_eq!(
        list_for(&[("LANGUAGE", "de:en_US")]),
        ["de", "en_US", "en", "C"]
    );
    // With nothing set GLib lists `C` twice: the one it guesses, and the one it always adds.
    assert_eq!(list_for(&[]), ["C", "C"]);
    assert_eq!(
        list_for(&[("LANGUAGE", ""), ("LANG", "fr_BE.UTF-8")]),
        ["fr_BE.UTF-8", "fr_BE", "fr.UTF-8", "fr", "C"]
    );
    // The order of precedence: LANGUAGE, then LC_ALL, then LC_MESSAGES, then LANG.
    assert_eq!(
        list_for(&[("LC_ALL", "a"), ("LC_MESSAGES", "b"), ("LANG", "c")]),
        ["a", "C"]
    );
    assert_eq!(list_for(&[("LC_MESSAGES", "b"), ("LANG", "c")]), ["b", "C"]);
    assert_eq!(list_for(&[("LANG", "c")]), ["c", "C"]);
    assert_eq!(list_for(&[("LANGUAGE", "l"), ("LC_ALL", "a")]), ["l", "C"]);
    // The order GLib really gives, which its documentation for g_get_locale_variants does not.
    assert_eq!(
        list_for(&[("LANGUAGE", "en_GB.UTF-8@euro")]),
        [
            "en_GB.UTF-8@euro",
            "en_GB@euro",
            "en.UTF-8@euro",
            "en@euro",
            "en_GB.UTF-8",
            "en_GB",
            "en.UTF-8",
            "en",
            "C"
        ]
    );
}

#[test]
fn a_name_follows_the_language_order_and_skips_a_bad_localized_value() {
    let zz_first = fixture_lookup(&ZZ_THEN_XX_YY);
    assert_eq!(
        zz_first.name_of("name-localized.desktop").as_deref(),
        Some("Name In Zz")
    );
    assert_eq!(
        zz_first
            .name_of("name-localized-only-xx.desktop")
            .as_deref(),
        Some("Only Xx")
    );
    assert_eq!(
        zz_first.name_of("name-localized-bad.desktop").as_deref(),
        Some("Good Xx")
    );
    assert_eq!(
        zz_first
            .name_of("name-localized-no-plain.desktop")
            .as_deref(),
        Some("Only Localized")
    );
    let modified = fixture_lookup(&XX_YY_WITH_CODESET_AND_MODIFIER);
    assert_eq!(
        modified.name_of("name-localized.desktop").as_deref(),
        Some("Name In Xx YY")
    );
    assert_eq!(
        modified
            .name_of("name-localized-modifier.desktop")
            .as_deref(),
        Some("Modified")
    );
    // A key's language is matched exactly, `Name[XX]` is not `Name[xx]`, and English has none.
    let english = english_lookup();
    assert_eq!(
        english.name_of("name-localized.desktop").as_deref(),
        Some("Plain Name")
    );
    assert_eq!(
        english
            .name_of("name-localized-no-plain.desktop")
            .as_deref(),
        Some(UNNAMED)
    );
}

#[test]
fn a_file_that_does_not_parse_as_a_key_file_is_refused_whole() {
    let lookup = english_lookup();
    for refused in [
        "parse-garbage-line.desktop",
        "parse-no-group.desktop",
        "parse-wrong-start-group.desktop",
        "parse-encoding-latin1.desktop",
        "parse-bad-key-name.desktop",
        "parse-empty-key.desktop",
    ] {
        assert_eq!(lookup.name_of(refused), None, "{refused}");
    }
    assert_eq!(
        lookup.name_of("parse-encoding-utf8.desktop").as_deref(),
        Some("Utf Eight")
    );
    assert_eq!(
        lookup.name_of("parse-comments.desktop").as_deref(),
        Some("With Comments")
    );
    assert_eq!(
        lookup.name_of("parse-group-twice.desktop").as_deref(),
        Some("Group Twice Again")
    );
}

#[test]
fn a_file_that_names_a_gettext_catalogue_is_read_by_its_own_name_keys() {
    assert_eq!(
        english_lookup()
            .name_of("gettext-domain.desktop")
            .as_deref(),
        Some("Own Name")
    );
    assert_eq!(
        fixture_lookup(&ZZ_THEN_XX_YY)
            .name_of("gettext-domain.desktop")
            .as_deref(),
        Some("Own Name In Xx")
    );
}

#[test]
fn the_reference_agrees_in_english() {
    assert_reference_agrees(&ENGLISH);
}

#[test]
fn the_reference_agrees_when_a_translated_name_must_win() {
    assert_reference_agrees(&ZZ_THEN_XX_YY);
}

#[test]
fn the_reference_agrees_with_a_codeset_and_a_modifier_in_the_language() {
    assert_reference_agrees(&XX_YY_WITH_CODESET_AND_MODIFIER);
}

#[test]
fn every_fixture_desktop_file_has_an_id_in_the_reference_list() {
    let listed = fs::read_to_string(fixtures().join("ids.txt")).unwrap();
    let listed: Vec<&str> = listed.lines().collect();
    for data_directory in ["home", "system-a", "system-b"] {
        let applications = fixtures().join(data_directory).join("applications");
        let mut stack = vec![(applications, String::new())];
        while let Some((directory, prefix)) = stack.pop() {
            for entry in fs::read_dir(&directory).unwrap() {
                let entry = entry.unwrap();
                let name = entry.file_name().into_string().unwrap();
                if name.ends_with(".desktop") {
                    assert!(
                        listed.contains(&format!("{prefix}{name}").as_str()),
                        "{prefix}{name}"
                    );
                }
                if entry.path().is_dir() {
                    stack.push((entry.path(), format!("{prefix}{name}-")));
                }
            }
        }
    }
}

#[test]
fn an_unreadable_file_a_directory_random_bytes_a_20_mib_file_and_a_symlink_loop_are_each_a_miss() {
    // Nothing is unreadable to root, and a test that quietly passed there would be a hole.
    // SAFETY: geteuid has no preconditions and cannot fail.
    assert_ne!(
        unsafe { libc::geteuid() },
        0,
        "this row needs an unreadable file: do not run it as root"
    );
    let directory = TemporaryDirectory::new("odd-files");
    let applications = directory.applications();
    fs::write(applications.join("odd-unreadable.desktop"), MINIMAL_ENTRY).unwrap();
    fs::set_permissions(
        applications.join("odd-unreadable.desktop"),
        fs::Permissions::from_mode(0o000),
    )
    .unwrap();
    fs::create_dir(applications.join("odd-directory.desktop")).unwrap();
    fs::write(applications.join("odd-random.desktop"), random_bytes()).unwrap();
    let huge = fs::File::create(applications.join("odd-huge.desktop")).unwrap();
    huge.set_len(HUGE_FILE_BYTES).unwrap();
    symlink(
        "odd-loop-b.desktop",
        applications.join("odd-loop-a.desktop"),
    )
    .unwrap();
    symlink(
        "odd-loop-a.desktop",
        applications.join("odd-loop-b.desktop"),
    )
    .unwrap();
    let lookup = directory.lookup();
    for desktop_id in [
        "odd-unreadable.desktop",
        "odd-directory.desktop",
        "odd-random.desktop",
        "odd-huge.desktop",
        "odd-loop-a.desktop",
    ] {
        assert_miss_in_time(&lookup, desktop_id);
    }
}

/// Bytes with no `=`, `[` or newline in them, from a fixed seed, so no line of them can be a
/// key or a group and the file cannot parse by chance.
fn random_bytes() -> Vec<u8> {
    let mut state = RANDOM_BYTES_SEED;
    let mut bytes = Vec::with_capacity(RANDOM_BYTES_LENGTH);
    while bytes.len() < RANDOM_BYTES_LENGTH {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let byte = state.to_le_bytes()[0];
        if !matches!(byte, b'=' | b'[' | b'\n' | b'#') {
            bytes.push(byte);
        }
    }
    bytes
}

#[test]
fn a_named_pipe_in_a_files_place_is_a_miss_and_does_not_block() {
    let directory = TemporaryDirectory::new("pipe");
    let pipe_path = std::ffi::CString::new(
        directory
            .applications()
            .join("odd-pipe.desktop")
            .to_str()
            .unwrap(),
    )
    .unwrap();
    // SAFETY: the path is a valid NUL-terminated string that outlives the call.
    assert_eq!(unsafe { libc::mkfifo(pipe_path.as_ptr(), 0o600) }, 0);
    assert_miss_in_time(&directory.lookup(), "odd-pipe.desktop");
}

#[test]
fn a_file_over_the_byte_bound_is_a_miss_where_glib_would_read_it() {
    let directory = TemporaryDirectory::new("bound");
    let padding_comment_start = "#";
    let write_entry_of_size = |file_name: &str, total_bytes: u64| {
        let padding_bytes =
            total_bytes as usize - MINIMAL_ENTRY.len() - padding_comment_start.len();
        let text = format!(
            "{MINIMAL_ENTRY}{padding_comment_start}{}",
            "x".repeat(padding_bytes)
        );
        assert_eq!(text.len() as u64, total_bytes);
        fs::write(directory.applications().join(file_name), text).unwrap();
    };
    write_entry_of_size("at-the-bound.desktop", MAX_DESKTOP_FILE_BYTES);
    write_entry_of_size("over-the-bound.desktop", MAX_DESKTOP_FILE_BYTES + 1);
    let lookup = directory.lookup();
    assert_eq!(
        lookup.name_of("at-the-bound.desktop").as_deref(),
        Some("Big")
    );
    assert_miss_in_time(&lookup, "over-the-bound.desktop");
}

#[test]
fn nothing_is_cached_between_lookups() {
    let directory = TemporaryDirectory::new("no-cache");
    let entry_path = directory.applications().join("changing.desktop");
    let lookup = directory.lookup();
    assert_eq!(lookup.name_of("changing.desktop"), None);
    fs::write(
        &entry_path,
        "[Desktop Entry]\nType=Application\nName=First\n",
    )
    .unwrap();
    assert_eq!(lookup.name_of("changing.desktop").as_deref(), Some("First"));
    fs::write(
        &entry_path,
        "[Desktop Entry]\nType=Application\nName=Second\n",
    )
    .unwrap();
    assert_eq!(
        lookup.name_of("changing.desktop").as_deref(),
        Some("Second")
    );
}

#[test]
fn a_whole_id_file_wins_over_a_subdirectory_and_one_file_is_read_per_directory() {
    let directory = TemporaryDirectory::new("ambiguous");
    let applications = directory.applications();
    fs::create_dir(applications.join("x")).unwrap();
    fs::write(
        applications.join("x-y.desktop"),
        "[Desktop Entry]\nType=Application\nName=Whole\n",
    )
    .unwrap();
    fs::write(
        applications.join("x/y.desktop"),
        "[Desktop Entry]\nType=Application\nName=Sub\n",
    )
    .unwrap();
    assert_eq!(
        directory.lookup().name_of("x-y.desktop").as_deref(),
        Some("Whole")
    );
    // The file that wins is the only one tried: when it does not load, the other is not.
    fs::write(
        applications.join("x-y.desktop"),
        "[Desktop Entry]\nType=Link\n",
    )
    .unwrap();
    assert_eq!(directory.lookup().name_of("x-y.desktop"), None);
}

#[test]
fn the_first_word_of_a_command_line_is_read_as_the_shell_reads_it() {
    use super::shell::first_word;
    assert_eq!(first_word("tool --flag").as_deref(), Some("tool"));
    assert_eq!(first_word("  tool").as_deref(), Some("tool"));
    assert_eq!(first_word("\"two words\" x").as_deref(), Some("two words"));
    assert_eq!(
        first_word("'single quoted' x").as_deref(),
        Some("single quoted")
    );
    assert_eq!(first_word("a\\ b c").as_deref(), Some("a b"));
    assert_eq!(
        first_word("pre\"mid dle\"post x").as_deref(),
        Some("premid dlepost")
    );
    assert_eq!(first_word("\"a\\\"b\"").as_deref(), Some("a\"b"));
    assert_eq!(first_word("\"a\\qb\"").as_deref(), Some("a\\qb"));
    assert_eq!(first_word("# comment\ntool").as_deref(), Some("tool"));
    // The whole line must parse, not only the first word.
    assert_eq!(first_word("tool \"open"), None);
    assert_eq!(first_word("tool 'open"), None);
    assert_eq!(first_word("tool \\"), None);
    assert_eq!(first_word(""), None);
    assert_eq!(first_word("   \t "), None);
    assert_eq!(first_word("# only a comment"), None);
}

#[test]
fn an_id_of_many_dashes_over_symlinked_directories_is_a_miss_in_time() {
    let directory = TemporaryDirectory::new("dash-symlinks");
    let applications = directory.applications();
    // Two links to the directory itself: every dash can be read as a step into either of them.
    symlink(".", applications.join("a")).unwrap();
    symlink(".", applications.join("a-a")).unwrap();
    let many_segments = "a-".repeat(SYMLINK_ID_SEGMENT_COUNT);
    assert_miss_in_time(&directory.lookup(), &format!("{many_segments}x.desktop"));
}

#[test]
fn the_reference_agrees_when_path_is_unset_and_the_default_search_path_applies() {
    // `exec-bare-sh.desktop` (`Exec=sh`) is found only through `/bin:/usr/bin:.`, and the entries
    // that need the fixtures' bin are not found.
    assert_reference_agrees_with(&ENGLISH, SearchPath::Unset, "expected-english-no-path.tsv");
}

#[test]
fn the_reference_agrees_when_path_has_an_empty_entry_that_means_the_current_directory() {
    // `exec-cwd-tool.desktop` (`Exec=cwd-tool`) is found only by the empty entry, in the
    // fixtures directory.
    assert_reference_agrees_with(
        &ENGLISH,
        SearchPath::EmptyEntry,
        "expected-english-empty-path-entry.tsv",
    );
}
