//! Interactive Bevy app entrypoint and world/UI glue.

use crate::{
    config::{ClientConfig, SessionCredentials},
    input::commands::{MOVEMENT_FLAG_BRAKE, MOVEMENT_FLAG_JUMP, MoveInputFrame},
    login::{AppState, LoginPlugin},
    net::{MessageTransport, NetworkBridge, NetworkCommand, NetworkEvent, spawn_network_thread},
    observe::ClientObserver,
    presentation::{
        animation::{animated_scale, animation_state_from_velocity},
        smoothing::smooth_translation,
    },
    protocol::EffectCueKind,
    sim::{
        predictor,
        profile::MovementProfile,
        types::{MovementMode, PredictedMoveState},
    },
    skill_targeting::prepare_skill_dispatch,
    stdio::{
        ClientStdioCommand, ClientStdioInterface, SnapshotFields, emit as emit_stdio,
        emit_owned as emit_stdio_owned, snapshot_fields,
    },
    voxel::{
        BoundarySnapPreview, BoundarySnapRequest, MacroCoord, MicroCoord, NormalBlockData,
        VoxelMaterialId, VoxelRenderCell, VoxelWorld, execute_voxel_cli_command,
    },
    world::remote_actor::{RemoteActorIdentity, RemoteActorKind},
    world::remote_player::{RemoteMotionSample, RemotePlayerState},
};
use bevy::{
    app::AppExit,
    ecs::system::SystemParam,
    input::{
        keyboard::{Key, KeyboardInput},
        mouse::{MouseMotion, MouseWheel},
    },
    prelude::*,
    window::{PrimaryWindow, WindowPlugin},
};
use std::{
    collections::{HashMap, VecDeque},
    path::PathBuf,
};

#[derive(Component)]
struct PlayerVisual {
    cid: i64,
}

#[derive(Component)]
struct HudText;

#[derive(Component)]
struct ChatLogText;

#[derive(Component)]
struct ChatInputText;

#[derive(Component)]
struct EffectVisual {
    kind: EffectCueKind,
    timer: Timer,
    origin: Vec3,
    target: Vec3,
    radius: f32,
}

#[derive(Component)]
struct TargetPointMarker;

#[derive(Component)]
struct MainCamera;

#[derive(Resource, Debug)]
struct OrbitCameraState {
    yaw: f32,
    pitch: f32,
    distance: f32,
    target: Vec3,
}

impl Default for OrbitCameraState {
    fn default() -> Self {
        Self {
            yaw: -0.75,
            pitch: 0.55,
            distance: CAMERA_DEFAULT_DISTANCE,
            target: Vec3::new(0.0, CAMERA_LOOK_HEIGHT, 0.0),
        }
    }
}

#[derive(Resource, Default, Debug, Clone)]
struct VoxelSelectionState {
    selection: Option<VoxelRaySelection>,
}

#[derive(Debug, Copy, Clone, PartialEq)]
struct RenderRay {
    origin: Vec3,
    direction: Vec3,
}

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
struct MicroCellTarget {
    macro_coord: MacroCoord,
    micro: MicroCoord,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct VoxelRaySelection {
    occupied_macro: MacroCoord,
    adjacent_macro: MacroCoord,
    face_normal: MacroCoord,
    occupied_micro: Option<MicroCellTarget>,
    adjacent_micro: Option<MicroCellTarget>,
}

#[derive(Resource, Clone)]
struct SceneRenderAssets {
    cube_mesh: Handle<Mesh>,
    player_mesh: Handle<Mesh>,
    target_mesh: Handle<Mesh>,
    dirt_material: Handle<StandardMaterial>,
    stone_material: Handle<StandardMaterial>,
    wood_material: Handle<StandardMaterial>,
    ice_material: Handle<StandardMaterial>,
    dirt_refined_material: Handle<StandardMaterial>,
    stone_refined_material: Handle<StandardMaterial>,
    wood_refined_material: Handle<StandardMaterial>,
    ice_refined_material: Handle<StandardMaterial>,
    local_player_material: Handle<StandardMaterial>,
    remote_player_material: Handle<StandardMaterial>,
    moving_player_material: Handle<StandardMaterial>,
    selected_actor_material: Handle<StandardMaterial>,
    npc_material: Handle<StandardMaterial>,
    target_material: Handle<StandardMaterial>,
}

#[derive(SystemParam)]
struct VoxelInputParams<'w, 's> {
    mouse: Res<'w, ButtonInput<MouseButton>>,
    keyboard: Res<'w, ButtonInput<KeyCode>>,
    wheel_reader: MessageReader<'w, 's, MouseWheel>,
    chat_state: Res<'w, ChatState>,
    observer: Res<'w, ClientObserver>,
    selection_state: Res<'w, VoxelSelectionState>,
    voxel_world: ResMut<'w, VoxelWorld>,
    world_state: ResMut<'w, WorldState>,
}

#[derive(SystemParam)]
struct MovementSendParams<'w> {
    time: Res<'w, Time>,
    bridge: Res<'w, NetworkBridge>,
    config: Res<'w, ClientConfig>,
    observer: Res<'w, ClientObserver>,
    world_state: Res<'w, WorldState>,
    movement_intent: ResMut<'w, MovementIntent>,
    movement_dispatch: ResMut<'w, MovementDispatchState>,
    tick: ResMut<'w, MovementTick>,
}

#[derive(SystemParam)]
struct OrbitCameraParams<'w, 's> {
    time: Res<'w, Time>,
    chat_state: Res<'w, ChatState>,
    mouse: Res<'w, ButtonInput<MouseButton>>,
    keyboard: Res<'w, ButtonInput<KeyCode>>,
    motion_reader: MessageReader<'w, 's, MouseMotion>,
    wheel_reader: MessageReader<'w, 's, MouseWheel>,
    world_state: Res<'w, WorldState>,
    local_render_prediction: Res<'w, LocalRenderPrediction>,
    voxel_world: Res<'w, VoxelWorld>,
    orbit: ResMut<'w, OrbitCameraState>,
    camera: Single<'w, 's, &'static mut Transform, With<MainCamera>>,
}

#[derive(SystemParam)]
struct PlayerVisualParams<'w, 's> {
    time: Res<'w, Time>,
    world_state: Res<'w, WorldState>,
    local_render_prediction: Res<'w, LocalRenderPrediction>,
    config: Res<'w, ClientConfig>,
    voxel_world: Res<'w, VoxelWorld>,
    assets: Res<'w, SceneRenderAssets>,
    existing: Query<
        'w,
        's,
        (
            Entity,
            &'static PlayerVisual,
            &'static mut Transform,
            &'static mut MeshMaterial3d<StandardMaterial>,
        ),
    >,
}

#[derive(SystemParam)]
struct StdioCommandParams<'w> {
    time: Res<'w, Time>,
    stdio: Res<'w, ClientStdioInterface>,
    bridge: Res<'w, NetworkBridge>,
    local_render_prediction: Res<'w, LocalRenderPrediction>,
    voxel_world: ResMut<'w, VoxelWorld>,
    world_state: ResMut<'w, WorldState>,
    movement_intent: ResMut<'w, MovementIntent>,
    app_exit: MessageWriter<'w, AppExit>,
}

type HudTextSingle<'w, 's> = Single<
    'w,
    's,
    &'static mut Text,
    (With<HudText>, Without<ChatLogText>, Without<ChatInputText>),
>;
type ChatLogTextSingle<'w, 's> = Single<
    'w,
    's,
    &'static mut Text,
    (With<ChatLogText>, Without<HudText>, Without<ChatInputText>),
>;
type ChatInputTextSingle<'w, 's> = Single<
    'w,
    's,
    &'static mut Text,
    (With<ChatInputText>, Without<HudText>, Without<ChatLogText>),
>;

#[derive(SystemParam)]
struct HudTextParams<'w, 's> {
    hud: HudTextSingle<'w, 's>,
    chat_log_text: ChatLogTextSingle<'w, 's>,
    chat_input_text: ChatInputTextSingle<'w, 's>,
}

#[derive(Component, Copy, Clone, PartialEq, Eq, Hash)]
struct VoxelCellVisual {
    macro_coord: MacroCoord,
    micro: Option<crate::voxel::MicroCoord>,
}

#[derive(Resource, Default)]
struct WorldState {
    status: String,
    scene_joined: bool,
    local_cid: i64,
    local_position: Option<Vec3>,
    local_velocity: Vec3,
    remote_players: HashMap<i64, RemotePlayerState>,
    local_hp: u16,
    local_max_hp: u16,
    local_alive: bool,
    remote_actor_identity: HashMap<i64, RemoteActorIdentity>,
    remote_player_health: HashMap<i64, (u16, u16, bool)>,
    chat_log: VecDeque<String>,
    logs: VecDeque<String>,
    last_rtt_ms: Option<f64>,
    last_offset_ms: Option<f64>,
    last_heartbeat_ts: Option<u64>,
    control_transport: MessageTransport,
    movement_transport: MessageTransport,
    fast_lane_status: String,
    udp_endpoint: Option<String>,
    last_local_update_transport: Option<MessageTransport>,
    last_remote_move_transport: Option<MessageTransport>,
    selected_target_cid: Option<i64>,
    selected_target_point: Option<Vec3>,
}

#[derive(Resource, Default)]
struct ChatState {
    enabled: bool,
    draft: String,
}

#[derive(Resource)]
struct MovementTick(Timer);

#[derive(Resource, Default)]
struct MovementIntent {
    direction: Vec2,
    expires_at: f64,
    jump_requested: bool,
}

#[derive(Resource)]
struct MovementDispatchState {
    stop_sent: bool,
}

#[derive(Resource, Default)]
struct InputTraceState {
    last_direction_label: String,
}

#[derive(Resource)]
/// Visual layer for the local predicted player. Anchor mirrors the latest
/// authoritative/predicted sim position; `pending_correction` captures any
/// visual offset introduced by authority corrections and decays to zero via
/// Unreal-style exponential smoothing so the player never sees a teleport.
struct LocalRenderPrediction {
    anchor_state: Option<PredictedMoveState>,
    render_state: Option<PredictedMoveState>,
    partial_elapsed_secs: f32,
    pending_correction: Vec3,
    smoothing_rate_hz: f32,
    profile: MovementProfile,
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
    fn reset(&mut self, position: Vec3) {
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
    fn sync_full_state(&mut self, position: Vec3, velocity: Vec3, acceleration: Vec3) {
        let new_anchor = PredictedMoveState {
            seq: 0,
            tick: 0,
            position,
            velocity,
            acceleration,
            movement_mode: MovementMode::Grounded,
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

    fn clear(&mut self) {
        self.anchor_state = None;
        self.render_state = None;
        self.partial_elapsed_secs = 0.0;
        self.pending_correction = Vec3::ZERO;
    }

    /// Returns the current outstanding visual correction magnitude in world units.
    fn pending_correction_distance(&self) -> f32 {
        self.pending_correction.length()
    }
}

const VISUAL_SMOOTHING_SPEED: f32 = 18.0;
const VISUAL_SNAP_DISTANCE: f32 = 96.0;
const VISUAL_HARD_SNAP_DISTANCE: f32 = 256.0;
const DEFAULT_VISUAL_SMOOTHING_RATE_HZ: f32 = 15.0;
const VISUAL_CORRECTION_EPSILON_SQ: f32 = 0.01;
const FINAL_STOP_SYNC_SPEED_EPSILON: f32 = 1.0;
const VOXEL_RENDER_CELL_SIZE: f32 = 100.0;
const VOXEL_RENDER_MICRO_SIZE: f32 = VOXEL_RENDER_CELL_SIZE / crate::voxel::MICRO_PER_MACRO as f32;
const CAMERA_LOOK_HEIGHT: f32 = 110.0;
const CAMERA_DEFAULT_DISTANCE: f32 = 410.0;
const CAMERA_MIN_DISTANCE: f32 = 180.0;
const CAMERA_MAX_DISTANCE: f32 = 620.0;
const CAMERA_YAW_SENSITIVITY: f32 = 0.005;
const CAMERA_PITCH_SENSITIVITY: f32 = 0.004;
const CAMERA_MIN_PITCH: f32 = 0.2;
const CAMERA_MAX_PITCH: f32 = 1.15;
const VOXEL_RAY_MAX_DISTANCE: f32 = 2_500.0;
const ACTOR_HALF_HEIGHT: f32 = 18.0;

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

    let mut app = App::new();
    app.insert_resource(ClearColor(Color::srgb(0.05, 0.07, 0.09)))
        .insert_resource(config.clone())
        .insert_resource(WorldState {
            status: if starts_in_game {
                "starting client".to_string()
            } else {
                "waiting for login".to_string()
            },
            local_velocity: Vec3::ZERO,
            local_hp: 100,
            local_max_hp: 100,
            local_alive: true,
            control_transport: MessageTransport::Tcp,
            movement_transport: MessageTransport::Tcp,
            fast_lane_status: "tcp fallback".to_string(),
            ..default()
        })
        .insert_resource(ChatState::default())
        .insert_resource(MovementIntent::default())
        .insert_resource(MovementDispatchState::default())
        .insert_resource(InputTraceState::default())
        .insert_resource(LocalRenderPrediction::default())
        .insert_resource(OrbitCameraState::default())
        .insert_resource(VoxelSelectionState::default())
        .insert_resource(voxel_world)
        .insert_resource(observer)
        .insert_resource(stdio)
        .insert_resource(MovementTick(Timer::from_seconds(
            config.movement_interval_ms as f32 / 1_000.0,
            TimerMode::Repeating,
        )))
        .add_plugins(DefaultPlugins.set(WindowPlugin {
            primary_window: Some(Window {
                title: "Hemifuture Bevy Client".to_string(),
                resolution: (1280, 720).into(),
                ..default()
            }),
            ..default()
        }))
        .add_plugins(LoginPlugin)
        .init_state::<AppState>()
        .add_systems(Startup, setup)
        .add_systems(OnEnter(AppState::Game), enter_game_setup)
        .add_systems(
            Update,
            (
                poll_network_events,
                toggle_chat_mode,
                collect_chat_text,
                (
                    update_orbit_camera,
                    update_voxel_selection,
                    handle_target_selection_input,
                    handle_point_target_input,
                    handle_voxel_input,
                )
                    .chain(),
                handle_skill_input,
                sample_movement_input,
                poll_stdio_commands,
                movement_sender,
                (
                    sync_voxel_visuals,
                    advance_local_render_prediction,
                    sync_player_visuals,
                )
                    .chain(),
                update_target_point_marker,
                draw_voxel_guides,
                draw_effect_gizmos,
                update_effect_visuals,
                update_hud_text,
            )
                .run_if(in_state(AppState::Game)),
        );

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
    mut world_state: ResMut<WorldState>,
    mut windows: Query<&mut Window, With<PrimaryWindow>>,
) {
    let bridge = spawn_network_thread(config.clone(), creds.clone(), observer.clone());
    commands.insert_resource(bridge);

    world_state.local_cid = creds.cid;
    world_state.status = "starting client".to_string();

    if let Ok(mut window) = windows.single_mut() {
        window.title = format!(
            "Hemifuture Bevy Client - {} / cid {}",
            creds.username, creds.cid
        );
    }
}

fn setup(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
) {
    let assets = SceneRenderAssets {
        cube_mesh: meshes.add(Cuboid::new(1.0, 1.0, 1.0)),
        player_mesh: meshes.add(Cuboid::new(1.0, 1.0, 1.0)),
        target_mesh: meshes.add(Cuboid::new(1.0, 1.0, 1.0)),
        dirt_material: materials.add(StandardMaterial {
            base_color: voxel_material_color(VoxelMaterialId::Dirt, false),
            perceptual_roughness: 0.9,
            ..default()
        }),
        stone_material: materials.add(StandardMaterial {
            base_color: voxel_material_color(VoxelMaterialId::Stone, false),
            perceptual_roughness: 0.95,
            ..default()
        }),
        wood_material: materials.add(StandardMaterial {
            base_color: voxel_material_color(VoxelMaterialId::Wood, false),
            perceptual_roughness: 0.86,
            ..default()
        }),
        ice_material: materials.add(StandardMaterial {
            base_color: voxel_material_color(VoxelMaterialId::Ice, false),
            perceptual_roughness: 0.38,
            metallic: 0.02,
            ..default()
        }),
        dirt_refined_material: materials.add(transparent_material(voxel_material_color(
            VoxelMaterialId::Dirt,
            true,
        ))),
        stone_refined_material: materials.add(transparent_material(voxel_material_color(
            VoxelMaterialId::Stone,
            true,
        ))),
        wood_refined_material: materials.add(transparent_material(voxel_material_color(
            VoxelMaterialId::Wood,
            true,
        ))),
        ice_refined_material: materials.add(transparent_material(voxel_material_color(
            VoxelMaterialId::Ice,
            true,
        ))),
        local_player_material: materials.add(StandardMaterial {
            base_color: Color::srgb(0.25, 0.95, 0.45),
            emissive: Color::srgb(0.02, 0.16, 0.04).into(),
            ..default()
        }),
        remote_player_material: materials.add(Color::srgb(0.3, 0.65, 1.0)),
        moving_player_material: materials.add(Color::srgb(0.35, 0.75, 1.0)),
        selected_actor_material: materials.add(Color::srgb(1.0, 0.95, 0.35)),
        npc_material: materials.add(Color::srgb(0.95, 0.45, 0.35)),
        target_material: materials.add(StandardMaterial {
            base_color: Color::srgba(0.95, 0.35, 0.95, 0.82),
            alpha_mode: AlphaMode::Blend,
            unlit: true,
            ..default()
        }),
    };

    commands.spawn((
        PointLight {
            intensity: 2_600_000.0,
            range: 1_800.0,
            shadows_enabled: true,
            ..default()
        },
        Transform::from_xyz(450.0, 900.0, 450.0),
    ));
    commands.spawn((
        DirectionalLight {
            illuminance: 7_000.0,
            shadows_enabled: true,
            ..default()
        },
        Transform::from_translation(Vec3::new(-1.0, 2.0, 1.0)).looking_at(Vec3::ZERO, Vec3::Y),
    ));

    commands.spawn((
        Camera3d::default(),
        MainCamera,
        camera_transform_from_orbit(&OrbitCameraState::default()),
    ));

    commands.spawn((
        HudText,
        Text::new(""),
        TextFont {
            font_size: 18.0,
            ..default()
        },
        TextColor(Color::WHITE),
        Node {
            position_type: PositionType::Absolute,
            top: px(12),
            left: px(12),
            ..default()
        },
    ));

    commands.spawn((
        ChatLogText,
        Text::new(""),
        TextFont {
            font_size: 18.0,
            ..default()
        },
        TextColor(Color::srgb(0.85, 0.9, 1.0)),
        Node {
            position_type: PositionType::Absolute,
            left: px(12),
            bottom: px(56),
            ..default()
        },
    ));

    commands.spawn((
        ChatInputText,
        Text::new(""),
        TextFont {
            font_size: 20.0,
            ..default()
        },
        TextColor(Color::srgb(1.0, 0.95, 0.55)),
        Node {
            position_type: PositionType::Absolute,
            left: px(12),
            bottom: px(12),
            ..default()
        },
    ));

    commands.spawn((
        TargetPointMarker,
        Mesh3d(assets.target_mesh.clone()),
        MeshMaterial3d(assets.target_material.clone()),
        Visibility::Hidden,
        Transform::from_xyz(0.0, 0.0, 0.0).with_scale(Vec3::new(22.0, 6.0, 22.0)),
    ));

    commands.insert_resource(assets);
}

fn poll_network_events(
    mut commands: Commands,
    bridge: Res<NetworkBridge>,
    time: Res<Time>,
    stdio: Res<ClientStdioInterface>,
    mut world_state: ResMut<WorldState>,
    mut local_render_prediction: ResMut<LocalRenderPrediction>,
    mut movement_dispatch: ResMut<MovementDispatchState>,
) {
    let Ok(receiver) = bridge.rx.lock() else {
        return;
    };

    while let Ok(event) = receiver.try_recv() {
        match event {
            NetworkEvent::Status(status) => {
                world_state.status = status.clone();
                if stdio.is_enabled() {
                    emit_stdio("status", &[("message", status.clone())]);
                }
                push_line(&mut world_state.logs, status);
            }
            NetworkEvent::EnteredScene { cid, location } => {
                world_state.scene_joined = true;
                world_state.status = format!("in scene as cid {cid}");
                world_state.local_cid = cid;
                let world_location = net_to_world(location);
                world_state.local_position = Some(world_location);
                world_state.local_velocity = Vec3::ZERO;
                local_render_prediction.reset(world_location);
                world_state.remote_players.clear();
                world_state.remote_actor_identity.clear();
                world_state.remote_player_health.clear();
                world_state.last_local_update_transport = None;
                world_state.last_remote_move_transport = None;
                world_state.selected_target_cid = None;
                world_state.selected_target_point = None;
                movement_dispatch.stop_sent = true;
                push_line(&mut world_state.logs, format!("entered scene cid={cid}"));
            }
            NetworkEvent::LocalPosition {
                cid: _,
                location,
                velocity,
                acceleration,
                transport,
            } => {
                let world_location = net_to_world(location);
                let world_velocity = net_to_world(velocity);
                let world_acceleration = net_to_world(acceleration);
                world_state.local_position = Some(world_location);
                world_state.local_velocity = world_velocity;
                local_render_prediction.sync_full_state(
                    world_location,
                    world_velocity,
                    world_acceleration,
                );
                world_state.last_local_update_transport = Some(transport);
            }
            NetworkEvent::PlayerEnter { cid, location } => {
                if cid != world_state.local_cid {
                    world_state.remote_players.insert(
                        cid,
                        RemotePlayerState::seeded(
                            cid,
                            net_to_world(location),
                            time.elapsed_secs_f64(),
                        ),
                    );
                }
                if stdio.is_enabled() {
                    emit_stdio(
                        "player_enter",
                        &[
                            ("cid", cid.to_string()),
                            (
                                "location",
                                format!("{:.1},{:.1},{:.1}", location[0], location[1], location[2]),
                            ),
                        ],
                    );
                }
                push_line(&mut world_state.logs, format!("player {cid} entered AOI"));
            }
            NetworkEvent::PlayerMove {
                snapshot,
                transport,
            } => {
                let cid = snapshot.cid;
                if cid != world_state.local_cid {
                    let received_at = time.elapsed_secs_f64();
                    if let Some(state) = world_state.remote_players.get_mut(&cid) {
                        state.push_snapshot(snapshot, received_at);
                    } else {
                        world_state
                            .remote_players
                            .insert(cid, RemotePlayerState::from_snapshot(snapshot, received_at));
                    }
                }
                world_state.last_remote_move_transport = Some(transport);
            }
            NetworkEvent::PlayerLeave { cid } => {
                world_state.remote_players.remove(&cid);
                world_state.remote_actor_identity.remove(&cid);
                world_state.remote_player_health.remove(&cid);
                if world_state.selected_target_cid == Some(cid) {
                    world_state.selected_target_cid = None;
                }
                push_line(&mut world_state.logs, format!("player {cid} left AOI"));
            }
            NetworkEvent::ActorIdentity { cid, kind, name } => {
                world_state.remote_actor_identity.insert(
                    cid,
                    RemoteActorIdentity {
                        cid,
                        kind,
                        name: name.clone(),
                    },
                );
                push_line(
                    &mut world_state.logs,
                    format!("actor: cid={cid} kind={:?} name={name}", kind),
                );
            }
            NetworkEvent::ChatMessage {
                cid,
                username,
                text,
            } => {
                if stdio.is_enabled() {
                    emit_stdio(
                        "chat_message",
                        &[
                            ("cid", cid.to_string()),
                            ("username", username.clone()),
                            ("text", text.clone()),
                        ],
                    );
                }
                push_line(
                    &mut world_state.chat_log,
                    format!("[{cid}/{username}] {text}"),
                );
            }
            NetworkEvent::SkillEvent { cid, skill_id, .. } => {
                if stdio.is_enabled() {
                    emit_stdio(
                        "skill_event",
                        &[("cid", cid.to_string()), ("skill_id", skill_id.to_string())],
                    );
                }
                push_line(
                    &mut world_state.logs,
                    format!("skill event: cid={cid} skill={skill_id}"),
                );
            }
            NetworkEvent::PlayerState {
                cid,
                hp,
                max_hp,
                alive,
            } => {
                if cid == world_state.local_cid {
                    world_state.local_hp = hp;
                    world_state.local_max_hp = max_hp;
                    world_state.local_alive = alive;
                } else {
                    world_state
                        .remote_player_health
                        .insert(cid, (hp, max_hp, alive));
                }

                if stdio.is_enabled() {
                    emit_stdio(
                        "player_state",
                        &[
                            ("cid", cid.to_string()),
                            ("hp", hp.to_string()),
                            ("max_hp", max_hp.to_string()),
                            ("alive", alive.to_string()),
                        ],
                    );
                }
                push_line(
                    &mut world_state.logs,
                    format!("state: cid={cid} hp={hp}/{max_hp} alive={alive}"),
                );
            }
            NetworkEvent::CombatHit {
                source_cid,
                target_cid,
                skill_id,
                damage,
                hp_after,
                ..
            } => {
                if stdio.is_enabled() {
                    emit_stdio(
                        "combat_hit",
                        &[
                            ("source_cid", source_cid.to_string()),
                            ("target_cid", target_cid.to_string()),
                            ("skill_id", skill_id.to_string()),
                            ("damage", damage.to_string()),
                            ("hp_after", hp_after.to_string()),
                        ],
                    );
                }
                push_line(
                    &mut world_state.logs,
                    format!(
                        "combat: {source_cid} -> {target_cid} skill={skill_id} damage={damage} hp_after={hp_after}"
                    ),
                );
            }
            NetworkEvent::EffectEvent {
                cue_kind,
                origin,
                target_position,
                radius,
                duration_ms,
                ..
            } => {
                let origin_world = net_to_world(origin);
                let target_world = net_to_world(target_position);
                commands.spawn((
                    EffectVisual {
                        kind: cue_kind,
                        timer: Timer::from_seconds(duration_ms as f32 / 1_000.0, TimerMode::Once),
                        origin: origin_world,
                        target: target_world,
                        radius: radius as f32,
                    },
                    Transform::from_translation(sim_to_render_position(effect_spawn_translation(
                        cue_kind,
                        origin_world,
                        target_world,
                    ))),
                ));
            }
            NetworkEvent::TimeSync { rtt_ms, offset_ms } => {
                world_state.last_rtt_ms = Some(rtt_ms);
                world_state.last_offset_ms = Some(offset_ms);
            }
            NetworkEvent::Heartbeat { server_ts } => {
                world_state.last_heartbeat_ts = Some(server_ts);
            }
            NetworkEvent::TransportState {
                control_transport,
                movement_transport,
                fast_lane_status,
                udp_endpoint,
            } => {
                world_state.control_transport = control_transport;
                world_state.movement_transport = movement_transport;
                world_state.fast_lane_status = fast_lane_status;
                world_state.udp_endpoint = udp_endpoint;
            }
            NetworkEvent::ReconcileStats {
                total_corrections,
                total_replays,
                total_hard_snaps,
                total_window_trims,
                last_replayed_frames,
                last_pending_inputs,
                last_correction_distance,
            } => {
                if stdio.is_enabled() {
                    emit_stdio(
                        "reconcile_stats",
                        &[
                            ("total_corrections", total_corrections.to_string()),
                            ("total_replays", total_replays.to_string()),
                            ("total_hard_snaps", total_hard_snaps.to_string()),
                            ("total_window_trims", total_window_trims.to_string()),
                            ("last_replayed_frames", last_replayed_frames.to_string()),
                            ("last_pending_inputs", last_pending_inputs.to_string()),
                            (
                                "last_correction_distance",
                                format!("{:.3}", last_correction_distance),
                            ),
                        ],
                    );
                }
            }
            NetworkEvent::Log(line) => {
                if stdio.is_enabled() {
                    emit_stdio("log", &[("line", line.clone())]);
                }
                push_line(&mut world_state.logs, line)
            }
            NetworkEvent::Disconnected(reason) => {
                world_state.scene_joined = false;
                world_state.status = format!("disconnected: {reason}");
                world_state.local_position = None;
                world_state.local_velocity = Vec3::ZERO;
                world_state.remote_players.clear();
                world_state.remote_actor_identity.clear();
                world_state.remote_player_health.clear();
                world_state.movement_transport = MessageTransport::Tcp;
                world_state.fast_lane_status = "tcp fallback".to_string();
                world_state.udp_endpoint = None;
                world_state.last_local_update_transport = None;
                world_state.last_remote_move_transport = None;
                world_state.selected_target_cid = None;
                world_state.selected_target_point = None;
                local_render_prediction.clear();
                movement_dispatch.stop_sent = true;
                if stdio.is_enabled() {
                    emit_stdio("disconnected", &[("reason", reason.clone())]);
                }
                push_line(&mut world_state.logs, format!("disconnect: {reason}"));
            }
        }
    }
}

fn toggle_chat_mode(
    keyboard: Res<ButtonInput<KeyCode>>,
    bridge: Res<NetworkBridge>,
    observer: Res<ClientObserver>,
    mut chat_state: ResMut<ChatState>,
) {
    if !chat_state.enabled && keyboard.just_pressed(KeyCode::Enter) {
        chat_state.enabled = true;
        observer.emit("input", "chat_opened", &[]);
        return;
    }

    if chat_state.enabled && keyboard.just_pressed(KeyCode::Escape) {
        chat_state.enabled = false;
        chat_state.draft.clear();
        observer.emit("input", "chat_cancelled", &[]);
        return;
    }

    if chat_state.enabled && keyboard.just_pressed(KeyCode::Enter) {
        let message = chat_state.draft.trim().to_string();
        if !message.is_empty() {
            bridge.send(NetworkCommand::Chat(message));
            observer.emit(
                "input",
                "chat_submitted",
                &[("draft", chat_state.draft.clone())],
            );
        }
        chat_state.draft.clear();
        chat_state.enabled = false;
    }
}

fn collect_chat_text(
    mut keyboard_input_reader: MessageReader<KeyboardInput>,
    mut chat_state: ResMut<ChatState>,
) {
    if !chat_state.enabled {
        return;
    }

    for keyboard_input in keyboard_input_reader.read() {
        if !keyboard_input.state.is_pressed() {
            continue;
        }

        match (&keyboard_input.logical_key, &keyboard_input.text) {
            (Key::Backspace, _) => {
                chat_state.draft.pop();
            }
            (Key::Enter, _) => {}
            (_, Some(inserted_text)) if inserted_text.chars().all(is_printable_char) => {
                chat_state.draft.push_str(inserted_text);
            }
            _ => {}
        }
    }
}

fn handle_skill_input(
    keyboard: Res<ButtonInput<KeyCode>>,
    bridge: Res<NetworkBridge>,
    observer: Res<ClientObserver>,
    chat_state: Res<ChatState>,
    mut world_state: ResMut<WorldState>,
) {
    if chat_state.enabled {
        return;
    }

    let skill_modifier =
        keyboard.pressed(KeyCode::ShiftLeft) || keyboard.pressed(KeyCode::ShiftRight);
    if !skill_modifier {
        return;
    }

    if keyboard.just_pressed(KeyCode::Digit1) {
        send_targeted_skill(&bridge, &observer, &mut world_state, 1);
    }

    if keyboard.just_pressed(KeyCode::Digit2) {
        send_targeted_skill(&bridge, &observer, &mut world_state, 2);
    }

    if keyboard.just_pressed(KeyCode::Digit3) {
        send_targeted_skill(&bridge, &observer, &mut world_state, 3);
    }

    if keyboard.just_pressed(KeyCode::Digit4) {
        send_targeted_skill(&bridge, &observer, &mut world_state, 4);
    }
}

fn handle_target_selection_input(
    keyboard: Res<ButtonInput<KeyCode>>,
    mut world_state: ResMut<WorldState>,
    observer: Res<ClientObserver>,
) {
    if !keyboard.just_pressed(KeyCode::Tab) {
        return;
    }

    let mut cids = world_state
        .remote_actor_identity
        .keys()
        .copied()
        .collect::<Vec<_>>();
    cids.sort_unstable();

    if cids.is_empty() {
        world_state.selected_target_cid = None;
        return;
    }

    let next = match world_state.selected_target_cid {
        Some(current) => {
            let index = cids
                .iter()
                .position(|cid| *cid == current)
                .unwrap_or(usize::MAX);
            cids.get((index + 1) % cids.len()).copied()
        }
        None => cids.first().copied(),
    };

    world_state.selected_target_cid = next;
    world_state.selected_target_point = None;
    if let Some(cid) = next {
        observer.emit("input", "target_selected", &[("cid", cid.to_string())]);
    }
}

fn handle_point_target_input(
    mouse: Res<ButtonInput<MouseButton>>,
    keyboard: Res<ButtonInput<KeyCode>>,
    windows: Query<&Window, With<PrimaryWindow>>,
    camera: Single<(&Camera, &GlobalTransform), With<MainCamera>>,
    mut world_state: ResMut<WorldState>,
    observer: Res<ClientObserver>,
) {
    let target_modifier =
        keyboard.pressed(KeyCode::ShiftLeft) || keyboard.pressed(KeyCode::ShiftRight);
    if mouse.just_pressed(MouseButton::Right) && target_modifier {
        let Ok(window) = windows.single() else {
            return;
        };

        if let Some(cursor) = window.cursor_position() {
            let (camera, camera_transform) = *camera;
            let Some(render_point) = ray_from_viewport(camera, camera_transform, cursor)
                .and_then(|ray| ray_intersection_with_y_plane(ray.origin, ray.direction, 0.0))
            else {
                return;
            };
            let sim_point = render_to_sim_position(render_point);
            world_state.selected_target_point = Some(sim_point);
            world_state.selected_target_cid = None;
            observer.emit(
                "input",
                "target_point_selected",
                &[(
                    "point",
                    format!("{:.1},{:.1},{:.1}", sim_point.x, sim_point.y, sim_point.z),
                )],
            );
        }
    }
}

fn handle_voxel_input(params: VoxelInputParams) {
    let VoxelInputParams {
        mouse,
        keyboard,
        mut wheel_reader,
        chat_state,
        observer,
        selection_state,
        mut voxel_world,
        mut world_state,
    } = params;

    if chat_state.enabled {
        return;
    }

    for (key, index) in [
        (KeyCode::Digit1, 0),
        (KeyCode::Digit2, 1),
        (KeyCode::Digit3, 2),
        (KeyCode::Digit4, 3),
        (KeyCode::Digit5, 4),
        (KeyCode::Digit6, 5),
        (KeyCode::Digit7, 6),
    ] {
        if keyboard.just_pressed(key) && voxel_world.select_hotbar_index(index).is_ok() {
            observer.emit(
                "voxel",
                "hotbar_select",
                &[
                    ("index", (index + 1).to_string()),
                    ("selected", voxel_world.hotbar().selected.label),
                    ("source", "keyboard".to_string()),
                ],
            );
        }
    }

    let wheel_delta = wheel_reader.read().map(|event| event.y).sum::<f32>();
    let control_zoom =
        keyboard.pressed(KeyCode::ControlLeft) || keyboard.pressed(KeyCode::ControlRight);
    if wheel_delta.abs() > f32::EPSILON && !control_zoom {
        let len = voxel_world.hotbar().entries.len();
        let current = voxel_world.hotbar().selected_index;
        let next = if wheel_delta < 0.0 {
            (current + 1) % len
        } else {
            (current + len - 1) % len
        };
        let _ = voxel_world.select_hotbar_index(next);
        observer.emit(
            "voxel",
            "hotbar_select",
            &[
                ("index", (next + 1).to_string()),
                ("selected", voxel_world.hotbar().selected.label),
                ("source", "wheel".to_string()),
            ],
        );
    }

    let place_requested = keyboard.just_pressed(KeyCode::KeyF)
        || (mouse.just_pressed(MouseButton::Right)
            && !keyboard.pressed(KeyCode::ShiftLeft)
            && !keyboard.pressed(KeyCode::ShiftRight));
    let break_requested =
        keyboard.just_pressed(KeyCode::KeyG) || mouse.just_pressed(MouseButton::Left);
    if !place_requested && !break_requested {
        return;
    }

    let Some(selection) = selection_state.selection.clone() else {
        observer.emit(
            "voxel",
            "edit_rejected",
            &[("reason", "no_selection".to_string())],
        );
        return;
    };

    if break_requested {
        let coord = selection.occupied_macro;
        let ok = voxel_world.break_block(coord);
        observer.emit(
            "voxel",
            if ok { "break" } else { "break_rejected" },
            &[
                ("coord", crate::voxel::format_macro_coord(coord)),
                (
                    "face_normal",
                    crate::voxel::format_macro_coord(selection.face_normal),
                ),
                ("source", "center_ray".to_string()),
            ],
        );
        push_line(
            &mut world_state.logs,
            format!(
                "voxel break {} ok={ok}",
                crate::voxel::format_macro_coord(coord)
            ),
        );
    }

    if place_requested {
        let selected = voxel_world.hotbar().selected;
        let coord = selection.adjacent_macro;
        let (ok, label, event) = if let Some(material) = selected.material_id {
            (
                voxel_world.place_block(coord, NormalBlockData::new(material)),
                material.label().to_string(),
                "place",
            )
        } else if let Some(prefab_name) = selected.prefab_name {
            let request = BoundarySnapRequest {
                prefab_name: prefab_name.clone(),
                hit_macro: selection.occupied_macro,
                face_normal: selection.face_normal,
                rotation: selected.rotation,
            };
            let snap = voxel_world.place_prefab_boundary_snap(&request);
            let ok = if snap.ok {
                true
            } else {
                let reason = snap
                    .preview
                    .as_ref()
                    .and_then(|preview| preview.reject_reason.as_deref())
                    .unwrap_or("preview_unavailable");
                if should_fallback_to_macro_prefab_place(reason) {
                    voxel_world
                        .place_prefab(&prefab_name, coord, selected.rotation)
                        .ok
                } else {
                    false
                }
            };
            (ok, prefab_name, "prefab_place_snap")
        } else {
            (false, selected.label, "place")
        };
        observer.emit(
            "voxel",
            if ok { event } else { "place_rejected" },
            &[
                ("coord", crate::voxel::format_macro_coord(coord)),
                (
                    "hit_coord",
                    crate::voxel::format_macro_coord(selection.occupied_macro),
                ),
                (
                    "face_normal",
                    crate::voxel::format_macro_coord(selection.face_normal),
                ),
                ("selected", label.clone()),
                ("source", "center_ray".to_string()),
            ],
        );
        push_line(
            &mut world_state.logs,
            format!(
                "voxel place {} selected={} ok={ok}",
                crate::voxel::format_macro_coord(coord),
                label
            ),
        );
    }
}

fn send_targeted_skill(
    bridge: &NetworkBridge,
    observer: &ClientObserver,
    world_state: &mut WorldState,
    skill_id: u16,
) {
    let selected_target_point = world_state
        .selected_target_point
        .map(|point| [point.x as f64, point.y as f64, point.z as f64]);
    let visible_actor_count = world_state.remote_players.len();

    let dispatch = match prepare_skill_dispatch(
        skill_id,
        world_state.selected_target_cid,
        selected_target_point,
        visible_actor_count,
    ) {
        Ok(dispatch) => dispatch,
        Err(block) => {
            let message = format!("skill {skill_id} blocked: {}", block.reason);
            world_state.status = message.clone();
            push_line(&mut world_state.logs, format!("{message} ({})", block.hint));
            observer.emit(
                "input",
                "skill_blocked",
                &[
                    ("skill_id", skill_id.to_string()),
                    ("reason", block.reason.to_string()),
                    ("hint", block.hint.to_string()),
                ],
            );
            return;
        }
    };

    bridge.send(NetworkCommand::CastSkillTargeted {
        skill_id,
        target_cid: dispatch.target_cid,
        target_position: dispatch.target_position,
    });

    observer.emit(
        "input",
        "skill_key",
        &[
            ("skill_id", skill_id.to_string()),
            (
                "target_cid",
                dispatch
                    .target_cid
                    .map(|value: i64| value.to_string())
                    .unwrap_or_else(|| "auto".to_string()),
            ),
            (
                "target_point",
                dispatch
                    .target_position
                    .map(|value| format!("{:.1},{:.1},{:.1}", value[0], value[1], value[2]))
                    .unwrap_or_else(|| "n/a".to_string()),
            ),
        ],
    );
}

fn sample_movement_input(
    time: Res<Time>,
    keyboard: Res<ButtonInput<KeyCode>>,
    mut keyboard_input_reader: MessageReader<KeyboardInput>,
    chat_state: Res<ChatState>,
    observer: Res<ClientObserver>,
    mut input_trace: ResMut<InputTraceState>,
    mut movement_intent: ResMut<MovementIntent>,
) {
    if chat_state.enabled {
        movement_intent.direction = Vec2::ZERO;
        movement_intent.expires_at = 0.0;
        movement_intent.jump_requested = false;
        maybe_log_direction_change(&observer, &mut input_trace, movement_intent.direction);
        return;
    }

    if keyboard.just_pressed(KeyCode::Space) {
        movement_intent.jump_requested = true;
        observer.emit(
            "input",
            "jump_pressed",
            &[("source", "keyboard".to_string())],
        );
    }

    let direction = current_movement_direction(&keyboard);

    // `expires_at` belongs to stdio-driven timed moves. Keyboard intent must
    // track `ButtonInput::pressed()` exactly — extending a 250 ms latch on
    // every held frame would keep the unit sliding (and the predictor
    // rotating residual velocity toward the last direction) for frames
    // after every key release.
    if direction.length_squared() > 0.0 {
        movement_intent.direction = direction;
        movement_intent.expires_at = 0.0;
        maybe_log_direction_change(&observer, &mut input_trace, movement_intent.direction);
        return;
    }

    for keyboard_input in keyboard_input_reader.read() {
        if !keyboard_input.state.is_pressed() {
            continue;
        }

        let direction = movement_direction_from_key(&keyboard_input.logical_key);
        if direction.length_squared() > 0.0 {
            movement_intent.direction = direction;
            movement_intent.expires_at = 0.0;
            maybe_log_direction_change(&observer, &mut input_trace, movement_intent.direction);
            return;
        }
    }

    if time.elapsed_secs_f64() >= movement_intent.expires_at {
        movement_intent.direction = Vec2::ZERO;
    }

    maybe_log_direction_change(&observer, &mut input_trace, movement_intent.direction);
}

fn movement_sender(params: MovementSendParams) {
    let MovementSendParams {
        time,
        bridge,
        config,
        observer,
        world_state,
        mut movement_intent,
        mut movement_dispatch,
        mut tick,
    } = params;

    if !world_state.scene_joined {
        return;
    }

    if !tick.0.tick(time.delta()).just_finished() {
        return;
    }

    let direction = movement_intent.direction;
    let jump_requested = movement_intent.jump_requested;
    let movement_flags = movement_flags_for_intent(direction, jump_requested);

    let should_send_stop_sync = should_send_stop_sync(
        direction,
        world_state.local_velocity,
        movement_dispatch.stop_sent,
    );

    if direction.length_squared() == 0.0 && !should_send_stop_sync && !jump_requested {
        return;
    }

    bridge.send(NetworkCommand::MoveInputSample {
        input_dir: [direction.x, direction.y],
        dt_ms: config.movement_interval_ms as u16,
        speed_scale: 1.0,
        movement_flags,
    });

    observer.emit(
        "input",
        "movement_sample_queued",
        &[
            (
                "direction",
                format!("{:.2},{:.2}", direction.x, direction.y),
            ),
            ("movement_flags", movement_flags.to_string()),
            ("dt_ms", config.movement_interval_ms.to_string()),
            ("should_send_stop_sync", should_send_stop_sync.to_string()),
            (
                "local_position",
                world_state
                    .local_position
                    .map(|value| format!("{:.1},{:.1},{:.1}", value.x, value.y, value.z))
                    .unwrap_or_else(|| "n/a".to_string()),
            ),
            (
                "local_velocity",
                format!(
                    "{:.1},{:.1},{:.1}",
                    world_state.local_velocity.x,
                    world_state.local_velocity.y,
                    world_state.local_velocity.z
                ),
            ),
        ],
    );

    movement_intent.jump_requested = false;
    movement_dispatch.stop_sent = direction.length_squared() == 0.0
        && world_state.local_velocity.length() <= FINAL_STOP_SYNC_SPEED_EPSILON;
}

fn poll_stdio_commands(params: StdioCommandParams) {
    let StdioCommandParams {
        time,
        stdio,
        bridge,
        local_render_prediction,
        mut voxel_world,
        mut world_state,
        mut movement_intent,
        mut app_exit,
    } = params;

    loop {
        let Some(command) = stdio.try_recv() else {
            break;
        };

        match command {
            ClientStdioCommand::Snapshot => {
                let mut fields = snapshot_fields(SnapshotFields {
                    status: &world_state.status,
                    scene_joined: world_state.scene_joined,
                    local_cid: world_state.local_cid,
                    local_position: world_state.local_position,
                    local_hp: world_state.local_hp,
                    local_max_hp: world_state.local_max_hp,
                    local_alive: world_state.local_alive,
                    movement_transport: world_state.movement_transport.label(),
                    fast_lane_status: &world_state.fast_lane_status,
                    remote_player_count: world_state
                        .remote_actor_identity
                        .values()
                        .filter(|identity| matches!(identity.kind, RemoteActorKind::Player))
                        .count(),
                    remote_npc_count: world_state
                        .remote_actor_identity
                        .values()
                        .filter(|identity| identity.is_npc())
                        .count(),
                });
                fields.push(("voxel_sync", "offline-local".to_string()));
                fields.push((
                    "voxel_solid_cells",
                    voxel_world.total_solid_cells().to_string(),
                ));
                fields.push((
                    "voxel_hotbar",
                    (voxel_world.hotbar().selected_index + 1).to_string(),
                ));
                fields.push(("voxel_selected", voxel_world.hotbar().selected.label));
                emit_stdio("snapshot", &fields);
            }
            ClientStdioCommand::Position => {
                emit_stdio(
                    "position",
                    &[(
                        "local_position",
                        world_state
                            .local_position
                            .map(|value| format!("{:.1},{:.1},{:.1}", value.x, value.y, value.z))
                            .unwrap_or_else(|| "n/a".to_string()),
                    )],
                );
            }
            ClientStdioCommand::Transport => {
                emit_stdio(
                    "transport",
                    &[
                        (
                            "control_transport",
                            world_state.control_transport.label().to_string(),
                        ),
                        (
                            "movement_transport",
                            world_state.movement_transport.label().to_string(),
                        ),
                        ("fast_lane_status", world_state.fast_lane_status.clone()),
                    ],
                );
            }
            ClientStdioCommand::Players => {
                let now_secs = time.elapsed_secs_f64();
                let mut players = world_state
                    .remote_players
                    .iter()
                    .filter_map(|(cid, player)| {
                        let identity = world_state.remote_actor_identity.get(cid);
                        if matches!(identity.map(|value| value.kind), Some(RemoteActorKind::Npc)) {
                            return None;
                        }
                        let position = player.sample_motion(now_secs).position;
                        Some(format!(
                            "{cid}:{:.1},{:.1},{:.1}",
                            position.x, position.y, position.z
                        ))
                    })
                    .collect::<Vec<_>>();
                players.sort();
                emit_stdio(
                    "players",
                    &[("players", format!("[{}]", players.join(";")))],
                );
            }
            ClientStdioCommand::Npcs => {
                let now_secs = time.elapsed_secs_f64();
                let mut npcs = world_state
                    .remote_players
                    .iter()
                    .filter_map(|(cid, player)| {
                        let identity = world_state.remote_actor_identity.get(cid)?;
                        if !identity.is_npc() {
                            return None;
                        }

                        let position = player.sample_motion(now_secs).position;
                        Some(format!(
                            "{cid}:{}:{:.1},{:.1},{:.1}",
                            identity.name, position.x, position.y, position.z
                        ))
                    })
                    .collect::<Vec<_>>();
                npcs.sort();
                emit_stdio("npcs", &[("npcs", format!("[{}]", npcs.join(";")))]);
            }
            ClientStdioCommand::Target(target_cid) => {
                world_state.selected_target_cid = Some(target_cid);
                world_state.selected_target_point = None;
                emit_stdio("target", &[("target_cid", target_cid.to_string())]);
            }
            ClientStdioCommand::ClearTarget => {
                world_state.selected_target_cid = None;
                emit_stdio("target_cleared", &[]);
            }
            ClientStdioCommand::TargetPoint(point) => {
                world_state.selected_target_point = Some(point);
                world_state.selected_target_cid = None;
                emit_stdio(
                    "target_point",
                    &[(
                        "point",
                        format!("{:.1},{:.1},{:.1}", point.x, point.y, point.z),
                    )],
                );
            }
            ClientStdioCommand::ClearTargetPoint => {
                world_state.selected_target_point = None;
                emit_stdio("target_point_cleared", &[]);
            }
            ClientStdioCommand::Chat(text) => {
                bridge.send(NetworkCommand::Chat(text.clone()));
                emit_stdio("chat_sent", &[("text", text)]);
            }
            ClientStdioCommand::Skill {
                skill_id,
                target_cid,
            } => {
                let selected_target_point = world_state
                    .selected_target_point
                    .map(|point| [point.x as f64, point.y as f64, point.z as f64]);
                let visible_actor_count = world_state.remote_players.len();
                let dispatch = match prepare_skill_dispatch(
                    skill_id,
                    target_cid.or(world_state.selected_target_cid),
                    selected_target_point,
                    visible_actor_count,
                ) {
                    Ok(dispatch) => dispatch,
                    Err(block) => {
                        let message = format!("skill {skill_id} blocked: {}", block.reason);
                        world_state.status = message.clone();
                        push_line(&mut world_state.logs, format!("{message} ({})", block.hint));
                        emit_stdio(
                            "skill_blocked",
                            &[
                                ("skill_id", skill_id.to_string()),
                                ("reason", block.reason.to_string()),
                                ("hint", block.hint.to_string()),
                            ],
                        );
                        continue;
                    }
                };
                bridge.send(NetworkCommand::CastSkillTargeted {
                    skill_id,
                    target_cid: dispatch.target_cid,
                    target_position: dispatch.target_position,
                });
                emit_stdio(
                    "skill_sent",
                    &[
                        ("skill_id", skill_id.to_string()),
                        (
                            "target_cid",
                            dispatch
                                .target_cid
                                .map(|value| value.to_string())
                                .unwrap_or_else(|| "auto".to_string()),
                        ),
                        (
                            "target_point",
                            dispatch
                                .target_position
                                .map(|value| {
                                    format!("{:.1},{:.1},{:.1}", value[0], value[1], value[2])
                                })
                                .unwrap_or_else(|| "n/a".to_string()),
                        ),
                    ],
                );
            }
            ClientStdioCommand::Move {
                direction,
                direction_label,
                duration_ms,
            } => {
                movement_intent.direction = direction;
                movement_intent.expires_at = time.elapsed_secs_f64() + duration_ms as f64 / 1_000.0;
                emit_stdio(
                    "move_queued",
                    &[
                        ("direction", direction_label),
                        ("duration_ms", duration_ms.to_string()),
                    ],
                );
            }
            ClientStdioCommand::Stop => {
                movement_intent.direction = Vec2::ZERO;
                movement_intent.expires_at = 0.0;
                emit_stdio("stop", &[]);
            }
            ClientStdioCommand::Jump => {
                movement_intent.jump_requested = true;
                emit_stdio("jump", &[("queued", "true".to_string())]);
            }
            ClientStdioCommand::ReconcileStats => {
                bridge.send(NetworkCommand::RequestReconcileStats);
                emit_stdio("reconcile_stats_requested", &[]);
            }
            ClientStdioCommand::DiagRender => {
                let anchor_position = local_render_prediction
                    .anchor_state
                    .as_ref()
                    .map(|state| state.position);
                let render_position = local_render_prediction
                    .render_state
                    .as_ref()
                    .map(|state| state.position);
                emit_stdio(
                    "diag_render",
                    &[
                        (
                            "anchor",
                            anchor_position
                                .map(|value| {
                                    format!("{:.2},{:.2},{:.2}", value.x, value.y, value.z)
                                })
                                .unwrap_or_else(|| "n/a".to_string()),
                        ),
                        (
                            "render",
                            render_position
                                .map(|value| {
                                    format!("{:.2},{:.2},{:.2}", value.x, value.y, value.z)
                                })
                                .unwrap_or_else(|| "n/a".to_string()),
                        ),
                        (
                            "pending_correction",
                            format!(
                                "{:.3},{:.3},{:.3}",
                                local_render_prediction.pending_correction.x,
                                local_render_prediction.pending_correction.y,
                                local_render_prediction.pending_correction.z
                            ),
                        ),
                        (
                            "pending_correction_distance",
                            format!(
                                "{:.3}",
                                local_render_prediction.pending_correction_distance()
                            ),
                        ),
                        (
                            "drift",
                            format!(
                                "{:.3}",
                                local_render_prediction.pending_correction_distance()
                            ),
                        ),
                        (
                            "smoothing_rate_hz",
                            format!("{:.1}", local_render_prediction.smoothing_rate_hz),
                        ),
                        (
                            "partial_elapsed_secs",
                            format!("{:.4}", local_render_prediction.partial_elapsed_secs),
                        ),
                    ],
                );
            }
            ClientStdioCommand::Voxel(command) => {
                let result =
                    execute_voxel_cli_command(&mut voxel_world, command, Some(&voxel_save_dir()));
                emit_stdio_owned(&result.event, result.ok, &result.fields);
            }
            ClientStdioCommand::Quit => {
                bridge.send(NetworkCommand::Shutdown);
                emit_stdio("quit", &[("final_status", world_state.status.clone())]);
                app_exit.write(AppExit::Success);
            }
        }
    }
}

fn current_movement_direction(keyboard: &ButtonInput<KeyCode>) -> Vec2 {
    let mut direction = Vec2::ZERO;

    if keyboard.pressed(KeyCode::KeyW) || keyboard.pressed(KeyCode::ArrowUp) {
        direction.y += 1.0;
    }
    if keyboard.pressed(KeyCode::KeyS) || keyboard.pressed(KeyCode::ArrowDown) {
        direction.y -= 1.0;
    }
    if keyboard.pressed(KeyCode::KeyA) || keyboard.pressed(KeyCode::ArrowLeft) {
        direction.x -= 1.0;
    }
    if keyboard.pressed(KeyCode::KeyD) || keyboard.pressed(KeyCode::ArrowRight) {
        direction.x += 1.0;
    }

    direction
}

fn movement_direction_from_key(key: &Key) -> Vec2 {
    match key {
        Key::Character(value) if value.eq_ignore_ascii_case("w") => Vec2::new(0.0, 1.0),
        Key::Character(value) if value.eq_ignore_ascii_case("s") => Vec2::new(0.0, -1.0),
        Key::Character(value) if value.eq_ignore_ascii_case("a") => Vec2::new(-1.0, 0.0),
        Key::Character(value) if value.eq_ignore_ascii_case("d") => Vec2::new(1.0, 0.0),
        Key::ArrowUp => Vec2::new(0.0, 1.0),
        Key::ArrowDown => Vec2::new(0.0, -1.0),
        Key::ArrowLeft => Vec2::new(-1.0, 0.0),
        Key::ArrowRight => Vec2::new(1.0, 0.0),
        _ => Vec2::ZERO,
    }
}

fn sync_voxel_visuals(
    mut commands: Commands,
    voxel_world: Res<VoxelWorld>,
    assets: Res<SceneRenderAssets>,
    mut existing: Query<(
        Entity,
        &VoxelCellVisual,
        &mut Transform,
        &mut MeshMaterial3d<StandardMaterial>,
    )>,
) {
    let desired = voxel_world
        .render_cells_3d()
        .into_iter()
        .map(|cell| ((cell.macro_coord, cell.micro), cell))
        .collect::<HashMap<_, _>>();

    let mut remaining = desired.clone();
    for (entity, visual, mut transform, mut material) in &mut existing {
        let key = (visual.macro_coord, visual.micro);
        if let Some(cell) = desired.get(&key) {
            transform.translation = voxel_render_translation(*cell);
            transform.scale = voxel_render_scale(*cell);
            *material = MeshMaterial3d(voxel_material_handle(
                &assets,
                cell.material_id,
                cell.refined,
            ));
            remaining.remove(&key);
        } else {
            commands.entity(entity).despawn();
        }
    }

    for cell in remaining.values().copied() {
        commands.spawn((
            VoxelCellVisual {
                macro_coord: cell.macro_coord,
                micro: cell.micro,
            },
            Mesh3d(assets.cube_mesh.clone()),
            MeshMaterial3d(voxel_material_handle(
                &assets,
                cell.material_id,
                cell.refined,
            )),
            Transform::from_translation(voxel_render_translation(cell))
                .with_scale(voxel_render_scale(cell)),
        ));
    }
}

fn sync_player_visuals(mut commands: Commands, mut params: PlayerVisualParams) {
    let mut entities_by_cid = HashMap::new();
    for (entity, visual, _transform, _material) in &params.existing {
        entities_by_cid.insert(visual.cid, entity);
    }

    let now_secs = params.time.elapsed_secs_f64();
    let mut desired = params
        .world_state
        .remote_players
        .iter()
        .map(|(&cid, state)| (cid, state.sample_motion(now_secs)))
        .collect::<HashMap<_, _>>();
    if let Some(local) = params
        .local_render_prediction
        .render_state
        .as_ref()
        .map(|state| RemoteMotionSample {
            position: state.position,
            velocity: state.velocity,
        })
        .or_else(|| {
            params
                .world_state
                .local_position
                .map(|local| RemoteMotionSample {
                    position: local,
                    velocity: params.world_state.local_velocity,
                })
        })
    {
        desired.insert(params.world_state.local_cid, local);
    }

    for (&cid, motion) in &desired {
        let target = actor_render_position(&params.voxel_world, motion.position);
        let animation =
            animation_state_from_velocity(motion.velocity, params.config.movement_speed);
        let actor_kind = params
            .world_state
            .remote_actor_identity
            .get(&cid)
            .map(|identity| identity.kind)
            .unwrap_or(RemoteActorKind::Player);
        let selected = params.world_state.selected_target_cid == Some(cid);
        let local = cid == params.world_state.local_cid;
        let material = actor_material_handle(
            &params.assets,
            local,
            selected,
            actor_kind,
            animation.moving,
        );

        if let Some(entity) = entities_by_cid.remove(&cid) {
            if let Ok((_entity, _visual, mut transform, mut existing_material)) =
                params.existing.get_mut(entity)
            {
                transform.translation = if local {
                    target
                } else {
                    smooth_translation(
                        transform.translation,
                        target,
                        params.time.delta_secs(),
                        VISUAL_SMOOTHING_SPEED,
                        VISUAL_SNAP_DISTANCE,
                    )
                };
                transform.scale =
                    animated_scale(transform.scale, animation, params.time.delta_secs());
                *existing_material = MeshMaterial3d(material);
            }
        } else {
            let scale = if matches!(actor_kind, RemoteActorKind::Npc) {
                Vec3::new(30.0, 28.0, 24.0)
            } else {
                Vec3::new(24.0, 36.0, 24.0)
            };

            commands.spawn((
                PlayerVisual { cid },
                Mesh3d(params.assets.player_mesh.clone()),
                MeshMaterial3d(material),
                Transform::from_translation(target).with_scale(
                    scale * animated_scale(Vec3::ONE, animation, params.time.delta_secs()),
                ),
            ));
        }
    }

    for (cid, entity) in entities_by_cid {
        if cid != params.world_state.local_cid {
            commands.entity(entity).despawn();
        }
    }
}

fn update_effect_visuals(
    mut commands: Commands,
    time: Res<Time>,
    mut effects: Query<(Entity, &mut Transform, &mut EffectVisual)>,
) {
    for (entity, mut transform, mut effect) in &mut effects {
        effect.timer.tick(time.delta());
        let progress = effect.timer.fraction();
        let translation =
            effect_interpolated_translation(effect.kind, effect.origin, effect.target, progress);
        transform.translation = sim_to_render_position(translation) + Vec3::Y * 10.0;

        if effect.timer.is_finished() {
            commands.entity(entity).despawn();
        }
    }
}

fn update_target_point_marker(
    world_state: Res<WorldState>,
    mut marker: Single<(&mut Transform, &mut Visibility), With<TargetPointMarker>>,
) {
    if let Some(point) = world_state.selected_target_point {
        *marker.1 = Visibility::Visible;
        marker.0.translation = sim_to_render_position(point) + Vec3::Y * 6.0;
    } else {
        *marker.1 = Visibility::Hidden;
    }
}

fn update_hud_text(
    world_state: Res<WorldState>,
    chat_state: Res<ChatState>,
    voxel_world: Res<VoxelWorld>,
    selection_state: Res<VoxelSelectionState>,
    mut texts: HudTextParams,
) {
    let selected_target = world_state
        .selected_target_cid
        .and_then(|cid| world_state.remote_actor_identity.get(&cid))
        .map(|identity| format!("{} ({cid})", identity.name, cid = identity.cid))
        .unwrap_or_else(|| "none".to_string());
    let selected_point = world_state
        .selected_target_point
        .map(|value| format!("{:.1}, {:.1}, {:.1}", value.x, value.y, value.z))
        .unwrap_or_else(|| "none".to_string());
    let voxel_selection = selection_state
        .selection
        .as_ref()
        .map(|selection| {
            format!(
                "hit={} adjacent={} normal={}",
                crate::voxel::format_macro_coord(selection.occupied_macro),
                crate::voxel::format_macro_coord(selection.adjacent_macro),
                crate::voxel::format_macro_coord(selection.face_normal)
            )
        })
        .unwrap_or_else(|| "none".to_string());

    texts.hud.0 = format!(
        "status: {}\ndemo: control={} | movement={} | fast-lane={}\nudp endpoint: {}\nAOI peers: {} (npcs: {})\nselected target: {}\nselected point: {}\nvoxel hotbar: {} ({})\nvoxel selection: {}\nlocal cid: {}\nposition: {}\nhp: {}/{} alive={}\nlast move ack: {}\nlast AOI move: {}\nrtt: {}\noffset: {}\nheartbeat: {}\ncontrols: WASD/Space move | drag LMB/MMB orbit | Ctrl+wheel zoom | center ray LMB/G break | RMB/F place | wheel/1-7 hotbar | Shift+1-4 skills | Shift+RMB target | Enter chat",
        world_state.status,
        world_state.control_transport.label(),
        world_state.movement_transport.label(),
        world_state.fast_lane_status,
        world_state
            .udp_endpoint
            .clone()
            .unwrap_or_else(|| "n/a".to_string()),
        world_state.remote_players.len(),
        world_state
            .remote_actor_identity
            .values()
            .filter(|identity| identity.is_npc())
            .count(),
        selected_target,
        selected_point,
        voxel_world.hotbar().selected.label,
        voxel_world.hotbar().selected_index + 1,
        voxel_selection,
        world_state.local_cid,
        world_state
            .local_position
            .map(|pos| format!("{:.1}, {:.1}, {:.1}", pos.x, pos.y, pos.z))
            .unwrap_or_else(|| "n/a".to_string()),
        world_state.local_hp,
        world_state.local_max_hp,
        world_state.local_alive,
        world_state
            .last_local_update_transport
            .map(|transport| transport.label().to_string())
            .unwrap_or_else(|| "n/a".to_string()),
        world_state
            .last_remote_move_transport
            .map(|transport| transport.label().to_string())
            .unwrap_or_else(|| "n/a".to_string()),
        world_state
            .last_rtt_ms
            .map(|value| format!("{value:.1} ms"))
            .unwrap_or_else(|| "n/a".to_string()),
        world_state
            .last_offset_ms
            .map(|value| format!("{value:.1} ms"))
            .unwrap_or_else(|| "n/a".to_string()),
        world_state
            .last_heartbeat_ts
            .map(|value| value.to_string())
            .unwrap_or_else(|| "n/a".to_string()),
    );

    let recent_chat = world_state
        .chat_log
        .iter()
        .rev()
        .take(5)
        .cloned()
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<Vec<_>>();
    let recent_logs = world_state
        .logs
        .iter()
        .rev()
        .take(4)
        .cloned()
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<Vec<_>>();

    let mut sections = Vec::new();
    if !recent_chat.is_empty() {
        sections.push(format!("chat\n{}", recent_chat.join("\n")));
    }
    if !recent_logs.is_empty() {
        sections.push(format!("transport/demo\n{}", recent_logs.join("\n")));
    }
    texts.chat_log_text.0 = sections.join("\n\n");

    texts.chat_input_text.0 = if chat_state.enabled {
        format!("> {}_", chat_state.draft)
    } else {
        String::new()
    };
}

fn push_line(buffer: &mut VecDeque<String>, line: String) {
    if buffer.len() >= 10 {
        buffer.pop_front();
    }
    buffer.push_back(line);
}

fn net_to_world(value: [f64; 3]) -> Vec3 {
    Vec3::new(value[0] as f32, value[1] as f32, value[2] as f32)
}

fn sim_to_render_position(position: Vec3) -> Vec3 {
    Vec3::new(position.x, position.z, position.y)
}

fn render_to_sim_position(position: Vec3) -> Vec3 {
    Vec3::new(position.x, position.z, position.y)
}

fn camera_transform_from_orbit(state: &OrbitCameraState) -> Transform {
    let horizontal = state.distance * state.pitch.cos();
    let offset = Vec3::new(
        horizontal * state.yaw.sin(),
        state.distance * state.pitch.sin(),
        horizontal * state.yaw.cos(),
    );
    Transform::from_translation(state.target + offset).looking_at(state.target, Vec3::Y)
}

fn ray_from_viewport(
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

fn ray_intersection_with_y_plane(origin: Vec3, direction: Vec3, y: f32) -> Option<Vec3> {
    if direction.y.abs() <= f32::EPSILON {
        return None;
    }
    let distance = (y - origin.y) / direction.y;
    (distance >= 0.0).then_some(origin + direction * distance)
}

fn voxel_render_translation(cell: VoxelRenderCell) -> Vec3 {
    let mut x = cell.macro_coord.x as f32 * VOXEL_RENDER_CELL_SIZE + VOXEL_RENDER_CELL_SIZE * 0.5;
    let mut y = cell.macro_coord.y as f32 * VOXEL_RENDER_CELL_SIZE + VOXEL_RENDER_CELL_SIZE * 0.5;
    let mut z = cell.macro_coord.z as f32 * VOXEL_RENDER_CELL_SIZE + VOXEL_RENDER_CELL_SIZE * 0.5;
    if let Some(micro) = cell.micro {
        x = cell.macro_coord.x as f32 * VOXEL_RENDER_CELL_SIZE
            + (micro.x as f32 + 0.5) * VOXEL_RENDER_MICRO_SIZE;
        y = cell.macro_coord.y as f32 * VOXEL_RENDER_CELL_SIZE
            + (micro.y as f32 + 0.5) * VOXEL_RENDER_MICRO_SIZE;
        z = cell.macro_coord.z as f32 * VOXEL_RENDER_CELL_SIZE
            + (micro.z as f32 + 0.5) * VOXEL_RENDER_MICRO_SIZE;
    }
    Vec3::new(x, y, z)
}

fn voxel_render_scale(cell: VoxelRenderCell) -> Vec3 {
    let size = if cell.refined {
        VOXEL_RENDER_MICRO_SIZE * 0.95
    } else {
        VOXEL_RENDER_CELL_SIZE * 0.96
    };
    Vec3::splat(size)
}

fn voxel_material_color(material_id: VoxelMaterialId, refined: bool) -> Color {
    let color = match material_id {
        VoxelMaterialId::Dirt => Color::srgb(0.45, 0.34, 0.22),
        VoxelMaterialId::Stone => Color::srgb(0.48, 0.52, 0.56),
        VoxelMaterialId::Wood => Color::srgb(0.64, 0.42, 0.22),
        VoxelMaterialId::Ice => Color::srgb(0.52, 0.82, 0.95),
    };
    if refined {
        color.with_alpha(0.82)
    } else {
        color
    }
}

fn transparent_material(color: Color) -> StandardMaterial {
    StandardMaterial {
        base_color: color,
        alpha_mode: AlphaMode::Blend,
        perceptual_roughness: 0.88,
        ..default()
    }
}

fn voxel_material_handle(
    assets: &SceneRenderAssets,
    material_id: VoxelMaterialId,
    refined: bool,
) -> Handle<StandardMaterial> {
    match (material_id, refined) {
        (VoxelMaterialId::Dirt, false) => assets.dirt_material.clone(),
        (VoxelMaterialId::Stone, false) => assets.stone_material.clone(),
        (VoxelMaterialId::Wood, false) => assets.wood_material.clone(),
        (VoxelMaterialId::Ice, false) => assets.ice_material.clone(),
        (VoxelMaterialId::Dirt, true) => assets.dirt_refined_material.clone(),
        (VoxelMaterialId::Stone, true) => assets.stone_refined_material.clone(),
        (VoxelMaterialId::Wood, true) => assets.wood_refined_material.clone(),
        (VoxelMaterialId::Ice, true) => assets.ice_refined_material.clone(),
    }
}

fn actor_material_handle(
    assets: &SceneRenderAssets,
    local: bool,
    selected: bool,
    actor_kind: RemoteActorKind,
    moving: bool,
) -> Handle<StandardMaterial> {
    if local {
        assets.local_player_material.clone()
    } else if selected {
        assets.selected_actor_material.clone()
    } else if matches!(actor_kind, RemoteActorKind::Npc) {
        assets.npc_material.clone()
    } else if moving {
        assets.moving_player_material.clone()
    } else {
        assets.remote_player_material.clone()
    }
}

fn should_fallback_to_macro_prefab_place(reason: &str) -> bool {
    matches!(reason, "no_target_boundary" | "no_contact" | "empty_prefab")
}

fn update_orbit_camera(mut params: OrbitCameraParams) {
    if !params.chat_state.enabled {
        let rotating =
            params.mouse.pressed(MouseButton::Left) || params.mouse.pressed(MouseButton::Middle);
        if rotating {
            let delta = params
                .motion_reader
                .read()
                .fold(Vec2::ZERO, |acc, event| acc + event.delta);
            params.orbit.yaw -= delta.x * CAMERA_YAW_SENSITIVITY;
            params.orbit.pitch = (params.orbit.pitch + delta.y * CAMERA_PITCH_SENSITIVITY)
                .clamp(CAMERA_MIN_PITCH, CAMERA_MAX_PITCH);
        } else {
            params.motion_reader.clear();
        }

        let control_zoom = params.keyboard.pressed(KeyCode::ControlLeft)
            || params.keyboard.pressed(KeyCode::ControlRight);
        let wheel_delta = params.wheel_reader.read().map(|event| event.y).sum::<f32>();
        if control_zoom && wheel_delta.abs() > f32::EPSILON {
            params.orbit.distance = (params.orbit.distance - wheel_delta * 28.0)
                .clamp(CAMERA_MIN_DISTANCE, CAMERA_MAX_DISTANCE);
        }
    } else {
        params.motion_reader.clear();
        params.wheel_reader.clear();
    }

    let desired_target = params
        .local_render_prediction
        .render_state
        .as_ref()
        .map(|state| actor_render_position(&params.voxel_world, state.position))
        .or_else(|| {
            params
                .world_state
                .local_position
                .map(|position| actor_render_position(&params.voxel_world, position))
        })
        .map(|position| position + Vec3::Y * CAMERA_LOOK_HEIGHT)
        .unwrap_or(params.orbit.target);

    let target = smooth_translation(
        params.orbit.target,
        desired_target,
        params.time.delta_secs(),
        8.0,
        300.0,
    );
    params.orbit.target = target;
    **params.camera = camera_transform_from_orbit(&params.orbit);
}

fn update_voxel_selection(
    windows: Query<&Window, With<PrimaryWindow>>,
    camera: Single<(&Camera, &GlobalTransform), With<MainCamera>>,
    voxel_world: Res<VoxelWorld>,
    mut selection_state: ResMut<VoxelSelectionState>,
) {
    let Ok(window) = windows.single() else {
        selection_state.selection = None;
        return;
    };
    let center = Vec2::new(window.width() * 0.5, window.height() * 0.5);
    let (camera, camera_transform) = *camera;
    selection_state.selection = ray_from_viewport(camera, camera_transform, center)
        .and_then(|ray| find_voxel_selection_from_ray(&voxel_world, ray.origin, ray.direction));
}

fn draw_voxel_guides(
    voxel_world: Res<VoxelWorld>,
    selection_state: Res<VoxelSelectionState>,
    mut gizmos: Gizmos,
) {
    let grid_extent = VOXEL_RENDER_CELL_SIZE * 24.0;
    let grid_color = Color::srgba(0.32, 0.38, 0.44, 0.36);
    for index in -12..=12 {
        let offset = index as f32 * VOXEL_RENDER_CELL_SIZE;
        gizmos.line(
            Vec3::new(-grid_extent, 0.0, offset),
            Vec3::new(grid_extent, 0.0, offset),
            grid_color,
        );
        gizmos.line(
            Vec3::new(offset, 0.0, -grid_extent),
            Vec3::new(offset, 0.0, grid_extent),
            grid_color,
        );
    }

    let Some(selection) = selection_state.selection.as_ref() else {
        return;
    };

    let (hit_min, hit_max) = selection_bounds(selection);
    draw_face_outline(
        &mut gizmos,
        hit_min,
        hit_max,
        selection.face_normal,
        Color::srgb(1.0, 0.95, 0.35),
    );

    let selected = voxel_world.hotbar().selected;
    if selected.material_id.is_some() {
        let (min, max) = macro_bounds(selection.adjacent_macro);
        draw_box_wire(&mut gizmos, min, max, Color::srgba(0.35, 1.0, 0.55, 0.72));
        return;
    }

    if let Some(prefab_name) = selected.prefab_name {
        let request = BoundarySnapRequest {
            prefab_name,
            hit_macro: selection.occupied_macro,
            face_normal: selection.face_normal,
            rotation: selected.rotation,
        };
        let preview = voxel_world.preview_prefab_boundary_snap(&request);
        if preview.ok {
            draw_prefab_preview(&mut gizmos, &preview, Color::srgba(0.45, 0.9, 1.0, 0.7));
        } else if preview
            .reject_reason
            .as_deref()
            .is_some_and(should_fallback_to_macro_prefab_place)
        {
            let (min, max) = macro_bounds(selection.adjacent_macro);
            draw_box_wire(&mut gizmos, min, max, Color::srgba(0.45, 0.9, 1.0, 0.5));
        }
    }
}

fn draw_effect_gizmos(effects: Query<&EffectVisual>, mut gizmos: Gizmos) {
    for effect in &effects {
        let progress = effect.timer.fraction();
        let color = effect_runtime_color(effect.kind, progress);
        let origin = sim_to_render_position(effect.origin) + Vec3::Y * 18.0;
        let target = sim_to_render_position(effect.target) + Vec3::Y * 18.0;
        let current = sim_to_render_position(effect_interpolated_translation(
            effect.kind,
            effect.origin,
            effect.target,
            progress,
        )) + Vec3::Y * 18.0;

        match effect.kind {
            EffectCueKind::Projectile => {
                gizmos.line(origin, current, color);
                gizmos.sphere(current, 8.0, color);
            }
            EffectCueKind::MeleeArc | EffectCueKind::ChainArc => {
                gizmos.line(origin, target, color);
                gizmos.sphere(current, 5.0, color);
            }
            EffectCueKind::AoeRing => {
                gizmos.circle(
                    Isometry3d::new(target, Quat::from_rotation_arc(Vec3::Z, Vec3::Y)),
                    effect.radius.max(24.0),
                    color,
                );
            }
            EffectCueKind::ImpactPulse | EffectCueKind::Unknown(_) => {
                gizmos.sphere(current, 10.0 + progress * 22.0, color);
            }
        }
    }
}

fn actor_render_position(voxel_world: &VoxelWorld, sim_position: Vec3) -> Vec3 {
    let render = sim_to_render_position(sim_position);
    let grounded_y =
        surface_center_y_at_render_xz(voxel_world, render.x, render.z, ACTOR_HALF_HEIGHT, render.y);
    Vec3::new(render.x, grounded_y, render.z)
}

fn surface_center_y_at_render_xz(
    voxel_world: &VoxelWorld,
    render_x: f32,
    render_z: f32,
    half_height: f32,
    fallback_y: f32,
) -> f32 {
    let mut top_y = None::<f32>;
    for cell in voxel_world.render_cells_3d() {
        let (min, max) = voxel_cell_bounds(cell);
        if render_x >= min.x && render_x <= max.x && render_z >= min.z && render_z <= max.z {
            top_y = Some(top_y.map_or(max.y, |current| current.max(max.y)));
        }
    }
    top_y
        .map(|top| top + half_height)
        .unwrap_or(fallback_y)
        .max(fallback_y)
}

fn find_voxel_selection_from_ray(
    voxel_world: &VoxelWorld,
    origin: Vec3,
    direction: Vec3,
) -> Option<VoxelRaySelection> {
    let direction = direction.try_normalize()?;
    let mut best = None::<(f32, VoxelRenderCell, MacroCoord, Vec3)>;

    for cell in voxel_world.render_cells_3d() {
        let (min, max) = voxel_cell_bounds(cell);
        if let Some((distance, face_normal)) =
            ray_intersect_aabb(origin, direction, min, max, VOXEL_RAY_MAX_DISTANCE)
            && best
                .as_ref()
                .is_none_or(|(best_distance, _, _, _)| distance < *best_distance)
        {
            best = Some((distance, cell, face_normal, origin + direction * distance));
        }
    }

    let (_distance, cell, face_normal, hit_point) = best?;
    let adjacent_macro = MacroCoord::new(
        cell.macro_coord.x + face_normal.x,
        cell.macro_coord.y + face_normal.y,
        cell.macro_coord.z + face_normal.z,
    );
    let occupied_micro = match cell.micro {
        Some(micro) => Some(MicroCellTarget {
            macro_coord: cell.macro_coord,
            micro,
        }),
        None => micro_target_from_render_point(hit_point - macro_coord_to_vec3(face_normal) * 0.01),
    };
    let adjacent_micro =
        micro_target_from_render_point(hit_point + macro_coord_to_vec3(face_normal) * 0.01);

    Some(VoxelRaySelection {
        occupied_macro: cell.macro_coord,
        adjacent_macro,
        face_normal,
        occupied_micro,
        adjacent_micro,
    })
}

fn ray_intersect_aabb(
    origin: Vec3,
    direction: Vec3,
    min: Vec3,
    max: Vec3,
    max_distance: f32,
) -> Option<(f32, MacroCoord)> {
    let mut t_min = 0.0_f32;
    let mut t_max = max_distance;
    let mut normal = MacroCoord::new(0, 0, 0);

    for axis in 0..3 {
        let origin_axis = origin[axis];
        let direction_axis = direction[axis];
        let min_axis = min[axis];
        let max_axis = max[axis];

        if direction_axis.abs() <= f32::EPSILON {
            if origin_axis < min_axis || origin_axis > max_axis {
                return None;
            }
            continue;
        }

        let (near_plane, far_plane, near_normal, _far_normal) = if direction_axis > 0.0 {
            (
                min_axis,
                max_axis,
                negative_axis_normal(axis),
                positive_axis_normal(axis),
            )
        } else {
            (
                max_axis,
                min_axis,
                positive_axis_normal(axis),
                negative_axis_normal(axis),
            )
        };
        let t_near = (near_plane - origin_axis) / direction_axis;
        let t_far = (far_plane - origin_axis) / direction_axis;

        if t_near > t_min {
            t_min = t_near;
            normal = near_normal;
        }
        t_max = t_max.min(t_far);
        if t_min > t_max {
            return None;
        }
    }

    (t_min >= 0.0 && t_min <= max_distance).then_some((t_min, normal))
}

fn positive_axis_normal(axis: usize) -> MacroCoord {
    match axis {
        0 => MacroCoord::new(1, 0, 0),
        1 => MacroCoord::new(0, 1, 0),
        _ => MacroCoord::new(0, 0, 1),
    }
}

fn negative_axis_normal(axis: usize) -> MacroCoord {
    match axis {
        0 => MacroCoord::new(-1, 0, 0),
        1 => MacroCoord::new(0, -1, 0),
        _ => MacroCoord::new(0, 0, -1),
    }
}

fn macro_coord_to_vec3(coord: MacroCoord) -> Vec3 {
    Vec3::new(coord.x as f32, coord.y as f32, coord.z as f32)
}

fn voxel_cell_bounds(cell: VoxelRenderCell) -> (Vec3, Vec3) {
    if let Some(micro) = cell.micro {
        micro_bounds(MicroCellTarget {
            macro_coord: cell.macro_coord,
            micro,
        })
    } else {
        macro_bounds(cell.macro_coord)
    }
}

fn macro_bounds(coord: MacroCoord) -> (Vec3, Vec3) {
    let min = Vec3::new(
        coord.x as f32 * VOXEL_RENDER_CELL_SIZE,
        coord.y as f32 * VOXEL_RENDER_CELL_SIZE,
        coord.z as f32 * VOXEL_RENDER_CELL_SIZE,
    );
    (min, min + Vec3::splat(VOXEL_RENDER_CELL_SIZE))
}

fn micro_bounds(target: MicroCellTarget) -> (Vec3, Vec3) {
    let min = Vec3::new(
        target.macro_coord.x as f32 * VOXEL_RENDER_CELL_SIZE
            + target.micro.x as f32 * VOXEL_RENDER_MICRO_SIZE,
        target.macro_coord.y as f32 * VOXEL_RENDER_CELL_SIZE
            + target.micro.y as f32 * VOXEL_RENDER_MICRO_SIZE,
        target.macro_coord.z as f32 * VOXEL_RENDER_CELL_SIZE
            + target.micro.z as f32 * VOXEL_RENDER_MICRO_SIZE,
    );
    (min, min + Vec3::splat(VOXEL_RENDER_MICRO_SIZE))
}

fn micro_target_from_render_point(point: Vec3) -> Option<MicroCellTarget> {
    let macro_coord = MacroCoord::new(
        (point.x / VOXEL_RENDER_CELL_SIZE).floor() as i32,
        (point.y / VOXEL_RENDER_CELL_SIZE).floor() as i32,
        (point.z / VOXEL_RENDER_CELL_SIZE).floor() as i32,
    );
    let macro_min = Vec3::new(
        macro_coord.x as f32 * VOXEL_RENDER_CELL_SIZE,
        macro_coord.y as f32 * VOXEL_RENDER_CELL_SIZE,
        macro_coord.z as f32 * VOXEL_RENDER_CELL_SIZE,
    );
    let local = point - macro_min;
    let micro = MicroCoord::new(
        (local.x / VOXEL_RENDER_MICRO_SIZE)
            .floor()
            .clamp(0.0, (crate::voxel::MICRO_PER_MACRO - 1) as f32) as i32,
        (local.y / VOXEL_RENDER_MICRO_SIZE)
            .floor()
            .clamp(0.0, (crate::voxel::MICRO_PER_MACRO - 1) as f32) as i32,
        (local.z / VOXEL_RENDER_MICRO_SIZE)
            .floor()
            .clamp(0.0, (crate::voxel::MICRO_PER_MACRO - 1) as f32) as i32,
    );
    Some(MicroCellTarget { macro_coord, micro })
}

fn selection_bounds(selection: &VoxelRaySelection) -> (Vec3, Vec3) {
    selection
        .occupied_micro
        .map(micro_bounds)
        .unwrap_or_else(|| macro_bounds(selection.occupied_macro))
}

fn draw_prefab_preview(gizmos: &mut Gizmos, preview: &BoundarySnapPreview, color: Color) {
    for cell in &preview.cells {
        for x in 0..crate::voxel::MICRO_PER_MACRO {
            for y in 0..crate::voxel::MICRO_PER_MACRO {
                for z in 0..crate::voxel::MICRO_PER_MACRO {
                    let micro = MicroCoord::new(x, y, z);
                    if cell.data.micro_occupancy_mask.contains(micro) {
                        let (min, max) = micro_bounds(MicroCellTarget {
                            macro_coord: cell.macro_coord,
                            micro,
                        });
                        draw_box_wire(gizmos, min, max, color);
                    }
                }
            }
        }
    }
}

fn draw_face_outline(gizmos: &mut Gizmos, min: Vec3, max: Vec3, normal: MacroCoord, color: Color) {
    let corners = if normal.x != 0 {
        let x = if normal.x > 0 { max.x } else { min.x };
        [
            Vec3::new(x, min.y, min.z),
            Vec3::new(x, max.y, min.z),
            Vec3::new(x, max.y, max.z),
            Vec3::new(x, min.y, max.z),
        ]
    } else if normal.y != 0 {
        let y = if normal.y > 0 { max.y } else { min.y };
        [
            Vec3::new(min.x, y, min.z),
            Vec3::new(max.x, y, min.z),
            Vec3::new(max.x, y, max.z),
            Vec3::new(min.x, y, max.z),
        ]
    } else {
        let z = if normal.z > 0 { max.z } else { min.z };
        [
            Vec3::new(min.x, min.y, z),
            Vec3::new(max.x, min.y, z),
            Vec3::new(max.x, max.y, z),
            Vec3::new(min.x, max.y, z),
        ]
    };
    for index in 0..4 {
        gizmos.line(corners[index], corners[(index + 1) % 4], color);
    }
}

fn draw_box_wire(gizmos: &mut Gizmos, min: Vec3, max: Vec3, color: Color) {
    let corners = [
        Vec3::new(min.x, min.y, min.z),
        Vec3::new(max.x, min.y, min.z),
        Vec3::new(max.x, max.y, min.z),
        Vec3::new(min.x, max.y, min.z),
        Vec3::new(min.x, min.y, max.z),
        Vec3::new(max.x, min.y, max.z),
        Vec3::new(max.x, max.y, max.z),
        Vec3::new(min.x, max.y, max.z),
    ];
    for (a, b) in [
        (0, 1),
        (1, 2),
        (2, 3),
        (3, 0),
        (4, 5),
        (5, 6),
        (6, 7),
        (7, 4),
        (0, 4),
        (1, 5),
        (2, 6),
        (3, 7),
    ] {
        gizmos.line(corners[a], corners[b], color);
    }
}

fn effect_color(kind: EffectCueKind) -> Color {
    match kind {
        EffectCueKind::MeleeArc => Color::srgba(1.0, 0.82, 0.3, 0.75),
        EffectCueKind::Projectile => Color::srgba(0.45, 0.95, 1.0, 0.9),
        EffectCueKind::AoeRing => Color::srgba(0.8, 0.45, 1.0, 0.55),
        EffectCueKind::ChainArc => Color::srgba(1.0, 0.95, 0.55, 0.8),
        EffectCueKind::ImpactPulse => Color::srgba(1.0, 0.55, 0.35, 0.7),
        EffectCueKind::Unknown(_) => Color::srgba(1.0, 1.0, 1.0, 0.5),
    }
}

fn effect_spawn_translation(kind: EffectCueKind, origin: Vec3, target: Vec3) -> Vec3 {
    match kind {
        EffectCueKind::Projectile | EffectCueKind::MeleeArc | EffectCueKind::ChainArc => origin,
        _ => target,
    }
}

fn effect_interpolated_translation(
    kind: EffectCueKind,
    origin: Vec3,
    target: Vec3,
    progress: f32,
) -> Vec3 {
    match kind {
        EffectCueKind::Projectile => origin.lerp(target, progress),
        EffectCueKind::MeleeArc => origin.lerp(target, 0.35),
        EffectCueKind::ChainArc => origin.lerp(target, 0.5),
        _ => target,
    }
}

fn effect_runtime_color(kind: EffectCueKind, progress: f32) -> Color {
    let mut color = effect_color(kind);
    let alpha = color.to_srgba().alpha;
    color.set_alpha((1.0 - progress).clamp(0.0, 1.0) * alpha);
    color
}

fn is_printable_char(chr: char) -> bool {
    let is_in_private_use_area = ('\u{e000}'..='\u{f8ff}').contains(&chr)
        || ('\u{f0000}'..='\u{ffffd}').contains(&chr)
        || ('\u{100000}'..='\u{10fffd}').contains(&chr);

    !is_in_private_use_area && !chr.is_ascii_control()
}

fn maybe_log_direction_change(
    observer: &ClientObserver,
    input_trace: &mut InputTraceState,
    direction: Vec2,
) {
    if !observer.enabled() {
        return;
    }

    let label = direction_label(direction);
    if input_trace.last_direction_label != label {
        observer.emit(
            "input",
            "movement_direction_changed",
            &[("direction", label.clone())],
        );
        input_trace.last_direction_label = label;
    }
}

fn direction_label(direction: Vec2) -> String {
    if direction == Vec2::ZERO {
        return "idle".to_string();
    }

    format!("{:.1},{:.1}", direction.x, direction.y)
}

fn voxel_save_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join(".demo")
        .join("observe")
}

fn advance_local_render_prediction(
    time: Res<Time>,
    config: Res<ClientConfig>,
    movement_intent: Res<MovementIntent>,
    mut local_render_prediction: ResMut<LocalRenderPrediction>,
) {
    let Some(anchor) = local_render_prediction.anchor_state.clone() else {
        return;
    };

    let dt_secs = time.delta_secs();

    // Unreal-style exponential decay: `x(t) = x0 * exp(-rate * t)` drives the
    // outstanding visual correction toward zero without ever teleporting.
    let decay = (-local_render_prediction.smoothing_rate_hz * dt_secs).exp();
    local_render_prediction.pending_correction *= decay;
    if local_render_prediction.pending_correction.length_squared() < VISUAL_CORRECTION_EPSILON_SQ {
        local_render_prediction.pending_correction = Vec3::ZERO;
    }

    local_render_prediction.partial_elapsed_secs = (local_render_prediction.partial_elapsed_secs
        + dt_secs)
        .clamp(0.0, config.movement_interval_ms as f32 / 1_000.0);

    let direction = movement_intent.direction;
    let movement_flags = movement_flags_for_intent(direction, movement_intent.jump_requested);

    let partial_elapsed = local_render_prediction.partial_elapsed_secs;
    let stepped_anchor = if partial_elapsed <= f32::EPSILON {
        anchor.clone()
    } else {
        let partial_frame = MoveInputFrame {
            seq: 0,
            client_tick: anchor.tick,
            dt_ms: (partial_elapsed * 1_000.0)
                .round()
                .clamp(1.0, config.movement_interval_ms as f32) as u16,
            input_dir: Vec2::new(direction.x, direction.y),
            speed_scale: 1.0,
            movement_flags,
        };
        predictor::step(&anchor, &partial_frame, &local_render_prediction.profile)
    };

    let render_pos = stepped_anchor.position + local_render_prediction.pending_correction;
    local_render_prediction.render_state = Some(PredictedMoveState {
        position: render_pos,
        ..stepped_anchor
    });
}

fn should_send_stop_sync(direction: Vec2, local_velocity: Vec3, stop_sent: bool) -> bool {
    if direction.length_squared() > 0.0 {
        return true;
    }

    // Keep emitting zero-input brake frames until the local prediction has
    // actually settled. Otherwise the authoritative path can stop on a
    // non-zero residual velocity snapshot, which causes the local and remote
    // final positions to drift apart after longer movement bursts.
    !stop_sent || local_velocity.length() > FINAL_STOP_SYNC_SPEED_EPSILON
}

fn movement_flags_for_intent(direction: Vec2, jump_requested: bool) -> u16 {
    let mut movement_flags = if direction.length_squared() == 0.0 {
        MOVEMENT_FLAG_BRAKE
    } else {
        0
    };

    if jump_requested {
        movement_flags |= MOVEMENT_FLAG_JUMP;
    }

    movement_flags
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn movement_direction_maps_wasd_and_arrows() {
        let mut keyboard = ButtonInput::<KeyCode>::default();
        keyboard.press(KeyCode::KeyW);
        keyboard.press(KeyCode::ArrowLeft);

        let direction = current_movement_direction(&keyboard);

        assert_eq!(direction, Vec2::new(-1.0, 1.0));
    }

    #[test]
    fn movement_direction_from_logical_key_supports_wasd_and_arrows() {
        assert_eq!(
            movement_direction_from_key(&Key::Character("w".into())),
            Vec2::new(0.0, 1.0)
        );
        assert_eq!(
            movement_direction_from_key(&Key::Character("A".into())),
            Vec2::new(-1.0, 0.0)
        );
        assert_eq!(
            movement_direction_from_key(&Key::ArrowRight),
            Vec2::new(1.0, 0.0)
        );
    }

    #[test]
    fn stop_sync_continues_while_local_velocity_is_nonzero() {
        assert!(should_send_stop_sync(
            Vec2::ZERO,
            Vec3::new(8.0, 0.0, 0.0),
            true
        ));
        assert!(should_send_stop_sync(Vec2::ZERO, Vec3::ZERO, false));
        assert!(!should_send_stop_sync(Vec2::ZERO, Vec3::ZERO, true));
    }

    /// Regression: releasing every movement key must zero the intent on the
    /// very next system tick. A previous 250 ms `expires_at` grace kept the
    /// last direction latched, so the predictor and the `movement_sender` path
    /// continued advancing the unit (and rotating residual velocity toward the
    /// latched direction) for frames after the physical release — visible as
    /// slide-and-auto-turn after releasing WASD.
    #[test]
    fn releasing_all_keys_zeroes_intent_immediately() {
        use bevy::input::keyboard::KeyboardInput;

        let mut app = App::new();
        app.init_resource::<Time>()
            .init_resource::<ButtonInput<KeyCode>>()
            .add_message::<KeyboardInput>()
            .insert_resource(ChatState::default())
            .insert_resource(ClientObserver::default())
            .insert_resource(InputTraceState::default())
            .insert_resource(MovementIntent::default())
            .add_systems(Update, sample_movement_input);

        // Press W for one frame — intent should track the held direction and
        // keep `expires_at` clear (no stdio timer latch).
        app.world_mut()
            .resource_mut::<ButtonInput<KeyCode>>()
            .press(KeyCode::KeyW);
        app.update();

        {
            let intent = app.world().resource::<MovementIntent>();
            assert_eq!(intent.direction, Vec2::new(0.0, 1.0));
            assert_eq!(
                intent.expires_at, 0.0,
                "keyboard press must not set expires_at — that field is reserved for stdio timed moves"
            );
        }

        // Release every key, flush the same-frame press events, and advance
        // the Bevy clock by one 16 ms tick. With the 250 ms latch removed the
        // intent must collapse to ZERO on this very update.
        app.world_mut()
            .resource_mut::<ButtonInput<KeyCode>>()
            .release_all();
        app.world_mut()
            .resource_mut::<Messages<KeyboardInput>>()
            .clear();
        app.world_mut()
            .resource_mut::<Time>()
            .advance_by(std::time::Duration::from_millis(16));
        app.update();

        let intent = app.world().resource::<MovementIntent>();
        assert_eq!(
            intent.direction,
            Vec2::ZERO,
            "direction must zero immediately on key release — prior 250 ms latch caused slide+auto-turn"
        );
    }

    #[test]
    fn pressing_space_sets_one_shot_jump_intent_and_flag() {
        let mut app = App::new();
        app.init_resource::<Time>()
            .init_resource::<ButtonInput<KeyCode>>()
            .add_message::<KeyboardInput>()
            .insert_resource(ChatState::default())
            .insert_resource(ClientObserver::default())
            .insert_resource(InputTraceState::default())
            .insert_resource(MovementIntent::default())
            .add_systems(Update, sample_movement_input);

        app.world_mut()
            .resource_mut::<ButtonInput<KeyCode>>()
            .press(KeyCode::Space);
        app.update();

        let intent = app.world().resource::<MovementIntent>();
        assert!(intent.jump_requested);
        assert_eq!(
            movement_flags_for_intent(Vec2::ZERO, true),
            MOVEMENT_FLAG_BRAKE | crate::input::commands::MOVEMENT_FLAG_JUMP
        );
    }

    #[test]
    fn voxel_3d_ray_selects_hit_face_and_adjacent_macro() {
        let mut world = VoxelWorld::new();
        world.place_block(
            MacroCoord::new(0, 0, 0),
            NormalBlockData::new(VoxelMaterialId::Dirt),
        );

        let selection = find_voxel_selection_from_ray(
            &world,
            Vec3::new(50.0, 260.0, 50.0),
            Vec3::new(0.0, -1.0, 0.0),
        )
        .expect("top face hit");

        assert_eq!(selection.occupied_macro, MacroCoord::new(0, 0, 0));
        assert_eq!(selection.face_normal, MacroCoord::new(0, 1, 0));
        assert_eq!(selection.adjacent_macro, MacroCoord::new(0, 1, 0));
        assert_eq!(selection.occupied_micro.unwrap().micro.y, 7);
        assert_eq!(
            selection.adjacent_micro.unwrap().macro_coord,
            MacroCoord::new(0, 1, 0)
        );
    }

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
        render.sync_full_state(Vec3::new(8.0, 0.0, 0.0), Vec3::ZERO, Vec3::ZERO);
        let render_at_first_sync = render.render_state.as_ref().unwrap().position;
        assert!((render_at_first_sync.x - 0.0).abs() < 0.01);

        // Authoritative correction pulls anchor back to 4 — render must stay
        // near the visible 8 so the player does not see a teleport.
        render.sync_full_state(Vec3::new(4.0, 0.0, 0.0), Vec3::ZERO, Vec3::ZERO);
        let render_after_correction = render.render_state.as_ref().unwrap().position;
        assert!((render_after_correction.x - render_at_first_sync.x).abs() < 0.01);
        assert!(render.pending_correction_distance() > 3.0);
    }

    #[test]
    fn local_render_prediction_hard_snaps_on_huge_drift() {
        let mut render = LocalRenderPrediction::default();
        render.reset(Vec3::new(0.0, 0.0, 0.0));

        // First settle at a position far from the next sync to build a visible
        // history.
        render.sync_full_state(Vec3::new(10.0, 0.0, 0.0), Vec3::ZERO, Vec3::ZERO);

        // A 400-unit authoritative jump exceeds VISUAL_HARD_SNAP_DISTANCE and
        // must zero the pending correction — the render faithfully jumps.
        render.sync_full_state(Vec3::new(-390.0, 0.0, 0.0), Vec3::ZERO, Vec3::ZERO);
        assert_eq!(render.pending_correction, Vec3::ZERO);
        let rendered = render.render_state.as_ref().unwrap().position;
        assert!((rendered.x - (-390.0)).abs() < 0.01);
    }

    #[test]
    fn local_render_prediction_reset_clears_correction() {
        let mut render = LocalRenderPrediction::default();
        render.reset(Vec3::new(0.0, 0.0, 0.0));
        render.sync_full_state(Vec3::new(8.0, 0.0, 0.0), Vec3::ZERO, Vec3::ZERO);
        render.sync_full_state(Vec3::new(4.0, 0.0, 0.0), Vec3::ZERO, Vec3::ZERO);
        assert!(render.pending_correction_distance() > 0.0);

        render.reset(Vec3::new(100.0, 0.0, 0.0));
        assert_eq!(render.pending_correction, Vec3::ZERO);
        assert_eq!(
            render.render_state.as_ref().unwrap().position,
            Vec3::new(100.0, 0.0, 0.0)
        );
    }
}
