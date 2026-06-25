//! `StdioPlugin` — registers `poll_stdio_commands` so stdin commands are
//! drained once per frame and translated into network/voxel/movement
//! mutations.

use bevy::app::AppExit;
use bevy::ecs::system::SystemParam;
use bevy::prelude::*;

use crate::app::{
    LocalRenderPrediction, MovementIntent, WorldState, push_line, schedule::ClientSet,
    voxel_save_dir,
};
use crate::login::AppState;
use crate::net::{NetworkBridge, NetworkCommand};
use crate::session::ConnectionState;
use crate::skill::prepare_skill_dispatch;
use crate::voxel::mesher::greedy_mesh_chunk;
use crate::voxel::{VoxelAuthority, VoxelWorld, execute_voxel_cli_command};
use crate::world::remote_actor::RemoteActorKind;

use super::{
    ClientStdioCommand, ClientStdioInterface, SnapshotFields, emit as emit_stdio,
    emit_owned as emit_stdio_owned, snapshot_fields,
};

pub struct StdioPlugin;

impl Plugin for StdioPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(
            Update,
            poll_stdio_commands
                .in_set(ClientSet::Stdio)
                .run_if(in_state(AppState::Game)),
        );
    }
}

#[derive(SystemParam)]
struct StdioCommandParams<'w> {
    time: Res<'w, Time>,
    stdio: Res<'w, ClientStdioInterface>,
    bridge: Res<'w, NetworkBridge>,
    local_render_prediction: Res<'w, LocalRenderPrediction>,
    voxel_world: ResMut<'w, VoxelWorld>,
    voxel_authority: Res<'w, VoxelAuthority>,
    world_state: ResMut<'w, WorldState>,
    connection: ResMut<'w, ConnectionState>,
    movement_intent: ResMut<'w, MovementIntent>,
    app_exit: MessageWriter<'w, AppExit>,
}

/// Maximum number of stdio commands processed per Bevy frame.
///
/// Audit E-L1: previously the loop drained the entire channel each frame,
/// so a 1000-command burst (replay scripts, fuzz harness, accidental
/// `cat huge_file.txt | ./bevy_client`) could starve the rest of the
/// schedule. With a per-frame budget the rest of the burst simply spills
/// to the next frame.
const STDIO_COMMANDS_PER_FRAME: usize = 16;

fn poll_stdio_commands(params: StdioCommandParams) {
    let StdioCommandParams {
        time,
        stdio,
        bridge,
        local_render_prediction,
        mut voxel_world,
        voxel_authority,
        mut world_state,
        mut connection,
        mut movement_intent,
        mut app_exit,
    } = params;

    let mut processed = 0usize;
    loop {
        if processed >= STDIO_COMMANDS_PER_FRAME {
            // Defer the remainder until the next frame to keep frame time
            // bounded under bursts.
            break;
        }
        let Some(command) = stdio.try_recv() else {
            break;
        };
        processed += 1;

        match command {
            ClientStdioCommand::Snapshot => {
                let mut fields = snapshot_fields(SnapshotFields {
                    status: &connection.status,
                    scene_joined: connection.scene_joined,
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
                        connection.status = message.clone();
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
            ClientStdioCommand::VoxelAuthorityStatus => {
                let store = &voxel_authority.store;
                let mut total_quads = 0usize;
                let mut renderable_chunks = 0usize;
                for coord in store.chunk_coords() {
                    if let Some(chunk) = store.chunk(coord) {
                        let quads = greedy_mesh_chunk(chunk, 1.0).quad_count();
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
            ClientStdioCommand::VoxelSubscribe {
                logical_scene_id,
                center,
                radius,
            } => {
                bridge.send(NetworkCommand::SubscribeChunks {
                    logical_scene_id,
                    center_chunk: center,
                    radius,
                    known: Vec::new(),
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
                crate::stdio::emit_voxel_chunk_info(&voxel_authority.store, coord);
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
                            format!("{},{},{}", target_macro[0], target_macro[1], target_macro[2]),
                        ),
                        ("material_id", material_id.to_string()),
                    ],
                );
            }
            ClientStdioCommand::VoxelFollow {
                logical_scene_id,
                radius,
            } => match world_state.local_position {
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
                        known: Vec::new(),
                    });
                    emit_stdio(
                        "va_follow",
                        &[
                            ("position", format!("{:.1},{:.1},{:.1}", pos.x, pos.y, pos.z)),
                            (
                                "center_chunk",
                                format!("{},{},{}", center[0], center[1], center[2]),
                            ),
                            ("radius", radius.to_string()),
                        ],
                    );
                }
                None => emit_stdio("va_follow", &[("error", "no local position yet".to_string())]),
            },
            ClientStdioCommand::VoxelMacroInfo { global_macro } => {
                crate::stdio::emit_voxel_macro_info(&voxel_authority.store, global_macro);
            }
            ClientStdioCommand::VoxelFields => {
                crate::stdio::emit_voxel_fields(&voxel_authority.field_store);
            }
            ClientStdioCommand::VoxelSemiconductors { chunk_coord } => {
                crate::stdio::emit_voxel_semiconductors(
                    &voxel_authority.store,
                    &voxel_authority.field_store,
                    chunk_coord,
                );
            }
            ClientStdioCommand::VoxelSurfaceList { chunk_coord } => {
                crate::stdio::emit_voxel_surface_list(&voxel_authority.store, chunk_coord);
            }
            ClientStdioCommand::ChatLog { count } => {
                crate::stdio::emit_event_log("chat_log", &world_state.chat_log, count);
            }
            ClientStdioCommand::SkillLog { count } => {
                crate::stdio::emit_event_log("skill_log", &world_state.skill_log, count);
            }
            ClientStdioCommand::CombatLog { count } => {
                crate::stdio::emit_event_log("combat_log", &world_state.combat_log, count);
            }
            ClientStdioCommand::EffectLog { count } => {
                crate::stdio::emit_event_log("effect_log", &world_state.effect_log, count);
            }
            ClientStdioCommand::Echo { text } => {
                emit_stdio("echo", &[("text", text)]);
            }
            ClientStdioCommand::Wait { ms } => {
                // The GUI is frame-driven; it must NOT block the schedule. Report the
                // request non-blocking so scripts know `wait` only truly blocks headless.
                emit_stdio(
                    "wait",
                    &[
                        ("ms", ms.to_string()),
                        ("gui_blocking", "false".to_string()),
                    ],
                );
            }
            ClientStdioCommand::VoxelUnsubscribe {
                logical_scene_id,
                coord,
            } => {
                // GUI: send the unsubscribe; local eviction is handled by the live
                // AOI follow path (voxel_authority is a read-only Res here).
                bridge.send(NetworkCommand::UnsubscribeChunks {
                    logical_scene_id,
                    chunks: vec![coord],
                });
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
                emit_stdio("quit", &[("final_status", connection.status.clone())]);
                app_exit.write(AppExit::Success);
            }
        }
    }
}
