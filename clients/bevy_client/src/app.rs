use crate::{
    config::ClientConfig,
    net::{NetworkBridge, NetworkCommand, NetworkEvent, spawn_network_thread},
};
use bevy::{
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
    local_cid: i64,
    local_position: Option<Vec3>,
    remote_players: HashMap<i64, Vec3>,
    chat_log: VecDeque<String>,
    logs: VecDeque<String>,
    last_rtt_ms: Option<f64>,
    last_offset_ms: Option<f64>,
    last_heartbeat_ts: Option<u64>,
}

#[derive(Resource, Default)]
struct ChatState {
    enabled: bool,
    draft: String,
}

#[derive(Resource)]
struct MovementTick(Timer);

pub fn run() {
    let config = ClientConfig::from_env();
    let bridge = spawn_network_thread(config.clone());

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
            ..default()
        })
        .insert_resource(ChatState::default())
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
        .add_systems(Startup, setup)
        .add_systems(
            Update,
            (
                poll_network_events,
                toggle_chat_mode,
                collect_chat_text,
                handle_skill_input,
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
                world_state.status = format!("in scene as cid {cid}");
                world_state.local_cid = cid;
                world_state.local_position = Some(net_to_world(location));
                push_line(&mut world_state.logs, format!("entered scene cid={cid}"));
            }
            NetworkEvent::LocalPosition { cid: _, location } => {
                world_state.local_position = Some(net_to_world(location));
            }
            NetworkEvent::PlayerEnter { cid, location } => {
                if cid != world_state.local_cid {
                    world_state
                        .remote_players
                        .insert(cid, net_to_world(location));
                }
                push_line(&mut world_state.logs, format!("player {cid} entered AOI"));
            }
            NetworkEvent::PlayerMove { cid, location } => {
                if cid != world_state.local_cid {
                    world_state
                        .remote_players
                        .insert(cid, net_to_world(location));
                }
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
            NetworkEvent::Log(line) => push_line(&mut world_state.logs, line),
            NetworkEvent::Disconnected(reason) => {
                world_state.status = format!("disconnected: {reason}");
                push_line(&mut world_state.logs, format!("disconnect: {reason}"));
            }
        }
    }
}

fn toggle_chat_mode(
    keyboard: Res<ButtonInput<KeyCode>>,
    bridge: Res<NetworkBridge>,
    mut chat_state: ResMut<ChatState>,
    mut world_state: ResMut<WorldState>,
) {
    if !chat_state.enabled && keyboard.just_pressed(KeyCode::Enter) {
        chat_state.enabled = true;
        return;
    }

    if chat_state.enabled && keyboard.just_pressed(KeyCode::Escape) {
        chat_state.enabled = false;
        chat_state.draft.clear();
        return;
    }

    if chat_state.enabled && keyboard.just_pressed(KeyCode::Enter) {
        let message = chat_state.draft.trim().to_string();
        if !message.is_empty() {
            bridge.send(NetworkCommand::Chat(message.clone()));
            push_line(&mut world_state.chat_log, format!("[me] {message}"));
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
    chat_state: Res<ChatState>,
) {
    if chat_state.enabled {
        return;
    }

    if keyboard.just_pressed(KeyCode::Digit1) {
        bridge.send(NetworkCommand::CastSkill(1));
    }
}

fn movement_sender(
    time: Res<Time>,
    keyboard: Res<ButtonInput<KeyCode>>,
    bridge: Res<NetworkBridge>,
    config: Res<ClientConfig>,
    world_state: Res<WorldState>,
    chat_state: Res<ChatState>,
    mut tick: ResMut<MovementTick>,
) {
    if chat_state.enabled || !world_state.status.starts_with("in scene") {
        return;
    }

    if !tick.0.tick(time.delta()).just_finished() {
        return;
    }

    let Some(position) = world_state.local_position else {
        return;
    };

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

    let velocity = if direction.length_squared() > 0.0 {
        let normalized = direction.normalize() * config.movement_speed;
        [normalized.x as f64, normalized.y as f64, 0.0]
    } else {
        [0.0, 0.0, 0.0]
    };

    bridge.send(NetworkCommand::Movement {
        location: [position.x as f64, position.y as f64, position.z as f64],
        velocity,
        acceleration: [0.0, 0.0, 0.0],
    });
}

fn sync_player_visuals(
    mut commands: Commands,
    world_state: Res<WorldState>,
    existing: Query<(Entity, &PlayerVisual)>,
) {
    let mut entities_by_cid = HashMap::new();
    for (entity, visual) in &existing {
        entities_by_cid.insert(visual.cid, entity);
    }

    let mut desired = world_state.remote_players.clone();
    if let Some(local) = world_state.local_position {
        desired.insert(world_state.local_cid, local);
    }

    for (&cid, &position) in &desired {
        if let Some(entity) = entities_by_cid.remove(&cid) {
            commands.entity(entity).insert(Transform::from_translation(
                position + Vec3::new(0.0, 0.0, 1.0),
            ));
        } else {
            let color = if cid == world_state.local_cid {
                Color::srgb(0.25, 0.95, 0.45)
            } else {
                Color::srgb(0.3, 0.65, 1.0)
            };

            commands.spawn((
                PlayerVisual { cid },
                Sprite::from_color(color, Vec2::splat(24.0)),
                Transform::from_translation(position + Vec3::new(0.0, 0.0, 1.0)),
            ));
        }
    }

    for (cid, entity) in entities_by_cid {
        if cid != world_state.local_cid {
            commands.entity(entity).despawn();
        }
    }
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
        "status: {}\nlocal cid: {}\nposition: {}\nrtt: {}\noffset: {}\nheartbeat: {}\ncontrols: WASD move | Enter chat | 1 pulse skill",
        world_state.status,
        world_state.local_cid,
        world_state
            .local_position
            .map(|pos| format!("{:.1}, {:.1}, {:.1}", pos.x, pos.y, pos.z))
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

    chat_log_text.0 = world_state
        .chat_log
        .iter()
        .rev()
        .take(8)
        .cloned()
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<Vec<_>>()
        .join("\n");

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
