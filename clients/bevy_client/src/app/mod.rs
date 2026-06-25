//! Interactive Bevy app entrypoint and world/UI glue.
//!
//! `app::run` is the composition root for the GUI / stdio modes. The
//! restructure plan in `docs/superpowers/specs/2026-04-25-bevy-client-restructure-design.md`
//! splits this file into Bevy `Plugin`s (one per domain) under
//! `app::plugins::BevyClientPlugins`. While that migration is in progress
//! `app::run` continues to register systems directly; new systems should
//! land inside their owning Plugin instead.

pub mod plugins;
pub mod schedule;

use self::{plugins::BevyClientPlugins, schedule::configure_client_sets};
use crate::{
    config::ClientConfig,
    login::{AppState, LoginPlugin},
    net::spawn_network_thread,
    observe::ClientObserver,
    session::{ConnectionPhase, ConnectionState, SessionCredentials},
    sim::{
        profile::MovementProfile,
        types::{MovementMode, PredictedMoveState},
    },
    stdio::ClientStdioInterface,
    voxel::VoxelWorld,
};
use bevy::{
    prelude::*,
    window::{PrimaryWindow, WindowPlugin},
};
use std::{collections::VecDeque, path::PathBuf};

#[derive(Debug, Copy, Clone, PartialEq)]
pub(crate) struct RenderRay {
    pub origin: Vec3,
    pub direction: Vec3,
}

/// Scene-wide render assets created in `setup` and consumed by all of
/// the in-world render plugins (`VoxelPlugin`, `PresentationPlugin`, …).
///
/// Refined micro cells share the same opaque material as their macro
/// parents — see `voxel::plugin::voxel_material_color`.
#[derive(Resource, Clone)]
pub(crate) struct SceneRenderAssets {
    pub cube_mesh: Handle<Mesh>,
    pub player_mesh: Handle<Mesh>,
    pub target_mesh: Handle<Mesh>,
    pub dirt_material: Handle<StandardMaterial>,
    pub stone_material: Handle<StandardMaterial>,
    pub wood_material: Handle<StandardMaterial>,
    pub ice_material: Handle<StandardMaterial>,
    pub local_player_material: Handle<StandardMaterial>,
    pub remote_player_material: Handle<StandardMaterial>,
    pub moving_player_material: Handle<StandardMaterial>,
    pub selected_actor_material: Handle<StandardMaterial>,
    pub npc_material: Handle<StandardMaterial>,
    pub target_material: Handle<StandardMaterial>,
}

#[derive(Resource, Default)]
pub(crate) struct MovementIntent {
    pub direction: Vec2,
    pub expires_at: f64,
    pub jump_requested: bool,
}

#[derive(Resource)]
pub(crate) struct MovementDispatchState {
    pub stop_sent: bool,
}

#[derive(Resource)]
/// Visual layer for the local predicted player. Anchor mirrors the latest
/// authoritative/predicted sim position; `pending_correction` captures any
/// visual offset introduced by authority corrections and decays to zero via
/// Unreal-style exponential smoothing so the player never sees a teleport.
///
/// Audit B-L3: `smoothing_rate_hz` is **deliberately decoupled** from the
/// adaptive `ReplayGovernance::soft_position_error` / jitter EWMA in
/// `LocalPredictionRuntime`. Rationale: the visual smoothing rate must
/// stay perceptually constant — making it follow jitter would mean a
/// laggy network suddenly feels mushy *and* that the avatar drifts
/// noticeably for the duration of the spike. The reconciler already
/// inflates its tolerance under jitter (B-M1) so the visual layer does
/// not need a second feedback loop. If a future use case demands
/// jitter-aware smoothing, route it through
/// `LocalPredictionRuntime::current_jitter_ms` rather than reading the
/// governance threshold directly — the governance value is bounded by
/// `max_soft_position_error` which would silently cap any derived rate.
pub(crate) struct LocalRenderPrediction {
    pub anchor_state: Option<PredictedMoveState>,
    pub render_state: Option<PredictedMoveState>,
    pub partial_elapsed_secs: f32,
    pub pending_correction: Vec3,
    pub smoothing_rate_hz: f32,
    pub profile: MovementProfile,
}

impl Default for LocalRenderPrediction {
    fn default() -> Self {
        Self {
            anchor_state: None,
            render_state: None,
            partial_elapsed_secs: 0.0,
            pending_correction: Vec3::ZERO,
            smoothing_rate_hz: DEFAULT_VISUAL_SMOOTHING_RATE_HZ,
            profile: MovementProfile::default(),
        }
    }
}

impl LocalRenderPrediction {
    pub(crate) fn reset(&mut self, position: Vec3) {
        let state = PredictedMoveState::idle(position);
        self.anchor_state = Some(state.clone());
        self.render_state = Some(state);
        self.partial_elapsed_secs = 0.0;
        self.pending_correction = Vec3::ZERO;
    }

    /// Receives the next authoritative/predicted anchor sample. The old render
    /// position is preserved by folding the resulting delta into
    /// `pending_correction`, which decays toward zero each frame so corrections
    /// blend in rather than teleport. Large jumps hard-snap to prevent visible
    /// rubberbanding from accumulating.
    pub(crate) fn sync_full_state(
        &mut self,
        position: Vec3,
        velocity: Vec3,
        acceleration: Vec3,
        movement_mode: MovementMode,
    ) {
        let new_anchor = PredictedMoveState {
            seq: 0,
            tick: 0,
            position,
            velocity,
            acceleration,
            movement_mode,
            ground_z: position.z,
        };

        let old_rendered_pos = self
            .render_state
            .as_ref()
            .map(|state| state.position)
            .or_else(|| self.anchor_state.as_ref().map(|state| state.position));
        let delta = match old_rendered_pos {
            Some(old_rendered) => old_rendered - position,
            None => Vec3::ZERO,
        };

        self.pending_correction = if delta.length() > VISUAL_HARD_SNAP_DISTANCE {
            Vec3::ZERO
        } else {
            delta
        };

        self.anchor_state = Some(new_anchor.clone());
        self.partial_elapsed_secs = 0.0;

        let render_pos = new_anchor.position + self.pending_correction;
        self.render_state = Some(PredictedMoveState {
            position: render_pos,
            ..new_anchor
        });
    }

    pub(crate) fn clear(&mut self) {
        self.anchor_state = None;
        self.render_state = None;
        self.partial_elapsed_secs = 0.0;
        self.pending_correction = Vec3::ZERO;
    }

    /// Returns the current outstanding visual correction magnitude in world units.
    pub(crate) fn pending_correction_distance(&self) -> f32 {
        self.pending_correction.length()
    }
}

pub(crate) const VISUAL_SMOOTHING_SPEED: f32 = 18.0;
pub(crate) const VISUAL_SNAP_DISTANCE: f32 = 96.0;
pub(crate) const VISUAL_HARD_SNAP_DISTANCE: f32 = 256.0;
pub(crate) const DEFAULT_VISUAL_SMOOTHING_RATE_HZ: f32 = 15.0;
pub(crate) const VISUAL_CORRECTION_EPSILON_SQ: f32 = 0.01;
pub(crate) const FINAL_STOP_SYNC_SPEED_EPSILON: f32 = 1.0;

impl Default for MovementDispatchState {
    fn default() -> Self {
        Self { stop_sent: true }
    }
}

/// Runs the interactive Bevy client.
///
/// If `initial_credentials` is `Some`, the login panel is skipped and the network thread
/// is launched immediately. Otherwise the login state renders an egui panel to collect
/// a username and perform the auto_login handshake.
pub fn run(
    config: ClientConfig,
    observer: ClientObserver,
    stdio: ClientStdioInterface,
    initial_credentials: Option<SessionCredentials>,
) {
    let starts_in_game = initial_credentials.is_some();
    let mut voxel_world = VoxelWorld::new();
    voxel_world.bootstrap_showcase(2);

    // Seed the local actor at the world origin so the third-person camera
    // has a target to follow and `sync_player_visuals` has a local cid to
    // render even before (or in lieu of) a server connection. Once the
    // network thread receives `EnteredScene` / `LocalPosition`,
    // `NetworkPlugin` overwrites both with the server-authoritative state.
    let mut local_render_prediction = LocalRenderPrediction::default();
    local_render_prediction.reset(Vec3::ZERO);

    let mut app = App::new();
    app.insert_resource(ClearColor(Color::srgb(0.05, 0.07, 0.09)))
        .insert_resource(config.clone())
        // LocalPlayerState::default() seeds local_position=ZERO / hp=100 / alive=true
        // exactly as the old WorldState construction did; NetworkPlugin overwrites it
        // with server-authoritative state on scene entry.
        .init_resource::<crate::world::LocalPlayerState>()
        .insert_resource(ConnectionState {
            phase: ConnectionPhase::Connecting,
            status: if starts_in_game {
                "starting client".to_string()
            } else {
                "waiting for login".to_string()
            },
        })
        .insert_resource(MovementIntent::default())
        .insert_resource(MovementDispatchState::default())
        .insert_resource(local_render_prediction)
        .insert_resource(voxel_world)
        .init_resource::<crate::voxel::VoxelAoiState>()
        .init_resource::<crate::skill::TargetSelection>()
        .init_resource::<crate::hud::GameLogs>()
        .init_resource::<crate::net::NetTelemetry>()
        .init_resource::<crate::world::RemotePlayers>()
        .insert_resource(observer)
        .insert_resource(stdio)
        .add_plugins(DefaultPlugins.set(WindowPlugin {
            primary_window: Some(Window {
                title: "Hemifuture Bevy Client".to_string(),
                resolution: (1280, 720).into(),
                ..default()
            }),
            ..default()
        }))
        .add_plugins(LoginPlugin)
        .add_plugins(BevyClientPlugins)
        .init_state::<AppState>();

    configure_client_sets(&mut app);

    // Build the shared render-asset handles once, at the composition root, so the
    // resource exists before any domain `Startup` system runs (the voxel target
    // marker + the presentation/voxel renderers read `Res<SceneRenderAssets>`).
    // `Assets<Mesh>` / `Assets<StandardMaterial>` are registered by DefaultPlugins'
    // build() above, so they are present in the world at this point.
    let scene_assets = crate::scene::build_scene_render_assets(app.world_mut());
    app.insert_resource(scene_assets);

    app.add_systems(OnEnter(AppState::Game), enter_game_setup);

    if let Some(creds) = initial_credentials {
        app.insert_resource(creds);
        app.world_mut()
            .resource_mut::<NextState<AppState>>()
            .set(AppState::Game);
    }

    app.run();
}

fn enter_game_setup(
    mut commands: Commands,
    config: Res<ClientConfig>,
    creds: Res<SessionCredentials>,
    observer: Res<ClientObserver>,
    mut local_player: ResMut<crate::world::LocalPlayerState>,
    mut connection: ResMut<ConnectionState>,
    mut windows: Query<&mut Window, With<PrimaryWindow>>,
) {
    let bridge = spawn_network_thread(config.clone(), creds.clone(), observer.clone());
    commands.insert_resource(bridge);

    local_player.cid = creds.cid;
    connection.status = "starting client".to_string();

    if let Ok(mut window) = windows.single_mut() {
        window.title = format!(
            "Hemifuture Bevy Client - {} / cid {}",
            creds.username, creds.cid
        );
    }
}

pub(crate) fn voxel_save_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join(".demo")
        .join("observe")
}

/// Translates a wire-protocol `[f64; 3]` into a Bevy `Vec3` in the
/// simulation coordinate space.
pub(crate) fn net_to_world(value: [f64; 3]) -> Vec3 {
    Vec3::new(value[0] as f32, value[1] as f32, value[2] as f32)
}

/// Re-maps a sim-coord vector (`Y` = up at the simulation level) into
/// the render axis convention used by the Bevy 3D view.
pub(crate) fn sim_to_render_position(position: Vec3) -> Vec3 {
    Vec3::new(position.x, position.z, position.y)
}

/// Inverse of `sim_to_render_position` — used when picking points from
/// the render plane back into sim coordinates.
pub(crate) fn render_to_sim_position(position: Vec3) -> Vec3 {
    Vec3::new(position.x, position.z, position.y)
}

/// Builds a viewport-space ray from cursor / window-center coordinates.
pub(crate) fn ray_from_viewport(
    camera: &Camera,
    camera_transform: &GlobalTransform,
    viewport_position: Vec2,
) -> Option<RenderRay> {
    let ray = camera
        .viewport_to_world(camera_transform, viewport_position)
        .ok()?;
    Some(RenderRay {
        origin: ray.origin,
        direction: ray.direction.as_vec3(),
    })
}

/// Intersects a render-space ray against a horizontal plane at the given
/// world-space `y`.
pub(crate) fn ray_intersection_with_y_plane(origin: Vec3, direction: Vec3, y: f32) -> Option<Vec3> {
    if direction.y.abs() <= f32::EPSILON {
        return None;
    }
    let distance = (y - origin.y) / direction.y;
    (distance >= 0.0).then_some(origin + direction * distance)
}

/// Append a status / log line, clipping the buffer to the most recent 10.
pub(crate) fn push_line(buffer: &mut VecDeque<String>, line: String) {
    if buffer.len() >= 10 {
        buffer.pop_front();
    }
    buffer.push_back(line);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::{MacroCoord, VoxelMaterialId};

    #[test]
    fn voxel_3d_render_cells_include_all_refined_micro_slots() {
        let mut world = VoxelWorld::new();
        let placed = world.place_prefab(
            "builtin_sphere",
            MacroCoord::new(8, 5, 8),
            crate::voxel::Rotation::Rot0,
        );
        assert!(placed.ok);

        let refined_cells = world.render_cells_3d();
        assert_eq!(refined_cells.len(), 280);
        assert!(refined_cells.iter().any(|cell| {
            cell.macro_coord == MacroCoord::new(8, 5, 8)
                && cell.micro == Some(crate::voxel::MicroCoord::new(4, 4, 4))
                && cell.material_id == VoxelMaterialId::Wood
        }));
    }

    #[test]
    fn local_render_prediction_accumulates_correction_without_teleport() {
        let mut render = LocalRenderPrediction::default();
        render.reset(Vec3::new(0.0, 0.0, 0.0));

        // Simulate the anchor drifting forward by 8 units (predicted input).
        render.sync_full_state(
            Vec3::new(8.0, 0.0, 0.0),
            Vec3::ZERO,
            Vec3::ZERO,
            MovementMode::Grounded,
        );
        let render_at_first_sync = render
            .render_state
            .as_ref()
            .expect("render_state should be set after sync_full_state")
            .position;
        assert!((render_at_first_sync.x - 0.0).abs() < 0.01);

        // Authoritative correction pulls anchor back to 4 — render must stay
        // near the visible 8 so the player does not see a teleport.
        render.sync_full_state(
            Vec3::new(4.0, 0.0, 0.0),
            Vec3::ZERO,
            Vec3::ZERO,
            MovementMode::Grounded,
        );
        let render_after_correction = render
            .render_state
            .as_ref()
            .expect("render_state should be set after sync_full_state")
            .position;
        assert!((render_after_correction.x - render_at_first_sync.x).abs() < 0.01);
        assert!(render.pending_correction_distance() > 3.0);
    }

    #[test]
    fn local_render_prediction_preserves_authoritative_movement_mode() {
        let mut render = LocalRenderPrediction::default();

        render.sync_full_state(
            Vec3::new(0.0, 0.0, 100.0),
            Vec3::new(0.0, 0.0, 25.0),
            Vec3::ZERO,
            MovementMode::Airborne,
        );

        assert_eq!(
            render
                .anchor_state
                .as_ref()
                .expect("anchor_state should be set after sync_full_state")
                .movement_mode,
            MovementMode::Airborne
        );
        assert_eq!(
            render
                .render_state
                .as_ref()
                .expect("render_state should be set after sync_full_state")
                .movement_mode,
            MovementMode::Airborne
        );
    }

    #[test]
    fn local_render_prediction_hard_snaps_on_huge_drift() {
        let mut render = LocalRenderPrediction::default();
        render.reset(Vec3::new(0.0, 0.0, 0.0));

        // First settle at a position far from the next sync to build a visible
        // history.
        render.sync_full_state(
            Vec3::new(10.0, 0.0, 0.0),
            Vec3::ZERO,
            Vec3::ZERO,
            MovementMode::Grounded,
        );

        // A 400-unit authoritative jump exceeds VISUAL_HARD_SNAP_DISTANCE and
        // must zero the pending correction — the render faithfully jumps.
        render.sync_full_state(
            Vec3::new(-390.0, 0.0, 0.0),
            Vec3::ZERO,
            Vec3::ZERO,
            MovementMode::Grounded,
        );
        assert_eq!(render.pending_correction, Vec3::ZERO);
        let rendered = render
            .render_state
            .as_ref()
            .expect("render_state should be set after sync_full_state")
            .position;
        assert!((rendered.x - (-390.0)).abs() < 0.01);
    }

    #[test]
    fn local_render_prediction_reset_clears_correction() {
        let mut render = LocalRenderPrediction::default();
        render.reset(Vec3::new(0.0, 0.0, 0.0));
        render.sync_full_state(
            Vec3::new(8.0, 0.0, 0.0),
            Vec3::ZERO,
            Vec3::ZERO,
            MovementMode::Grounded,
        );
        render.sync_full_state(
            Vec3::new(4.0, 0.0, 0.0),
            Vec3::ZERO,
            Vec3::ZERO,
            MovementMode::Grounded,
        );
        assert!(render.pending_correction_distance() > 0.0);

        render.reset(Vec3::new(100.0, 0.0, 0.0));
        assert_eq!(render.pending_correction, Vec3::ZERO);
        assert_eq!(
            render
                .render_state
                .as_ref()
                .expect("render_state should be set after reset")
                .position,
            Vec3::new(100.0, 0.0, 0.0)
        );
    }
}
