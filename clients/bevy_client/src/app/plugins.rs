//! `BevyClientPlugins` — the canonical PluginGroup for the GUI / stdio
//! Bevy client.
//!
//! This PluginGroup is the structural spine for the GUI / stdio client.
//! Domain systems are being moved out of `app::run` into their owning
//! plugins one subsystem at a time; plugins that have not migrated yet stay
//! as explicit stubs so the final boundary remains visible.
//!
//! Order matters at the plugin-boundary level, and gameplay systems that are
//! sensitive to frame order opt into the canonical `Network -> Stdio -> Input
//! -> Logic -> Sync -> Render` sets described in
//! `crate::app::schedule::ClientSet`.

use bevy::app::{PluginGroup, PluginGroupBuilder};
use bevy::prelude::*;

use crate::camera::CameraPlugin;
use crate::chat::ChatPlugin;
use crate::effects::EffectPlugin;
use crate::hud::HudPlugin;
use crate::movement::MovementSyncPlugin;
use crate::net::NetworkPlugin;
use crate::presentation::PresentationPlugin;
use crate::skill::SkillPlugin;
use crate::stdio::StdioPlugin;
use crate::voxel::{
    DebrisEffectPlugin, HeatSmokePlugin, LightningPlugin, VoxelAuthorityPlugin,
    VoxelChunkRenderPlugin, VoxelFieldRenderPlugin, VoxelPlugin,
};

/// Canonical Bevy client `PluginGroup`.
///
/// Plugins listed here run in addition to `LoginPlugin` and Bevy's
/// `DefaultPlugins`; the composition lives in [`crate::app::run`].
pub struct BevyClientPlugins;

impl PluginGroup for BevyClientPlugins {
    fn build(self) -> PluginGroupBuilder {
        PluginGroupBuilder::start::<Self>()
            .add(NetworkPlugin)
            .add(StdioPlugin)
            .add(InputPlugin)
            .add(CameraPlugin)
            .add(ChatPlugin)
            .add(VoxelPlugin)
            .add(VoxelAuthorityPlugin)
            .add(VoxelChunkRenderPlugin)
            .add(VoxelFieldRenderPlugin)
            .add(DebrisEffectPlugin)
            .add(HeatSmokePlugin)
            .add(LightningPlugin)
            .add(SkillPlugin)
            .add(MovementSyncPlugin)
            .add(EffectPlugin)
            .add(HudPlugin)
            .add(PresentationPlugin)
            .add(ObservePlugin)
    }
}

macro_rules! stub_plugin {
    ($name:ident, $doc:expr) => {
        #[doc = $doc]
        pub struct $name;

        impl Plugin for $name {
            fn build(&self, _app: &mut App) {
                // Migration stub — systems move here as each domain is split
                // out of app::run.
            }
        }
    };
}

// NetworkPlugin is now defined in `crate::net::plugin`.
// StdioPlugin is now defined in `crate::stdio::plugin`.
stub_plugin!(
    InputPlugin,
    "Keyboard / mouse / chat input — emits domain events for voxel, skill, chat, hotbar."
);
// CameraPlugin is now defined in `crate::camera::plugin`.
// ChatPlugin is now defined in `crate::chat::plugin`.
// VoxelPlugin is now defined in `crate::voxel::plugin`.
// SkillPlugin is now defined in `crate::skill::plugin`.
// MovementSyncPlugin is now defined in `crate::movement::plugin`.
// EffectPlugin is now defined in `crate::effects::plugin`.
// HudPlugin is now defined in `crate::hud::plugin`.
// PresentationPlugin is now defined in `crate::presentation::plugin`.
stub_plugin!(
    ObservePlugin,
    "Observe log flush + lifetime hooks (Startup + Last)."
);
