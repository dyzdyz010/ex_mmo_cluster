//! Headless client entrypoints used by automation and non-visual QA.

use crate::{
    config::{ClientConfig, SessionCredentials},
    net::{MessageTransport, NetworkBridge, NetworkCommand, NetworkEvent, spawn_network_thread},
    observe::ClientObserver,
    stdio::{ClientStdioCommand, ClientStdioInterface, emit as emit_stdio, snapshot_fields},
    world::remote_actor::RemoteActorIdentity,
};
use bevy::prelude::{Vec2, Vec3};
use std::{
    collections::HashMap,
    sync::mpsc::TryRecvError,
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Debug)]
/// Options controlling scripted headless runs.
pub struct HeadlessOptions {
    pub script: String,
    pub wait_for_scene_ms: u64,
    pub drain_after_script_ms: u64,
}

impl Default for HeadlessOptions {
    fn default() -> Self {
        Self {
            script: "wait:500,move:w:600,move:d:600,chat:headless hello,skill:1,wait:1500"
                .to_string(),
            wait_for_scene_ms: 8_000,
            drain_after_script_ms: 1_500,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
enum HeadlessAction {
    Wait(u64),
    Move {
        direction: Vec2,
        label: String,
        duration_ms: u64,
    },
    Chat(String),
    Skill(u16),
    Snapshot,
}

#[derive(Debug, Default)]
struct HeadlessState {
    status: String,
    scene_joined: bool,
    local_cid: i64,
    local_position: Option<Vec3>,
    local_hp: u16,
    local_max_hp: u16,
    local_alive: bool,
    remote_players: HashMap<i64, Vec3>,
    remote_actor_identity: HashMap<i64, RemoteActorIdentity>,
    selected_target_cid: Option<i64>,
    selected_target_point: Option<Vec3>,
    last_local_transport: Option<MessageTransport>,
    last_remote_transport: Option<MessageTransport>,
    movement_transport: MessageTransport,
    fast_lane_status: String,
}

/// Runs the client headlessly with a scripted action list.
pub fn run(
    config: ClientConfig,
    creds: SessionCredentials,
    observer: ClientObserver,
    options: HeadlessOptions,
) -> Result<(), String> {
    let actions = parse_script(&options.script)?;
    observer.emit(
        "headless",
        "start",
        &[
            ("gate_addr", config.gate_addr.clone()),
            ("username", creds.username.clone()),
            ("cid", creds.cid.to_string()),
            ("script", options.script.clone()),
        ],
    );

    let bridge = spawn_network_thread(config.clone(), creds.clone(), observer.clone());
    let mut state = HeadlessState::default();

    wait_for_scene(
        &bridge,
        &observer,
        &mut state,
        Duration::from_millis(options.wait_for_scene_ms),
    )?;

    for action in actions {
        run_action(&bridge, &config, &observer, &mut state, action)?;
    }

    drain_events_for(
        &bridge,
        &observer,
        &mut state,
        Duration::from_millis(options.drain_after_script_ms),
    )?;

    bridge.send(NetworkCommand::Shutdown);
    observer.emit(
        "headless",
        "completed",
        &[("final_status", state.status.clone())],
    );

    Ok(())
}

/// Runs the headless client while exposing the same attached stdio interface as the GUI mode.
pub fn run_stdio(
    config: ClientConfig,
    creds: SessionCredentials,
    observer: ClientObserver,
    stdio: ClientStdioInterface,
    wait_for_scene_ms: u64,
) -> Result<(), String> {
    observer.emit(
        "headless",
        "start",
        &[
            ("gate_addr", config.gate_addr.clone()),
            ("username", creds.username.clone()),
            ("cid", creds.cid.to_string()),
            ("mode", "stdio".to_string()),
        ],
    );

    let bridge = spawn_network_thread(config.clone(), creds.clone(), observer.clone());
    let mut state = HeadlessState::default();

    wait_for_scene(
        &bridge,
        &observer,
        &mut state,
        Duration::from_millis(wait_for_scene_ms),
    )?;

    loop {
        drain_events_once(&bridge, &observer, &mut state)?;

        if let Some(command) = stdio.try_recv() {
            match command {
                ClientStdioCommand::Snapshot => {
                    emit_stdio(
                        "snapshot",
                        &snapshot_fields(
                            &state.status,
                            state.scene_joined,
                            state.local_cid,
                            state.local_position,
                            state.local_hp,
                            state.local_max_hp,
                            state.local_alive,
                            state.movement_transport.label(),
                            &state.fast_lane_status,
                            state.remote_players.len(),
                            state
                                .remote_actor_identity
                                .values()
                                .filter(|identity| identity.is_npc())
                                .count(),
                        ),
                    );
                }
                ClientStdioCommand::Position => {
                    emit_stdio(
                        "position",
                        &[(
                            "local_position",
                            state
                                .local_position
                                .map(format_vec3)
                                .unwrap_or_else(|| "n/a".to_string()),
                        )],
                    );
                }
                ClientStdioCommand::Transport => {
                    emit_stdio(
                        "transport",
                        &[
                            (
                                "movement_transport",
                                state.movement_transport.label().to_string(),
                            ),
                            ("fast_lane_status", state.fast_lane_status.clone()),
                        ],
                    );
                }
                ClientStdioCommand::Players => {
                    let players = state
                        .remote_players
                        .iter()
                        .filter_map(|(cid, position)| {
                            let identity = state.remote_actor_identity.get(cid);
                            if identity.is_some() && identity.is_some_and(|value| value.is_npc()) {
                                return None;
                            }

                            Some((*cid, *position))
                        })
                        .collect::<HashMap<_, _>>();
                    emit_stdio(
                        "players",
                        &[("players", format_players(&players))],
                    );
                }
                ClientStdioCommand::Npcs => {
                    let mut npcs = state
                        .remote_actor_identity
                        .iter()
                        .filter_map(|(cid, identity)| {
                            if !identity.is_npc() {
                                return None;
                            }

                            let position = state.remote_players.get(cid)?;
                            Some(format!("{cid}:{}:{}", identity.name, format_vec3(*position)))
                        })
                        .collect::<Vec<_>>();
                    npcs.sort();
                    emit_stdio("npcs", &[("npcs", format!("[{}]", npcs.join(";")))]);
                }
                ClientStdioCommand::Target(target_cid) => {
                    state.selected_target_cid = Some(target_cid);
                    state.selected_target_point = None;
                    emit_stdio("target", &[("target_cid", target_cid.to_string())]);
                }
                ClientStdioCommand::ClearTarget => {
                    state.selected_target_cid = None;
                    emit_stdio("target_cleared", &[]);
                }
                ClientStdioCommand::TargetPoint(point) => {
                    state.selected_target_point = Some(point);
                    state.selected_target_cid = None;
                    emit_stdio(
                        "target_point",
                        &[("point", format_vec3(point))],
                    );
                }
                ClientStdioCommand::ClearTargetPoint => {
                    state.selected_target_point = None;
                    emit_stdio("target_point_cleared", &[]);
                }
                ClientStdioCommand::Chat(text) => {
                    observer.emit("headless", "chat", &[("text", text.clone())]);
                    bridge.send(NetworkCommand::Chat(text.clone()));
                    emit_stdio("chat_sent", &[("text", text)]);
                }
                ClientStdioCommand::Skill { skill_id, target_cid } => {
                    let target_cid = target_cid.or(state.selected_target_cid);
                    let target_position = if skill_id == 3 {
                        state.selected_target_point.map(vec3_to_net)
                    } else {
                        None
                    };
                    observer.emit(
                        "headless",
                        "skill",
                        &[
                            ("skill_id", skill_id.to_string()),
                            (
                                "target_cid",
                                target_cid
                                    .map(|value: i64| value.to_string())
                                    .unwrap_or_else(|| "auto".to_string()),
                            ),
                            (
                                "target_point",
                                target_position
                                    .map(|value| format_net_vec(value))
                                    .unwrap_or_else(|| "n/a".to_string()),
                            ),
                        ],
                    );
                    bridge.send(NetworkCommand::CastSkillTargeted {
                        skill_id,
                        target_cid,
                        target_position,
                    });
                    emit_stdio(
                        "skill_sent",
                        &[
                            ("skill_id", skill_id.to_string()),
                            (
                                "target_cid",
                                target_cid
                                    .map(|value: i64| value.to_string())
                                    .unwrap_or_else(|| "auto".to_string()),
                            ),
                            (
                                "target_point",
                                target_position
                                    .map(|value| format_net_vec(value))
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
                    run_move(
                        &bridge,
                        &config,
                        &observer,
                        &mut state,
                        direction,
                        &direction_label,
                        duration_ms,
                    )?;
                    emit_stdio(
                        "move_done",
                        &[
                            ("direction", direction_label),
                            (
                                "local_position",
                                state
                                    .local_position
                                    .map(format_vec3)
                                    .unwrap_or_else(|| "n/a".to_string()),
                            ),
                        ],
                    );
                }
                ClientStdioCommand::Stop => {
                    bridge.send(NetworkCommand::MoveInputSample {
                        input_dir: [0.0, 0.0],
                        dt_ms: config.movement_interval_ms as u16,
                        speed_scale: 1.0,
                        movement_flags: 0b10,
                    });
                    emit_stdio("stop", &[]);
                }
                ClientStdioCommand::Quit => {
                    bridge.send(NetworkCommand::Shutdown);
                    observer.emit(
                        "headless",
                        "completed",
                        &[("final_status", state.status.clone())],
                    );
                    emit_stdio("quit", &[("final_status", state.status.clone())]);
                    return Ok(());
                }
            }
        }

        thread::sleep(Duration::from_millis(25));
    }
}

fn wait_for_scene(
    bridge: &NetworkBridge,
    observer: &ClientObserver,
    state: &mut HeadlessState,
    timeout: Duration,
) -> Result<(), String> {
    let deadline = Instant::now() + timeout;

    while Instant::now() < deadline {
        drain_events_once(bridge, observer, state)?;
        if state.scene_joined {
            observer.emit(
                "headless",
                "scene_ready",
                &[
                    ("local_cid", state.local_cid.to_string()),
                    ("status", state.status.clone()),
                ],
            );
            return Ok(());
        }

        thread::sleep(Duration::from_millis(25));
    }

    Err(format!(
        "timed out waiting for scene join; last status={}",
        state.status
    ))
}

fn run_action(
    bridge: &NetworkBridge,
    config: &ClientConfig,
    observer: &ClientObserver,
    state: &mut HeadlessState,
    action: HeadlessAction,
) -> Result<(), String> {
    match action {
        HeadlessAction::Wait(ms) => {
            observer.emit("headless", "wait", &[("duration_ms", ms.to_string())]);
            drain_events_for(bridge, observer, state, Duration::from_millis(ms))
        }
        HeadlessAction::Move {
            direction,
            label,
            duration_ms,
        } => run_move(
            bridge,
            config,
            observer,
            state,
            direction,
            &label,
            duration_ms,
        ),
        HeadlessAction::Chat(text) => {
            observer.emit("headless", "chat", &[("text", text.clone())]);
            bridge.send(NetworkCommand::Chat(text));
            drain_events_for(bridge, observer, state, Duration::from_millis(250))
        }
        HeadlessAction::Skill(skill_id) => {
            let target_position = if skill_id == 3 {
                state.selected_target_point.map(vec3_to_net)
            } else {
                None
            };
            observer.emit("headless", "skill", &[("skill_id", skill_id.to_string())]);
            bridge.send(NetworkCommand::CastSkillTargeted {
                skill_id,
                target_cid: state.selected_target_cid,
                target_position,
            });
            drain_events_for(bridge, observer, state, Duration::from_millis(250))
        }
        HeadlessAction::Snapshot => {
            observer.emit(
                "headless",
                "snapshot",
                &[
                    ("status", state.status.clone()),
                    ("scene_joined", state.scene_joined.to_string()),
                    (
                        "local_position",
                        state
                            .local_position
                            .map(format_vec3)
                            .unwrap_or_else(|| "n/a".to_string()),
                    ),
                    (
                        "movement_transport",
                        state.movement_transport.label().to_string(),
                    ),
                    ("fast_lane_status", state.fast_lane_status.clone()),
                ],
            );
            Ok(())
        }
    }
}

fn run_move(
    bridge: &NetworkBridge,
    config: &ClientConfig,
    observer: &ClientObserver,
    state: &mut HeadlessState,
    direction: Vec2,
    label: &str,
    duration_ms: u64,
) -> Result<(), String> {
    let Some(start_position) = state.local_position else {
        return Err("cannot execute headless move before local position is known".to_string());
    };

    observer.emit(
        "headless",
        "move_begin",
        &[
            ("direction", label.to_string()),
            ("duration_ms", duration_ms.to_string()),
            ("start_position", format_vec3(start_position)),
        ],
    );

    let deadline = Instant::now() + Duration::from_millis(duration_ms);

    while Instant::now() < deadline {
        drain_events_once(bridge, observer, state)?;
        bridge.send(NetworkCommand::MoveInputSample {
            input_dir: [direction.x, direction.y],
            dt_ms: config.movement_interval_ms as u16,
            speed_scale: 1.0,
            movement_flags: 0,
        });
        thread::sleep(Duration::from_millis(config.movement_interval_ms));
    }

    bridge.send(NetworkCommand::MoveInputSample {
        input_dir: [0.0, 0.0],
        dt_ms: config.movement_interval_ms as u16,
        speed_scale: 1.0,
        movement_flags: 0b10,
    });

    observer.emit(
        "headless",
        "move_end",
        &[
            ("direction", label.to_string()),
            (
                "final_position",
                state
                    .local_position
                    .map(format_vec3)
                    .unwrap_or_else(|| "n/a".to_string()),
            ),
            (
                "last_ack_transport",
                state
                    .last_local_transport
                    .map(|transport| transport.label().to_string())
                    .unwrap_or_else(|| "n/a".to_string()),
            ),
        ],
    );

    drain_events_for(bridge, observer, state, Duration::from_millis(350))
}

fn drain_events_for(
    bridge: &NetworkBridge,
    observer: &ClientObserver,
    state: &mut HeadlessState,
    duration: Duration,
) -> Result<(), String> {
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        drain_events_once(bridge, observer, state)?;
        thread::sleep(Duration::from_millis(25));
    }
    Ok(())
}

fn drain_events_once(
    bridge: &NetworkBridge,
    observer: &ClientObserver,
    state: &mut HeadlessState,
) -> Result<(), String> {
    let receiver = bridge
        .rx
        .lock()
        .map_err(|_| "failed to lock network event receiver".to_string())?;

    loop {
        match receiver.try_recv() {
            Ok(event) => apply_event(observer, state, event),
            Err(TryRecvError::Empty) => return Ok(()),
            Err(TryRecvError::Disconnected) => {
                return Err("network event channel disconnected".to_string());
            }
        }
    }
}

fn apply_event(observer: &ClientObserver, state: &mut HeadlessState, event: NetworkEvent) {
    match event {
        NetworkEvent::Status(status) => state.status = status,
        NetworkEvent::EnteredScene { cid, location } => {
            state.scene_joined = true;
            state.local_cid = cid;
            state.local_position = Some(vec3_from_net(location));
            state.remote_players.clear();
            state.remote_actor_identity.clear();
        }
        NetworkEvent::LocalPosition {
            cid,
            location,
            velocity: _,
            transport,
        } => {
            state.local_cid = cid;
            state.local_position = Some(vec3_from_net(location));
            state.last_local_transport = Some(transport);
        }
        NetworkEvent::PlayerMove {
            transport,
            snapshot,
        } => {
            let cid = snapshot.cid;
            let location = [
                snapshot.position.x as f64,
                snapshot.position.y as f64,
                snapshot.position.z as f64,
            ];
            state.remote_players.insert(cid, vec3_from_net(location));
            state.last_remote_transport = Some(transport);
            observer.emit(
                "headless",
                "remote_move_seen",
                &[
                    ("cid", cid.to_string()),
                    ("server_tick", snapshot.server_tick.to_string()),
                    ("transport", transport.label().to_string()),
                    ("location", format_net_vec(location)),
                ],
            );
        }
        NetworkEvent::TransportState {
            movement_transport,
            fast_lane_status,
            ..
        } => {
            state.movement_transport = movement_transport;
            state.fast_lane_status = fast_lane_status;
        }
        NetworkEvent::Disconnected(reason) => {
            state.scene_joined = false;
            state.status = format!("disconnected: {reason}");
            state.remote_players.clear();
            state.remote_actor_identity.clear();
            state.selected_target_cid = None;
            state.selected_target_point = None;
        }
        NetworkEvent::PlayerEnter { cid, location } => {
            state.remote_players.insert(cid, vec3_from_net(location));
        }
        NetworkEvent::ActorIdentity { cid, kind, name } => {
            state.remote_actor_identity.insert(
                cid,
                RemoteActorIdentity { cid, kind, name },
            );
        }
        NetworkEvent::PlayerState {
            cid,
            hp,
            max_hp,
            alive,
        } => {
            if cid == state.local_cid {
                state.local_hp = hp;
                state.local_max_hp = max_hp;
                state.local_alive = alive;
            }
        }
        NetworkEvent::CombatHit {
            source_cid,
            target_cid,
            skill_id,
            damage,
            hp_after,
            ..
        } => {
            observer.emit(
                "headless",
                "combat_hit_seen",
                &[
                    ("source_cid", source_cid.to_string()),
                    ("target_cid", target_cid.to_string()),
                    ("skill_id", skill_id.to_string()),
                    ("damage", damage.to_string()),
                    ("hp_after", hp_after.to_string()),
                ],
            );
        }
        NetworkEvent::PlayerLeave { cid } => {
            state.remote_players.remove(&cid);
            state.remote_actor_identity.remove(&cid);
            if state.selected_target_cid == Some(cid) {
                state.selected_target_cid = None;
            }
        }
        NetworkEvent::EffectEvent {
            source_cid,
            skill_id,
            cue_kind,
            ..
        } => {
            observer.emit(
                "headless",
                "effect_seen",
                &[
                    ("source_cid", source_cid.to_string()),
                    ("skill_id", skill_id.to_string()),
                    ("cue_kind", format!("{cue_kind:?}")),
                ],
            );
        }
        NetworkEvent::Log(line) => {
            observer.emit("headless", "network_log", &[("line", line)]);
        }
        _ => {}
    }
}

fn parse_script(script: &str) -> Result<Vec<HeadlessAction>, String> {
    script
        .split(',')
        .map(str::trim)
        .filter(|segment| !segment.is_empty())
        .map(parse_action)
        .collect()
}

fn parse_action(segment: &str) -> Result<HeadlessAction, String> {
    let parts = segment.splitn(3, ':').collect::<Vec<_>>();

    match parts.as_slice() {
        ["wait", duration] => parse_u64(duration).map(HeadlessAction::Wait),
        ["move", direction, duration] => Ok(HeadlessAction::Move {
            direction: parse_direction(direction)?,
            label: (*direction).to_string(),
            duration_ms: parse_u64(duration)?,
        }),
        ["chat", text] => Ok(HeadlessAction::Chat((*text).to_string())),
        ["skill", skill_id] => parse_u16(skill_id).map(HeadlessAction::Skill),
        ["snapshot"] => Ok(HeadlessAction::Snapshot),
        _ => Err(format!("unsupported headless action segment: {segment}")),
    }
}

fn parse_direction(value: &str) -> Result<Vec2, String> {
    match value.to_ascii_lowercase().as_str() {
        "w" | "up" => Ok(Vec2::new(0.0, 1.0)),
        "s" | "down" => Ok(Vec2::new(0.0, -1.0)),
        "a" | "left" => Ok(Vec2::new(-1.0, 0.0)),
        "d" | "right" => Ok(Vec2::new(1.0, 0.0)),
        other => Err(format!("unsupported move direction: {other}")),
    }
}

fn parse_u64(value: &str) -> Result<u64, String> {
    value
        .parse::<u64>()
        .map_err(|error| format!("invalid integer {value:?}: {error}"))
}

fn parse_u16(value: &str) -> Result<u16, String> {
    value
        .parse::<u16>()
        .map_err(|error| format!("invalid skill id {value:?}: {error}"))
}

fn vec3_from_net(value: [f64; 3]) -> Vec3 {
    Vec3::new(value[0] as f32, value[1] as f32, value[2] as f32)
}

fn vec3_to_net(value: Vec3) -> [f64; 3] {
    [value.x as f64, value.y as f64, value.z as f64]
}

fn format_vec3(value: Vec3) -> String {
    format!("{:.1},{:.1},{:.1}", value.x, value.y, value.z)
}

fn format_net_vec(value: [f64; 3]) -> String {
    format!("{:.1},{:.1},{:.1}", value[0], value[1], value[2])
}

fn format_players(players: &HashMap<i64, Vec3>) -> String {
    let mut entries = players
        .iter()
        .map(|(cid, position)| {
            format!(
                "{cid}:{:.1},{:.1},{:.1}",
                position.x, position.y, position.z
            )
        })
        .collect::<Vec<_>>();
    entries.sort();
    format!("[{}]", entries.join(";"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_supported_headless_actions() {
        assert_eq!(
            parse_script("wait:500,move:w:600,chat:hello,skill:1,snapshot").unwrap(),
            vec![
                HeadlessAction::Wait(500),
                HeadlessAction::Move {
                    direction: Vec2::new(0.0, 1.0),
                    label: "w".to_string(),
                    duration_ms: 600,
                },
                HeadlessAction::Chat("hello".to_string()),
                HeadlessAction::Skill(1),
                HeadlessAction::Snapshot,
            ]
        );
    }

    #[test]
    fn rejects_invalid_direction() {
        let error = parse_script("move:q:100").unwrap_err();
        assert!(error.contains("unsupported move direction"));
    }
}
