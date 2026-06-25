//! Skill input + targeting for the Bevy client.
//!
//! - `targeting` — pure dispatch decision (`prepare_skill_dispatch`).
//! - `plugin` — keyboard skill hotkeys, target/point picking systems.

use bevy::prelude::*;

pub mod plugin;
pub mod targeting;

pub use plugin::SkillPlugin;
pub use targeting::prepare_skill_dispatch;

/// Current targeting intent — the actor cid (Tab-cycle / stdio `target`) or the
/// ground point (Shift+RMB / stdio `targetpoint`) a skill will aim at
/// (架构重整阶段2:从 `WorldState` god-resource 收口到 skill 域)。Selection is
/// **mutually exclusive**: setting a cid clears the point and vice versa. Read by
/// the HUD (target panel), the voxel target marker, and the skill dispatch; cleared
/// by net on death / scene-leave / target despawn.
#[derive(Resource, Default)]
pub struct TargetSelection {
    pub cid: Option<i64>,
    pub point: Option<Vec3>,
}
