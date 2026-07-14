//! `NetworkPlugin` — drains `NetworkEvent`s queued by the background
//! network thread and projects them into the per-domain runtime resources
//! (`LocalPlayerState`, `RemotePlayers`, `NetTelemetry`, `GameLogs`,
//! `TargetSelection`, `VoxelAoiState`, …), prediction state, and effect cues.

use bevy::prelude::*;

use crate::app::{
    LocalRenderPrediction, MovementDispatchState, net_to_world, push_line, schedule::ClientSet,
    sim_to_render_position,
};
use crate::effects::{EffectVisual, effect_spawn_translation};
use crate::hud::GameLogs;
use crate::login::AppState;
use crate::session::{ConnectionPhase, ConnectionState};
use crate::skill::TargetSelection;
use crate::stdio::{ClientStdioInterface, emit as emit_stdio};
use crate::world::{LocalPlayerState, RemotePlayers};
use crate::world::remote_actor::RemoteActorIdentity;
use crate::world::remote_player::RemotePlayerState;

use super::NetTelemetry;
use super::events::{MessageTransport, NetworkBridge, NetworkCommand, NetworkEvent};

pub struct NetworkPlugin;

impl Plugin for NetworkPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<VoxelSubscribeRetry>().add_systems(
            Update,
            (poll_network_events, voxel_subscribe_retry)
                .chain()
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
    keepalive_timer: Timer,
    keepalive_tile: Option<[i32; 3]>,
}

/// 订阅 lease 的自维护续约周期；不得依赖玩家继续移动来维持窗口活性。
const VOXEL_WINDOW_KEEPALIVE_SECS: f32 = 60.0;

impl Default for VoxelSubscribeRetry {
    fn default() -> Self {
        Self {
            timer: Timer::from_seconds(1.0, TimerMode::Repeating),
            attempts: 0,
            keepalive_timer: Timer::from_seconds(VOXEL_WINDOW_KEEPALIVE_SECS, TimerMode::Repeating),
            keepalive_tile: None,
        }
    }
}

impl VoxelSubscribeRetry {
    /// 推进 keepalive 时钟；tile 改变时先重置，避免重心后立即重复续约。
    fn tick_keepalive(&mut self, delta: std::time::Duration, tile: [i32; 3]) -> bool {
        if self.keepalive_tile != Some(tile) {
            self.keepalive_tile = Some(tile);
            self.keepalive_timer.reset();
            return false;
        }
        self.keepalive_timer.tick(delta).just_finished()
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
    stdio: Res<ClientStdioInterface>,
    mut logs: ResMut<GameLogs>,
    connection: Res<ConnectionState>,
    mut voxel_aoi: ResMut<crate::voxel::VoxelAoiState>,
    mut voxel_authority: ResMut<crate::voxel::VoxelAuthority>,
    mut retry: ResMut<VoxelSubscribeRetry>,
) {
    let retry_due = retry.timer.tick(time.delta()).just_finished();
    // Only meaningful once joined with a subscription center recorded.
    let (Some(tile), Some(center)) = (voxel_aoi.subscribed_tile, voxel_aoi.subscribed_center)
    else {
        retry.keepalive_tile = None;
        retry.keepalive_timer.reset();
        return;
    };
    if !connection.scene_joined() {
        return;
    }
    let keepalive_due = retry.tick_keepalive(time.delta(), tile);
    let keepalive_sent = if keepalive_due {
        let known_count = send_voxel_window_subscription(&bridge, &voxel_authority, center);
        push_line(
            &mut logs.general,
            format!(
                "voxel xyz tile window reason=keepalive tile={tile:?} center={center:?} chunks={} known={known_count}",
                VOXEL_NEAR_WINDOW_CHUNK_COUNT
            ),
        );
        if stdio.is_enabled() {
            emit_stdio(
                "voxel_window_renewed",
                &[
                    ("reason", "keepalive".to_string()),
                    ("tile", format!("{},{},{}", tile[0], tile[1], tile[2])),
                    (
                        "center_chunk",
                        format!("{},{},{}", center[0], center[1], center[2]),
                    ),
                    ("chunk_count", VOXEL_NEAR_WINDOW_CHUNK_COUNT.to_string()),
                    ("known_count", known_count.to_string()),
                ],
            );
        }
        true
    } else {
        false
    };
    if !retry_due {
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
    if keepalive_sent {
        return;
    }
    if retry.attempts >= MAX_SUBSCRIBE_RETRIES {
        return;
    }
    retry.attempts += 1;
    push_line(
        &mut logs.general,
        format!(
            "voxel subscribe retry {}/{} (0 chunks loaded)",
            retry.attempts, MAX_SUBSCRIBE_RETRIES
        ),
    );
    subscribe_voxel_around(
        &bridge,
        &mut logs,
        &mut voxel_aoi,
        &mut voxel_authority,
        tile,
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
            &mut logs.general,
            "voxel: still 0 chunks after max resubscribes (terrain may be absent server-side)"
                .to_string(),
        );
    }
}

/// 一个 voxel chunk 跨 16 个 macro，每个 macro 为 100cm。
const VOXEL_CHUNK_WORLD_SIZE: f64 = 1600.0;

/// 每个 tile 在 X/Y/Z 三轴都含 7 个 chunk。
const VOXEL_TILE_SIZE_CHUNKS: i32 = 7;

/// 近场以中心 tile 为核心，保留相邻一层 tile，即 `3x3x3 = 27 tiles`。
const VOXEL_NEAR_TILE_RADIUS: i32 = 1;

/// tile 中心到三 tile 窗口外沿的 chunk L∞ 半径：`7 + 3 = 10`。
const VOXEL_SUBSCRIBE_RADIUS: u8 = 10;

/// 完整 XYZ 近场窗口边长：`2 * 10 + 1 = 21 chunks`。
const VOXEL_NEAR_WINDOW_EDGE_CHUNKS: usize = 21;

/// 完整 XYZ 近场窗口体积：`21^3 = 9261 chunks`。
const VOXEL_NEAR_WINDOW_CHUNK_COUNT: usize =
    VOXEL_NEAR_WINDOW_EDGE_CHUNKS * VOXEL_NEAR_WINDOW_EDGE_CHUNKS * VOXEL_NEAR_WINDOW_EDGE_CHUNKS;

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

/// 由 chunk identity 计算完整 XYZ tile identity。
///
/// 必须使用 Euclidean 除法：chunk `-1` 属于 tile `-1`，而不是 tile `0`。
fn tile_of_chunk(chunk: [i32; 3]) -> [i32; 3] {
    [
        chunk[0].div_euclid(VOXEL_TILE_SIZE_CHUNKS),
        chunk[1].div_euclid(VOXEL_TILE_SIZE_CHUNKS),
        chunk[2].div_euclid(VOXEL_TILE_SIZE_CHUNKS),
    ]
}

/// 返回 tile 的中心 chunk；边长 7 为奇数，因此中心偏移恒为 3。
fn tile_center_chunk(tile: [i32; 3]) -> [i32; 3] {
    let half = VOXEL_TILE_SIZE_CHUNKS / 2;
    [
        tile[0] * VOXEL_TILE_SIZE_CHUNKS + half,
        tile[1] * VOXEL_TILE_SIZE_CHUNKS + half,
        tile[2] * VOXEL_TILE_SIZE_CHUNKS + half,
    ]
}

/// 判断 chunk 是否属于以 `center` 为中心的现役 `21x21x21` 窗口。
fn chunk_is_in_near_window(chunk: [i32; 3], center: [i32; 3]) -> bool {
    let radius = VOXEL_SUBSCRIBE_RADIUS as i32;
    (chunk[0] - center[0]).abs() <= radius
        && (chunk[1] - center[1]).abs() <= radius
        && (chunk[2] - center[2]).abs() <= radius
}

/// 枚举一个完整 XYZ 近场窗口；冷启动窗口必须精确包含 9261 个 chunk。
fn near_window_chunks(center: [i32; 3]) -> Vec<[i32; 3]> {
    let radius = VOXEL_SUBSCRIBE_RADIUS as i32;
    let mut chunks = Vec::with_capacity(VOXEL_NEAR_WINDOW_CHUNK_COUNT);
    for cx in (center[0] - radius)..=(center[0] + radius) {
        for cy in (center[1] - radius)..=(center[1] + radius) {
            for cz in (center[2] - radius)..=(center[2] + radius) {
                chunks.push([cx, cy, cz]);
            }
        }
    }
    chunks
}

/// 返回旧窗口中不再属于新窗口的完整 XYZ 差集。
fn chunks_falling_out(from: [i32; 3], to: [i32; 3]) -> Vec<[i32; 3]> {
    near_window_chunks(from)
        .into_iter()
        .filter(|chunk| !chunk_is_in_near_window(*chunk, to))
        .collect()
}

/// 计算位置对应的现役 tile 与窗口中心。
///
/// 同一 tile 内移动不会重订；速度不再改变 authority 窗口 identity，预取应由
/// 独立的候选加载层实现，不能偏移 confirmed truth 窗口。
fn aoi_target_center(
    location: [f64; 3],
    subscribed_tile: Option<[i32; 3]>,
) -> Option<([i32; 3], [i32; 3])> {
    let tile = tile_of_chunk(voxel_chunk_of(location));
    if subscribed_tile == Some(tile) {
        return None;
    }
    Some((tile, tile_center_chunk(tile)))
}

/// 只选择新窗口内的已知版本，并钉死协议上限为 9261 条。
fn known_versions_in_near_window(
    authority: &crate::voxel::VoxelAuthority,
    center: [i32; 3],
) -> Vec<([i32; 3], u64)> {
    let mut known: Vec<_> = authority
        .store
        .known_versions()
        .into_iter()
        .filter(|(chunk, _)| chunk_is_in_near_window(*chunk, center))
        .collect();
    known.sort_unstable_by_key(|(chunk, _)| *chunk);
    known.truncate(VOXEL_NEAR_WINDOW_CHUNK_COUNT);
    known
}

/// 发送同一个完整 XYZ 窗口；供重心、冷启动重试和 keepalive 共用。
fn send_voxel_window_subscription(
    bridge: &NetworkBridge,
    authority: &crate::voxel::VoxelAuthority,
    center_chunk: [i32; 3],
) -> usize {
    let known = known_versions_in_near_window(authority, center_chunk);
    let known_count = known.len();
    bridge.send(NetworkCommand::SubscribeChunks {
        logical_scene_id: 1,
        center_chunk,
        radius: VOXEL_SUBSCRIBE_RADIUS,
        known,
    });
    known_count
}

/// 切换完整 XYZ 近场窗口，并退订、驱逐旧窗口差集。
fn subscribe_voxel_around(
    bridge: &NetworkBridge,
    logs: &mut GameLogs,
    voxel_aoi: &mut crate::voxel::VoxelAoiState,
    authority: &mut crate::voxel::VoxelAuthority,
    tile: [i32; 3],
    center_chunk: [i32; 3],
) {
    let known_count = send_voxel_window_subscription(bridge, authority, center_chunk);

    if let Some(old_center) = voxel_aoi.subscribed_center
        && old_center != center_chunk
    {
        let dropped = chunks_falling_out(old_center, center_chunk);
        if !dropped.is_empty() {
            for coord in &dropped {
                authority.store.evict(*coord);
            }
            bridge.send(NetworkCommand::UnsubscribeChunks {
                logical_scene_id: 1,
                chunks: dropped.clone(),
            });
            push_line(
                &mut logs.general,
                format!(
                    "voxel xyz window diff entered={} exited={} retained={}",
                    dropped.len(),
                    dropped.len(),
                    VOXEL_NEAR_WINDOW_CHUNK_COUNT - dropped.len()
                ),
            );
        }
    }

    voxel_aoi.subscribed_center = Some(center_chunk);
    voxel_aoi.subscribed_tile = Some(tile);
    push_line(
        &mut logs.general,
        format!(
            "voxel xyz tile window tile={tile:?} center={center_chunk:?} tile_size={} tile_radius={} chunk_radius={} tiles=27 chunks={} known={}",
            VOXEL_TILE_SIZE_CHUNKS,
            VOXEL_NEAR_TILE_RADIUS,
            VOXEL_SUBSCRIBE_RADIUS,
            VOXEL_NEAR_WINDOW_CHUNK_COUNT,
            known_count
        ),
    );
}

#[allow(clippy::too_many_arguments)]
fn poll_network_events(
    mut commands: Commands,
    bridge: Res<NetworkBridge>,
    time: Res<Time>,
    stdio: Res<ClientStdioInterface>,
    mut local_player: ResMut<LocalPlayerState>,
    mut connection: ResMut<ConnectionState>,
    mut local_render_prediction: ResMut<LocalRenderPrediction>,
    mut movement_dispatch: ResMut<MovementDispatchState>,
    mut voxel_aoi: ResMut<crate::voxel::VoxelAoiState>,
    mut voxel_authority: ResMut<crate::voxel::VoxelAuthority>,
    mut voxel_subscribe_retry: ResMut<VoxelSubscribeRetry>,
    mut target: ResMut<TargetSelection>,
    mut logs: ResMut<GameLogs>,
    mut telemetry: ResMut<NetTelemetry>,
    mut remote: ResMut<RemotePlayers>,
    mut edit_feedback: ResMut<crate::hud::EditFeedback>,
) {
    let receiver = match bridge.rx.lock() {
        Ok(receiver) => receiver,
        Err(poisoned) => {
            // Audit E-S2: poisoned NetworkBridge mutex means the network
            // thread panicked while holding the lock. Surface it through
            // ConnectionState.status + GameLogs so the operator sees a
            // definitive error in HUD / stdio instead of silent freeze.
            // Recover the inner receiver to continue draining events that
            // may have arrived before the panic.
            let recovered = poisoned.into_inner();
            connection.status =
                "network bridge mutex poisoned (network thread panicked)".to_string();
            push_line(
                &mut logs.general,
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
                push_line(&mut logs.general, status);
            }
            NetworkEvent::EnteredScene { cid, location } => {
                connection.phase = ConnectionPhase::InScene;
                connection.status = format!("in scene as cid {cid}");
                local_player.cid = cid;
                let world_location = net_to_world(location);
                local_player.position = Some(world_location);
                local_player.velocity = Vec3::ZERO;
                local_render_prediction.reset(world_location);
                remote.players.clear();
                remote.identity.clear();
                remote.health.clear();
                telemetry.last_local_update_transport = None;
                telemetry.last_remote_move_transport = None;
                target.cid = None;
                target.point = None;
                movement_dispatch.stop_sent = true;
                push_line(&mut logs.general, format!("entered scene cid={cid}"));

                // 进入场景时建立完整 XYZ tile 窗口；后续只在跨 tile 时换窗。
                voxel_aoi.subscribed_center = None;
                voxel_aoi.subscribed_tile = None;
                voxel_subscribe_retry.keepalive_tile = None;
                voxel_subscribe_retry.keepalive_timer.reset();
                let (tile, center) =
                    aoi_target_center(location, None).expect("首次进入场景必须建立近场窗口");
                subscribe_voxel_around(
                    &bridge,
                    &mut logs,
                    &mut voxel_aoi,
                    &mut voxel_authority,
                    tile,
                    center,
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
                local_player.position = Some(world_location);
                local_player.velocity = world_velocity;
                local_render_prediction.sync_full_state(
                    world_location,
                    world_velocity,
                    world_acceleration,
                    movement_mode,
                );
                telemetry.last_local_update_transport = Some(transport);

                // confirmed truth 窗口按完整 XYZ tile identity 跟随；tile 内移动不重订。
                if let Some((tile, center)) = aoi_target_center(location, voxel_aoi.subscribed_tile)
                {
                    subscribe_voxel_around(
                        &bridge,
                        &mut logs,
                        &mut voxel_aoi,
                        &mut voxel_authority,
                        tile,
                        center,
                    );
                }
            }
            NetworkEvent::PlayerEnter { cid, location } => {
                if cid != local_player.cid {
                    remote.players.insert(
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
                push_line(&mut logs.general, format!("player {cid} entered AOI"));
            }
            NetworkEvent::PlayerMove {
                snapshot,
                transport,
            } => {
                let cid = snapshot.cid;
                if cid != local_player.cid {
                    let received_at = time.elapsed_secs_f64();
                    if let Some(state) = remote.players.get_mut(&cid) {
                        state.push_snapshot(snapshot, received_at);
                    } else {
                        remote.players
                            .insert(cid, RemotePlayerState::from_snapshot(snapshot, received_at));
                    }
                }
                telemetry.last_remote_move_transport = Some(transport);
            }
            NetworkEvent::PlayerLeave { cid } => {
                remote.players.remove(&cid);
                remote.identity.remove(&cid);
                remote.health.remove(&cid);
                if target.cid == Some(cid) {
                    target.cid = None;
                }
                push_line(&mut logs.general, format!("player {cid} left AOI"));
            }
            NetworkEvent::ActorIdentity { cid, kind, name } => {
                remote.identity.insert(
                    cid,
                    RemoteActorIdentity {
                        cid,
                        kind,
                        name: name.clone(),
                    },
                );
                push_line(
                    &mut logs.general,
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
                    &mut logs.chat,
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
                    &mut logs.general,
                    format!("skill event: cid={cid} skill={skill_id}"),
                );
                push_line(
                    &mut logs.skill,
                    format!("{cid} skill={skill_id}"),
                );
            }
            NetworkEvent::PlayerState {
                cid,
                hp,
                max_hp,
                alive,
            } => {
                if cid == local_player.cid {
                    local_player.hp = hp;
                    local_player.max_hp = max_hp;
                    local_player.alive = alive;
                } else {
                    remote.health
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
                    &mut logs.general,
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
                    &mut logs.general,
                    format!(
                        "combat: {source_cid} -> {target_cid} skill={skill_id} damage={damage} hp_after={hp_after}"
                    ),
                );
                push_line(
                    &mut logs.combat,
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
                    &mut logs.effect,
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
                telemetry.last_rtt_ms = Some(rtt_ms);
                telemetry.last_offset_ms = Some(offset_ms);
            }
            NetworkEvent::Heartbeat { server_ts } => {
                telemetry.last_heartbeat_ts = Some(server_ts);
            }
            NetworkEvent::TransportState {
                control_transport,
                movement_transport,
                fast_lane_status,
                udp_endpoint,
            } => {
                telemetry.control_transport = control_transport;
                telemetry.movement_transport = movement_transport;
                telemetry.fast_lane_status = fast_lane_status;
                telemetry.udp_endpoint = udp_endpoint;
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
                            &mut logs.general,
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
                push_line(&mut logs.general, line)
            }
            NetworkEvent::Disconnected(reason) => {
                connection.phase = ConnectionPhase::Reconnecting { attempt: 0 };
                connection.status = format!("disconnected: {reason}");
                local_player.position = None;
                local_player.velocity = Vec3::ZERO;
                remote.players.clear();
                remote.identity.clear();
                remote.health.clear();
                telemetry.movement_transport = MessageTransport::Tcp;
                telemetry.fast_lane_status = "tcp fallback".to_string();
                telemetry.udp_endpoint = None;
                telemetry.last_local_update_transport = None;
                telemetry.last_remote_move_transport = None;
                target.cid = None;
                target.point = None;
                local_render_prediction.clear();
                movement_dispatch.stop_sent = true;
                if stdio.is_enabled() {
                    emit_stdio("disconnected", &[("reason", reason.clone())]);
                }
                push_line(&mut logs.general, format!("disconnect: {reason}"));
            }
            NetworkEvent::Reconnecting {
                attempt,
                max_attempts,
            } => {
                connection.phase = ConnectionPhase::Reconnecting { attempt };
                connection.status = format!("reconnecting (attempt {attempt}/{max_attempts})");
                if stdio.is_enabled() {
                    emit_stdio(
                        "reconnecting",
                        &[
                            ("attempt", attempt.to_string()),
                            ("max_attempts", max_attempts.to_string()),
                        ],
                    );
                }
                push_line(
                    &mut logs.general,
                    format!("reconnecting (attempt {attempt}/{max_attempts})"),
                );
            }
            NetworkEvent::ReconnectFailed => {
                connection.phase = ConnectionPhase::Failed;
                connection.status =
                    "reconnect failed — please restart the client".to_string();
                if stdio.is_enabled() {
                    emit_stdio("reconnect_failed", &[]);
                }
                push_line(
                    &mut logs.general,
                    "reconnect failed after exhausting retries — please restart the client"
                        .to_string(),
                );
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
    fn negative_chunk_maps_to_negative_tile_center() {
        // tile -1 覆盖 chunk -7..=-1，中心必须是 -4；不能用向零截断除法。
        assert_eq!(tile_of_chunk([-1, -7, -8]), [-1, -1, -2]);
        assert_eq!(tile_center_chunk([-1, -1, -2]), [-4, -4, -11]);

        let (tile, center) = aoi_target_center([-100.0, -100.0, -100.0], None).unwrap();
        assert_eq!(tile, [-1, -1, -1]);
        assert_eq!(center, [-4, -4, -4]);
    }

    #[test]
    fn cold_xyz_window_contains_exactly_9261_chunks() {
        let chunks = near_window_chunks([3, 3, 3]);
        assert_eq!(chunks.len(), 9261);
        assert_eq!(chunks.len(), VOXEL_NEAR_WINDOW_CHUNK_COUNT);
        assert!(
            chunks
                .iter()
                .all(|chunk| chunk_is_in_near_window(*chunk, [3, 3, 3]))
        );
    }

    #[test]
    fn one_axis_tile_cross_has_3087_exited_and_6174_retained() {
        let old_center = tile_center_chunk([0, 0, 0]);
        let new_center = tile_center_chunk([1, 0, 0]);
        let dropped = chunks_falling_out(old_center, new_center);
        assert_eq!(dropped.len(), 3087);
        assert_eq!(VOXEL_NEAR_WINDOW_CHUNK_COUNT - dropped.len(), 6174);
        assert!(
            dropped.iter().all(|chunk| chunk[0] < new_center[0] - 10),
            "单轴跨 tile 的退出集合必须是 7x21x21 的尾部 slab"
        );
    }

    #[test]
    fn movement_inside_same_tile_does_not_resubscribe() {
        let tile = [0, 0, 0];
        assert!(aoi_target_center([0.0, 0.0, 0.0], Some(tile)).is_none());
        assert!(
            aoi_target_center(
                [
                    VOXEL_CHUNK_WORLD_SIZE * 6.99,
                    VOXEL_CHUNK_WORLD_SIZE * 6.99,
                    VOXEL_CHUNK_WORLD_SIZE * 6.99,
                ],
                Some(tile),
            )
            .is_none()
        );
    }

    #[test]
    fn keepalive_is_due_at_60_seconds_and_resets_after_tile_recenter() {
        let mut retry = VoxelSubscribeRetry::default();

        // 首次锚定只建立计时基准，即使传入 60 秒也不能立刻续约。
        assert!(!retry.tick_keepalive(
            std::time::Duration::from_secs(60),
            [0, 0, 0]
        ));
        assert!(!retry.tick_keepalive(
            std::time::Duration::from_secs(59),
            [0, 0, 0]
        ));
        assert!(retry.tick_keepalive(std::time::Duration::from_secs(1), [0, 0, 0]));

        // 跨 tile 重心必须重置时钟，防止新窗口建立后紧接着重复发送。
        assert!(!retry.tick_keepalive(
            std::time::Duration::from_secs(60),
            [1, 0, 0]
        ));
        assert!(!retry.tick_keepalive(
            std::time::Duration::from_secs(59),
            [1, 0, 0]
        ));
        assert!(retry.tick_keepalive(std::time::Duration::from_secs(1), [1, 0, 0]));
    }

    #[test]
    fn known_versions_are_limited_to_the_new_xyz_window() {
        let center = tile_center_chunk([0, 0, 0]);
        let mut authority = crate::voxel::VoxelAuthority::default();
        for (index, coord) in near_window_chunks(center).into_iter().enumerate() {
            authority.store.seed_chunk(
                coord,
                crate::voxel::authority::AuthorityChunk {
                    chunk_version: index as u64 + 1,
                    ..Default::default()
                },
            );
        }
        authority.store.seed_chunk(
            [100, 100, 100],
            crate::voxel::authority::AuthorityChunk {
                chunk_version: 99_999,
                ..Default::default()
            },
        );

        let known = known_versions_in_near_window(&authority, center);
        assert_eq!(known.len(), 9261);
        assert!(
            known
                .iter()
                .all(|(coord, _)| chunk_is_in_near_window(*coord, center))
        );
        assert!(!known.iter().any(|(coord, _)| *coord == [100, 100, 100]));
    }
}
