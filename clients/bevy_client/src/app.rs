//! Interactive Bevy app entrypoint and world/UI glue.

use crate::{
    input::commands::{MoveInputFrame, MOVEMENT_FLAG_BRAKE},
    config::{ClientConfig, SessionCredentials},
    login::{AppState, LoginPlugin},
    net::{MessageTransport, NetworkBridge, NetworkCommand, NetworkEvent, spawn_network_thread},
    observe::ClientObserver,
    presentation::{
        animation::{animated_scale, animation_state_from_velocity},
        camera::{desired_camera_target, smooth_camera_translation},
        smoothing::smooth_translation,
    },
    protocol::EffectCueKind,
    sim::{
        predictor,
        profile::MovementProfile,
        types::{MovementMode, PredictedMoveState},
    },
    skill_targeting::prepare_skill_dispatch,
    stdio::{ClientStdioCommand, ClientStdioInterface, emit as emit_stdio, snapshot_fields},
    world::remote_actor::{RemoteActorIdentity, RemoteActorKind},
    world::remote_player::{RemoteMotionSample, RemotePlayerState},
};
use bevy::{
    app::AppExit,
    input::keyboard::{Key, KeyboardInput},
    prelude::*,
    window::{PrimaryWindow, WindowPlugin},
};
use std::collections::{HashMap, VecDeque};

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
struct LocalRenderPrediction {
    anchor_state: Option<PredictedMoveState>,
    render_state: Option<PredictedMoveState>,
    partial_elapsed_secs: f32,
    profile: MovementProfile,
}

impl Default for LocalRenderPrediction {
    fn default() -> Self {
        Self {
            anchor_state: None,
            render_state: None,
            partial_elapsed_secs: 0.0,
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
    }

    fn sync_full_state(&mut self, position: Vec3, velocity: Vec3, acceleration: Vec3) {
        let state = PredictedMoveState {
            tick: 0,
            position,
            velocity,
            acceleration,
            movement_mode: MovementMode::Grounded,
        };

        self.anchor_state = Some(state.clone());
        self.render_state = Some(state);
        self.partial_elapsed_secs = 0.0;
    }

    fn clear(&mut self) {
        self.anchor_state = None;
        self.render_state = None;
        self.partial_elapsed_secs = 0.0;
    }
}

const VISUAL_SMOOTHING_SPEED: f32 = 18.0;
const VISUAL_SNAP_DISTANCE: f32 = 96.0;
const FINAL_STOP_SYNC_SPEED_EPSILON: f32 = 1.0;

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
                handle_target_selection_input,
                handle_point_target_input,
                handle_skill_input,
                sample_movement_input,
                poll_stdio_commands,
                movement_sender,
                (advance_local_render_prediction, sync_player_visuals, camera_follow_local_player).chain(),
                update_target_point_marker,
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

fn setup(mut commands: Commands) {
    commands.spawn(Camera2d);

    spawn_grid(&mut commands);

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
        Sprite {
            color: Color::srgba(0.95, 0.35, 0.95, 0.8),
            custom_size: Some(Vec2::new(18.0, 18.0)),
            ..default()
        },
        Visibility::Hidden,
        Transform::from_xyz(0.0, 0.0, 6.0),
    ));
}

fn spawn_grid(commands: &mut Commands) {
    for offset in (-10..=10).map(|step| step as f32 * 200.0) {
        commands.spawn((
            Sprite::from_color(Color::srgba(0.2, 0.25, 0.3, 0.5), Vec2::new(4_200.0, 2.0)),
            Transform::from_xyz(0.0, offset, -10.0),
        ));
        commands.spawn((
            Sprite::from_color(Color::srgba(0.2, 0.25, 0.3, 0.5), Vec2::new(2.0, 4_200.0)),
            Transform::from_xyz(offset, 0.0, -10.0),
        ));
    }
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
                    RemoteActorIdentity { cid, kind, name: name.clone() },
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
                        &[
                            ("cid", cid.to_string()),
                            ("skill_id", skill_id.to_string()),
                        ],
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
                    Sprite {
                        color: effect_color(cue_kind),
                        custom_size: Some(effect_size(cue_kind, radius as f32)),
                        ..default()
                    },
                    Transform::from_translation(effect_spawn_translation(cue_kind, origin_world, target_world))
                        .with_scale(effect_scale(cue_kind, radius as f32)),
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
            let index = cids.iter().position(|cid| *cid == current).unwrap_or(usize::MAX);
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
    windows: Query<&Window, With<PrimaryWindow>>,
    camera: Single<&Transform, (With<Camera2d>, Without<PlayerVisual>)>,
    mut world_state: ResMut<WorldState>,
    observer: Res<ClientObserver>,
) {
    if mouse.just_pressed(MouseButton::Right) {
        let Ok(window) = windows.single() else {
            return;
        };

        if let Some(cursor) = window.cursor_position() {
            let world = cursor_to_world(cursor, window, camera.translation);
            world_state.selected_target_point = Some(world);
            world_state.selected_target_cid = None;
            observer.emit(
                "input",
                "target_point_selected",
                &[(
                    "point",
                    format!("{:.1},{:.1},{:.1}", world.x, world.y, world.z),
                )],
            );
        }
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
        maybe_log_direction_change(&observer, &mut input_trace, movement_intent.direction);
        return;
    }

    let direction = current_movement_direction(&keyboard);

    if direction.length_squared() > 0.0 {
        movement_intent.direction = direction;
        movement_intent.expires_at = time.elapsed_secs_f64() + 0.25;
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
            movement_intent.expires_at = time.elapsed_secs_f64() + 0.25;
            maybe_log_direction_change(&observer, &mut input_trace, movement_intent.direction);
            return;
        }
    }

    if time.elapsed_secs_f64() >= movement_intent.expires_at {
        movement_intent.direction = Vec2::ZERO;
    }

    maybe_log_direction_change(&observer, &mut input_trace, movement_intent.direction);
}

fn movement_sender(
    time: Res<Time>,
    bridge: Res<NetworkBridge>,
    config: Res<ClientConfig>,
    observer: Res<ClientObserver>,
    world_state: Res<WorldState>,
    movement_intent: Res<MovementIntent>,
    mut movement_dispatch: ResMut<MovementDispatchState>,
    mut tick: ResMut<MovementTick>,
) {
    if !world_state.scene_joined {
        return;
    }

    if !tick.0.tick(time.delta()).just_finished() {
        return;
    }

    let direction = movement_intent.direction;
    let movement_flags = if direction.length_squared() == 0.0 {
        0b10
    } else {
        0
    };

    let should_send_stop_sync = should_send_stop_sync(
        direction,
        world_state.local_velocity,
        movement_dispatch.stop_sent,
    );

    if direction.length_squared() == 0.0 && !should_send_stop_sync {
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
            ("direction", format!("{:.2},{:.2}", direction.x, direction.y)),
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

    movement_dispatch.stop_sent = direction.length_squared() == 0.0
        && world_state.local_velocity.length() <= FINAL_STOP_SYNC_SPEED_EPSILON;
}

fn poll_stdio_commands(
    time: Res<Time>,
    stdio: Res<ClientStdioInterface>,
    bridge: Res<NetworkBridge>,
    mut world_state: ResMut<WorldState>,
    mut movement_intent: ResMut<MovementIntent>,
    mut app_exit: MessageWriter<AppExit>,
) {
    loop {
        let Some(command) = stdio.try_recv() else {
            break;
        };

        match command {
            ClientStdioCommand::Snapshot => {
                let fields = snapshot_fields(
                    &world_state.status,
                    world_state.scene_joined,
                    world_state.local_cid,
                    world_state.local_position,
                    world_state.local_hp,
                    world_state.local_max_hp,
                    world_state.local_alive,
                    world_state.movement_transport.label(),
                    &world_state.fast_lane_status,
                    world_state
                        .remote_actor_identity
                        .values()
                        .filter(|identity| matches!(identity.kind, RemoteActorKind::Player))
                        .count(),
                    world_state
                        .remote_actor_identity
                        .values()
                        .filter(|identity| identity.is_npc())
                        .count(),
                );
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
                    &[("point", format!("{:.1},{:.1},{:.1}", point.x, point.y, point.z))],
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
            ClientStdioCommand::Skill { skill_id, target_cid } => {
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
                                .map(|value| format!("{:.1},{:.1},{:.1}", value[0], value[1], value[2]))
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

fn sync_player_visuals(
    mut commands: Commands,
    time: Res<Time>,
    world_state: Res<WorldState>,
    local_render_prediction: Res<LocalRenderPrediction>,
    config: Res<ClientConfig>,
    mut existing: Query<(Entity, &PlayerVisual, &mut Transform, &mut Sprite)>,
) {
    let mut entities_by_cid = HashMap::new();
    for (entity, visual, _transform, _sprite) in &existing {
        entities_by_cid.insert(visual.cid, entity);
    }

    let now_secs = time.elapsed_secs_f64();
    let mut desired = world_state
        .remote_players
        .iter()
        .map(|(&cid, state)| (cid, state.sample_motion(now_secs)))
        .collect::<HashMap<_, _>>();
    if let Some(local) = local_render_prediction
        .render_state
        .as_ref()
        .map(|state| RemoteMotionSample {
            position: state.position,
            velocity: state.velocity,
        })
        .or_else(|| {
            world_state.local_position.map(|local| RemoteMotionSample {
                position: local,
                velocity: world_state.local_velocity,
            })
        })
    {
        desired.insert(
            world_state.local_cid,
            local,
        );
    }

    for (&cid, motion) in &desired {
        let target = motion.position + Vec3::new(0.0, 0.0, 1.0);
        let animation = animation_state_from_velocity(motion.velocity, config.movement_speed);
        let actor_kind = world_state
            .remote_actor_identity
            .get(&cid)
            .map(|identity| identity.kind)
            .unwrap_or(RemoteActorKind::Player);
        let selected = world_state.selected_target_cid == Some(cid);

        if let Some(entity) = entities_by_cid.remove(&cid) {
            if let Ok((_entity, _visual, mut transform, mut sprite)) = existing.get_mut(entity) {
                transform.translation = if cid == world_state.local_cid {
                    target
                } else {
                    smooth_translation(
                        transform.translation,
                        target,
                        time.delta_secs(),
                        VISUAL_SMOOTHING_SPEED,
                        VISUAL_SNAP_DISTANCE,
                    )
                };
                transform.scale = animated_scale(transform.scale, animation, time.delta_secs());
                sprite.color = if cid == world_state.local_cid {
                    Color::srgb(0.25, 0.95, 0.45)
                } else if selected {
                    Color::srgb(1.0, 0.95, 0.35)
                } else if matches!(actor_kind, RemoteActorKind::Npc) {
                    Color::srgb(0.95, 0.45, 0.35)
                } else if animation.moving {
                    Color::srgb(0.35, 0.75, 1.0)
                } else {
                    Color::srgb(0.3, 0.65, 1.0)
                };
            }
        } else {
            let color = if cid == world_state.local_cid {
                Color::srgb(0.25, 0.95, 0.45)
            } else if selected {
                Color::srgb(1.0, 0.95, 0.35)
            } else if matches!(actor_kind, RemoteActorKind::Npc) {
                Color::srgb(0.95, 0.45, 0.35)
            } else {
                Color::srgb(0.3, 0.65, 1.0)
            };

            let size = if matches!(actor_kind, RemoteActorKind::Npc) {
                Vec2::new(28.0, 22.0)
            } else {
                Vec2::splat(24.0)
            };

            commands.spawn((
                PlayerVisual { cid },
                Sprite::from_color(color, size),
                Transform::from_translation(target).with_scale(animated_scale(
                    Vec3::ONE,
                    animation,
                    time.delta_secs(),
                )),
            ));
        }
    }

    for (cid, entity) in entities_by_cid {
        if cid != world_state.local_cid {
            commands.entity(entity).despawn();
        }
    }
}

fn update_effect_visuals(
    mut commands: Commands,
    time: Res<Time>,
    mut effects: Query<(Entity, &mut Transform, &mut Sprite, &mut EffectVisual)>,
) {
    for (entity, mut transform, mut sprite, mut effect) in &mut effects {
        effect.timer.tick(time.delta());
        let progress = effect.timer.fraction();
        let translation = effect_interpolated_translation(effect.kind, effect.origin, effect.target, progress);
        transform.translation = translation + Vec3::new(0.0, 0.0, 5.0);
        transform.scale = effect_runtime_scale(effect.kind, effect.radius, progress);
        transform.rotation = effect_rotation(effect.kind, effect.origin, effect.target);
        sprite.color = effect_runtime_color(effect.kind, progress);

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
        marker.0.translation = point + Vec3::new(0.0, 0.0, 6.0);
    } else {
        *marker.1 = Visibility::Hidden;
    }
}

fn update_hud_text(
    world_state: Res<WorldState>,
    chat_state: Res<ChatState>,
    mut hud: Single<&mut Text, (With<HudText>, Without<ChatLogText>, Without<ChatInputText>)>,
    mut chat_log_text: Single<
        &mut Text,
        (With<ChatLogText>, Without<HudText>, Without<ChatInputText>),
    >,
    mut chat_input_text: Single<
        &mut Text,
        (With<ChatInputText>, Without<HudText>, Without<ChatLogText>),
    >,
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

    hud.0 = format!(
        "status: {}\ndemo: control={} | movement={} | fast-lane={}\nudp endpoint: {}\nAOI peers: {} (npcs: {})\nselected target: {}\nselected point: {}\nlocal cid: {}\nposition: {}\nhp: {}/{} alive={}\nlast move ack: {}\nlast AOI move: {}\nrtt: {}\noffset: {}\nheartbeat: {}\ncontrols: WASD move | Tab cycle target | RMB set point | 1-4 cast skills | Enter chat",
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
    chat_log_text.0 = sections.join("\n\n");

    chat_input_text.0 = if chat_state.enabled {
        format!("> {}_", chat_state.draft)
    } else {
        String::new()
    };
}

fn camera_follow_local_player(
    time: Res<Time>,
    world_state: Res<WorldState>,
    visuals: Query<(&PlayerVisual, &Transform), Without<Camera2d>>,
    mut camera: Single<&mut Transform, (With<Camera2d>, Without<PlayerVisual>)>,
) {
    let local_visual = visuals
        .iter()
        .find(|(visual, _transform)| visual.cid == world_state.local_cid)
        .map(|(_visual, transform)| transform.translation);

    if let Some(target) = desired_camera_target(local_visual, world_state.local_position) {
        camera.translation =
            smooth_camera_translation(camera.translation, target, time.delta_secs());
    }
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

fn cursor_to_world(cursor: Vec2, window: &Window, camera_translation: Vec3) -> Vec3 {
    let world_x = cursor.x - window.width() * 0.5 + camera_translation.x;
    let world_y = window.height() * 0.5 - cursor.y + camera_translation.y;
    Vec3::new(world_x, world_y, 90.0)
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

fn effect_size(kind: EffectCueKind, radius: f32) -> Vec2 {
    match kind {
        EffectCueKind::MeleeArc => Vec2::new(48.0, 18.0),
        EffectCueKind::Projectile => Vec2::splat(12.0),
        EffectCueKind::AoeRing => Vec2::new(radius.max(24.0), radius.max(24.0)),
        EffectCueKind::ChainArc => Vec2::new(80.0, 8.0),
        EffectCueKind::ImpactPulse => Vec2::splat(24.0),
        EffectCueKind::Unknown(_) => Vec2::splat(16.0),
    }
}

fn effect_scale(kind: EffectCueKind, radius: f32) -> Vec3 {
    match kind {
        EffectCueKind::AoeRing => Vec3::new((radius / 32.0).max(1.0), (radius / 32.0).max(1.0), 1.0),
        _ => Vec3::ONE,
    }
}

fn effect_spawn_translation(kind: EffectCueKind, origin: Vec3, target: Vec3) -> Vec3 {
    match kind {
        EffectCueKind::Projectile | EffectCueKind::MeleeArc | EffectCueKind::ChainArc => origin,
        _ => target,
    }
}

fn effect_interpolated_translation(kind: EffectCueKind, origin: Vec3, target: Vec3, progress: f32) -> Vec3 {
    match kind {
        EffectCueKind::Projectile => origin.lerp(target, progress),
        EffectCueKind::MeleeArc => origin.lerp(target, 0.35),
        EffectCueKind::ChainArc => origin.lerp(target, 0.5),
        _ => target,
    }
}

fn effect_runtime_scale(kind: EffectCueKind, radius: f32, progress: f32) -> Vec3 {
    match kind {
        EffectCueKind::Projectile => Vec3::splat(1.0 + progress * 0.4),
        EffectCueKind::AoeRing => {
            let base = (radius / 48.0).max(0.8);
            Vec3::splat(base + progress * 0.45)
        }
        EffectCueKind::ImpactPulse => Vec3::splat(1.0 + progress * 1.8),
        EffectCueKind::MeleeArc => Vec3::new(1.0 + progress * 0.8, 1.0, 1.0),
        EffectCueKind::ChainArc => Vec3::new(1.0 + progress * 0.2, 1.0, 1.0),
        EffectCueKind::Unknown(_) => effect_scale(kind, radius),
    }
}

fn effect_runtime_color(kind: EffectCueKind, progress: f32) -> Color {
    let mut color = effect_color(kind);
    let alpha = color.to_srgba().alpha;
    color.set_alpha((1.0 - progress).clamp(0.0, 1.0) * alpha);
    color
}

fn effect_rotation(kind: EffectCueKind, origin: Vec3, target: Vec3) -> Quat {
    match kind {
        EffectCueKind::MeleeArc | EffectCueKind::ChainArc | EffectCueKind::Projectile => {
            let delta = target - origin;
            Quat::from_rotation_z(delta.y.atan2(delta.x))
        }
        _ => Quat::IDENTITY,
    }
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

fn advance_local_render_prediction(
    time: Res<Time>,
    config: Res<ClientConfig>,
    movement_intent: Res<MovementIntent>,
    mut local_render_prediction: ResMut<LocalRenderPrediction>,
) {
    let Some(anchor) = local_render_prediction.anchor_state.clone() else {
        return;
    };

    local_render_prediction.partial_elapsed_secs = (local_render_prediction.partial_elapsed_secs
        + time.delta_secs())
    .clamp(0.0, config.movement_interval_ms as f32 / 1_000.0);

    let direction = movement_intent.direction;
    let movement_flags = if direction.length_squared() == 0.0 {
        MOVEMENT_FLAG_BRAKE
    } else {
        0
    };

    if local_render_prediction.partial_elapsed_secs <= f32::EPSILON {
        local_render_prediction.render_state = Some(anchor);
        return;
    }

    let partial_frame = MoveInputFrame {
        seq: 0,
        client_tick: anchor.tick,
        dt_ms: (local_render_prediction.partial_elapsed_secs * 1_000.0)
            .round()
            .clamp(1.0, config.movement_interval_ms as f32) as u16,
        input_dir: Vec2::new(direction.x, direction.y),
        speed_scale: 1.0,
        movement_flags,
    };

    local_render_prediction.render_state =
        Some(predictor::step(&anchor, &partial_frame, &local_render_prediction.profile));
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

    #[test]
    fn cursor_to_world_flips_window_y_axis() {
        let mut window = Window::default();
        window.resolution.set(1280.0, 720.0);

        let camera = Vec3::new(100.0, 200.0, 999.0);

        let bottom_cursor = Vec2::new(640.0, 700.0);
        let top_cursor = Vec2::new(640.0, 20.0);

        let bottom_world = cursor_to_world(bottom_cursor, &window, camera);
        let top_world = cursor_to_world(top_cursor, &window, camera);

        assert!(bottom_world.y < camera.y);
        assert!(top_world.y > camera.y);
        assert_eq!(bottom_world.x, camera.x);
        assert_eq!(top_world.x, camera.x);
    }
}
