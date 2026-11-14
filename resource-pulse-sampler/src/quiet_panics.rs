//! For tests that make a port panic on purpose: keeps the panic hook from printing those panics'
//! messages to the test output, and restores the hook afterwards.
//!
//! The hook is process-wide and tests run on several threads, so a [`QuietPanics`] holds a lock
//! for as long as it lives (the tests that replace the hook run one at a time), and the hook it
//! installs stays quiet only on the thread that made it: a panic on any other thread, such as
//! another test's failing assertion, still reaches the previous hook and is printed.

use std::panic::{self, PanicHookInfo};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::{self, ThreadId};

/// A panic hook, as `std::panic::take_hook` returns it.
type PanicHook = Box<dyn Fn(&PanicHookInfo<'_>) + Sync + Send + 'static>;

/// Held by the one [`QuietPanics`] alive at a time.
static HOOK_REPLACEMENT_LOCK: Mutex<()> = Mutex::new(());

/// While alive, panics on the thread that created it print nothing.
pub(crate) struct QuietPanics {
    /// The hook in place before, shared with the quiet hook, which forwards to it.
    previous_hook: Option<Arc<PanicHook>>,
    /// Released last, once the previous hook is back.
    _hook_replacement: MutexGuard<'static, ()>,
}

impl QuietPanics {
    /// Silences panics on this thread until the value is dropped.
    pub(crate) fn on_this_thread() -> QuietPanics {
        // A test that panicked while holding the lock poisons it; the lock guards no data.
        let hook_replacement = HOOK_REPLACEMENT_LOCK
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let previous_hook: Arc<PanicHook> = Arc::new(panic::take_hook());
        let quiet_thread: ThreadId = thread::current().id();
        let forwarded_hook = Arc::clone(&previous_hook);
        panic::set_hook(Box::new(move |panic_info| {
            if thread::current().id() != quiet_thread {
                forwarded_hook(panic_info);
            }
        }));
        QuietPanics {
            previous_hook: Some(previous_hook),
            _hook_replacement: hook_replacement,
        }
    }
}

impl Drop for QuietPanics {
    /// Puts the previous hook back, itself when nothing else holds it.
    ///
    /// Not while this thread unwinds from a failed test: replacing the hook then would panic again
    /// and abort every test. The quiet hook stays, which is harmless: it forwards every other thread's
    /// panic, and a finished test's thread id is never reused.
    fn drop(&mut self) {
        if thread::panicking() {
            return;
        }
        // Dropping the quiet hook drops its share of the previous one.
        drop(panic::take_hook());
        let Some(previous_hook) = self.previous_hook.take() else {
            return;
        };
        match Arc::try_unwrap(previous_hook) {
            Ok(previous_hook) => panic::set_hook(previous_hook),
            Err(shared_previous_hook) => {
                panic::set_hook(Box::new(move |panic_info| shared_previous_hook(panic_info)))
            }
        }
    }
}
