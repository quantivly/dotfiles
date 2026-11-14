//! Reading and parsing a file with each failure logged, rate-limited, as `service/sampler.js`'s
//! `_readAndParse`, `_parseOrLog`, `_logReadFailure` and `_logRateLimited` do.

use std::path::Path;

use super::Sampler;
use crate::ports::ReadFailure;

impl Sampler {
    /// Logs a message at most once per `ERROR_LOG_REPEAT_INTERVAL_USEC` for its template key.
    pub(super) fn log_rate_limited(&mut self, message: &str, template_key: &str) {
        self.error_log
            .log(self.clock.as_ref(), message, template_key);
    }

    /// Logs a message whose text is its own template key.
    pub(super) fn log_once_per_interval(&mut self, message: &str) {
        self.log_rate_limited(message, message);
    }

    /// Logs a failed read, rate-limited per path whatever the failure says.
    pub(super) fn log_read_failure(&mut self, path: &Path, failure: &ReadFailure) {
        let path_text = path.display();
        let failure_text = failure.file_failure_text(path);
        self.log_rate_limited(
            &format!("cannot read {path_text}: {failure_text}"),
            &format!("cannot read {path_text}"),
        );
    }

    /// Reads and parses a file, logging a failed read or an unparseable file; `None` on either.
    pub(super) fn read_and_parse<Parsed>(
        &mut self,
        path: &Path,
        parse: impl FnOnce(&str) -> Option<Parsed>,
    ) -> Option<Parsed> {
        match self.reader.read_to_text(path) {
            Ok(contents) => self.parse_or_log(&contents, path, parse),
            Err(failure) => {
                self.log_read_failure(path, &failure);
                None
            }
        }
    }

    /// Parses a file's contents, logging when they are unparseable.
    pub(super) fn parse_or_log<Parsed>(
        &mut self,
        contents: &str,
        path: &Path,
        parse: impl FnOnce(&str) -> Option<Parsed>,
    ) -> Option<Parsed> {
        let parsed = parse(contents);
        if parsed.is_none() {
            self.log_once_per_interval(&format!("cannot parse {}", path.display()));
        }
        parsed
    }
}
