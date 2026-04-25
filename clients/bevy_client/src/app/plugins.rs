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
use crate::stdio::StdioPlugin;

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

stub_plugin!(
    NetworkPlugin,
    "Network bridge, command queue, and `NetworkEvent` polling."
);
// StdioPlugin is now defined in `crate::stdio::plugin`.
stub_plugin!(
    InputPlugin,
    "Keyboard / mouse / chat input — emits domain events for voxel, skill, chat, hotbar."
);
// CameraPlugin is now defined in `crate::camera::plugin`.
stub_plugin!(
    ChatPlugin,
    "Chat input mode, log buffer, and outbound chat dispatch."
);
stub_plugin!(
    VoxelPlugin,
    "Voxel selection, hit-face highlight, prefab preview, edit dispatch."
);
stub_plugin!(
    SkillPlugin,
    "Skill targeting, casting queue, and target-point picking."
);
stub_plugin!(
    MovementSyncPlugin,
    "Movement uplink tick + local render prediction integration."
);
stub_plugin!(
    EffectPlugin,
    "Effect-cue visuals (gizmo + transient meshes)."
);
stub_plugin!(HudPlugin, "HUD text aggregation and rendering.");
stub_plugin!(
    PresentationPlugin,
    "Player visuals, actor materials, selection guides."
);
stub_plugin!(
    ObservePlugin,
    "Observe log flush + lifetime hooks (Startup + Last)."
);
