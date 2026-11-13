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

pub mod constants;
