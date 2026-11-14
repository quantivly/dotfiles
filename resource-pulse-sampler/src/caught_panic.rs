//! Where a throw in gjs is a panic here: running a step so that its panic becomes a failure value,
//! and the text a caught panic is logged with. Crate-level, so the sampler and the tick loop's own
//! catches log a caught panic the same way.

use std::any::Any;
use std::panic::{catch_unwind, AssertUnwindSafe};

/// What a caught panic is logged as when its payload is not text (a panic with a value of another
/// type, which no code here raises).
pub(crate) const NON_TEXT_PANIC_TEXT: &str = "a panic whose payload is not text";

/// The panic's own message when it is text (`panic!` with a literal gives a `&str`, with a format a
/// `String`), else [`NON_TEXT_PANIC_TEXT`].
pub(crate) fn panic_text(payload: &(dyn Any + Send)) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        return (*message).to_string();
    }
    payload
        .downcast_ref::<String>()
        .cloned()
        .unwrap_or_else(|| NON_TEXT_PANIC_TEXT.to_string())
}

/// Runs a step, returning its value, or the text of its panic, as a gjs `try` gives the value or
/// the error (the caller logs it as gjs logs the error).
pub(crate) fn catching_panic<Value>(step: impl FnOnce() -> Value) -> Result<Value, String> {
    catch_unwind(AssertUnwindSafe(step)).map_err(|payload| panic_text(payload.as_ref()))
}

/// A best-effort value (`callOrNull`): the step's value, or `None` when it panics. Used only while
/// publishing "no data" after a failure that is being logged anyway, where this step may well be
/// what failed.
pub(crate) fn value_or_none<Value>(step: impl FnOnce() -> Value) -> Option<Value> {
    catch_unwind(AssertUnwindSafe(step)).ok()
}

#[cfg(test)]
mod tests {
    use super::{catching_panic, NON_TEXT_PANIC_TEXT};
    use crate::quiet_panics::QuietPanics;
    use std::panic::panic_any;

    #[test]
    fn a_panic_with_a_formatted_message_gives_the_formatted_text() {
        let reason = "disk on fire";
        let caught = {
            let _quiet = QuietPanics::on_this_thread();
            catching_panic(|| -> u32 { panic!("{reason}") })
        };
        assert_eq!(caught, Err("disk on fire".to_string()));
    }

    #[test]
    fn a_panic_whose_payload_is_not_text_gives_the_fixed_text() {
        let caught = {
            let _quiet = QuietPanics::on_this_thread();
            catching_panic(|| -> u32 { panic_any(42_i32) })
        };
        assert_eq!(caught, Err(NON_TEXT_PANIC_TEXT.to_string()));
    }
}
