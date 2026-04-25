//! HUD overlay text for the Bevy client (status, transport, voxel hotbar,
//! AOI peers, RTT/offset, recent chat, recent logs).

pub mod plugin;

pub use plugin::{HudPlugin, HudText};
