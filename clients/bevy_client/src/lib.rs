//! Bevy client crate for the local MMO runtime.
//!
//! This crate is split by responsibility:
//!
//! - `net` owns transport/runtime protocol handling
//! - `sim` owns prediction/reconciliation data structures
//! - `presentation` owns visual smoothing helpers
//! - `world` owns local/remote actor runtime state
//! - `app` and `headless` provide the interactive and automation entrypoints

pub mod app;
pub mod config;
pub mod headless;
pub mod input;
pub mod movement;
pub mod net;
pub mod observe;
pub mod presentation;
pub mod protocol;
pub mod protocol_v2;
pub mod sim;
pub mod stdio;
pub mod world;
