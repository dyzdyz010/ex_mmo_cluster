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
use crate::session::ConnectionState;
use crate::stdio::{ClientStdioInterface, emit as emit_stdio};
use crate::world::remote_actor::RemoteActorIdentity;
use crate::world::remote_player::RemotePlayerState;

use super::events::{MessageTransport, NetworkBridge, NetworkCommand, NetworkEvent};

pub struct NetworkPlugin;

impl Plugin for NetworkPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<VoxelSubscribeRetry>().add_systems(
            Update,
            (poll_network_events, voxel_subscribe_retry)
                .in_set(ClientSet::Network)
                .run_if(in_state(AppState::Game)),
        );
    }
}

/// Bounded backoff for the post-join voxel subscribe: if the first subscribe
/// races the server's scene/region attach (the intermittent "chunks=0" with no
/// terrain), there is otherwise NO recovery for a stationary or chunk-interior
/// player (boundary-cross + resync can't bootstrap from zero chunks).
#[derive(Resource)]
struct VoxelSubscribeRetry {
    timer: Timer,
    attempts: u32,
}

impl Default for VoxelSubscribeRetry {
    fn default() -> Self {
        Self {
            timer: Timer::from_seconds(1.0, TimerMode::Repeating),
            attempts: 0,
        }
    }
}

// A freshly-booted server's scene/region/chunk-cold-load path is not ready the
// instant the client joins — empirically it can take tens of seconds before a
// subscribe streams any chunks (region lease settling, ChunkProcess cold load
// from PostgreSQL, beacon registration). The old 5×1s budget gave up inside that
// window, and a stationary / chunk-interior player has NO other recovery
// (boundary-cross + resync can't bootstrap from zero chunks), so the world
// stayed permanently empty. Keep retrying with a gentle backoff across a
// generous window (~90s) so the subscribe survives any realistic cold-start
// warm-up; the per-chunk-arrival reset below means a genuinely empty location
// still settles quickly without spamming forever.
const MAX_SUBSCRIBE_RETRIES: u32 = 40;
const SUBSCRIBE_RETRY_MAX_INTERVAL_SECS: f32 = 3.0;

fn voxel_subscribe_retry(
    time: Res<Time>,
    bridge: Res<NetworkBridge>,
    mut world_state: ResMut<WorldState>,
    connection: Res<ConnectionState>,
    mut voxel_aoi: ResMut<crate::voxel::VoxelAoiState>,
    mut voxel_authority: ResMut<crate::voxel::VoxelAuthority>,
    mut retry: ResMut<VoxelSubscribeRetry>,
) {
    if !retry.timer.tick(time.delta()).just_finished() {
        return;
    }
    // Only meaningful once joined with a subscription center recorded.
    let Some(center) = voxel_aoi.subscribed_center else {
        return;
    };
    if !connection.scene_joined {
        return;
    }
    // Terrain arrived → reset (interval + attempts) so a future genuine
    // zero-state (e.g. a fresh region after migration) can retry from scratch.
    if voxel_authority.store.chunk_count() > 0 {
        retry.attempts = 0;
        retry
            .timer
            .set_duration(std::time::Duration::from_secs_f32(1.0));
        return;
    }
    if retry.attempts >= MAX_SUBSCRIBE_RETRIES {
        return;
    }
    retry.attempts += 1;
    push_line(
        &mut world_state.logs,
        format!(
            "voxel subscribe retry {}/{} (0 chunks loaded)",
            retry.attempts, MAX_SUBSCRIBE_RETRIES
        ),
    );
    subscribe_voxel_around(
        &bridge,
        &mut world_state,
        &mut voxel_aoi,
        &mut voxel_authority,
        center,
    );
    // Gentle backoff: ramp the interval from 1s toward a 3s cap so 40 attempts
    // span ~90s of warm-up tolerance instead of hammering once per second.
    let next_interval =
        (1.0 + retry.attempts as f32 * 0.08).min(SUBSCRIBE_RETRY_MAX_INTERVAL_SECS);
    retry
        .timer
        .set_duration(std::time::Duration::from_secs_f32(next_interval));
    if retry.attempts == MAX_SUBSCRIBE_RETRIES {
        push_line(
            &mut world_state.logs,
            "voxel: still 0 chunks after max resubscribes (terrain may be absent server-side)"
                .to_string(),
        );
    }
}

/// One voxel chunk spans 16 macro × 100cm = 1600 server world units.
const VOXEL_CHUNK_WORLD_SIZE: f64 = 1600.0;

/// L∞ radius of the voxel subscription around the player's chunk. 2 covers the
/// default 5×5-chunk dev platform from spawn; the server caps radius at 4.
const VOXEL_SUBSCRIBE_RADIUS: u8 = 2;

/// Maps a server sim-space position (`[server_x, server_y, server_z]`) to its
/// containing voxel chunk coord.
///
/// Voxel/chunk space uses the **render** axis convention (chunk axis 1 = up =
/// server Z), the same convention as `chunk_translation`, the authority store,
/// and the avatar grounding path — and the server itself
/// (`SceneServer.Movement.VoxelCollision` maps movement `{x,y,z}` → voxel
/// `{x,z,y}`). So we MUST swap Y↔Z here, exactly like `sim_to_render_position`.
///
/// The omission was a real bug: dividing the raw sim position component-wise put
/// the horizontal `server_y` travel onto the *vertical* chunk axis while the
/// near-constant vertical `server_z` (~185) pinned the true horizontal chunk
/// axis at 0 — so AOI subscription stopped streaming terrain in the travel
/// direction and the player eventually walked into the void. At the default
/// spawn all three axes are < 1600 so every mapping collapses to `[0,0,0]`,
/// which is why it stayed hidden until the player moved.
pub(crate) fn voxel_chunk_of(location: [f64; 3]) -> [i32; 3] {
    [
        (location[0] / VOXEL_CHUNK_WORLD_SIZE).floor() as i32,
        (location[2] / VOXEL_CHUNK_WORLD_SIZE).floor() as i32,
        (location[1] / VOXEL_CHUNK_WORLD_SIZE).floor() as i32,
    ]
}

/// Chunks in the L∞ box of `radius` around `from` that are NOT in the box around
/// `to` — i.e. the chunks that fall out of the AOI as the center moves.
fn chunks_falling_out(from: [i32; 3], to: [i32; 3], radius: i32) -> Vec<[i32; 3]> {
    let mut dropped = Vec::new();
    for cx in (from[0] - radius)..=(from[0] + radius) {
        for cy in (from[1] - radius)..=(from[1] + radius) {
            for cz in (from[2] - radius)..=(from[2] + radius) {
                let in_new = (cx - to[0]).abs() <= radius
                    && (cy - to[1]).abs() <= radius
                    && (cz - to[2]).abs() <= radius;
                if !in_new {
                    dropped.push([cx, cy, cz]);
                }
            }
        }
    }
    dropped
}

/// Hysteresis margin (chunk units) past the anchor chunk's far boundary before the
/// AOI re-anchors (阶段4 step4.5). A boundary sits 0.5 chunks from the anchor
/// centre, so the player must travel 0.5 + this into the next chunk to re-centre —
/// small jitter on a boundary no longer thrashes subscribe/unsubscribe.
const VOXEL_AOI_HYSTERESIS: f64 = 0.35;

/// Minimum per-axis speed (server units/sec) to lead the subscription box one chunk
/// ahead along that axis (阶段4 step4.5 沿速度方向预取下一 slab). Below it the box
/// stays centred on the player.
const VOXEL_PREFETCH_SPEED: f64 = 200.0;

/// Player position in continuous voxel-chunk space (render-axis convention: chunk
/// axis 1 = up = server Z). `voxel_chunk_of` is exactly its component-wise floor.
fn voxel_chunk_pos(location: [f64; 3]) -> [f64; 3] {
    [
        location[0] / VOXEL_CHUNK_WORLD_SIZE,
        location[2] / VOXEL_CHUNK_WORLD_SIZE,
        location[1] / VOXEL_CHUNK_WORLD_SIZE,
    ]
}

/// One chunk lead along an axis once its speed clears `VOXEL_PREFETCH_SPEED`.
fn prefetch_lead(axis_velocity: f64) -> i32 {
    if axis_velocity > VOXEL_PREFETCH_SPEED {
        1
    } else if axis_velocity < -VOXEL_PREFETCH_SPEED {
        -1
    } else {
        0
    }
}

/// Decides the AOI subscription for a position update with hysteresis + directional
/// prefetch. Returns `Some((anchor, center))` to re-subscribe — `anchor` is the
/// player's own chunk (the hysteresis reference for next time) and `center` is the
/// possibly velocity-led box centre — or `None` to keep the current subscription.
///
/// `location` / `velocity` are raw server sim-space (same space `voxel_chunk_of`
/// consumes); the Y↔Z swap to chunk axes happens inside.
fn aoi_target_center(
    location: [f64; 3],
    velocity: [f64; 3],
    anchor: Option<[i32; 3]>,
) -> Option<([i32; 3], [i32; 3])> {
    let pos = voxel_chunk_pos(location);
    let player_chunk = [
        pos[0].floor() as i32,
        pos[1].floor() as i32,
        pos[2].floor() as i32,
    ];

    let recenter = match anchor {
        None => true,
        Some(a) => {
            (0..3).any(|i| (pos[i] - (a[i] as f64 + 0.5)).abs() > 0.5 + VOXEL_AOI_HYSTERESIS)
        }
    };

    if !recenter {
        return None;
    }

    // Velocity in the same swapped chunk-axis convention as `voxel_chunk_pos`.
    let center = [
        player_chunk[0] + prefetch_lead(velocity[0]),
        player_chunk[1] + prefetch_lead(velocity[2]),
        player_chunk[2] + prefetch_lead(velocity[1]),
    ];
    Some((player_chunk, center))
}

/// Subscribes to the voxel chunks around `center_chunk`, records it as the
/// current subscription center, and — as the center moves — UNSUBSCRIBES + evicts
/// the chunks that fell out of the box. Without the unsubscribe the server keeps
/// fanning out deltas/field snapshots for every chunk the player ever entered and
/// the client store grows unbounded for the whole session.
fn subscribe_voxel_around(
    bridge: &NetworkBridge,
    world_state: &mut WorldState,
    voxel_aoi: &mut crate::voxel::VoxelAoiState,
    authority: &mut crate::voxel::VoxelAuthority,
    center_chunk: [i32; 3],
) {
    bridge.send(NetworkCommand::SubscribeChunks {
        logical_scene_id: 1,
        center_chunk,
        radius: VOXEL_SUBSCRIBE_RADIUS,
        // Advertise every chunk we already hold (from the on-disk cache or this
        // session) so the server diffs against our versions and skips unchanged
        // chunks. The server matches per-coord, ignoring entries outside the box.
        known: authority.store.known_versions(),
    });

    if let Some(old_center) = voxel_aoi.subscribed_center
        && old_center != center_chunk
    {
        let dropped = chunks_falling_out(old_center, center_chunk, VOXEL_SUBSCRIBE_RADIUS as i32);
        if !dropped.is_empty() {
            for coord in &dropped {
                authority.store.evict(*coord);
            }
            bridge.send(NetworkCommand::UnsubscribeChunks {
                logical_scene_id: 1,
                chunks: dropped.clone(),
            });
            push_line(
                &mut world_state.logs,
                format!("voxel unsubscribe {} chunks leaving AOI", dropped.len()),
            );
        }
    }

    voxel_aoi.subscribed_center = Some(center_chunk);
    push_line(
        &mut world_state.logs,
        format!("voxel subscribe center={center_chunk:?} radius={VOXEL_SUBSCRIBE_RADIUS}"),
    );
}

#[allow(clippy::too_many_arguments)]
fn poll_network_events(
    mut commands: Commands,
    bridge: Res<NetworkBridge>,
    time: Res<Time>,
    stdio: Res<ClientStdioInterface>,
    mut world_state: ResMut<WorldState>,
    mut connection: ResMut<ConnectionState>,
    mut local_render_prediction: ResMut<LocalRenderPrediction>,
    mut movement_dispatch: ResMut<MovementDispatchState>,
    mut voxel_aoi: ResMut<crate::voxel::VoxelAoiState>,
    mut voxel_authority: ResMut<crate::voxel::VoxelAuthority>,
    mut edit_feedback: ResMut<crate::hud::EditFeedback>,
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
            connection.status =
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
                connection.status = status.clone();
                if stdio.is_enabled() {
                    emit_stdio("status", &[("message", status.clone())]);
                }
                push_line(&mut world_state.logs, status);
            }
            NetworkEvent::EnteredScene { cid, location } => {
                connection.scene_joined = true;
                connection.status = format!("in scene as cid {cid}");
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

                // Auto-subscribe to the voxel chunks around the spawn so the
                // server-authoritative renderer (VoxelChunkRenderPlugin) gets data
                // without manual CLI. logical_scene_id defaults to 1 (no protocol
                // field carries it yet — see M1.8d note). The follow-up in
                // `LocalPosition` re-subscribes as the player crosses chunks (AOI).
                voxel_aoi.subscribed_center = None;
                voxel_aoi.aoi_anchor = Some(voxel_chunk_of(location));
                subscribe_voxel_around(
                    &bridge,
                    &mut world_state,
                    &mut voxel_aoi,
                    &mut voxel_authority,
                    voxel_chunk_of(location),
                );
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

                // AOI follow (阶段4 step4.5): re-subscribe as the player moves, but
                // with a hysteresis deadzone (no thrash hovering on a chunk boundary)
                // and a velocity-led center (prefetch the slab ahead). Multiple
                // LocalPosition updates in one frame naturally merge — each re-anchor
                // updates `voxel_aoi_anchor`, so only a genuine deadzone exit triggers.
                if let Some((anchor, center)) =
                    aoi_target_center(location, velocity, voxel_aoi.aoi_anchor)
                {
                    voxel_aoi.aoi_anchor = Some(anchor);
                    subscribe_voxel_around(
                        &bridge,
                        &mut world_state,
                        &mut voxel_aoi,
                        &mut voxel_authority,
                        center,
                    );
                }
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
                push_line(
                    &mut world_state.skill_log,
                    format!("{cid} skill={skill_id}"),
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
                push_line(
                    &mut world_state.combat_log,
                    format!(
                        "{source_cid}->{target_cid} skill={skill_id} damage={damage} hp_after={hp_after}"
                    ),
                );
            }
            NetworkEvent::EffectEvent {
                source_cid,
                skill_id,
                cue_kind,
                origin,
                target_position,
                radius,
                duration_ms,
                ..
            } => {
                push_line(
                    &mut world_state.effect_log,
                    format!("{source_cid} skill={skill_id} cue={cue_kind:?}"),
                );
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
            NetworkEvent::Voxel(voxel) => {
                // Edit-feedback closing the loop (阶段0): a failed authoritative
                // ACK (rejected/stale) means the player's build/dig did NOT land.
                // Flash a localized reason + log it BEFORE handing the message to
                // the authority store, so the rejection is never silently dropped.
                if let crate::voxel::wire::VoxelServerMessage::VoxelIntentResult(result) = &voxel {
                    if result.is_failure() {
                        edit_feedback.flash_failure(&result.reason, time.elapsed_secs());
                        push_line(
                            &mut world_state.logs,
                            format!(
                                "voxel edit {} (seq {}): {}",
                                result.result_label(),
                                result.client_intent_seq,
                                result.reason
                            ),
                        );
                    }
                }
                // Thin glue: hand the decoded message to the voxel authority
                // store's inbox; ingestion + meshing live in VoxelAuthorityPlugin.
                voxel_authority.enqueue(voxel);
            }
            NetworkEvent::Log(line) => {
                if stdio.is_enabled() {
                    emit_stdio("log", &[("line", line.clone())]);
                }
                push_line(&mut world_state.logs, line)
            }
            NetworkEvent::Disconnected(reason) => {
                connection.scene_joined = false;
                connection.status = format!("disconnected: {reason}");
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn voxel_chunk_of_swaps_vertical_axis_to_match_render_chunk_space() {
        // Default spawn {750,750,185}: all axes < 1600 → [0,0,0]. This collapse is
        // exactly why the missing-swap bug stayed hidden at spawn.
        assert_eq!(voxel_chunk_of([750.0, 750.0, 185.0]), [0, 0, 0]);

        // Walking the horizontal server_y axis must advance the HORIZONTAL chunk
        // axis (index 2), NOT the vertical one (index 1); the near-constant
        // vertical server_z keeps the vertical chunk axis at 0.
        let horizontal = voxel_chunk_of([750.0, 5000.0, 185.0]);
        assert_eq!(horizontal[0], 0);
        assert_eq!(
            horizontal[1], 0,
            "vertical chunk axis must stay 0 while walking horizontally"
        );
        assert_eq!(
            horizontal[2], 3,
            "horizontal server_y travel lands on chunk axis 2 (5000/1600 = 3)"
        );

        // Vertical server_z drives the vertical chunk axis (index 1).
        let vertical = voxel_chunk_of([750.0, 750.0, 5000.0]);
        assert_eq!(
            vertical[1], 3,
            "vertical server_z lands on chunk axis 1 (5000/1600 = 3)"
        );
        assert_eq!(vertical[2], 0);

        // Negative coords floor toward -∞ (Euclidean chunk boundaries).
        assert_eq!(voxel_chunk_of([-100.0, -100.0, -100.0]), [-1, -1, -1]);
    }

    #[test]
    fn chunks_falling_out_is_the_trailing_slab_on_a_one_step_move() {
        // Move center [0,0,0]→[0,0,1], radius 2: old box cz∈[-2,2], new box
        // cz∈[-1,3]. The chunks that fall out are exactly the cz=-2 slab (5×5×1).
        let dropped = chunks_falling_out([0, 0, 0], [0, 0, 1], 2);
        assert_eq!(dropped.len(), 25, "one-step move drops a 5×5 trailing slab");
        assert!(
            dropped.iter().all(|c| c[2] == -2),
            "all dropped chunks are on the trailing cz=-2 plane"
        );

        // No move → nothing falls out.
        assert!(chunks_falling_out([3, 0, -1], [3, 0, -1], 2).is_empty());

        // A jump farther than the box diameter drops the entire old box (5³=125).
        assert_eq!(chunks_falling_out([0, 0, 0], [100, 0, 0], 2).len(), 125);
    }

    const CHUNK: f64 = VOXEL_CHUNK_WORLD_SIZE;

    #[test]
    fn aoi_no_anchor_centers_on_player_chunk() {
        // Cold start (anchor None): subscribe centred on the player's chunk, anchor
        // becomes that chunk. Standing still → zero velocity → no prefetch lead.
        let (anchor, center) = aoi_target_center([0.0, 0.0, 0.0], [0.0, 0.0, 0.0], None).unwrap();
        assert_eq!(anchor, [0, 0, 0]);
        assert_eq!(center, [0, 0, 0]);
    }

    #[test]
    fn aoi_hysteresis_suppresses_boundary_jitter() {
        // Anchored on chunk 0. Crossing just past the boundary (chunk-x 1.05, i.e.
        // 0.55 past the anchor centre) is INSIDE the 0.5+0.35 deadzone → no re-sub,
        // even though voxel_chunk_of already reads chunk 1.
        let loc = [CHUNK * 1.05, 0.0, 0.0];
        assert_eq!(voxel_chunk_of(loc), [1, 0, 0]);
        assert!(aoi_target_center(loc, [0.0, 0.0, 0.0], Some([0, 0, 0])).is_none());

        // Moving deep into chunk 1 (1.9 → 1.4 past anchor centre, clears 0.85) → re-sub.
        let deep = [CHUNK * 1.9, 0.0, 0.0];
        let (anchor, _center) =
            aoi_target_center(deep, [0.0, 0.0, 0.0], Some([0, 0, 0])).unwrap();
        assert_eq!(anchor, [1, 0, 0]);
    }

    #[test]
    fn aoi_prefetch_leads_center_along_velocity() {
        // Re-anchoring while moving fast on server_x leads the box +1 on chunk axis 0;
        // server_y travel (fast) leads chunk axis 2 (the Y↔Z swap); slow axes don't.
        let loc = [CHUNK * 5.5, CHUNK * 5.5, 0.0];
        let vel = [VOXEL_PREFETCH_SPEED + 50.0, -(VOXEL_PREFETCH_SPEED + 50.0), 10.0];
        let (anchor, center) = aoi_target_center(loc, vel, None).unwrap();
        assert_eq!(anchor, [5, 0, 5]);
        assert_eq!(
            center,
            [6, 0, 4],
            "x leads +1, vertical axis 1 unled (slow server_z), axis 2 leads -1 (server_y back)"
        );
    }

    #[test]
    fn prefetch_lead_threshold() {
        assert_eq!(prefetch_lead(VOXEL_PREFETCH_SPEED + 1.0), 1);
        assert_eq!(prefetch_lead(-(VOXEL_PREFETCH_SPEED + 1.0)), -1);
        assert_eq!(prefetch_lead(VOXEL_PREFETCH_SPEED - 1.0), 0);
        assert_eq!(prefetch_lead(0.0), 0);
    }
}
