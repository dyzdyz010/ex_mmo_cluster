use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::sync::mpsc::{Sender, TryRecvError};
use std::time::{SystemTime, UNIX_EPOCH};

use bevy::input::keyboard::{Key, KeyboardInput};
use bevy::prelude::*;
use bevy::window::WindowResolution;
use bevy_client::config::ClientConfig;
use bevy_client::net::{NetCommand, NetEvent, NetworkBridge, TransportMode, spawn_network_thread};
use bevy_client::protocol::{ClientMessage, MovementAck, ServerMessage, Vec3 as NetVec3};

fn main() {
    let config = ClientConfig::from_env();
    let asset_path = resolve_asset_path();

    App::new()
        .insert_resource(ClearColor(Color::srgb(0.04, 0.04, 0.06)))
        .insert_resource(config.clone())
        .insert_resource(spawn_network_thread())
        .insert_resource(SessionState::from_config(&config))
        .insert_resource(WorldState::default())
        .insert_resource(ChatState::default())
        .insert_resource(FontHandle::default())
        .insert_resource(HeartbeatTicker(Timer::from_seconds(
            5.0,
            TimerMode::Repeating,
        )))
        .insert_resource(TimeSyncTicker(Timer::from_seconds(
            3.0,
            TimerMode::Repeating,
        )))
        .insert_resource(MovementTicker(Timer::from_seconds(
            1.0 / config.movement_tick_hz.max(1.0),
            TimerMode::Repeating,
        )))
        .add_plugins(
            DefaultPlugins
                .set(AssetPlugin {
                    file_path: asset_path,
                    ..default()
                })
                .set(WindowPlugin {
                    primary_window: Some(Window {
                        title: "Hemifuture Bevy Client".to_string(),
                        resolution: WindowResolution::new(1280.0, 720.0),
                        ..default()
                    }),
                    ..default()
                }),
        )
        .add_systems(Startup, setup)
        .add_systems(
            Update,
            (
                poll_network_events,
                reconnect_input,
                chat_keyboard_input,
                heartbeat_and_timesync,
                movement_input,
                skill_input,
                sync_player_visuals,
                skill_effect_lifetime,
                update_ui_text,
            ),
        )
        .run();
}

#[derive(Resource, Clone, Default)]
struct FontHandle(Handle<Font>);

#[derive(Resource)]
struct SessionState {
    username: String,
    token: String,
    cid: i64,
    next_request_id: u64,
    pending: HashMap<u64, PendingRequest>,
    status: SessionStatus,
    transport: TransportMode,
    last_error: Option<String>,
    last_info: Option<String>,
    last_heartbeat_ts: Option<u64>,
    rtt_ms: Option<u64>,
    clock_offset_ms: Option<i128>,
}

impl SessionState {
    fn from_config(config: &ClientConfig) -> Self {
        Self {
            username: config.username.clone(),
            token: config.token.clone(),
            cid: config.cid,
            next_request_id: 1,
            pending: HashMap::new(),
            status: SessionStatus::Disconnected,
            transport: TransportMode::TcpOnly,
            last_error: if config.token_ready() {
                None
            } else {
                Some("Set HMF_AUTH_TOKEN, then press R to connect".to_string())
            },
            last_info: Some("Press R to connect, Enter to chat, Space to cast Pulse".to_string()),
            last_heartbeat_ts: None,
            rtt_ms: None,
            clock_offset_ms: None,
        }
    }

    fn allocate_request(&mut self, pending: PendingRequest) -> u64 {
        let request_id = self.next_request_id;
        self.next_request_id += 1;
        self.pending.insert(request_id, pending);
        request_id
    }

    fn complete_request(&mut self, request_id: u64) -> Option<PendingRequest> {
        self.pending.remove(&request_id)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PendingRequest {
    Auth,
    EnterScene,
    Movement,
    Chat,
    Skill,
    FastLaneRequest,
    FastLaneAttach,
    TimeSync,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SessionStatus {
    Disconnected,
    Connecting,
    Authenticating,
    Authenticated,
    InScene,
}

#[derive(Resource, Default)]
struct WorldState {
    players: HashMap<i64, PlayerState>,
    entities: HashMap<i64, Entity>,
}

#[derive(Clone, Debug)]
struct PlayerState {
    location: NetVec3,
    is_local: bool,
}

#[derive(Resource, Default)]
struct ChatState {
    input_mode: bool,
    input_buffer: String,
    log: VecDeque<String>,
}

impl ChatState {
    fn push_log(&mut self, line: impl Into<String>) {
        self.log.push_back(line.into());
        while self.log.len() > 8 {
            self.log.pop_front();
        }
    }
}

#[derive(Resource)]
struct HeartbeatTicker(Timer);

#[derive(Resource)]
struct TimeSyncTicker(Timer);

#[derive(Resource)]
struct MovementTicker(Timer);

#[derive(Component)]
struct PlayerVisual {
    cid: i64,
}

#[derive(Component)]
struct SkillEffectVisual {
    timer: Timer,
}

#[derive(Component)]
struct StatusText;

#[derive(Component)]
struct ChatLogText;

#[derive(Component)]
struct ChatInputText;

#[derive(Component)]
struct HelpText;

fn setup(mut commands: Commands, asset_server: Res<AssetServer>, mut font: ResMut<FontHandle>) {
    font.0 = asset_server.load("fonts/DejaVuSans.ttf");

    commands.spawn(Camera2dBundle::default());
    spawn_grid(&mut commands);

    commands.spawn((
        TextBundle::from_section(
            "status",
            TextStyle {
                font: font.0.clone(),
                font_size: 18.0,
                color: Color::srgb(0.95, 0.95, 0.95),
            },
        )
        .with_style(Style {
            position_type: PositionType::Absolute,
            top: Val::Px(12.0),
            left: Val::Px(12.0),
            ..default()
        }),
        StatusText,
    ));

    commands.spawn((
        TextBundle::from_section(
            "chat",
            TextStyle {
                font: font.0.clone(),
                font_size: 18.0,
                color: Color::srgb(0.8, 0.9, 1.0),
            },
        )
        .with_style(Style {
            position_type: PositionType::Absolute,
            left: Val::Px(12.0),
            bottom: Val::Px(78.0),
            ..default()
        }),
        ChatLogText,
    ));

    commands.spawn((
        TextBundle::from_section(
            "chat input",
            TextStyle {
                font: font.0.clone(),
                font_size: 18.0,
                color: Color::srgb(1.0, 0.95, 0.7),
            },
        )
        .with_style(Style {
            position_type: PositionType::Absolute,
            left: Val::Px(12.0),
            bottom: Val::Px(42.0),
            ..default()
        }),
        ChatInputText,
    ));

    commands.spawn((
        TextBundle::from_section(
            "help",
            TextStyle {
                font: font.0.clone(),
                font_size: 16.0,
                color: Color::srgb(0.7, 0.8, 0.7),
            },
        )
        .with_style(Style {
            position_type: PositionType::Absolute,
            right: Val::Px(12.0),
            top: Val::Px(12.0),
            ..default()
        }),
        HelpText,
    ));
}

fn poll_network_events(
    mut commands: Commands,
    bridge: Res<NetworkBridge>,
    config: Res<ClientConfig>,
    mut session: ResMut<SessionState>,
    mut world: ResMut<WorldState>,
    mut chat: ResMut<ChatState>,
) {
    let receiver = bridge.event_rx.lock().expect("network receiver poisoned");
    loop {
        match receiver.try_recv() {
            Ok(NetEvent::Connected) => {
                session.status = SessionStatus::Connecting;
                session.last_info = Some("TCP connected".to_string());
                if config.token_ready() {
                    let request_id = session.allocate_request(PendingRequest::Auth);
                    let _ =
                        bridge
                            .command_tx
                            .send(NetCommand::SendTcp(ClientMessage::AuthRequest {
                                request_id,
                                username: session.username.clone(),
                                token: session.token.clone(),
                            }));
                    session.status = SessionStatus::Authenticating;
                } else {
                    session.last_error = Some(
                        "Missing HMF_AUTH_TOKEN; get a token from /ingame/login and copy `code` from the redirect URL".to_string(),
                    );
                }
            }
            Ok(NetEvent::Disconnected(reason)) => {
                session.status = SessionStatus::Disconnected;
                session.transport = TransportMode::TcpOnly;
                session.last_error = Some(reason);
                session.pending.clear();
            }
            Ok(NetEvent::TransportMode(mode)) => {
                session.transport = mode;
                session.last_info = Some(match mode {
                    TransportMode::TcpOnly => "Transport: TCP".to_string(),
                    TransportMode::UdpAttached => "Transport: UDP fast lane".to_string(),
                });
            }
            Ok(NetEvent::Error(error)) => {
                session.last_error = Some(error.clone());
                chat.push_log(format!("[net] {error}"));
            }
            Ok(NetEvent::Message(message)) => {
                handle_server_message(
                    &mut commands,
                    &bridge.command_tx,
                    &config,
                    &mut session,
                    &mut world,
                    &mut chat,
                    message,
                );
            }
            Err(TryRecvError::Empty) => break,
            Err(TryRecvError::Disconnected) => break,
        }
    }
}

fn reconnect_input(
    keyboard: Res<ButtonInput<KeyCode>>,
    bridge: Res<NetworkBridge>,
    config: Res<ClientConfig>,
    mut session: ResMut<SessionState>,
    mut chat: ResMut<ChatState>,
) {
    if keyboard.just_pressed(KeyCode::KeyR) {
        let _ = bridge.command_tx.send(NetCommand::Connect {
            tcp_addr: config.gate_tcp_addr,
        });
        session.status = SessionStatus::Connecting;
        session.last_error = None;
        chat.push_log(format!("Connecting to {}", config.gate_tcp_addr));
    }

    if keyboard.just_pressed(KeyCode::KeyX) {
        let _ = bridge.command_tx.send(NetCommand::Disconnect);
        chat.push_log("Disconnected".to_string());
    }
}

fn chat_keyboard_input(
    keyboard: Res<ButtonInput<KeyCode>>,
    mut key_events: EventReader<KeyboardInput>,
    bridge: Res<NetworkBridge>,
    mut session: ResMut<SessionState>,
    mut chat: ResMut<ChatState>,
) {
    if keyboard.just_pressed(KeyCode::Enter) && !chat.input_mode {
        chat.input_mode = true;
        chat.input_buffer.clear();
        return;
    }

    if !chat.input_mode {
        return;
    }

    if keyboard.just_pressed(KeyCode::Escape) {
        chat.input_mode = false;
        chat.input_buffer.clear();
        return;
    }

    if keyboard.just_pressed(KeyCode::Backspace) {
        chat.input_buffer.pop();
    }

    for event in key_events.read() {
        if !event.state.is_pressed() {
            continue;
        }

        if let Key::Character(value) = &event.logical_key {
            if !value.chars().any(|ch| ch.is_control()) {
                chat.input_buffer.push_str(value);
            }
        }
    }

    if keyboard.just_pressed(KeyCode::Enter) {
        let text = chat.input_buffer.trim().to_string();
        if !text.is_empty() && session.status == SessionStatus::InScene {
            let request_id = session.allocate_request(PendingRequest::Chat);
            let _ = bridge
                .command_tx
                .send(NetCommand::SendTcp(ClientMessage::ChatSay {
                    request_id,
                    text: text.clone(),
                }));
            chat.push_log(format!("[you] {text}"));
        }
        chat.input_mode = false;
        chat.input_buffer.clear();
    }
}

fn heartbeat_and_timesync(
    time: Res<Time>,
    bridge: Res<NetworkBridge>,
    mut session: ResMut<SessionState>,
    mut heartbeat: ResMut<HeartbeatTicker>,
    mut timesync: ResMut<TimeSyncTicker>,
) {
    if session.status != SessionStatus::Authenticated && session.status != SessionStatus::InScene {
        return;
    }

    heartbeat.0.tick(time.delta());
    if heartbeat.0.just_finished() {
        let _ = bridge
            .command_tx
            .send(NetCommand::SendTcp(ClientMessage::Heartbeat {
                timestamp: now_millis(),
            }));
    }

    timesync.0.tick(time.delta());
    if timesync.0.just_finished() {
        let request_id = session.allocate_request(PendingRequest::TimeSync);
        let _ = bridge
            .command_tx
            .send(NetCommand::SendTcp(ClientMessage::TimeSync {
                request_id,
                client_send_ts: now_millis(),
            }));
    }
}

fn movement_input(
    time: Res<Time>,
    keyboard: Res<ButtonInput<KeyCode>>,
    bridge: Res<NetworkBridge>,
    mut session: ResMut<SessionState>,
    world: Res<WorldState>,
    mut ticker: ResMut<MovementTicker>,
    chat: Res<ChatState>,
) {
    if session.status != SessionStatus::InScene || chat.input_mode {
        return;
    }

    ticker.0.tick(time.delta());
    if !ticker.0.just_finished() {
        return;
    }

    let mut axis = Vec2::ZERO;
    if keyboard.pressed(KeyCode::KeyW) || keyboard.pressed(KeyCode::ArrowUp) {
        axis.y += 1.0;
    }
    if keyboard.pressed(KeyCode::KeyS) || keyboard.pressed(KeyCode::ArrowDown) {
        axis.y -= 1.0;
    }
    if keyboard.pressed(KeyCode::KeyA) || keyboard.pressed(KeyCode::ArrowLeft) {
        axis.x -= 1.0;
    }
    if keyboard.pressed(KeyCode::KeyD) || keyboard.pressed(KeyCode::ArrowRight) {
        axis.x += 1.0;
    }

    if axis == Vec2::ZERO {
        return;
    }

    let Some(player) = world.players.get(&session.cid).cloned() else {
        return;
    };

    let velocity = axis.normalize() * 260.0;
    let dt = ticker.0.duration().as_secs_f64();
    let desired = NetVec3::new(
        player.location.x + velocity.x as f64 * dt,
        player.location.y + velocity.y as f64 * dt,
        player.location.z,
    );

    let request_id = session.allocate_request(PendingRequest::Movement);
    let message = ClientMessage::Movement {
        request_id,
        cid: session.cid,
        timestamp: now_millis(),
        location: desired,
        velocity: NetVec3::new(velocity.x as f64, velocity.y as f64, 0.0),
        acceleration: NetVec3::ZERO,
    };

    let _ = bridge.command_tx.send(NetCommand::SendMovement(message));
}

fn skill_input(
    keyboard: Res<ButtonInput<KeyCode>>,
    bridge: Res<NetworkBridge>,
    mut session: ResMut<SessionState>,
    mut chat: ResMut<ChatState>,
) {
    if session.status != SessionStatus::InScene || chat.input_mode {
        return;
    }

    if keyboard.just_pressed(KeyCode::Space) {
        let request_id = session.allocate_request(PendingRequest::Skill);
        let _ = bridge
            .command_tx
            .send(NetCommand::SendTcp(ClientMessage::SkillCast {
                request_id,
                skill_id: 1,
            }));
        chat.push_log("[you] cast Pulse".to_string());
    }
}

fn sync_player_visuals(
    mut commands: Commands,
    mut world: ResMut<WorldState>,
    mut query: Query<(Entity, &PlayerVisual, &mut Transform, &mut Sprite)>,
) {
    let known_cids: Vec<i64> = world.players.keys().copied().collect();

    for (entity, visual, mut transform, mut sprite) in query.iter_mut() {
        if let Some(player) = world.players.get(&visual.cid) {
            transform.translation = world_to_translation(player.location, player.is_local);
            sprite.color = if player.is_local {
                Color::srgb(0.35, 0.95, 0.55)
            } else {
                Color::srgb(0.35, 0.65, 1.0)
            };
        } else {
            commands.entity(entity).despawn_recursive();
            world.entities.remove(&visual.cid);
        }
    }

    for cid in known_cids {
        if world.entities.contains_key(&cid) {
            continue;
        }
        let Some(player) = world.players.get(&cid) else {
            continue;
        };
        let entity = commands
            .spawn((
                SpriteBundle {
                    sprite: Sprite {
                        color: if player.is_local {
                            Color::srgb(0.35, 0.95, 0.55)
                        } else {
                            Color::srgb(0.35, 0.65, 1.0)
                        },
                        custom_size: Some(Vec2::splat(20.0)),
                        ..default()
                    },
                    transform: Transform::from_translation(world_to_translation(
                        player.location,
                        player.is_local,
                    )),
                    ..default()
                },
                PlayerVisual { cid },
            ))
            .id();
        world.entities.insert(cid, entity);
    }
}

fn skill_effect_lifetime(
    mut commands: Commands,
    time: Res<Time>,
    mut query: Query<(Entity, &mut SkillEffectVisual, &mut Sprite)>,
) {
    for (entity, mut effect, mut sprite) in query.iter_mut() {
        effect.timer.tick(time.delta());
        let progress = effect.timer.fraction_remaining();
        sprite.color = sprite.color.with_alpha(progress);
        if effect.timer.finished() {
            commands.entity(entity).despawn_recursive();
        }
    }
}

fn update_ui_text(
    session: Res<SessionState>,
    chat: Res<ChatState>,
    world: Res<WorldState>,
    mut status_query: Query<&mut Text, With<StatusText>>,
    mut chat_log_query: Query<&mut Text, (With<ChatLogText>, Without<StatusText>)>,
    mut chat_input_query: Query<&mut Text, (With<ChatInputText>, Without<ChatLogText>)>,
    mut help_query: Query<&mut Text, (With<HelpText>, Without<ChatInputText>)>,
) {
    let player_count = world.players.len();
    for mut text in &mut status_query {
        text.sections[0].value = format!(
            "status: {:?}\ntransport: {:?}\nuser: {} cid={}\nplayers in AOI: {}\nrtt: {:?} ms\noffset: {:?} ms\nlast error: {}\nlast info: {}",
            session.status,
            session.transport,
            session.username,
            session.cid,
            player_count,
            session.rtt_ms,
            session.clock_offset_ms,
            session
                .last_error
                .clone()
                .unwrap_or_else(|| "-".to_string()),
            session.last_info.clone().unwrap_or_else(|| "-".to_string())
        );
    }

    for mut text in &mut chat_log_query {
        text.sections[0].value = chat.log.iter().cloned().collect::<Vec<_>>().join("\n");
    }

    for mut text in &mut chat_input_query {
        text.sections[0].value = if chat.input_mode {
            format!("> {}", chat.input_buffer)
        } else {
            "Press Enter to chat".to_string()
        };
    }

    for mut text in &mut help_query {
        text.sections[0].value =
            "WASD/Arrows move\nEnter chat\nSpace cast Pulse\nR connect\nX disconnect".to_string();
    }
}

fn handle_server_message(
    commands: &mut Commands,
    command_tx: &Sender<NetCommand>,
    config: &ClientConfig,
    session: &mut SessionState,
    world: &mut WorldState,
    chat: &mut ChatState,
    message: ServerMessage,
) {
    match message {
        ServerMessage::Result {
            packet_id,
            ok,
            movement,
        } => match session.complete_request(packet_id) {
            Some(PendingRequest::Auth) => {
                if ok {
                    session.status = SessionStatus::Authenticated;
                    session.last_info = Some("Auth ok".to_string());
                    let request_id = session.allocate_request(PendingRequest::EnterScene);
                    let _ = command_tx.send(NetCommand::SendTcp(ClientMessage::EnterScene {
                        request_id,
                        cid: session.cid,
                    }));
                } else {
                    session.status = SessionStatus::Disconnected;
                    session.last_error = Some("Auth failed".to_string());
                }
            }
            Some(PendingRequest::Movement) => {
                if let Some(MovementAck { cid, location }) = movement {
                    upsert_player(world, cid, location, cid == session.cid);
                } else if !ok {
                    session.last_error = Some("Movement rejected by server".to_string());
                }
            }
            Some(PendingRequest::Chat) => {
                if !ok {
                    session.last_error = Some("Chat rejected by server".to_string());
                }
            }
            Some(PendingRequest::Skill) => {
                if !ok {
                    session.last_error = Some("Skill rejected by server".to_string());
                    chat.push_log("[system] skill rejected".to_string());
                }
            }
            Some(PendingRequest::FastLaneRequest) => {
                if !ok {
                    session.last_error = Some("Fast lane request rejected".to_string());
                }
            }
            Some(PendingRequest::TimeSync) => {
                if !ok {
                    session.last_error = Some("TimeSync rejected".to_string());
                }
            }
            _ => {}
        },
        ServerMessage::EnterSceneResult {
            packet_id,
            ok,
            location,
        } => {
            let _ = session.complete_request(packet_id);
            if ok {
                session.status = SessionStatus::InScene;
                if let Some(location) = location {
                    upsert_player(world, session.cid, location, true);
                }
                session.last_info = Some("Entered scene".to_string());
                chat.push_log("[system] entered scene".to_string());
                if config.use_fast_lane {
                    let request_id = session.allocate_request(PendingRequest::FastLaneRequest);
                    let _ = command_tx.send(NetCommand::SendTcp(ClientMessage::FastLaneRequest {
                        request_id,
                    }));
                }
            } else {
                session.last_error = Some("EnterScene failed".to_string());
            }
        }
        ServerMessage::PlayerEnter { cid, location } => {
            if cid != session.cid {
                upsert_player(world, cid, location, false);
                chat.push_log(format!("[aoi] player {cid} entered"));
            }
        }
        ServerMessage::PlayerLeave { cid } => {
            world.players.remove(&cid);
            chat.push_log(format!("[aoi] player {cid} left"));
        }
        ServerMessage::PlayerMove { cid, location } => {
            upsert_player(world, cid, location, cid == session.cid);
        }
        ServerMessage::TimeSyncReply {
            packet_id,
            client_send_ts,
            server_recv_ts,
            server_send_ts,
        } => {
            let _ = session.complete_request(packet_id);
            let now = now_millis();
            session.rtt_ms = Some(now.saturating_sub(client_send_ts));
            let server_midpoint = (server_recv_ts as i128 + server_send_ts as i128) / 2;
            let client_midpoint = (client_send_ts as i128 + now as i128) / 2;
            session.clock_offset_ms = Some(server_midpoint - client_midpoint);
        }
        ServerMessage::HeartbeatReply { timestamp } => {
            session.last_heartbeat_ts = Some(timestamp);
        }
        ServerMessage::FastLaneResult {
            packet_id,
            ok,
            udp_port,
            ticket,
        } => {
            let _ = session.complete_request(packet_id);
            if ok {
                let attach_id = session.allocate_request(PendingRequest::FastLaneAttach);
                if let (Some(udp_port), Some(ticket)) = (udp_port, ticket) {
                    let _ = command_tx.send(NetCommand::AttachUdp {
                        gate_host: config.gate_host,
                        udp_port,
                        ticket,
                        request_id: attach_id,
                    });
                    chat.push_log("[net] requested UDP attach".to_string());
                }
            } else {
                session.last_error = Some("Fast lane bootstrap denied".to_string());
            }
        }
        ServerMessage::FastLaneAttached { packet_id, ok } => {
            let _ = session.complete_request(packet_id);
            if ok {
                session.transport = TransportMode::UdpAttached;
                chat.push_log("[net] UDP fast lane attached".to_string());
            } else {
                session.transport = TransportMode::TcpOnly;
                session.last_error = Some("UDP attach failed; falling back to TCP".to_string());
            }
        }
        ServerMessage::ChatMessage {
            cid,
            username,
            text,
        } => {
            chat.push_log(format!("[{cid}:{username}] {text}"));
        }
        ServerMessage::SkillEvent {
            cid,
            skill_id,
            location,
        } => {
            spawn_skill_effect(commands, location, cid == session.cid);
            chat.push_log(format!("[skill] cid={cid} skill={skill_id}"));
        }
    }
}

fn upsert_player(world: &mut WorldState, cid: i64, location: NetVec3, is_local: bool) {
    world
        .players
        .insert(cid, PlayerState { location, is_local });
}

fn spawn_skill_effect(commands: &mut Commands, location: NetVec3, local: bool) {
    commands.spawn((
        SpriteBundle {
            sprite: Sprite {
                color: if local {
                    Color::srgba(1.0, 0.85, 0.25, 0.8)
                } else {
                    Color::srgba(1.0, 0.35, 0.35, 0.8)
                },
                custom_size: Some(Vec2::splat(42.0)),
                ..default()
            },
            transform: Transform::from_translation(
                world_to_translation(location, false) + bevy::prelude::Vec3::Y * 10.0,
            ),
            ..default()
        },
        SkillEffectVisual {
            timer: Timer::from_seconds(0.35, TimerMode::Once),
        },
    ));
}

fn spawn_grid(commands: &mut Commands) {
    let extent = 1200.0;
    let color = Color::srgba(0.2, 0.25, 0.3, 0.35);
    for i in -6..=6 {
        let offset = i as f32 * 100.0;
        commands.spawn(SpriteBundle {
            sprite: Sprite {
                color,
                custom_size: Some(Vec2::new(2.0, extent)),
                ..default()
            },
            transform: Transform::from_xyz(offset, 0.0, -1.0),
            ..default()
        });
        commands.spawn(SpriteBundle {
            sprite: Sprite {
                color,
                custom_size: Some(Vec2::new(extent, 2.0)),
                ..default()
            },
            transform: Transform::from_xyz(0.0, offset, -1.0),
            ..default()
        });
    }
}

fn world_to_translation(location: NetVec3, local: bool) -> bevy::prelude::Vec3 {
    bevy::prelude::Vec3::new(
        location.x as f32,
        location.y as f32,
        if local { 10.0 } else { 5.0 },
    )
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time before unix epoch")
        .as_millis() as u64
}

fn resolve_asset_path() -> String {
    let repo_relative = Path::new("clients/bevy_client/assets");
    if repo_relative.exists() {
        return repo_relative.display().to_string();
    }
    "assets".to_string()
}
