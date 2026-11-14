//! What several modules' tests share: the fixture roots, a history built from values, and a clock
//! a test sets. Compiled for tests only. `tests/golden.rs` is an integration test, outside the
//! crate, and keeps its own.

use std::cell::Cell;
use std::num::NonZeroUsize;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use crate::history::RingBuffer;
use crate::ports::Clock;

/// How many values a history built by [`history_of`] holds: the protocol's history length.
const TEST_HISTORY_CAPACITY: usize = 150;
/// The clock label a [`SettableClock`] gives unless its test supplies its own source.
pub(crate) const TEST_CLOCK_LABEL: &str = "14:02";

/// Where one label comes from: a source that may fail, as the real clock's can.
pub(crate) type ClockLabelSource = Box<dyn Fn() -> Result<String, String>>;

/// The absolute path of a fixture root under `gnome-shell/tests/fixtures`.
pub(crate) fn fixture_root(root_name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../gnome-shell/tests/fixtures")
        .join(root_name)
}

/// A history holding these values, oldest first.
pub(crate) fn history_of(values: &[Option<f64>]) -> RingBuffer {
    let capacity = NonZeroUsize::new(TEST_HISTORY_CAPACITY).unwrap();
    let mut history = RingBuffer::new(capacity);
    for value in values {
        history.push(*value);
    }
    history
}

/// A clock whose time the test sets, shared with whoever holds the same cell, and whose label
/// comes from a source the test gives.
pub(crate) struct SettableClock {
    monotonic_usec: Rc<Cell<u64>>,
    clock_label_source: ClockLabelSource,
}

impl SettableClock {
    /// A clock reading `monotonic_usec`, with labels from `clock_label_source`.
    pub(crate) fn new(
        monotonic_usec: Rc<Cell<u64>>,
        clock_label_source: ClockLabelSource,
    ) -> SettableClock {
        SettableClock {
            monotonic_usec,
            clock_label_source,
        }
    }

    /// A clock reading `monotonic_usec`, whose label is always [`TEST_CLOCK_LABEL`].
    pub(crate) fn with_fixed_label(monotonic_usec: Rc<Cell<u64>>) -> SettableClock {
        SettableClock::new(
            monotonic_usec,
            Box::new(|| Ok(TEST_CLOCK_LABEL.to_string())),
        )
    }

    /// Sets the time the clock reads.
    pub(crate) fn set(&self, monotonic_usec: u64) {
        self.monotonic_usec.set(monotonic_usec);
    }
}

impl Clock for SettableClock {
    /// The time the test set.
    fn monotonic_usec(&self) -> u64 {
        self.monotonic_usec.get()
    }

    /// The label the test's source gives.
    fn clock_label(&self) -> Result<String, String> {
        (self.clock_label_source)()
    }
}
