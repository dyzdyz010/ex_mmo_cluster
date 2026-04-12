use crate::{
    config::ClientConfig,
    movement::next_movement_command,
    net::{MessageTransport, NetworkBridge, NetworkCommand, NetworkEvent, spawn_network_thread},
    observe::ClientObserver,
    stdio::{ClientStdioCommand, ClientStdioInterface, emit as emit_stdio, snapshot_fields},
};
use bevy::{
    app::AppExit,
    input::keyboard::{Key, KeyboardInput},
    prelude::*,
    window::WindowPlugin,
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
struct SkillPulse {
    timer: Timer,
}

#[derive(Resource, Default)]
struct WorldState {
    status: String,
    scene_joined: bool,
    local_cid: i64,
    local_position: Option<Vec3>,
    remote_players: HashMap<i64, Vec3>,
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

const VISUAL_SMOOTHING_SPEED: f32 = 18.0;
const VISUAL_SNAP_DISTANCE: f32 = 96.0;

impl Default for MovementDispatchState {
    fn default() -> Self {
        Self { stop_sent: true }
    }
}

pub fn run(config: ClientConfig, observer: ClientObserver, stdio: ClientStdioInterface) {
    let bridge = spawn_network_thread(config.clone(), observer.clone());
    let window_title = format!(
        "Hemifuture Bevy Client - {} / cid {}",
        config.username, config.cid
    );

    App::new()
        .insert_resource(ClearColor(Color::srgb(0.05, 0.07, 0.09)))
        .insert_resource(config.clone())
        .insert_resource(bridge)
        .insert_resource(WorldState {
            status: if config.token.is_empty() {
                "missing token: set BEVY_CLIENT_TOKEN".to_string()
            } else {
                "starting client".to_string()
            },
            local_cid: config.cid,
            control_transport: MessageTransport::Tcp,
            movement_transport: MessageTransport::Tcp,
            fast_lane_status: "tcp fallback".to_string(),
            ..default()
        })
        .insert_resource(ChatState::default())
        .insert_resource(MovementIntent::default())
        .insert_resource(MovementDispatchState::default())
        .insert_resource(InputTraceState::default())
        .insert_resource(observer)
        .insert_resource(stdio)
        .insert_resource(MovementTick(Timer::from_seconds(
            config.movement_interval_ms as f32 / 1_000.0,
            TimerMode::Repeating,
        )))
        .add_plugins(DefaultPlugins.set(WindowPlugin {
            primary_window: Some(Window {
                title: window_title,
                resolution: (1280, 720).into(),
                ..default()
            }),
            ..default()
        }))
        .add_systems(Startup, setup)
        .add_systems(
            Update,
            (
                poll_network_events,
                toggle_chat_mode,
                collect_chat_text,
                handle_skill_input,
                sample_movement_input,
                poll_stdio_commands,
                movement_sender,
                sync_player_visuals,
                update_skill_pulses,
                update_hud_text,
                camera_follow_local_player,
            ),
        )
        .run();
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
    mut world_state: ResMut<WorldState>,
    mut movement_dispatch: ResMut<MovementDispatchState>,
) {
    let Ok(receiver) = bridge.rx.lock() else {
        return;
    };

    while let Ok(event) = receiver.try_recv() {
        match event {
            NetworkEvent::Status(status) => {
                world_state.status = status.clone();
                push_line(&mut world_state.logs, status);
            }
            NetworkEvent::EnteredScene { cid, location } => {
                world_state.scene_joined = true;
                world_state.status = format!("in scene as cid {cid}");
                world_state.local_cid = cid;
                world_state.local_position = Some(net_to_world(location));
                world_state.remote_players.clear();
                world_state.last_local_update_transport = None;
                world_state.last_remote_move_transport = None;
                movement_dispatch.stop_sent = true;
                push_line(&mut world_state.logs, format!("entered scene cid={cid}"));
            }
            NetworkEvent::LocalPosition {
                cid: _,
                location,
                transport,
            } => {
                world_state.local_position = Some(net_to_world(location));
                world_state.last_local_update_transport = Some(transport);
            }
            NetworkEvent::PlayerEnter { cid, location } => {
                if cid != world_state.local_cid {
                    world_state
                        .remote_players
                        .insert(cid, net_to_world(location));
                }
                push_line(&mut world_state.logs, format!("player {cid} entered AOI"));
            }
            NetworkEvent::PlayerMove {
                cid,
                location,
                transport,
            } => {
                if cid != world_state.local_cid {
                    world_state
                        .remote_players
                        .insert(cid, net_to_world(location));
                }
                world_state.last_remote_move_transport = Some(transport);
            }
            NetworkEvent::PlayerLeave { cid } => {
                world_state.remote_players.remove(&cid);
                push_line(&mut world_state.logs, format!("player {cid} left AOI"));
            }
            NetworkEvent::ChatMessage {
                cid,
                username,
                text,
            } => {
                push_line(
                    &mut world_state.chat_log,
                    format!("[{cid}/{username}] {text}"),
                );
            }
            NetworkEvent::SkillEvent {
                cid,
                skill_id,
                location,
            } => {
                let world = net_to_world(location);
                commands.spawn((
                    SkillPulse {
                        timer: Timer::from_seconds(0.45, TimerMode::Once),
                    },
                    Sprite {
                        color: Color::srgba(1.0, 0.8, 0.2, 0.55),
                        custom_size: Some(Vec2::splat(32.0)),
                        ..default()
                    },
                    Transform::from_translation(world + Vec3::new(0.0, 0.0, 5.0)),
                ));
                push_line(
                    &mut world_state.logs,
                    format!("skill event: cid={cid} skill={skill_id}"),
                );
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
            NetworkEvent::Log(line) => push_line(&mut world_state.logs, line),
            NetworkEvent::Disconnected(reason) => {
                world_state.scene_joined = false;
                world_state.status = format!("disconnected: {reason}");
                world_state.local_position = None;
                world_state.remote_players.clear();
                world_state.movement_transport = MessageTransport::Tcp;
                world_state.fast_lane_status = "tcp fallback".to_string();
                world_state.udp_endpoint = None;
                world_state.last_local_update_transport = None;
                world_state.last_remote_move_transport = None;
                movement_dispatch.stop_sent = true;
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
) {
    if chat_state.enabled {
        return;
    }

    if keyboard.just_pressed(KeyCode::Digit1) {
        bridge.send(NetworkCommand::CastSkill(1));
        observer.emit("input", "skill_key", &[("skill_id", "1".to_string())]);
    }
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
    mut world_state: ResMut<WorldState>,
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

    let Some(position) = world_state.local_position else {
        return;
    };

    let direction = movement_intent.direction;

    let Some((desired_position, velocity, stop_sent)) = next_movement_command(
        position,
        direction,
        config.movement_speed,
        config.movement_interval_ms,
        movement_dispatch.stop_sent,
    ) else {
        return;
    };

    bridge.send(NetworkCommand::Movement {
        location: [
            desired_position.x as f64,
            desired_position.y as f64,
            desired_position.z as f64,
        ],
        velocity,
        acceleration: [0.0, 0.0, 0.0],
    });

    movement_dispatch.stop_sent = stop_sent;
    world_state.local_position = Some(desired_position);
}

fn poll_stdio_commands(
    time: Res<Time>,
    stdio: Res<ClientStdioInterface>,
    bridge: Res<NetworkBridge>,
    world_state: Res<WorldState>,
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
                    world_state.movement_transport.label(),
                    &world_state.fast_lane_status,
                    world_state.remote_players.len(),
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
                let mut players = world_state
                    .remote_players
                    .iter()
                    .map(|(cid, position)| {
                        format!(
                            "{cid}:{:.1},{:.1},{:.1}",
                            position.x, position.y, position.z
                        )
                    })
                    .collect::<Vec<_>>();
                players.sort();
                emit_stdio(
                    "players",
                    &[("players", format!("[{}]", players.join(";")))],
                );
            }
            ClientStdioCommand::Chat(text) => {
                bridge.send(NetworkCommand::Chat(text.clone()));
                emit_stdio("chat_sent", &[("text", text)]);
            }
            ClientStdioCommand::Skill(skill_id) => {
                bridge.send(NetworkCommand::CastSkill(skill_id));
                emit_stdio("skill_sent", &[("skill_id", skill_id.to_string())]);
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
    mut existing: Query<(Entity, &PlayerVisual, &mut Transform)>,
) {
    let mut entities_by_cid = HashMap::new();
    for (entity, visual, transform) in &existing {
        entities_by_cid.insert(visual.cid, (entity, transform.translation));
    }

    let mut desired = world_state.remote_players.clone();
    if let Some(local) = world_state.local_position {
        desired.insert(world_state.local_cid, local);
    }

    for (&cid, &position) in &desired {
        let target = position + Vec3::new(0.0, 0.0, 1.0);

        if let Some((entity, _)) = entities_by_cid.remove(&cid) {
            if let Ok((_entity, _visual, mut transform)) = existing.get_mut(entity) {
                transform.translation = smooth_translation(
                    transform.translation,
                    target,
                    time.delta_secs(),
                    VISUAL_SMOOTHING_SPEED,
                    VISUAL_SNAP_DISTANCE,
                );
            }
        } else {
            let color = if cid == world_state.local_cid {
                Color::srgb(0.25, 0.95, 0.45)
            } else {
                Color::srgb(0.3, 0.65, 1.0)
            };

            commands.spawn((
                PlayerVisual { cid },
                Sprite::from_color(color, Vec2::splat(24.0)),
                Transform::from_translation(target),
            ));
        }
    }

    for (cid, (entity, _translation)) in entities_by_cid {
        if cid != world_state.local_cid {
            commands.entity(entity).despawn();
        }
    }
}

fn smooth_translation(
    current: Vec3,
    target: Vec3,
    delta_secs: f32,
    smoothing_speed: f32,
    snap_distance: f32,
) -> Vec3 {
    let distance = current.distance(target);

    if distance <= f32::EPSILON {
        return target;
    }

    if distance >= snap_distance {
        return target;
    }

    let factor = (smoothing_speed * delta_secs).clamp(0.0, 1.0);
    current.lerp(target, factor)
}

fn update_skill_pulses(
    mut commands: Commands,
    time: Res<Time>,
    mut pulses: Query<(Entity, &mut Transform, &mut Sprite, &mut SkillPulse)>,
) {
    for (entity, mut transform, mut sprite, mut pulse) in &mut pulses {
        pulse.timer.tick(time.delta());
        let progress = pulse.timer.fraction();
        transform.scale = Vec3::splat(1.0 + progress * 2.5);
        sprite.color.set_alpha(0.55 * (1.0 - progress));

        if pulse.timer.is_finished() {
            commands.entity(entity).despawn();
        }
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
    hud.0 = format!(
        "status: {}\ndemo: control={} | movement={} | fast-lane={}\nudp endpoint: {}\nAOI peers: {}\nlocal cid: {}\nposition: {}\nlast move ack: {}\nlast AOI move: {}\nrtt: {}\noffset: {}\nheartbeat: {}\ncontrols: WASD move | Enter chat | 1 pulse skill",
        world_state.status,
        world_state.control_transport.label(),
        world_state.movement_transport.label(),
        world_state.fast_lane_status,
        world_state
            .udp_endpoint
            .clone()
            .unwrap_or_else(|| "n/a".to_string()),
        world_state.remote_players.len(),
        world_state.local_cid,
        world_state
            .local_position
            .map(|pos| format!("{:.1}, {:.1}, {:.1}", pos.x, pos.y, pos.z))
            .unwrap_or_else(|| "n/a".to_string()),
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
    world_state: Res<WorldState>,
    mut camera: Single<&mut Transform, (With<Camera2d>, Without<PlayerVisual>)>,
) {
    if let Some(position) = world_state.local_position {
        camera.translation.x = position.x;
        camera.translation.y = position.y;
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
    fn smooth_translation_moves_toward_target_without_overshoot() {
        let current = Vec3::new(0.0, 0.0, 0.0);
        let target = Vec3::new(10.0, 0.0, 0.0);

        let next = smooth_translation(current, target, 1.0 / 60.0, 18.0, 96.0);

        assert!(next.x > current.x);
        assert!(next.x < target.x);
        assert_eq!(next.y, 0.0);
    }

    #[test]
    fn smooth_translation_snaps_large_corrections() {
        let current = Vec3::new(0.0, 0.0, 0.0);
        let target = Vec3::new(200.0, 0.0, 0.0);

        let next = smooth_translation(current, target, 1.0 / 60.0, 18.0, 96.0);

        assert_eq!(next, target);
    }
}
