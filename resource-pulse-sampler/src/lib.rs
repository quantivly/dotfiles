//! Resource Pulse's sampler, compiled. This crate replaces the gjs service
//! under `gnome-shell/extensions/resource-pulse@dotfiles/service/`; its modules
//! are added one task at a time, each carrying the gjs rows it replaces.
//!
//! Tests may unwrap, index and panic: a failing test should say so loudly. The
//! program itself may not (see `[lints.clippy]` in Cargo.toml).
#![cfg_attr(
    test,
    allow(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::indexing_slicing,
        clippy::string_slice,
        clippy::panic
    )
)]

pub mod apps;
pub mod bus;
pub mod cadence;
pub mod constants;
pub mod cpu;
pub mod desktop_names;
pub mod history;
pub mod insertion_ordered_map;
pub mod js_string;
pub mod memory;
pub mod parsers;
pub mod ports;
pub mod pressure;
#[cfg(test)]
mod quiet_panics;
pub mod rate_limited_log;
