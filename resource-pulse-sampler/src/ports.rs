//! What the sampler reads files, lists directories and tells time through, so that its rows and the
//! golden scenarios can hand in their own (`service/sampler.js`'s injected `readFile`,
//! `listDirectoryNames`, `nowUsec` and `clockLabel`); and the real reader and lister, which stand for
//! `service/fileIo.js`'s `readFileToEnd` and `listSubdirectoryNames`.
//!
//! The real reader and lister fail with Gio's own texts (see [`gio_texts`]), so that a line the sampler
//! logs about a failed read reads as the gjs sampler's line about the same failure.

use std::fs::{self, DirEntry, File};
use std::io::{self, Read};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

/// Why a read or a listing failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadFailure {
    /// No such file or directory (ENOENT: Gio's `G_IO_ERROR_NOT_FOUND`).
    NotFound,
    /// No such device (ENODEV: Gio's `G_IO_ERROR_NO_SUCH_DEVICE`). kernfs answers a read from a file
    /// whose cgroup was removed after the open this way.
    NoSuchDevice,
    /// Any other failure, with what to log about it: for the real reader and lister, Gio's text.
    Other(String),
}

impl ReadFailure {
    /// Whether the file or directory is gone (`isVanishedCgroupError`): no such file, or no such
    /// device, and nothing else.
    pub fn is_vanished(&self) -> bool {
        matches!(self, ReadFailure::NotFound | ReadFailure::NoSuchDevice)
    }

    /// What gjs's `describeError` gives for this failure of a read of `path`: Gio's text for the
    /// errno, from the path, or the text an [`ReadFailure::Other`] carries.
    pub fn file_failure_text(&self, path: &Path) -> String {
        match self {
            ReadFailure::NotFound => {
                gio_texts::file_open_failure(path, gio_texts::NOT_FOUND_REASON)
            }
            ReadFailure::NoSuchDevice => {
                gio_texts::file_read_failure(gio_texts::NO_SUCH_DEVICE_REASON)
            }
            ReadFailure::Other(text) => text.clone(),
        }
    }

    /// What gjs's `describeError` gives for this failure of a listing of `path`.
    pub fn directory_failure_text(&self, path: &Path) -> String {
        match self {
            ReadFailure::NotFound => {
                gio_texts::directory_open_failure(path, gio_texts::NOT_FOUND_REASON)
            }
            ReadFailure::NoSuchDevice => {
                gio_texts::directory_open_failure(path, gio_texts::NO_SUCH_DEVICE_REASON)
            }
            ReadFailure::Other(text) => text.clone(),
        }
    }
}

/// Reads a whole file as text (`readFileToEnd`).
pub trait FileReader {
    /// The file's contents, every byte that is not part of valid UTF-8 replaced (see
    /// [`FileSystemReader`]).
    fn read_to_text(&self, path: &Path) -> Result<String, ReadFailure>;
}

/// Names the subdirectories of a directory (`listSubdirectoryNames`).
pub trait DirectoryLister {
    /// The names of the entries that are directories, in no defined order: the sampler sorts them
    /// where its result depends on the order.
    fn subdirectory_names(&self, path: &Path) -> Result<Vec<String>, ReadFailure>;
}

/// The sampler's two clocks (`nowUsec` and `clockLabel`).
pub trait Clock {
    /// Monotonic microseconds: `CLOCK_MONOTONIC`, the clock the client compares `takenAtUsec` with.
    fn monotonic_usec(&self) -> u64;
    /// Local wall-clock time as `HH:MM`, or what went wrong reading it.
    fn clock_label(&self) -> Result<String, String>;
}

/// Gio's texts for the failures the real reader and lister meet, and the one gjs gives for a name
/// that is not valid UTF-8. Each was probed through `service/fileIo.js` on a temporary tree (gjs
/// 1.88, GLib 2.88, `LANG=en_US.UTF-8`); the probe printed, per failure, the Gio code and message:
///
/// ```text
/// read missing        NOT_FOUND          Error opening file <path>: No such file or directory
/// read directory      IS_DIRECTORY       Error opening file <path>: Is a directory
/// read denied         PERMISSION_DENIED  Error opening file <path>: Permission denied
/// read under a file   NOT_DIRECTORY      Error opening file <path>: Not a directory
/// list missing        NOT_FOUND          Error opening directory '<path>': No such file or directory
/// list a file         NOT_DIRECTORY      Error opening directory '<path>': Not a directory
/// list denied         PERMISSION_DENIED  Error opening directory '<path>': Permission denied
/// list a directory holding `latin1-\351-x.service` (a plain Error, no Gio code):
///   Could not convert filename string to UTF-8 for string: latin1-\351-x.service. If string is invalid
///   UTF-8 and used for display purposes, try GLib attribute standard::display-name. The reason is:
///   Invalid byte sequence in conversion input.<one trailing space>
/// ```
///
/// A read that fails after a good open is `Error reading from file: <reason>` (GLib's
/// `glocalfileinputstream.c`, and the text `service-sampler.test.js` builds for ENODEV). The reasons
/// are glibc's `strerror` texts, which `g_strerror` gives under an English locale.
pub mod gio_texts {
    use std::path::Path;

    /// `g_strerror(ENOENT)`.
    pub const NOT_FOUND_REASON: &str = "No such file or directory";
    /// `g_strerror(ENODEV)`.
    pub const NO_SUCH_DEVICE_REASON: &str = "No such device";
    /// What follows the escaped name in gjs's text for a name that is not valid UTF-8, trailing
    /// space included.
    const FILENAME_CONVERSION_FAILURE_TAIL: &str = ". If string is invalid UTF-8 and used for display \
        purposes, try GLib attribute standard::display-name. The reason is: Invalid byte sequence in \
        conversion input. ";
    /// What precedes the escaped name in that text.
    const FILENAME_CONVERSION_FAILURE_HEAD: &str =
        "Could not convert filename string to UTF-8 for string: ";

    /// A file that could not be opened (`g_local_file_read`).
    pub fn file_open_failure(path: &Path, reason: &str) -> String {
        format!("Error opening file {}: {reason}", path.display())
    }

    /// A read that failed after a good open (`g_local_file_input_stream_read`).
    pub fn file_read_failure(reason: &str) -> String {
        format!("Error reading from file: {reason}")
    }

    /// A directory that could not be opened for listing (`_g_local_file_enumerator_new`).
    pub fn directory_open_failure(path: &Path, reason: &str) -> String {
        format!("Error opening directory '{}': {reason}", path.display())
    }

    /// gjs's text for a directory name that is not valid UTF-8 (`gjs_string_from_filename`).
    pub fn filename_conversion_failure(name_bytes: &[u8]) -> String {
        let escaped_name = escaped_as_g_strescape(name_bytes);
        format!(
            "{FILENAME_CONVERSION_FAILURE_HEAD}{escaped_name}{FILENAME_CONVERSION_FAILURE_TAIL}"
        )
    }

    /// The first byte `g_strescape` writes as three octal digits, and every one above it.
    const FIRST_OCTAL_ESCAPED_HIGH_BYTE: u8 = 0x7f;
    /// The first byte `g_strescape` copies as it is.
    const FIRST_PRINTED_BYTE: u8 = b' ';

    /// `g_strescape(bytes, NULL)`: `\b`, `\f`, `\n`, `\r`, `\t`, `\v`, `\\` and `\"` by name, every
    /// other byte below 0x20 or from 0x7F up as a backslash and three octal digits, the rest as is.
    fn escaped_as_g_strescape(bytes: &[u8]) -> String {
        let mut escaped = String::with_capacity(bytes.len());
        for &byte in bytes {
            let named_escape = match byte {
                b'\x08' => Some("\\b"),
                b'\x0c' => Some("\\f"),
                b'\n' => Some("\\n"),
                b'\r' => Some("\\r"),
                b'\t' => Some("\\t"),
                b'\x0b' => Some("\\v"),
                b'\\' => Some("\\\\"),
                b'"' => Some("\\\""),
                _ => None,
            };
            match named_escape {
                Some(named_escape) => escaped.push_str(named_escape),
                None if !(FIRST_PRINTED_BYTE..FIRST_OCTAL_ESCAPED_HIGH_BYTE).contains(&byte) => {
                    escaped.push_str(&format!("\\{byte:03o}"));
                }
                None => escaped.push(char::from(byte)),
            }
        }
        escaped
    }
}

/// The reason in an io error's text: `strerror`'s words alone, without the ` (os error N)` that Rust
/// adds, which is what `g_strerror` gives. An error with no errno keeps its whole text.
fn os_error_reason(error: &io::Error) -> String {
    let error_text = error.to_string();
    let Some(errno) = error.raw_os_error() else {
        return error_text;
    };
    let rust_errno_suffix = format!(" (os error {errno})");
    error_text
        .strip_suffix(&rust_errno_suffix)
        .map_or_else(|| error_text.clone(), str::to_string)
}

/// The vanished failure an errno stands for: ENOENT or ENODEV, and nothing else.
fn vanished_failure_of(error: &io::Error) -> Option<ReadFailure> {
    match error.raw_os_error() {
        Some(libc::ENOENT) => Some(ReadFailure::NotFound),
        Some(libc::ENODEV) => Some(ReadFailure::NoSuchDevice),
        _ => None,
    }
}

/// The real reader. It reads to the end of the file whatever size the file reports (a `/proc`,
/// `/sys` or cgroup file reports 0 or a whole page), and replaces each invalid UTF-8 sequence with
/// U+FFFD as `String::from_utf8_lossy` does.
///
/// gjs's `TextDecoder` does the same for every sequence but one kind: a byte F5 to F7 followed by one
/// or two continuation bytes is one U+FFFD in gjs (SpiderMonkey reads F5 to F7 as the lead of an
/// old-style four-byte form) and two or three here. No published field can carry such bytes: the
/// files the sampler reads are the kernel's numbers and names, and the one place a person can put
/// arbitrary bytes, a swap file's name in `/proc/swaps`, is only matched against `/dev/zram<n>`, never
/// published or logged.
pub struct FileSystemReader;

impl FileReader for FileSystemReader {
    /// The file's text, or why it could not be read: ENOENT and ENODEV as themselves, any other
    /// failure with Gio's text.
    fn read_to_text(&self, path: &Path) -> Result<String, ReadFailure> {
        let mut file = File::open(path).map_err(|error| failure_of_open(path, &error))?;
        let mut contents = Vec::new();
        file.read_to_end(&mut contents)
            .map_err(|error| failure_of_read(path, &error))?;
        Ok(String::from_utf8_lossy(&contents).into_owned())
    }
}

/// The real lister. Directories are named as Gio names them for `listSubdirectoryNames`: a symlink
/// to a directory counts (Gio follows it), and a name that is not valid UTF-8 fails the listing at
/// the first such directory, with gjs's text, as the gjs listing throws there.
pub struct FileSystemLister;

impl DirectoryLister for FileSystemLister {
    /// The subdirectories' names in the order the directory lists them, or why it could not be
    /// listed.
    fn subdirectory_names(&self, path: &Path) -> Result<Vec<String>, ReadFailure> {
        let entries = fs::read_dir(path).map_err(|error| {
            vanished_failure_of(&error).unwrap_or_else(|| {
                ReadFailure::Other(gio_texts::directory_open_failure(
                    path,
                    &os_error_reason(&error),
                ))
            })
        })?;
        let mut subdirectory_names = Vec::new();
        for entry in entries {
            let entry = entry.map_err(|error| listing_failure_text(path, &error))?;
            if !is_directory_entry(&entry)? {
                continue;
            }
            let name = entry.file_name().into_string().map_err(|name| {
                ReadFailure::Other(gio_texts::filename_conversion_failure(name.as_bytes()))
            })?;
            subdirectory_names.push(name);
        }
        Ok(subdirectory_names)
    }
}

/// A failure while reading a directory's entries, after a good open. Not one of the texts probed
/// (a directory cannot be made to fail there on demand); it names the directory as the open's does.
fn listing_failure_text(path: &Path, error: &io::Error) -> ReadFailure {
    let reason = os_error_reason(error);
    ReadFailure::Other(format!(
        "Error reading directory '{}': {reason}",
        path.display()
    ))
}

/// Whether a listed entry is a directory as Gio sees it, following a symlink: one whose target is
/// gone or unreadable is not. An entry that vanished since the listing read it is not one either;
/// any other failure to learn its type fails the listing.
fn is_directory_entry(entry: &DirEntry) -> Result<bool, ReadFailure> {
    match entry.file_type() {
        Ok(file_type) if file_type.is_symlink() => {
            Ok(fs::metadata(entry.path()).is_ok_and(|metadata| metadata.is_dir()))
        }
        Ok(file_type) => Ok(file_type.is_dir()),
        Err(error) if error.raw_os_error() == Some(libc::ENOENT) => Ok(false),
        Err(error) => {
            let reason = os_error_reason(&error);
            let entry_path = entry.path();
            Err(ReadFailure::Other(format!(
                "Error when getting information for file '{}': {reason}",
                entry_path.display()
            )))
        }
    }
}

/// The failure an open of `path` meets: ENOENT and ENODEV as themselves, anything else with Gio's
/// text for an open.
fn failure_of_open(path: &Path, error: &io::Error) -> ReadFailure {
    vanished_failure_of(error).unwrap_or_else(|| {
        ReadFailure::Other(gio_texts::file_open_failure(path, &os_error_reason(error)))
    })
}

/// The failure a read after a good open meets: ENOENT and ENODEV as themselves; a directory with
/// Gio's text for an open, since Gio refuses a directory when it opens it, where Rust opens it and
/// fails the read; anything else with Gio's text for a read.
fn failure_of_read(path: &Path, error: &io::Error) -> ReadFailure {
    if let Some(vanished_failure) = vanished_failure_of(error) {
        return vanished_failure;
    }
    let reason = os_error_reason(error);
    if error.raw_os_error() == Some(libc::EISDIR) {
        return ReadFailure::Other(gio_texts::file_open_failure(path, &reason));
    }
    ReadFailure::Other(gio_texts::file_read_failure(&reason))
}

#[cfg(test)]
mod tests;
