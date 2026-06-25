//! HUD overlay text for the Bevy client (status, transport, voxel hotbar,
//! AOI peers, RTT/offset, recent chat, recent logs).

pub mod build_hotbar;
pub mod edit_feedback;
pub mod plugin;

pub use build_hotbar::BuildHotbarPlugin;
pub use edit_feedback::{EditFeedback, EditFeedbackPlugin};
pub use plugin::{HudPlugin, HudText};
