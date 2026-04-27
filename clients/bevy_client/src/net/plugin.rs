//! `NetworkPlugin` — drains `NetworkEvent`s queued by the background
//! network thread and projects them into the Bevy world (`WorldState`,
//! prediction state, effect cues, etc.).

use bevy::prelude::*;

use crate::app::{
    LocalRenderPrediction, MovementDispatchState, WorldState, net_to_world, push_line,
    schedule::ClientSet, sim_to_render_position,
};
use crate::effects::{EffectVisual, effect_spawn_translation};
use crate::login::AppState;
use crate::stdio::{ClientStdioInterface, emit as emit_stdio};
use crate::world::remote_actor::RemoteActorIdentity;
use crate::world::remote_player::RemotePlayerState;

use super::events::{MessageTransport, NetworkBridge, NetworkEvent};

pub struct NetworkPlugin;

impl Plugin for NetworkPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(
            Update,
            poll_network_events
                .in_set(ClientSet::Network)
                .run_if(in_state(AppState::Game)),
        );
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
    let receiver = match bridge.rx.lock() {
        Ok(receiver) => receiver,
        Err(poisoned) => {
            // Audit E-S2: poisoned NetworkBridge mutex means the network
            // thread panicked while holding the lock. Surface it through
            // WorldState so the operator sees a definitive error in HUD /
            // stdio instead of silent freeze. Recover the inner receiver to
            // continue draining events that may have arrived before the
            // panic.
            let recovered = poisoned.into_inner();
            world_state.status =
                "network bridge mutex poisoned (network thread panicked)".to_string();
            push_line(
                &mut world_state.logs,
                "network bridge mutex poisoned; receiver recovered, but the network thread is dead — please restart"
                    .to_string(),
            );
            recovered
        }
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
                movement_mode,
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
                    movement_mode,
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
