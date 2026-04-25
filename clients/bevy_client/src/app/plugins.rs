//! `BevyClientPlugins` — the canonical PluginGroup for the GUI / stdio
//! Bevy client.
//!
//! Phase 3 introduces this PluginGroup as a structural skeleton. Each
//! domain Plugin currently registers nothing; phase 4 of the restructure
//! plan migrates systems out of `app::run` into their owning Plugin one
//! domain at a time. Adding the Plugin now (instead of waiting until the
//! migration finishes) makes each subsequent phase a pure additive change
//! to a single Plugin's `build()`.
//!
//! Order matters: Plugins are added in the canonical
//! `Network → Stdio → Input → Logic → Sync → Render` ordering described in
//! `crate::app::schedule::ClientSet`. Plugins do not currently tag their
//! systems with these sets — they will once the systems migrate.

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
use crate::voxel::VoxelPlugin;

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
                // Phase 3 stub — systems migrate here in phase 4.
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
