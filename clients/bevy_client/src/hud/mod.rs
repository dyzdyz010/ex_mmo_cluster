//! HUD overlay text for the Bevy client (status, transport, voxel hotbar,
//! AOI peers, RTT/offset, recent chat, recent logs).

use std::collections::VecDeque;

use bevy::prelude::Resource;

pub mod build_hotbar;
pub mod edit_feedback;
pub mod plugin;

pub use build_hotbar::BuildHotbarPlugin;
pub use edit_feedback::{EditFeedback, EditFeedbackPlugin};
pub use plugin::{HudPlugin, HudText};

/// Bounded rolling message histories surfaced by the HUD + the stdio harness
/// queries (架构重整阶段2:从 `WorldState` god-resource 收口到 hud 域)。Each
/// channel is a `VecDeque<String>` capped by [`crate::app::push_line`]. Mirrors
/// the headless `HeadlessState` log surface so GUI + headless report identically.
#[derive(Resource, Default)]
pub struct GameLogs {
    /// General system/status/diagnostic line history (was `WorldState::logs`).
    pub general: VecDeque<String>,
    /// Chat message history (was `chat_log`).
    pub chat: VecDeque<String>,
    /// Combat (damage/heal/death) history (was `combat_log`).
    pub combat: VecDeque<String>,
    /// Effect/status-cue history (was `effect_log`).
    pub effect: VecDeque<String>,
    /// Skill-cast history (was `skill_log`).
    pub skill: VecDeque<String>,
}
