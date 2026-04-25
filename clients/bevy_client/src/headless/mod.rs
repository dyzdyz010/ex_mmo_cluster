//! Headless client entrypoints used by automation and non-visual QA.
//!
//! - `run` / `run_stdio` — server-attached headless modes.
//! - `run_voxel_headless` — server-free local voxel CLI loop.
//!
//! Implementation lives in:
//! - `script` — `--script` parser
//! - `state` — `HeadlessState` + `apply_event` event reducer + helpers
//! - `runner` — server-attached `run` / `run_stdio`
//! - `voxel_runner` — `--voxel-headless` runner

pub mod runner;
pub mod script;
pub mod state;
pub mod voxel_runner;

pub use runner::{HeadlessOptions, run, run_stdio};
pub use voxel_runner::run_voxel_headless;
