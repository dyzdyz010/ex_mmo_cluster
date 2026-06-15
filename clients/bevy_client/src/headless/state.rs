//! Headless runtime state and the network-event reducer that mutates it.

use std::collections::HashMap;
use std::path::PathBuf;

use bevy::prelude::Vec3;

use crate::net::{MessageTransport, NetworkEvent};
use crate::observe::ClientObserver;
use crate::stdio::emit as emit_stdio;
use crate::voxel::VoxelWorld;
use crate::voxel::authority::VoxelAuthorityStore;
use crate::world::remote_actor::RemoteActorIdentity;

#[derive(Debug, Default)]
pub(super) struct HeadlessState {
    pub status: String,
    pub scene_joined: bool,
    pub local_cid: i64,
    pub local_position: Option<Vec3>,
    pub local_hp: u16,
    pub local_max_hp: u16,
    pub local_alive: bool,
    pub remote_players: HashMap<i64, Vec3>,
    pub remote_actor_identity: HashMap<i64, RemoteActorIdentity>,
    pub selected_target_cid: Option<i64>,
    pub selected_target_point: Option<Vec3>,
    pub last_local_transport: Option<MessageTransport>,
    pub last_remote_transport: Option<MessageTransport>,
    pub movement_transport: MessageTransport,
    pub fast_lane_status: String,
    pub voxel_world: VoxelWorld,
    /// Server-authoritative voxel store, fed by `NetworkEvent::Voxel`. Lets the
    /// headless harness drive + inspect the full server voxel pipeline (decode →
    /// ingest → mesh) without a window.
    pub voxel_authority: VoxelAuthorityStore,
}

pub(super) fn apply_event(
    observer: &ClientObserver,
    state: &mut HeadlessState,
    event: NetworkEvent,
) {
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
            acceleration: _,
            movement_mode: _,
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
            state
                .remote_actor_identity
                .insert(cid, RemoteActorIdentity { cid, kind, name });
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
        NetworkEvent::ReconcileStats {
            total_corrections,
            total_replays,
            total_hard_snaps,
            total_window_trims,
            last_replayed_frames,
            last_pending_inputs,
            last_correction_distance,
        } => {
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
                        format!("{last_correction_distance:.3}"),
                    ),
                ],
            );
        }
        NetworkEvent::Voxel(message) => match state.voxel_authority.ingest(&message) {
            Ok(outcome) => {
                observer.emit(
                    "headless",
                    "voxel_ingest",
                    &[("outcome", format!("{outcome:?}"))],
                );
            }
            Err(error) => {
                observer.emit("headless", "voxel_ingest_error", &[("error", error.0)]);
            }
        },
        _ => {}
    }
}

pub(super) fn vec3_from_net(value: [f64; 3]) -> Vec3 {
    Vec3::new(value[0] as f32, value[1] as f32, value[2] as f32)
}

pub(super) fn vec3_to_net(value: Vec3) -> [f64; 3] {
    [value.x as f64, value.y as f64, value.z as f64]
}

pub(super) fn format_vec3(value: Vec3) -> String {
    format!("{:.1},{:.1},{:.1}", value.x, value.y, value.z)
}

pub(super) fn format_net_vec(value: [f64; 3]) -> String {
    format!("{:.1},{:.1},{:.1}", value[0], value[1], value[2])
}

pub(super) fn format_players(players: &HashMap<i64, Vec3>) -> String {
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

pub(super) fn voxel_save_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join(".demo")
        .join("observe")
}
