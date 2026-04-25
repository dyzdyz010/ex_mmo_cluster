//! Skill input + targeting for the Bevy client.
//!
//! - `targeting` — pure dispatch decision (`prepare_skill_dispatch`).
//! - `plugin` — keyboard skill hotkeys, target/point picking systems.

pub mod plugin;
pub mod targeting;

pub use plugin::SkillPlugin;
pub use targeting::prepare_skill_dispatch;
