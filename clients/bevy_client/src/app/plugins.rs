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

use crate::camera::CameraPlugin;
use crate::chat::ChatPlugin;
use crate::effects::EffectPlugin;
use crate::hud::{BuildHotbarPlugin, EditFeedbackPlugin, HudPlugin};
use crate::movement::MovementSyncPlugin;
use crate::net::NetworkPlugin;
use crate::presentation::PresentationPlugin;
use crate::scene::SceneEnvironmentPlugin;
use crate::skill::SkillPlugin;
use crate::stdio::StdioPlugin;
use crate::voxel::{
    DebrisEffectPlugin, HeatSmokePlugin, IncandescencePlugin, LightningPlugin, MapCachePlugin,
    SemiconductorOverlayPlugin, VoxelAuthorityPlugin, VoxelChunkRenderPlugin,
    VoxelFieldRenderPlugin, VoxelPlugin,
};

/// Canonical Bevy client `PluginGroup`.
///
/// Plugins listed here run in addition to `LoginPlugin` and Bevy's
/// `DefaultPlugins`; the composition lives in [`crate::app::run`].
pub struct BevyClientPlugins;

impl PluginGroup for BevyClientPlugins {
    fn build(self) -> PluginGroupBuilder {
        PluginGroupBuilder::start::<Self>()
            .add(SceneEnvironmentPlugin)
            .add(NetworkPlugin)
            .add(StdioPlugin)
            .add(CameraPlugin)
            .add(ChatPlugin)
            .add(VoxelPlugin)
            .add(VoxelAuthorityPlugin)
            .add(MapCachePlugin)
            .add(VoxelChunkRenderPlugin)
            .add(VoxelFieldRenderPlugin)
            .add(SemiconductorOverlayPlugin)
            .add(IncandescencePlugin)
            .add(DebrisEffectPlugin)
            .add(HeatSmokePlugin)
            .add(LightningPlugin)
            .add(SkillPlugin)
            .add(MovementSyncPlugin)
            .add(EffectPlugin)
            .add(HudPlugin)
            .add(BuildHotbarPlugin)
            .add(EditFeedbackPlugin)
            .add(PresentationPlugin)
    }
}

// 架构重整阶段3:删除空的 `InputPlugin` / `ObservePlugin` 迁移 stub。输入逻辑实际
// 分布在各域插件(camera/skill/voxel/movement/chat),没有「共享输入」职责留给
// InputPlugin;`ClientObserver` 写入时自刷新(见 `observe.rs`),没有生命周期钩子
// 留给 ObservePlugin。两者均为 no-op,移除后所有插件都对应真实的域实现。
