//! Translation of network events / outbound messages into structured
//! `ClientObserver` emissions.
//!
//! `emit_event` is the canonical "send to app + record" path; `network_loop`
//! and friends should call it instead of touching the observer or the event
//! channel directly. `observe_outbound_message` mirrors the same pattern for
//! TCP/UDP send sites.

use std::sync::mpsc::Sender;

use crate::observe::ClientObserver;
use crate::protocol::ClientMessage;

use super::events::NetworkEvent;

pub(super) fn emit_event(
    observer: &ClientObserver,
    event_tx: &Sender<NetworkEvent>,
    event: NetworkEvent,
) {
    observe_network_event(observer, &event);
    if let Err(err) = event_tx.send(event) {
        // Audit A-L4: previously this swallowed the SendError silently.
        // The receiver being dropped means the Bevy app side has shut down
        // or the channel is gone — log it once via the observer (if still
        // available) so debugging is possible. The network thread will
        // continue and let its main loop notice the closed channel through
        // its own retry/exit path.
        if observer.enabled() {
            observer.emit(
                "network",
                "event_channel_closed",
                &[("dropped_event", format!("{:?}", err.0))],
            );
        }
    }
}

pub(super) fn observe_network_event(observer: &ClientObserver, event: &NetworkEvent) {
    if !observer.enabled() {
        return;
    }

    match event {
        NetworkEvent::Status(status) => {
            observer.emit("network", "status", &[("message", status.clone())]);
        }
        NetworkEvent::EnteredScene { cid, location } => {
            observer.emit(
                "network",
                "entered_scene",
                &[("cid", cid.to_string()), ("location", format_vec(location))],
            );
        }
        NetworkEvent::LocalPosition {
            cid,
            location,
            velocity,
            acceleration,
            transport,
        } => {
            observer.emit(
                "network",
                "movement_ack",
                &[
                    ("cid", cid.to_string()),
                    ("transport", transport.label().to_string()),
                    ("location", format_vec(location)),
                    ("velocity", format_vec(velocity)),
                    ("acceleration", format_vec(acceleration)),
                ],
            );
        }
        NetworkEvent::PlayerEnter { cid, location } => {
            observer.emit(
                "network",
                "player_enter",
                &[("cid", cid.to_string()), ("location", format_vec(location))],
            );
        }
        NetworkEvent::PlayerMove {
            snapshot,
            transport,
        } => {
            observer.emit(
                "network",
                "player_move",
                &[
                    ("cid", snapshot.cid.to_string()),
                    ("server_tick", snapshot.server_tick.to_string()),
                    ("transport", transport.label().to_string()),
                    (
                        "location",
                        format_vec(&[
                            snapshot.position.x as f64,
                            snapshot.position.y as f64,
                            snapshot.position.z as f64,
                        ]),
                    ),
                ],
            );
        }
        NetworkEvent::PlayerLeave { cid } => {
            observer.emit("network", "player_leave", &[("cid", cid.to_string())]);
        }
        NetworkEvent::ActorIdentity { cid, kind, name } => {
            observer.emit(
                "network",
                "actor_identity",
                &[
                    ("cid", cid.to_string()),
                    ("kind", format!("{kind:?}")),
                    ("name", name.clone()),
                ],
            );
        }
        NetworkEvent::ChatMessage {
            cid,
            username,
            text,
        } => {
            observer.emit(
                "network",
                "chat_message",
                &[
                    ("cid", cid.to_string()),
                    ("username", username.clone()),
                    ("text", text.clone()),
                ],
            );
        }
        NetworkEvent::SkillEvent {
            cid,
            skill_id,
            location,
        } => {
            observer.emit(
                "network",
                "skill_event",
                &[
                    ("cid", cid.to_string()),
                    ("skill_id", skill_id.to_string()),
                    ("location", format_vec(location)),
                ],
            );
        }
        NetworkEvent::PlayerState {
            cid,
            hp,
            max_hp,
            alive,
        } => {
            observer.emit(
                "network",
                "player_state",
                &[
                    ("cid", cid.to_string()),
                    ("hp", hp.to_string()),
                    ("max_hp", max_hp.to_string()),
                    ("alive", alive.to_string()),
                ],
            );
        }
        NetworkEvent::CombatHit {
            source_cid,
            target_cid,
            skill_id,
            damage,
            hp_after,
            location,
        } => {
            observer.emit(
                "network",
                "combat_hit",
                &[
                    ("source_cid", source_cid.to_string()),
                    ("target_cid", target_cid.to_string()),
                    ("skill_id", skill_id.to_string()),
                    ("damage", damage.to_string()),
                    ("hp_after", hp_after.to_string()),
                    ("location", format_vec(location)),
                ],
            );
        }
        NetworkEvent::EffectEvent {
            source_cid,
            skill_id,
            cue_kind,
            target_cid,
            origin,
            target_position,
            radius,
            duration_ms,
        } => {
            observer.emit(
                "network",
                "effect_event",
                &[
                    ("source_cid", source_cid.to_string()),
                    ("skill_id", skill_id.to_string()),
                    ("cue_kind", format!("{cue_kind:?}")),
                    (
                        "target_cid",
                        target_cid
                            .map(|v| v.to_string())
                            .unwrap_or_else(|| "n/a".to_string()),
                    ),
                    ("origin", format_vec(origin)),
                    ("target_position", format_vec(target_position)),
                    ("radius", format!("{radius:.1}")),
                    ("duration_ms", duration_ms.to_string()),
                ],
            );
        }
        NetworkEvent::TimeSync { rtt_ms, offset_ms } => {
            observer.emit(
                "network",
                "time_sync",
                &[
                    ("rtt_ms", format!("{rtt_ms:.1}")),
                    ("offset_ms", format!("{offset_ms:.1}")),
                ],
            );
        }
        NetworkEvent::Heartbeat { server_ts } => {
            observer.emit(
                "network",
                "heartbeat_reply",
                &[("server_ts", server_ts.to_string())],
            );
        }
        NetworkEvent::TransportState {
            control_transport,
            movement_transport,
            fast_lane_status,
            udp_endpoint,
        } => {
            observer.emit(
                "network",
                "transport_state",
                &[
                    ("control_transport", control_transport.label().to_string()),
                    ("movement_transport", movement_transport.label().to_string()),
                    ("fast_lane_status", fast_lane_status.clone()),
                    (
                        "udp_endpoint",
                        udp_endpoint.clone().unwrap_or_else(|| "n/a".to_string()),
                    ),
                ],
            );
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
            observer.emit(
                "network",
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
        NetworkEvent::Log(line) => observer.emit("network", "log", &[("message", line.clone())]),
        NetworkEvent::Disconnected(reason) => {
            observer.emit("network", "disconnected", &[("reason", reason.clone())]);
        }
    }
}

pub(super) fn observe_outbound_message(
    observer: &ClientObserver,
    transport: &str,
    message: &ClientMessage,
) {
    if !observer.enabled() {
        return;
    }

    match message {
        ClientMessage::AuthRequest {
            request_id,
            username,
            ..
        } => observer.emit(
            "network",
            "send_auth_request",
            &[
                ("transport", transport.to_string()),
                ("request_id", request_id.to_string()),
                ("username", username.clone()),
            ],
        ),
        ClientMessage::FastLaneRequest { request_id } => observer.emit(
            "network",
            "send_fast_lane_request",
            &[
                ("transport", transport.to_string()),
                ("request_id", request_id.to_string()),
            ],
        ),
        ClientMessage::FastLaneAttach { request_id, .. } => observer.emit(
            "network",
            "send_fast_lane_attach",
            &[
                ("transport", transport.to_string()),
                ("request_id", request_id.to_string()),
            ],
        ),
        ClientMessage::EnterScene { request_id, cid } => observer.emit(
            "network",
            "send_enter_scene",
            &[
                ("transport", transport.to_string()),
                ("request_id", request_id.to_string()),
                ("cid", cid.to_string()),
            ],
        ),
        ClientMessage::MovementInput {
            seq,
            client_tick,
            input_dir,
            speed_scale,
            movement_flags,
            ..
        } => observer.emit(
            "network",
            "send_movement_input",
            &[
                ("transport", transport.to_string()),
                ("seq", seq.to_string()),
                ("client_tick", client_tick.to_string()),
                (
                    "input_dir",
                    format!("{:.2},{:.2}", input_dir[0], input_dir[1]),
                ),
                ("speed_scale", format!("{speed_scale:.2}")),
                ("movement_flags", movement_flags.to_string()),
            ],
        ),
        ClientMessage::TimeSync {
            request_id,
            client_send_ts,
        } => observer.emit(
            "network",
            "send_time_sync",
            &[
                ("transport", transport.to_string()),
                ("request_id", request_id.to_string()),
                ("client_send_ts", client_send_ts.to_string()),
            ],
        ),
        ClientMessage::Heartbeat { timestamp } => observer.emit(
            "network",
            "send_heartbeat",
            &[
                ("transport", transport.to_string()),
                ("timestamp", timestamp.to_string()),
            ],
        ),
        ClientMessage::ChatSay { request_id, text } => observer.emit(
            "network",
            "send_chat",
            &[
                ("transport", transport.to_string()),
                ("request_id", request_id.to_string()),
                ("text", text.clone()),
            ],
        ),
        ClientMessage::SkillCast {
            request_id,
            skill_id,
            target_kind,
            target_cid,
            target_position,
        } => observer.emit(
            "network",
            "send_skill",
            &[
                ("transport", transport.to_string()),
                ("request_id", request_id.to_string()),
                ("skill_id", skill_id.to_string()),
                ("target_kind", format!("{target_kind:?}")),
                ("target_cid", target_cid.to_string()),
                ("target_position", format_vec(target_position)),
            ],
        ),
    }
}

fn format_vec(value: &[f64; 3]) -> String {
    format!("{:.1},{:.1},{:.1}", value[0], value[1], value[2])
}
