//! Server-attached headless modes: scripted (`run`) and stdio-driven
//! (`run_stdio`).

use std::sync::mpsc::TryRecvError;
use std::thread;
use std::time::{Duration, Instant};

use bevy::prelude::Vec2;

use crate::config::{ClientConfig, SessionCredentials};
use crate::input::commands::{MOVEMENT_FLAG_BRAKE, MOVEMENT_FLAG_JUMP};
use crate::net::{NetworkBridge, NetworkCommand, spawn_network_thread};
use crate::observe::ClientObserver;
use crate::skill::prepare_skill_dispatch;
use crate::stdio::{
    ClientStdioCommand, ClientStdioInterface, SnapshotFields, emit as emit_stdio,
    emit_owned as emit_stdio_owned, snapshot_fields,
};
use crate::voxel::execute_voxel_cli_command;

use super::script::{HeadlessAction, parse_script};
use super::state::{
    HeadlessState, apply_event, format_net_vec, format_players, format_vec3, vec3_to_net,
    voxel_save_dir,
};

/// Options controlling scripted headless runs.
#[derive(Clone, Debug)]
pub struct HeadlessOptions {
    pub script: String,
    pub wait_for_scene_ms: u64,
    pub drain_after_script_ms: u64,
}

impl Default for HeadlessOptions {
    fn default() -> Self {
        Self {
            script: "wait:500,move:w:600,move:d:600,chat:headless hello,wait:1500".to_string(),
            wait_for_scene_ms: 8_000,
            drain_after_script_ms: 1_500,
        }
    }
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

/// Runs the headless client while exposing the same attached stdio interface
/// as the GUI mode.
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
        drain_pending_resyncs(&bridge, &mut state);

        if let Some(command) = stdio.try_recv() {
            match command {
                ClientStdioCommand::Snapshot => {
                    let mut fields = snapshot_fields(SnapshotFields {
                        status: &state.status,
                        scene_joined: state.scene_joined,
                        local_cid: state.local_cid,
                        local_position: state.local_position,
                        local_hp: state.local_hp,
                        local_max_hp: state.local_max_hp,
                        local_alive: state.local_alive,
                        movement_transport: state.movement_transport.label(),
                        fast_lane_status: &state.fast_lane_status,
                        // Parity with the GUI snapshot (stdio/plugin.rs): count
                        // PLAYER-kind identities, not raw remote_players.len()
                        // (which also includes NPCs + any self echo) — else the
                        // two harnesses report different remote_player_count for
                        // the same world, undermining the harness as a truth source.
                        remote_player_count: state
                            .remote_actor_identity
                            .values()
                            .filter(|identity| {
                                matches!(identity.kind, crate::world::remote_actor::RemoteActorKind::Player)
                            })
                            .count(),
                        remote_npc_count: state
                            .remote_actor_identity
                            .values()
                            .filter(|identity| identity.is_npc())
                            .count(),
                    });
                    fields.push(("voxel_sync", "offline-local".to_string()));
                    fields.push((
                        "voxel_solid_cells",
                        state.voxel_world.total_solid_cells().to_string(),
                    ));
                    fields.push((
                        "voxel_hotbar",
                        (state.voxel_world.hotbar().selected_index + 1).to_string(),
                    ));
                    fields.push(("voxel_selected", state.voxel_world.hotbar().selected.label));
                    emit_stdio("snapshot", &fields);
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
                    let transport_or = |t: Option<crate::net::MessageTransport>| {
                        t.map(|v| v.label().to_string())
                            .unwrap_or_else(|| "n/a".to_string())
                    };
                    emit_stdio(
                        "transport",
                        &[
                            (
                                "control_transport",
                                state.control_transport.label().to_string(),
                            ),
                            (
                                "movement_transport",
                                state.movement_transport.label().to_string(),
                            ),
                            ("fast_lane_status", state.fast_lane_status.clone()),
                            ("last_local_transport", transport_or(state.last_local_transport)),
                            (
                                "last_remote_transport",
                                transport_or(state.last_remote_transport),
                            ),
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
                        .collect::<std::collections::HashMap<_, _>>();
                    emit_stdio("players", &[("players", format_players(&players))]);
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
                            Some(format!(
                                "{cid}:{}:{}",
                                identity.name,
                                format_vec3(*position)
                            ))
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
                    emit_stdio("target_point", &[("point", format_vec3(point))]);
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
                ClientStdioCommand::Skill {
                    skill_id,
                    target_cid,
                } => {
                    let dispatch = match prepare_skill_dispatch(
                        skill_id,
                        target_cid.or(state.selected_target_cid),
                        state.selected_target_point.map(vec3_to_net),
                        state.remote_players.len(),
                    ) {
                        Ok(dispatch) => dispatch,
                        Err(block) => {
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
                    observer.emit(
                        "headless",
                        "skill",
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
                                    .map(format_net_vec)
                                    .unwrap_or_else(|| "n/a".to_string()),
                            ),
                        ],
                    );
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
                                    .map(|value: i64| value.to_string())
                                    .unwrap_or_else(|| "auto".to_string()),
                            ),
                            (
                                "target_point",
                                dispatch
                                    .target_position
                                    .map(format_net_vec)
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
                        movement_flags: MOVEMENT_FLAG_BRAKE,
                    });
                    emit_stdio("stop", &[]);
                }
                ClientStdioCommand::Jump => {
                    bridge.send(NetworkCommand::MoveInputSample {
                        input_dir: [0.0, 0.0],
                        dt_ms: config.movement_interval_ms as u16,
                        speed_scale: 1.0,
                        movement_flags: MOVEMENT_FLAG_BRAKE | MOVEMENT_FLAG_JUMP,
                    });
                    emit_stdio("jump", &[("queued", "true".to_string())]);
                }
                ClientStdioCommand::ReconcileStats => {
                    bridge.send(NetworkCommand::RequestReconcileStats);
                    emit_stdio("reconcile_stats_requested", &[]);
                }
                ClientStdioCommand::DiagRender => {
                    emit_stdio(
                        "diag_render",
                        &[
                            (
                                "local_position",
                                state
                                    .local_position
                                    .map(|value| {
                                        format!("{:.2},{:.2},{:.2}", value.x, value.y, value.z)
                                    })
                                    .unwrap_or_else(|| "n/a".to_string()),
                            ),
                            ("drift", "n/a".to_string()),
                            ("mode", "headless".to_string()),
                        ],
                    );
                }
                ClientStdioCommand::Voxel(command) => {
                    let result = execute_voxel_cli_command(
                        &mut state.voxel_world,
                        command,
                        Some(&voxel_save_dir()),
                    );
                    emit_stdio_owned(&result.event, result.ok, &result.fields);
                }
                ClientStdioCommand::VoxelAuthorityStatus => {
                    emit_voxel_authority_status(&state.voxel_authority);
                }
                ClientStdioCommand::VoxelSubscribe {
                    logical_scene_id,
                    center,
                    radius,
                } => {
                    bridge.send(NetworkCommand::SubscribeChunks {
                        logical_scene_id,
                        center_chunk: center,
                        radius,
                    });
                    emit_stdio(
                        "va_subscribe_sent",
                        &[
                            ("scene_id", logical_scene_id.to_string()),
                            (
                                "center",
                                format!("{},{},{}", center[0], center[1], center[2]),
                            ),
                            ("radius", radius.to_string()),
                        ],
                    );
                }
                ClientStdioCommand::VoxelChunkInfo { coord } => {
                    crate::stdio::emit_voxel_chunk_info(&state.voxel_authority, coord);
                }
                ClientStdioCommand::VoxelEditLive {
                    logical_scene_id,
                    action,
                    target_macro,
                    material_id,
                } => {
                    bridge.send(NetworkCommand::EditVoxel {
                        logical_scene_id,
                        action,
                        target_macro,
                        material_id,
                    });
                    emit_stdio(
                        "va_edit_sent",
                        &[
                            (
                                "action",
                                if action == 0 { "place" } else { "break" }.to_string(),
                            ),
                            (
                                "target_macro",
                                format!(
                                    "{},{},{}",
                                    target_macro[0], target_macro[1], target_macro[2]
                                ),
                            ),
                            ("material_id", material_id.to_string()),
                        ],
                    );
                }
                ClientStdioCommand::VoxelFollow {
                    logical_scene_id,
                    radius,
                } => match state.local_position {
                    Some(pos) => {
                        let center = crate::net::plugin::voxel_chunk_of([
                            pos.x as f64,
                            pos.y as f64,
                            pos.z as f64,
                        ]);
                        bridge.send(NetworkCommand::SubscribeChunks {
                            logical_scene_id,
                            center_chunk: center,
                            radius,
                        });
                        emit_stdio(
                            "va_follow",
                            &[
                                ("position", format_vec3(pos)),
                                (
                                    "center_chunk",
                                    format!("{},{},{}", center[0], center[1], center[2]),
                                ),
                                ("radius", radius.to_string()),
                            ],
                        );
                    }
                    None => {
                        emit_stdio("va_follow", &[("error", "no local position yet".to_string())])
                    }
                },
                ClientStdioCommand::VoxelMacroInfo { global_macro } => {
                    crate::stdio::emit_voxel_macro_info(&state.voxel_authority, global_macro);
                }
                ClientStdioCommand::VoxelFields => {
                    crate::stdio::emit_voxel_fields(&state.field_store);
                }
                ClientStdioCommand::VoxelSemiconductors { chunk_coord } => {
                    crate::stdio::emit_voxel_semiconductors(
                        &state.voxel_authority,
                        &state.field_store,
                        chunk_coord,
                    );
                }
                ClientStdioCommand::VoxelSurfaceList { chunk_coord } => {
                    crate::stdio::emit_voxel_surface_list(&state.voxel_authority, chunk_coord);
                }
                ClientStdioCommand::ChatLog { count } => {
                    crate::stdio::emit_event_log("chat_log", &state.chat_log, count);
                }
                ClientStdioCommand::SkillLog { count } => {
                    crate::stdio::emit_event_log("skill_log", &state.skill_log, count);
                }
                ClientStdioCommand::CombatLog { count } => {
                    crate::stdio::emit_event_log("combat_log", &state.combat_log, count);
                }
                ClientStdioCommand::EffectLog { count } => {
                    crate::stdio::emit_event_log("effect_log", &state.effect_log, count);
                }
                ClientStdioCommand::Echo { text } => {
                    emit_stdio("echo", &[("text", text)]);
                }
                ClientStdioCommand::Wait { ms } => {
                    // Headless blocks the run loop, but keep draining network events so
                    // snapshots/deltas that arrive during the wait are applied (so a
                    // subsequent query sees fresh state). Poll in small slices.
                    let deadline = Instant::now() + Duration::from_millis(ms);
                    while Instant::now() < deadline {
                        drain_events_once(&bridge, &observer, &mut state)?;
                        drain_pending_resyncs(&bridge, &mut state);
                        thread::sleep(Duration::from_millis(10));
                    }
                    emit_stdio("wait", &[("ms", ms.to_string())]);
                }
                ClientStdioCommand::VoxelUnsubscribe {
                    logical_scene_id,
                    coord,
                } => {
                    bridge.send(NetworkCommand::UnsubscribeChunks {
                        logical_scene_id,
                        chunks: vec![coord],
                    });
                    state.voxel_authority.evict(coord);
                    emit_stdio(
                        "va_unsubscribe_sent",
                        &[("coord", format!("{},{},{}", coord[0], coord[1], coord[2]))],
                    );
                }
                ClientStdioCommand::VoxelPrefabPlace {
                    logical_scene_id,
                    blueprint_id,
                    anchor_macro,
                    rotation,
                } => {
                    bridge.send(NetworkCommand::PlacePrefab {
                        logical_scene_id,
                        blueprint_id,
                        anchor_macro,
                        rotation,
                    });
                    emit_stdio(
                        "va_prefab_sent",
                        &[
                            ("blueprint_id", blueprint_id.to_string()),
                            (
                                "anchor_macro",
                                format!("{},{},{}", anchor_macro[0], anchor_macro[1], anchor_macro[2]),
                            ),
                            ("rotation", rotation.to_string()),
                        ],
                    );
                }
                ClientStdioCommand::VoxelSurfacePlace {
                    logical_scene_id,
                    action,
                    host_macro,
                    face,
                    surface_type_id,
                } => {
                    bridge.send(NetworkCommand::PlaceSurfaceElement {
                        logical_scene_id,
                        action,
                        host_macro,
                        face,
                        surface_type_id,
                    });
                    emit_stdio(
                        "va_surface_sent",
                        &[
                            (
                                "action",
                                if action == 0 { "place" } else { "clear" }.to_string(),
                            ),
                            (
                                "host_macro",
                                format!("{},{},{}", host_macro[0], host_macro[1], host_macro[2]),
                            ),
                            ("face", face.to_string()),
                            ("surface_type_id", surface_type_id.to_string()),
                        ],
                    );
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

fn emit_voxel_authority_status(store: &crate::voxel::authority::VoxelAuthorityStore) {
    let mut total_quads = 0usize;
    let mut renderable_chunks = 0usize;
    for coord in store.chunk_coords() {
        if let Some(chunk) = store.chunk(coord) {
            let quads = crate::voxel::mesher::greedy_mesh_chunk(chunk, 1.0).quad_count();
            total_quads += quads;
            if quads > 0 {
                renderable_chunks += 1;
            }
        }
    }
    emit_stdio(
        "va_status",
        &[
            ("chunks", store.chunk_count().to_string()),
            ("renderable_chunks", renderable_chunks.to_string()),
            ("total_quads", total_quads.to_string()),
        ],
    );
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
            let dispatch = match prepare_skill_dispatch(
                skill_id,
                state.selected_target_cid,
                state.selected_target_point.map(vec3_to_net),
                state.remote_players.len(),
            ) {
                Ok(dispatch) => dispatch,
                Err(block) => {
                    observer.emit(
                        "headless",
                        "skill_blocked",
                        &[
                            ("skill_id", skill_id.to_string()),
                            ("reason", block.reason.to_string()),
                            ("hint", block.hint.to_string()),
                        ],
                    );
                    return Err(format!("skill {skill_id} blocked: {}", block.reason));
                }
            };
            observer.emit("headless", "skill", &[("skill_id", skill_id.to_string())]);
            bridge.send(NetworkCommand::CastSkillTargeted {
                skill_id,
                target_cid: dispatch.target_cid,
                target_position: dispatch.target_position,
            });
            drain_events_for(bridge, observer, state, Duration::from_millis(250))
        }
        HeadlessAction::Jump => {
            observer.emit("headless", "jump", &[]);
            bridge.send(NetworkCommand::MoveInputSample {
                input_dir: [0.0, 0.0],
                dt_ms: config.movement_interval_ms as u16,
                speed_scale: 1.0,
                movement_flags: MOVEMENT_FLAG_BRAKE | MOVEMENT_FLAG_JUMP,
            });
            drain_events_for(bridge, observer, state, Duration::from_millis(350))
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
        movement_flags: MOVEMENT_FLAG_BRAKE,
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

/// Drains queued resync requests into radius-0 re-subscribes (mirrors the GUI's
/// resync ECS system), so the harness re-pulls fresh snapshots after a delta-base
/// mismatch instead of holding stale chunk truth. Shared by the main loop + `wait`.
fn drain_pending_resyncs(bridge: &NetworkBridge, state: &mut HeadlessState) {
    if state.pending_resyncs.is_empty() {
        return;
    }
    let coords = std::mem::take(&mut state.pending_resyncs);
    for coord in coords {
        bridge.send(NetworkCommand::SubscribeChunks {
            logical_scene_id: 1,
            center_chunk: coord,
            radius: 0,
        });
    }
}
