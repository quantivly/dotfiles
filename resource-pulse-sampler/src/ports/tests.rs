//! The real reader and lister on temporary directories (and one fixture), and the texts they fail
//! with. Every expected text was printed by gjs through `service/fileIo.js` (see [`gio_texts`]); every
//! expected decoding by gjs's `TextDecoder` (the task's decoder probe).

use std::ffi::CString;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};

use super::*;

/// A text larger than a pipe's buffer (64 KiB), so a reader that stopped at a reported size, or at
/// one buffer, would come back short.
const FIFO_TEXT_LINE_COUNT: usize = 20_000;
/// The mode that denies the owner every access.
const NO_ACCESS_MODE: u32 = 0o000;
/// The mode that gives the owner back every access, so the directory can be removed.
const OWNER_ACCESS_MODE: u32 = 0o700;

/// A temporary directory removed on drop.
struct TemporaryDirectory(PathBuf);

impl TemporaryDirectory {
    /// A fresh, empty directory under the temporary directory, named for the test.
    fn new(label: &str) -> TemporaryDirectory {
        let path = std::env::temp_dir().join(format!(
            "resource-pulse-ports-test-{}-{label}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        TemporaryDirectory(path)
    }

    /// A path inside it.
    fn join(&self, relative_path: &str) -> PathBuf {
        self.0.join(relative_path)
    }

    /// A path inside it whose last component is the given bytes, valid UTF-8 or not.
    fn join_bytes(&self, name_bytes: &[u8]) -> PathBuf {
        self.0.join(std::ffi::OsStr::from_bytes(name_bytes))
    }
}

impl Drop for TemporaryDirectory {
    /// Gives back every access it took away, then removes the directory.
    fn drop(&mut self) {
        if let Ok(entries) = fs::read_dir(&self.0) {
            for entry in entries.flatten() {
                let _ = fs::set_permissions(
                    entry.path(),
                    fs::Permissions::from_mode(OWNER_ACCESS_MODE),
                );
            }
        }
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Fails the test when run as root, to whom nothing is unreadable: a permission row would pass
/// there without testing anything.
fn assert_not_root() {
    // SAFETY: geteuid has no preconditions and cannot fail.
    assert_ne!(
        unsafe { libc::geteuid() },
        0,
        "this row needs an unreadable file: do not run it as root"
    );
}

/// The fixture roots the gjs rows read.
fn fixture_root(root_name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../gnome-shell/tests/fixtures")
        .join(root_name)
}

/// The real reader's text of a file holding these bytes.
fn read_bytes_through_the_reader(label: &str, bytes: &[u8]) -> String {
    let directory = TemporaryDirectory::new(label);
    let path = directory.join("file");
    fs::write(&path, bytes).unwrap();
    FileSystemReader.read_to_text(&path).unwrap()
}

/// row: readFileToEnd reads a /proc file whole although it reports a size of 0
///
/// On a named pipe in a temporary directory rather than `/proc/self/status`: this task's tests read
/// only fixtures and temporary directories, and a pipe, like a `/proc` file, reports a size of 0 while
/// holding text, here more than one pipe buffer of it.
#[test]
fn readfiletoend_reads_a_proc_file_whole_although_it_reports_a_size_of_0() {
    let directory = TemporaryDirectory::new("fifo");
    let pipe_path = directory.join("status");
    let pipe_path_text = CString::new(pipe_path.as_os_str().as_bytes()).unwrap();
    // SAFETY: the path is a valid NUL-terminated string that outlives the call.
    assert_eq!(unsafe { libc::mkfifo(pipe_path_text.as_ptr(), 0o600) }, 0);
    let text: String = (0..FIFO_TEXT_LINE_COUNT)
        .map(|line| format!("Line:\t{line}\n"))
        .collect();
    let writer = {
        let (pipe_path, text) = (pipe_path.clone(), text.clone());
        std::thread::spawn(move || fs::write(pipe_path, text).unwrap())
    };
    let reported_size = fs::metadata(&pipe_path).unwrap().len();
    let read_text = FileSystemReader.read_to_text(&pipe_path).unwrap();
    writer.join().unwrap();
    assert_eq!(
        [
            reported_size,
            read_text.len() as u64,
            u64::from(read_text == text)
        ],
        [0, text.len() as u64, 1]
    );
}

/// row: listSubdirectoryNames names the subdirectories of a directory, and leaves its files out
#[test]
fn listsubdirectorynames_names_the_subdirectories_of_a_directory_and_leaves_its_files_out() {
    // root-bad-pmu's sys/devices/system/cpu holds cpu0/, cpu1/ and the file possible.
    let cpu_devices_path = fixture_root("root-bad-pmu").join("sys/devices/system/cpu");
    let mut names = FileSystemLister
        .subdirectory_names(&cpu_devices_path)
        .unwrap();
    names.sort();
    assert_eq!(names, ["cpu0", "cpu1"]);
}

/// sampler: a file with invalid text is read with the bad bytes replaced
///
/// Expected value: gjs's `TextDecoder` gives U+0066 U+006F U+006F U+FFFD U+000A for these bytes.
#[test]
fn a_file_with_invalid_text_is_read_with_the_bad_bytes_replaced() {
    let text = read_bytes_through_the_reader("invalid-text", &[0x66, 0x6f, 0x6f, 0xff, 0x0a]);
    assert_eq!(text, "foo\u{FFFD}\n");
}

/// The one kind of sequence where the reader and gjs's `TextDecoder` differ, pinned with both
/// results, beside sequences where they agree. gjs gives `41 f5 80 41 0a` as `A U+FFFD A \n` (one
/// replacement for F5 and its continuation byte); the reader gives two. Both give a truncated
/// sequence at the end of the text (`41 e2 82`) as one replacement, and a lead F5 followed by three
/// continuation bytes as four. The reader's doc comment says why no published field can differ.
#[test]
fn the_decoder_differs_from_gjs_only_on_f5_to_f7_with_one_or_two_continuation_bytes() {
    let gjs_differing_text = "A\u{FFFD}A\n";
    let reader_differing_text =
        read_bytes_through_the_reader("f5", &[0x41, 0xf5, 0x80, 0x41, 0x0a]);
    assert_ne!(reader_differing_text, gjs_differing_text);
    assert_eq!(reader_differing_text, "A\u{FFFD}\u{FFFD}A\n");
    let truncated_at_end = read_bytes_through_the_reader("truncated", &[0x41, 0xe2, 0x82]);
    assert_eq!(truncated_at_end, "A\u{FFFD}");
    let complete_old_form = read_bytes_through_the_reader("old-form", &[0xf5, 0x80, 0x80, 0x80]);
    assert_eq!(complete_old_form, "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}");
}

/// A missing file is `NotFound`; a directory, an unreadable file and a path under a file fail with
/// Gio's texts, as gjs's probe printed them.
#[test]
fn a_read_fails_as_gio_reports_it() {
    assert_not_root();
    let directory = TemporaryDirectory::new("read-failures");
    fs::create_dir(directory.join("dir")).unwrap();
    fs::write(directory.join("denied-file"), "x").unwrap();
    fs::set_permissions(
        directory.join("denied-file"),
        fs::Permissions::from_mode(NO_ACCESS_MODE),
    )
    .unwrap();
    let failure_of = |relative_path: &str| {
        FileSystemReader
            .read_to_text(&directory.join(relative_path))
            .unwrap_err()
    };
    let opening = |relative_path: &str, reason: &str| {
        let path = directory.join(relative_path).display().to_string();
        ReadFailure::Other(format!("Error opening file {path}: {reason}"))
    };
    assert_eq!(failure_of("missing"), ReadFailure::NotFound);
    assert_eq!(failure_of("dir"), opening("dir", "Is a directory"));
    assert_eq!(
        failure_of("denied-file"),
        opening("denied-file", "Permission denied")
    );
    assert_eq!(
        failure_of("denied-file/x"),
        opening("denied-file/x", "Not a directory")
    );
}

/// A missing directory is `NotFound`; a file and an unreadable directory fail with Gio's texts.
#[test]
fn a_listing_fails_as_gio_reports_it() {
    assert_not_root();
    let directory = TemporaryDirectory::new("list-failures");
    fs::write(directory.join("a-file"), "x").unwrap();
    fs::create_dir(directory.join("denied-dir")).unwrap();
    fs::set_permissions(
        directory.join("denied-dir"),
        fs::Permissions::from_mode(NO_ACCESS_MODE),
    )
    .unwrap();
    let failure_of = |relative_path: &str| {
        FileSystemLister
            .subdirectory_names(&directory.join(relative_path))
            .unwrap_err()
    };
    let opening = |relative_path: &str, reason: &str| {
        let path = directory.join(relative_path).display().to_string();
        ReadFailure::Other(format!("Error opening directory '{path}': {reason}"))
    };
    assert_eq!(failure_of("missing"), ReadFailure::NotFound);
    assert_eq!(failure_of("a-file"), opening("a-file", "Not a directory"));
    assert_eq!(
        failure_of("denied-dir"),
        opening("denied-dir", "Permission denied")
    );
}

/// Gio follows symlinks: one to a directory is listed, one to a file or dangling is not; files are
/// left out, a file's name that is not valid UTF-8 included. Expected value: gjs's probe listed
/// `good.service` and `link-to-dir` from this same tree.
#[test]
fn a_symlink_to_a_directory_is_listed_and_files_and_dangling_links_are_not() {
    let directory = TemporaryDirectory::new("symlinks");
    fs::create_dir(directory.join("good.service")).unwrap();
    fs::write(directory.join_bytes(b"file-\xff"), "x").unwrap();
    fs::write(directory.join("plain-file"), "x").unwrap();
    symlink("good.service", directory.join("link-to-dir")).unwrap();
    symlink("nowhere", directory.join("dangling")).unwrap();
    symlink("plain-file", directory.join("link-to-file")).unwrap();
    let mut names = FileSystemLister.subdirectory_names(&directory.0).unwrap();
    names.sort();
    assert_eq!(names, ["good.service", "link-to-dir"]);
}

/// A directory, or a symlink to one, whose name is not valid UTF-8 fails the whole listing with
/// gjs's text, as gjs's listing throws there. Expected texts: gjs's probe on these names.
#[test]
fn a_directory_name_that_is_not_utf8_fails_the_listing_with_gjs_text() {
    let directory = TemporaryDirectory::new("bad-names");
    fs::create_dir(directory.join("plain.service")).unwrap();
    fs::create_dir(directory.join_bytes(b"latin1-\xe9-x.service")).unwrap();
    let failure = FileSystemLister
        .subdirectory_names(&directory.0)
        .unwrap_err();
    assert_eq!(
        failure,
        ReadFailure::Other(
            "Could not convert filename string to UTF-8 for string: latin1-\\351-x.service. If \
             string is invalid UTF-8 and used for display purposes, try GLib attribute \
             standard::display-name. The reason is: Invalid byte sequence in conversion input. "
                .to_string()
        )
    );
    let linked = TemporaryDirectory::new("bad-link-name");
    fs::create_dir(linked.join("good.service")).unwrap();
    symlink("good.service", linked.join_bytes(b"link-\xfe")).unwrap();
    let link_failure = FileSystemLister.subdirectory_names(&linked.0).unwrap_err();
    assert!(
        matches!(&link_failure, ReadFailure::Other(text) if text.contains("string: link-\\376. ")),
        "{link_failure:?}"
    );
}

/// The name in gjs's text is escaped as `g_strescape` escapes it. Expected texts: gjs's probe on
/// directories with these names.
#[test]
fn a_name_is_escaped_as_g_strescape_escapes_it() {
    let escaped_names: Vec<String> = [
        &b"quote-\"-back-\\\\-tab-\t-\xff"[..],
        b"valid-\xc3\xa9-then-\xff.scope",
        b"trunc-\xe2\x82",
        b"del-\x7f-\xff",
    ]
    .iter()
    .map(|name_bytes| {
        let text = gio_texts::filename_conversion_failure(name_bytes);
        let after_head = text.split_once("string: ").unwrap().1;
        after_head.split_once(". If string").unwrap().0.to_string()
    })
    .collect();
    assert_eq!(
        escaped_names,
        [
            "quote-\\\"-back-\\\\\\\\-tab-\\t-\\377",
            "valid-\\303\\251-then-\\377.scope",
            "trunc-\\342\\202",
            "del-\\177-\\377",
        ]
    );
}

/// ENOENT and ENODEV are the two vanished failures, at the open and at the read; every other errno
/// is `Other` with Gio's text. ENODEV cannot be made on a temporary directory (kernfs gives it), so
/// the mapping is checked on the errors themselves.
#[test]
fn enoent_and_enodev_are_vanished_at_open_and_at_read_and_nothing_else_is() {
    let path = Path::new("/a/cgroup/cpu.stat");
    let os_error = io::Error::from_raw_os_error;
    assert_eq!(
        failure_of_open(path, &os_error(libc::ENOENT)),
        ReadFailure::NotFound
    );
    assert_eq!(
        failure_of_open(path, &os_error(libc::ENODEV)),
        ReadFailure::NoSuchDevice
    );
    assert_eq!(
        failure_of_read(path, &os_error(libc::ENODEV)),
        ReadFailure::NoSuchDevice
    );
    assert_eq!(
        failure_of_read(path, &os_error(libc::ENOENT)),
        ReadFailure::NotFound
    );
    assert_eq!(
        failure_of_read(path, &os_error(libc::EIO)),
        ReadFailure::Other("Error reading from file: Input/output error".to_string())
    );
    assert_eq!(
        failure_of_open(path, &os_error(libc::EACCES)),
        ReadFailure::Other("Error opening file /a/cgroup/cpu.stat: Permission denied".to_string())
    );
    let vanished: Vec<bool> = [
        ReadFailure::NotFound,
        ReadFailure::NoSuchDevice,
        ReadFailure::Other("No such file or directory".to_string()),
    ]
    .iter()
    .map(ReadFailure::is_vanished)
    .collect();
    assert_eq!(vanished, [true, true, false]);
}

/// What the sampler logs for a vanished file or directory is Gio's text for that errno: the open's
/// for ENOENT, the read's for ENODEV (the test row's `Error reading from file: No such device`),
/// and an `Other`'s own text as it is.
#[test]
fn a_failure_is_described_with_gio_text_for_its_errno() {
    let path = Path::new("/root/proc/swaps");
    let texts = [
        ReadFailure::NotFound.file_failure_text(path),
        ReadFailure::NoSuchDevice.file_failure_text(path),
        ReadFailure::Other("as handed in".to_string()).file_failure_text(path),
        ReadFailure::NotFound.directory_failure_text(path),
        ReadFailure::NoSuchDevice.directory_failure_text(path),
    ];
    assert_eq!(
        texts,
        [
            "Error opening file /root/proc/swaps: No such file or directory",
            "Error reading from file: No such device",
            "as handed in",
            "Error opening directory '/root/proc/swaps': No such file or directory",
            "Error opening directory '/root/proc/swaps': No such device",
        ]
    );
}
