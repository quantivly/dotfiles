//! Journal lines for failures, at most one per [`ERROR_LOG_REPEAT_INTERVAL_USEC`] for each template
//! key, ported from `lib/errorLog.js`'s `RateLimitedLogger`.

use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::constants::{ERROR_LOG_REPEAT_INTERVAL_USEC, LOG_PREFIX};
use crate::ports::Clock;

/// Writes each message at most once per [`ERROR_LOG_REPEAT_INTERVAL_USEC`] for its template key,
/// prefixed with [`LOG_PREFIX`] and a space. A first line and a line written again once the interval
/// has passed read the same: the message, with no count of the lines held back.
pub struct RateLimitedLog {
    /// Where a line goes (the journal, in the program).
    write: Box<dyn FnMut(&str)>,
    /// When each template key was last written, on the clock handed to [`RateLimitedLog::log`].
    last_logged_usec_by_template_key: HashMap<String, u64>,
}

impl RateLimitedLog {
    /// A log that has written nothing yet.
    pub fn new(write: Box<dyn FnMut(&str)>) -> RateLimitedLog {
        RateLimitedLog {
            write,
            last_logged_usec_by_template_key: HashMap::new(),
        }
    }

    /// Writes `message`, unless a message with the same template key was written less than
    /// [`ERROR_LOG_REPEAT_INTERVAL_USEC`] ago. Keys old enough to write again are forgotten first,
    /// so the table stays small.
    ///
    /// Never panics. A clock that panics loses the line: without a time it can be neither limited
    /// nor recorded. A writer that panics loses the line too, and the key counts as written, as in
    /// gjs, where the key is recorded before the write: there is nowhere left to report that
    /// failure, and the sampler must go on.
    ///
    /// Parameters
    /// ----------
    /// clock
    ///     Monotonic microseconds, read once per call (the sampler's own clock, as in gjs).
    /// message
    ///     The line, without the prefix.
    /// template_key
    ///     A stable name for a message whose text varies; a caller with none passes the message.
    pub fn log(&mut self, clock: &dyn Clock, message: &str, template_key: &str) {
        let Ok(now_usec) = catch_unwind(AssertUnwindSafe(|| clock.monotonic_usec())) else {
            return;
        };
        let last_logged_usec = self.last_logged_usec_by_template_key.get(template_key);
        if last_logged_usec
            .is_some_and(|&logged_at_usec| !is_interval_over(now_usec, logged_at_usec))
        {
            return;
        }
        self.last_logged_usec_by_template_key
            .retain(|_, logged_at_usec| !is_interval_over(now_usec, *logged_at_usec));
        self.last_logged_usec_by_template_key
            .insert(template_key.to_string(), now_usec);
        let line = format!("{LOG_PREFIX} {message}");
        let write = &mut self.write;
        // A writer's panic is dropped here, and only here: see the doc comment.
        let _ = catch_unwind(AssertUnwindSafe(|| write(&line)));
    }
}

/// `nowUsec - loggedAtUsec >= ERROR_LOG_REPEAT_INTERVAL_USEC`: whether the interval has run out since
/// a line was written. A clock that went backwards gives a negative difference in gjs, which is not
/// past the interval; `checked_sub` gives `None` there, which is not either, and never underflows.
fn is_interval_over(now_usec: u64, logged_at_usec: u64) -> bool {
    now_usec
        .checked_sub(logged_at_usec)
        .is_some_and(|elapsed_usec| elapsed_usec >= ERROR_LOG_REPEAT_INTERVAL_USEC)
}

#[cfg(test)]
mod tests {
    use std::cell::{Cell, RefCell};
    use std::rc::Rc;

    use super::*;
    use crate::quiet_panics::QuietPanics;
    use crate::test_support::SettableClock;

    /// A clock that panics, as a broken port might.
    struct PanickingClock;

    impl Clock for PanickingClock {
        /// Panics, as a broken clock port might.
        fn monotonic_usec(&self) -> u64 {
            panic!("clock exploded")
        }

        /// Never asked for by the log.
        fn clock_label(&self) -> Result<String, String> {
            Err("unused".to_string())
        }
    }

    /// A log whose lines land in the returned list.
    fn recording_log() -> (RateLimitedLog, Rc<RefCell<Vec<String>>>) {
        let written = Rc::new(RefCell::new(Vec::new()));
        let sink = Rc::clone(&written);
        let log = RateLimitedLog::new(Box::new(move |line| {
            sink.borrow_mut().push(line.to_string())
        }));
        (log, written)
    }

    /// The gjs logger's rule over one sequence of (clock, message, key), the key `None` for the
    /// message itself. Expected values: `RateLimitedLogger` run under gjs over the same sequence
    /// (a probe in the task's scratch directory): the first line, nothing inside the interval, the
    /// line again at exactly the interval, a key per template, nothing while the clock is behind
    /// the last line, and a key forgotten once its interval passed, which a clock gone back then
    /// writes again.
    #[test]
    fn each_template_key_writes_once_per_interval_and_keys_past_it_are_forgotten() {
        let steps: [(u64, &str, Option<&str>, Option<&str>); 13] = [
            (0, "a", None, Some("resource-pulse: a")),
            (1, "a", None, None),
            (1, "b 1", Some("b"), Some("resource-pulse: b 1")),
            (2, "b 2", Some("b"), None),
            (599_999_999, "a", None, None),
            (600_000_000, "a", None, Some("resource-pulse: a")),
            (600_000_001, "b 3", Some("b"), Some("resource-pulse: b 3")),
            (600_000_000, "a", None, None),
            (5, "a", None, None),
            (0, "x", None, Some("resource-pulse: x")),
            (700_000_000, "y", None, Some("resource-pulse: y")),
            (1, "x", None, Some("resource-pulse: x")),
            (1, "y", None, None),
        ];
        let clock = SettableClock::with_fixed_label(Rc::new(Cell::new(0)));
        let (mut log, written) = recording_log();
        for (now_usec, message, template_key, expected_line) in steps {
            clock.set(now_usec);
            let lines_before = written.borrow().len();
            log.log(&clock, message, template_key.unwrap_or(message));
            let new_line = written.borrow().get(lines_before).cloned();
            assert_eq!(
                new_line.as_deref(),
                expected_line,
                "at {now_usec} µs, {message}"
            );
        }
    }

    /// A clock that panics loses the line and records nothing; a writer that panics loses its line,
    /// and its key counts as written. Neither panic leaves `log`.
    #[test]
    fn a_panicking_clock_or_writer_loses_the_line_and_does_not_panic() {
        let quiet_panics = QuietPanics::on_this_thread();
        let (mut log, written) = recording_log();
        log.log(&PanickingClock, "lost", "lost");
        let clock = SettableClock::with_fixed_label(Rc::new(Cell::new(0)));
        log.log(&clock, "lost", "lost");
        let mut panicking_log = RateLimitedLog::new(Box::new(|_| panic!("writer exploded")));
        panicking_log.log(&clock, "dropped", "dropped");
        let write_attempts = Rc::new(Cell::new(0));
        let attempts = Rc::clone(&write_attempts);
        panicking_log.write = Box::new(move |_| attempts.set(attempts.get() + 1));
        panicking_log.log(&clock, "dropped", "dropped");
        // The panics this row makes on purpose are over: a failing assertion below must print its message.
        drop(quiet_panics);
        assert_eq!(*written.borrow(), vec!["resource-pulse: lost".to_string()]);
        assert_eq!(write_attempts.get(), 0);
    }
}
