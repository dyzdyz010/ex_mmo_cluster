//! Headless runtime state and the network-event reducer that mutates it.

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;

use bevy::prelude::Vec3;

use crate::app::push_line;
use crate::net::{MessageTransport, NetworkEvent};
use crate::observe::ClientObserver;
use crate::stdio::emit as emit_stdio;
use crate::voxel::VoxelWorld;
use crate::voxel::authority::VoxelAuthorityStore;
use crate::voxel::field_view::VoxelFieldStore;
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
    /// Control-plane transport (TCP/UDP) — distinct from `movement_transport` (the
    /// data plane). The GUI `transport` query reports both; headless used to omit
    /// control_transport (parity gap), so asymmetric TCP/UDP routing couldn't be verified.
    pub control_transport: MessageTransport,
    pub movement_transport: MessageTransport,
    pub fast_lane_status: String,
    pub voxel_world: VoxelWorld,
    /// Server-authoritative voxel store, fed by `NetworkEvent::Voxel`. Lets the
    /// headless harness drive + inspect the full server voxel pipeline (decode →
    /// ingest → mesh) without a window.
    pub voxel_authority: VoxelAuthorityStore,
    /// Emergence field regions (heat / electric / light / ...), fed by the
    /// `0x73`/`0x74` field stream. Previously dropped in headless (the bare store
    /// ignores field messages); tracked here so `va-fields` can self-verify that
    /// emergence reaches the client.
    pub field_store: VoxelFieldStore,
    /// Chunks the authority store asked to resync (delta base mismatch). Drained
    /// by `run_stdio` into radius-0 re-subscribes — the GUI does this via an ECS
    /// system; headless must do it explicitly or it renders stale truth.
    pub pending_resyncs: Vec<[i32; 3]>,
    /// Recent server-message history (bounded), so the harness can QUERY that a
    /// chat/skill/combat/effect message was received + decoded — not just observe
    /// the real-time emit. ChatMessage + SkillEvent were previously dropped by the
    /// `_ => {}` catchall (silent headless blind spot); now tracked here.
    pub chat_log: VecDeque<String>,
    pub skill_log: VecDeque<String>,
    pub combat_log: VecDeque<String>,
    pub effect_log: VecDeque<String>,
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
            control_transport,
            movement_transport,
            fast_lane_status,
            ..
        } => {
            state.control_transport = control_transport;
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
            push_line(
                &mut state.combat_log,
                format!(
                    "{source_cid}->{target_cid} skill={skill_id} damage={damage} hp_after={hp_after}"
                ),
            );
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
        NetworkEvent::ChatMessage { cid, username, text } => {
            // Previously dropped by the `_ => {}` catchall — a silent headless blind
            // spot. Track + observe so the harness can verify chat round-trips.
            push_line(&mut state.chat_log, format!("[{cid}/{username}] {text}"));
            observer.emit(
                "headless",
                "chat_seen",
                &[
                    ("cid", cid.to_string()),
                    ("username", username),
                    ("text", text),
                ],
            );
        }
        NetworkEvent::SkillEvent {
            cid,
            skill_id,
            location,
        } => {
            // Previously dropped by the catchall. A remote actor's skill cast cue.
            push_line(
                &mut state.skill_log,
                format!(
                    "{cid} skill={skill_id} at {:.1},{:.1},{:.1}",
                    location[0], location[1], location[2]
                ),
            );
            observer.emit(
                "headless",
                "skill_event_seen",
                &[("cid", cid.to_string()), ("skill_id", skill_id.to_string())],
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
            push_line(
                &mut state.effect_log,
                format!("{source_cid} skill={skill_id} cue={cue_kind:?}"),
            );
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
        NetworkEvent::Voxel(message) => {
            use crate::voxel::wire::VoxelServerMessage as V;
            match &message {
                // Field stream (0x73/0x74) feeds the field store (mirrors the GUI
                // VoxelAuthority.drain_inbox routing), so `va-fields` can observe
                // emergence; everything else is chunk truth → the chunk store.
                V::FieldRegionSnapshot(snap) => {
                    state.field_store.apply_snapshot(snap.clone());
                    observer.emit(
                        "headless",
                        "field_ingest",
                        &[
                            ("region", snap.region_id.to_string()),
                            ("mask", format!("0x{:02x}", snap.field_mask)),
                            ("cells", snap.macro_indices.len().to_string()),
                        ],
                    );
                }
                V::FieldRegionDestroyed(destroyed) => {
                    let removed = state.field_store.apply_destroyed(destroyed);
                    observer.emit(
                        "headless",
                        "field_destroyed",
                        &[
                            ("region", destroyed.region_id.to_string()),
                            ("removed", removed.to_string()),
                        ],
                    );
                }
                _ => match state.voxel_authority.ingest(&message) {
                    Ok(outcome) => {
                        // A version-gate failure (delta base ≠ held version, e.g.
                        // the chunk version churned from field activity) asks for a
                        // resync. The GUI re-subscribes automatically; headless must
                        // queue it so the harness re-pulls a fresh snapshot instead
                        // of silently rendering stale truth (else `va-macro` misses
                        // edits on field-active chunks).
                        if let crate::voxel::authority::IngestOutcome::Resync(coord) = &outcome {
                            state.pending_resyncs.push(*coord);
                        }
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
            }
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn observer() -> ClientObserver {
        // No log path + no stdout → a silent observer for assertions.
        ClientObserver::new(None, false)
    }

    #[test]
    fn chat_and_skill_events_are_tracked_not_dropped() {
        // Regression: ChatMessage + SkillEvent used to fall through the `_ => {}`
        // catchall (silent headless blind spot). They must now accumulate.
        let obs = observer();
        let mut state = HeadlessState {
            local_cid: 7,
            ..Default::default()
        };

        apply_event(
            &obs,
            &mut state,
            NetworkEvent::ChatMessage {
                cid: 9,
                username: "bob".to_string(),
                text: "hi there".to_string(),
            },
        );
        assert_eq!(state.chat_log.len(), 1);
        assert!(state.chat_log[0].contains("hi there"));

        apply_event(
            &obs,
            &mut state,
            NetworkEvent::SkillEvent {
                cid: 9,
                skill_id: 42,
                location: [1.0, 2.0, 3.0],
            },
        );
        assert_eq!(state.skill_log.len(), 1);
        assert!(state.skill_log[0].contains("skill=42"));

        apply_event(
            &obs,
            &mut state,
            NetworkEvent::CombatHit {
                source_cid: 9,
                target_cid: 7,
                skill_id: 42,
                damage: 5,
                hp_after: 95,
                location: [0.0, 0.0, 0.0],
            },
        );
        assert_eq!(state.combat_log.len(), 1);
        assert!(state.combat_log[0].contains("damage=5"));
    }

    #[test]
    fn transport_state_tracks_both_control_and_movement() {
        // control_transport used to be omitted from headless (GUI/headless parity gap).
        let obs = observer();
        let mut state = HeadlessState::default();
        apply_event(
            &obs,
            &mut state,
            NetworkEvent::TransportState {
                control_transport: MessageTransport::Tcp,
                movement_transport: MessageTransport::Udp,
                fast_lane_status: "attached".to_string(),
                udp_endpoint: None,
            },
        );
        assert_eq!(state.control_transport, MessageTransport::Tcp);
        assert_eq!(state.movement_transport, MessageTransport::Udp);
    }
}
