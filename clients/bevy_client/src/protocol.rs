//! Wire-level protocol shapes shared between the client runtime and the gate.

use std::fmt;

pub type NetVec3 = [f64; 3];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// Actor identity kind sent over the wire for remote-entity classification.
pub enum ActorKind {
    Player,
    Npc,
    Unknown(u8),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// Targeting mode attached to a skill cast request.
pub enum SkillTargetKind {
    Auto,
    Actor,
    Point,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// Stateless visual cue kind broadcast by the server for replicated effects.
pub enum EffectCueKind {
    MeleeArc,
    Projectile,
    AoeRing,
    ChainArc,
    ImpactPulse,
    Unknown(u8),
}

#[derive(Debug, Clone, PartialEq)]
/// Messages the client can send to the gate.
pub enum ClientMessage {
    AuthRequest {
        request_id: u64,
        username: String,
        token: String,
    },
    FastLaneRequest {
        request_id: u64,
    },
    FastLaneAttach {
        request_id: u64,
        ticket: String,
    },
    EnterScene {
        request_id: u64,
        cid: i64,
    },
    MovementInput {
        seq: u32,
        client_tick: u32,
        dt_ms: u16,
        input_dir: [f32; 2],
        speed_scale: f32,
        movement_flags: u16,
    },
    TimeSync {
        request_id: u64,
        client_send_ts: u64,
    },
    Heartbeat {
        timestamp: u64,
    },
    ChatSay {
        request_id: u64,
        text: String,
    },
    SkillCast {
        request_id: u64,
        skill_id: u16,
        target_kind: SkillTargetKind,
        target_cid: i64,
        target_position: NetVec3,
    },
}

#[derive(Debug, Clone, PartialEq)]
/// Messages the client can receive from the gate.
pub enum ServerMessage {
    Result {
        packet_id: u64,
        ok: bool,
    },
    MovementAck {
        ack_seq: u32,
        auth_tick: u32,
        cid: i64,
        location: NetVec3,
        velocity: NetVec3,
        acceleration: NetVec3,
        movement_mode: u8,
        correction_flags: u32,
        /// Audit B-M2: server-authoritative fixed-tick interval (ms),
        /// echoed in every ack so the client can compare it with its
        /// own `MovementProfile.fixed_dt_ms` and warn on drift.
        server_fixed_dt_ms: u16,
    },
    EnterSceneResult {
        packet_id: u64,
        ok: bool,
        location: Option<NetVec3>,
        /// Audit B-S1 / B-SRV2: server-side next-expected movement input
        /// `seq`. Present only on success (None on error). The client must
        /// reset its local input counter to this value before any movement
        /// input is sent.
        expected_seq: Option<u32>,
    },
    PlayerEnter {
        cid: i64,
        location: NetVec3,
    },
    PlayerLeave {
        cid: i64,
    },
    PlayerMove {
        cid: i64,
        server_tick: u32,
        location: NetVec3,
        velocity: NetVec3,
        acceleration: NetVec3,
        movement_mode: u8,
    },
    TimeSyncReply {
        packet_id: u64,
        client_send_ts: u64,
        server_recv_ts: u64,
        server_send_ts: u64,
    },
    HeartbeatReply {
        timestamp: u64,
    },
    FastLaneResult {
        packet_id: u64,
        ok: bool,
        udp_port: Option<u16>,
        ticket: Option<String>,
    },
    FastLaneAttached {
        packet_id: u64,
        ok: bool,
    },
    ChatMessage {
        cid: i64,
        username: String,
        text: String,
    },
    SkillEvent {
        cid: i64,
        skill_id: u16,
        location: NetVec3,
    },
    PlayerState {
        cid: i64,
        hp: u16,
        max_hp: u16,
        alive: bool,
    },
    CombatHit {
        source_cid: i64,
        target_cid: i64,
        skill_id: u16,
        damage: u16,
        hp_after: u16,
        location: NetVec3,
    },
    ActorIdentity {
        cid: i64,
        kind: ActorKind,
        name: String,
    },
    EffectEvent {
        source_cid: i64,
        skill_id: u16,
        cue_kind: EffectCueKind,
        target_cid: Option<i64>,
        origin: NetVec3,
        target_position: NetVec3,
        radius: f64,
        duration_ms: u32,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// Binary protocol parse/encode error.
pub struct ProtocolError(pub String);

impl fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ProtocolError {}

/// Encodes one client message as a length-prefixed TCP frame.
pub fn encode_client_frame(message: &ClientMessage) -> Vec<u8> {
    let payload = encode_client_payload(message);
    let mut frame = Vec::with_capacity(4 + payload.len());
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(&payload);
    frame
}

/// Decodes one server payload (without length prefix) into a structured message.
pub fn decode_server_payload(payload: &[u8]) -> Result<ServerMessage, ProtocolError> {
    if payload.is_empty() {
        return Err(ProtocolError("empty payload".into()));
    }

    let msg_type = payload[0];
    let body = &payload[1..];

    match msg_type {
        0x80 => decode_result(body),
        0x8B => {
            // 4 + 4 + 8 + 24 + 24 + 24 + 1 + 4 + 2 = 95 (audit B-M2 added u16).
            require_body_len(body, 95, "MovementAck")?;
            Ok(ServerMessage::MovementAck {
                ack_seq: read_u32(body, 0)?,
                auth_tick: read_u32(body, 4)?,
                cid: read_i64(body, 8)?,
                location: read_vec3(body, 16)?,
                velocity: read_vec3(body, 40)?,
                acceleration: read_vec3(body, 64)?,
                movement_mode: read_u8(body, 88)?,
                correction_flags: read_u32(body, 89)?,
                server_fixed_dt_ms: read_u16(body, 93)?,
            })
        }
        0x81 => {
            // 8 + 24 = 32
            require_body_len(body, 32, "PlayerEnter")?;
            Ok(ServerMessage::PlayerEnter {
                cid: read_i64(body, 0)?,
                location: read_vec3(body, 8)?,
            })
        }
        0x82 => {
            require_body_len(body, 8, "PlayerLeave")?;
            Ok(ServerMessage::PlayerLeave {
                cid: read_i64(body, 0)?,
            })
        }
        0x83 => {
            // 8 + 4 + 24 + 24 + 24 + 1 = 85
            require_body_len(body, 85, "PlayerMove")?;
            Ok(ServerMessage::PlayerMove {
                cid: read_i64(body, 0)?,
                server_tick: read_u32(body, 8)?,
                location: read_vec3(body, 12)?,
                velocity: read_vec3(body, 36)?,
                acceleration: read_vec3(body, 60)?,
                movement_mode: read_u8(body, 84)?,
            })
        }
        0x84 => {
            // 8 + 1 = 9 minimum (ok=false), or 9 + 24 + 4 = 37 (ok=true).
            // Audit B-S1 / B-SRV2 added the trailing expected_seq u32.
            require_body_len(body, 9, "EnterSceneResult")?;
            let packet_id = read_u64(body, 0)?;
            let ok = read_u8(body, 8)? == 0;
            // Audit A-M3: when ok, location is required by the protocol.
            // Previously we silently fell back to None on a short body and
            // then `runtime` `expect()`-panicked. Surface a proper error.
            let (location, expected_seq) = if ok {
                let location = read_vec3(body, 9)?;
                let expected_seq = read_u32(body, 33)?;
                (Some(location), Some(expected_seq))
            } else {
                (None, None)
            };

            Ok(ServerMessage::EnterSceneResult {
                packet_id,
                ok,
                location,
                expected_seq,
            })
        }
        0x87 => {
            require_body_len(body, 9, "FastLaneResult")?;
            let packet_id = read_u64(body, 0)?;
            let ok = read_u8(body, 8)? == 0;

            let (udp_port, ticket) = if ok && body.len() >= 13 {
                let udp_port = read_u16(body, 9)?;
                let (ticket, _) = read_string(body, 11)?;
                (Some(udp_port), Some(ticket))
            } else {
                (None, None)
            };

            Ok(ServerMessage::FastLaneResult {
                packet_id,
                ok,
                udp_port,
                ticket,
            })
        }
        0x88 => {
            require_body_len(body, 9, "FastLaneAttached")?;
            Ok(ServerMessage::FastLaneAttached {
                packet_id: read_u64(body, 0)?,
                ok: read_u8(body, 8)? == 0,
            })
        }
        0x85 => {
            // 8 + 8 + 8 + 8 = 32
            require_body_len(body, 32, "TimeSyncReply")?;
            Ok(ServerMessage::TimeSyncReply {
                packet_id: read_u64(body, 0)?,
                client_send_ts: read_u64(body, 8)?,
                server_recv_ts: read_u64(body, 16)?,
                server_send_ts: read_u64(body, 24)?,
            })
        }
        0x86 => {
            require_body_len(body, 8, "HeartbeatReply")?;
            Ok(ServerMessage::HeartbeatReply {
                timestamp: read_u64(body, 0)?,
            })
        }
        0x89 => {
            require_body_len(body, 10, "ChatMessage")?; // 8 cid + 2 string-len prefix
            let cid = read_i64(body, 0)?;
            let (username, after_name) = read_string(body, 8)?;
            let (text, _) = read_string(body, after_name)?;
            Ok(ServerMessage::ChatMessage {
                cid,
                username,
                text,
            })
        }
        0x8A => {
            // 8 + 2 + 24 = 34
            require_body_len(body, 34, "SkillEvent")?;
            Ok(ServerMessage::SkillEvent {
                cid: read_i64(body, 0)?,
                skill_id: read_u16(body, 8)?,
                location: read_vec3(body, 10)?,
            })
        }
        0x8C => {
            // 8 + 2 + 2 + 1 = 13
            require_body_len(body, 13, "PlayerState")?;
            Ok(ServerMessage::PlayerState {
                cid: read_i64(body, 0)?,
                hp: read_u16(body, 8)?,
                max_hp: read_u16(body, 10)?,
                alive: read_u8(body, 12)? != 0,
            })
        }
        0x8D => {
            // 8 + 8 + 2 + 2 + 2 + 24 = 46
            require_body_len(body, 46, "CombatHit")?;
            Ok(ServerMessage::CombatHit {
                source_cid: read_i64(body, 0)?,
                target_cid: read_i64(body, 8)?,
                skill_id: read_u16(body, 16)?,
                damage: read_u16(body, 18)?,
                hp_after: read_u16(body, 20)?,
                location: read_vec3(body, 22)?,
            })
        }
        0x8E => {
            require_body_len(body, 11, "ActorIdentity")?; // 8 cid + 1 kind + 2 string-len
            let cid = read_i64(body, 0)?;
            let kind = decode_actor_kind(read_u8(body, 8)?);
            let (name, _) = read_string(body, 9)?;
            Ok(ServerMessage::ActorIdentity { cid, kind, name })
        }
        0x8F => {
            // 8 + 2 + 1 + 8 + 24 + 24 + 8 + 4 = 79
            require_body_len(body, 79, "EffectEvent")?;
            Ok(ServerMessage::EffectEvent {
                source_cid: read_i64(body, 0)?,
                skill_id: read_u16(body, 8)?,
                cue_kind: decode_effect_cue_kind(read_u8(body, 10)?),
                target_cid: decode_target_cid(read_i64(body, 11)?),
                origin: read_vec3(body, 19)?,
                target_position: read_vec3(body, 43)?,
                radius: read_f64(body, 67)?,
                duration_ms: read_u32(body, 75)?,
            })
        }
        other => Err(ProtocolError(format!(
            "unknown server message type: {other:#x}"
        ))),
    }
}

/// Extracts one complete frame from a length-prefixed receive buffer.
pub fn take_frame(buffer: &mut Vec<u8>) -> Option<Vec<u8>> {
    if buffer.len() < 4 {
        return None;
    }

    let length = u32::from_be_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]) as usize;
    if buffer.len() < length + 4 {
        return None;
    }

    let payload = buffer[4..4 + length].to_vec();
    buffer.drain(..4 + length);
    Some(payload)
}

/// Encodes the payload portion of one client message.
pub fn encode_client_payload(message: &ClientMessage) -> Vec<u8> {
    match message {
        ClientMessage::AuthRequest {
            request_id,
            username,
            token,
        } => {
            let mut payload = vec![0x05];
            payload.extend_from_slice(&request_id.to_be_bytes());
            write_string(&mut payload, username);
            write_string(&mut payload, token);
            payload
        }
        ClientMessage::FastLaneRequest { request_id } => {
            let mut payload = vec![0x06];
            payload.extend_from_slice(&request_id.to_be_bytes());
            payload
        }
        ClientMessage::FastLaneAttach { request_id, ticket } => {
            let mut payload = vec![0x07];
            payload.extend_from_slice(&request_id.to_be_bytes());
            write_string(&mut payload, ticket);
            payload
        }
        ClientMessage::EnterScene { request_id, cid } => {
            let mut payload = vec![0x02];
            payload.extend_from_slice(&request_id.to_be_bytes());
            payload.extend_from_slice(&cid.to_be_bytes());
            payload
        }
        ClientMessage::MovementInput {
            seq,
            client_tick,
            dt_ms,
            input_dir,
            speed_scale,
            movement_flags,
        } => {
            let mut payload = vec![0x01];
            payload.extend_from_slice(&seq.to_be_bytes());
            payload.extend_from_slice(&client_tick.to_be_bytes());
            payload.extend_from_slice(&dt_ms.to_be_bytes());
            payload.extend_from_slice(&input_dir[0].to_be_bytes());
            payload.extend_from_slice(&input_dir[1].to_be_bytes());
            payload.extend_from_slice(&speed_scale.to_be_bytes());
            payload.extend_from_slice(&movement_flags.to_be_bytes());
            payload
        }
        ClientMessage::TimeSync {
            request_id,
            client_send_ts,
        } => {
            let mut payload = vec![0x03];
            payload.extend_from_slice(&request_id.to_be_bytes());
            payload.extend_from_slice(&client_send_ts.to_be_bytes());
            payload
        }
        ClientMessage::Heartbeat { timestamp } => {
            let mut payload = vec![0x04];
            payload.extend_from_slice(&timestamp.to_be_bytes());
            payload
        }
        ClientMessage::ChatSay { request_id, text } => {
            let mut payload = vec![0x08];
            payload.extend_from_slice(&request_id.to_be_bytes());
            write_string(&mut payload, text);
            payload
        }
        ClientMessage::SkillCast {
            request_id,
            skill_id,
            target_kind,
            target_cid,
            target_position,
        } => {
            let mut payload = vec![0x09];
            payload.extend_from_slice(&request_id.to_be_bytes());
            payload.extend_from_slice(&skill_id.to_be_bytes());
            payload.push(encode_skill_target_kind(*target_kind));
            payload.extend_from_slice(&target_cid.to_be_bytes());
            payload.extend_from_slice(&target_position[0].to_be_bytes());
            payload.extend_from_slice(&target_position[1].to_be_bytes());
            payload.extend_from_slice(&target_position[2].to_be_bytes());
            payload
        }
    }
}

fn decode_result(body: &[u8]) -> Result<ServerMessage, ProtocolError> {
    match body.len() {
        9 => Ok(ServerMessage::Result {
            packet_id: read_u64(body, 0)?,
            ok: read_u8(body, 8)? == 0,
        }),
        other => Err(ProtocolError(format!(
            "unexpected result body length: {other}"
        ))),
    }
}

fn write_string(buffer: &mut Vec<u8>, value: &str) {
    let bytes = value.as_bytes();
    buffer.extend_from_slice(&(bytes.len() as u16).to_be_bytes());
    buffer.extend_from_slice(bytes);
}

/// Asserts that `body` is at least `expected_min` bytes long, returning a
/// kind-specific error otherwise. Audit A-S1 / A-L1: makes "body too short"
/// errors precise per message type rather than relying on the underlying
/// `read_*` helpers' generic "missing X at offset Y" message.
fn require_body_len(body: &[u8], expected_min: usize, msg_kind: &str) -> Result<(), ProtocolError> {
    if body.len() < expected_min {
        return Err(ProtocolError(format!(
            "{msg_kind} body too short: {} < {}",
            body.len(),
            expected_min
        )));
    }
    Ok(())
}

fn read_u8(body: &[u8], offset: usize) -> Result<u8, ProtocolError> {
    body.get(offset)
        .copied()
        .ok_or_else(|| ProtocolError(format!("missing u8 at offset {offset}")))
}

fn read_u16(body: &[u8], offset: usize) -> Result<u16, ProtocolError> {
    let bytes = body
        .get(offset..offset + 2)
        .ok_or_else(|| ProtocolError(format!("missing u16 at offset {offset}")))?;
    Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
}

fn read_u64(body: &[u8], offset: usize) -> Result<u64, ProtocolError> {
    let bytes = body
        .get(offset..offset + 8)
        .ok_or_else(|| ProtocolError(format!("missing u64 at offset {offset}")))?;
    Ok(u64::from_be_bytes(bytes.try_into().expect("slice length")))
}

fn read_u32(body: &[u8], offset: usize) -> Result<u32, ProtocolError> {
    let bytes = body
        .get(offset..offset + 4)
        .ok_or_else(|| ProtocolError(format!("missing u32 at offset {offset}")))?;
    Ok(u32::from_be_bytes(bytes.try_into().expect("slice length")))
}

fn read_i64(body: &[u8], offset: usize) -> Result<i64, ProtocolError> {
    let bytes = body
        .get(offset..offset + 8)
        .ok_or_else(|| ProtocolError(format!("missing i64 at offset {offset}")))?;
    Ok(i64::from_be_bytes(bytes.try_into().expect("slice length")))
}

fn read_f64(body: &[u8], offset: usize) -> Result<f64, ProtocolError> {
    let bytes = body
        .get(offset..offset + 8)
        .ok_or_else(|| ProtocolError(format!("missing f64 at offset {offset}")))?;
    Ok(f64::from_be_bytes(bytes.try_into().expect("slice length")))
}

fn read_vec3(body: &[u8], offset: usize) -> Result<NetVec3, ProtocolError> {
    Ok([
        read_f64(body, offset)?,
        read_f64(body, offset + 8)?,
        read_f64(body, offset + 16)?,
    ])
}

fn read_string(body: &[u8], offset: usize) -> Result<(String, usize), ProtocolError> {
    let length = read_u16(body, offset)? as usize;
    let start = offset + 2;
    let end = start + length;
    let bytes = body
        .get(start..end)
        .ok_or_else(|| ProtocolError(format!("missing string bytes at offset {offset}")))?;
    let value = std::str::from_utf8(bytes)
        .map_err(|error| ProtocolError(format!("invalid utf8 string: {error}")))?;
    Ok((value.to_owned(), end))
}

fn decode_actor_kind(value: u8) -> ActorKind {
    match value {
        0 => ActorKind::Player,
        1 => ActorKind::Npc,
        other => ActorKind::Unknown(other),
    }
}

fn decode_effect_cue_kind(value: u8) -> EffectCueKind {
    match value {
        0 => EffectCueKind::MeleeArc,
        1 => EffectCueKind::Projectile,
        2 => EffectCueKind::AoeRing,
        3 => EffectCueKind::ChainArc,
        4 => EffectCueKind::ImpactPulse,
        other => EffectCueKind::Unknown(other),
    }
}

fn encode_skill_target_kind(value: SkillTargetKind) -> u8 {
    match value {
        SkillTargetKind::Auto => 0,
        SkillTargetKind::Actor => 1,
        SkillTargetKind::Point => 2,
    }
}

fn decode_target_cid(value: i64) -> Option<i64> {
    if value < 0 { None } else { Some(value) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_chat_and_skill_frames() {
        let chat = encode_client_frame(&ClientMessage::ChatSay {
            request_id: 7,
            text: "hello".into(),
        });
        assert_eq!(
            chat,
            vec![
                0, 0, 0, 16, 0x08, 0, 0, 0, 0, 0, 0, 0, 7, 0, 5, b'h', b'e', b'l', b'l', b'o'
            ]
        );

        let skill = encode_client_frame(&ClientMessage::SkillCast {
            request_id: 8,
            skill_id: 1,
            target_kind: SkillTargetKind::Actor,
            target_cid: 42,
            target_position: [10.0, 20.0, 30.0],
        });
        assert_eq!(u32::from_be_bytes(skill[0..4].try_into().unwrap()), 44);
        assert_eq!(skill[4], 0x09);
    }

    #[test]
    fn encodes_fast_lane_frames() {
        let bootstrap = encode_client_frame(&ClientMessage::FastLaneRequest { request_id: 9 });
        assert_eq!(bootstrap, vec![0, 0, 0, 9, 0x06, 0, 0, 0, 0, 0, 0, 0, 9]);

        let attach = encode_client_frame(&ClientMessage::FastLaneAttach {
            request_id: 10,
            ticket: "ticket-123".into(),
        });
        assert_eq!(
            attach,
            vec![
                0, 0, 0, 21, 0x07, 0, 0, 0, 0, 0, 0, 0, 10, 0, 10, b't', b'i', b'c', b'k', b'e',
                b't', b'-', b'1', b'2', b'3'
            ]
        );
    }

    #[test]
    fn encodes_movement_input_frame() {
        let frame = encode_client_frame(&ClientMessage::MovementInput {
            seq: 7,
            client_tick: 11,
            dt_ms: 100,
            input_dir: [1.0, 0.0],
            speed_scale: 1.0,
            movement_flags: 2,
        });

        assert_eq!(u32::from_be_bytes(frame[0..4].try_into().unwrap()), 25);
        assert_eq!(frame[4], 0x01);
    }

    #[test]
    fn decodes_chat_and_skill_events() {
        let chat = vec![
            0x89, 0, 0, 0, 0, 0, 0, 0, 42, 0, 6, b't', b'e', b's', b't', b'e', b'r', 0, 5, b'h',
            b'e', b'l', b'l', b'o',
        ];
        assert_eq!(
            decode_server_payload(&chat).unwrap(),
            ServerMessage::ChatMessage {
                cid: 42,
                username: "tester".into(),
                text: "hello".into(),
            }
        );

        let skill = vec![
            0x8A, 0, 0, 0, 0, 0, 0, 0, 42, 0, 1, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0, 0, 0,
            0, 0, 0x40, 0x08, 0, 0, 0, 0, 0, 0,
        ];
        assert_eq!(
            decode_server_payload(&skill).unwrap(),
            ServerMessage::SkillEvent {
                cid: 42,
                skill_id: 1,
                location: [1.0, 2.0, 3.0],
            }
        );

        let player_state = vec![0x8C, 0, 0, 0, 0, 0, 0, 0, 42, 0, 75, 0, 100, 1];
        assert_eq!(
            decode_server_payload(&player_state).unwrap(),
            ServerMessage::PlayerState {
                cid: 42,
                hp: 75,
                max_hp: 100,
                alive: true,
            }
        );

        let combat_hit = vec![
            0x8D, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 42, 0, 1, 0, 25, 0, 75, 0x3f, 0xf0,
            0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0, 0, 0, 0, 0, 0x40, 0x08, 0, 0, 0, 0, 0, 0,
        ];
        assert_eq!(
            decode_server_payload(&combat_hit).unwrap(),
            ServerMessage::CombatHit {
                source_cid: 7,
                target_cid: 42,
                skill_id: 1,
                damage: 25,
                hp_after: 75,
                location: [1.0, 2.0, 3.0],
            }
        );

        let effect = {
            let mut bytes = vec![0x8F];
            bytes.extend_from_slice(&7_i64.to_be_bytes());
            bytes.extend_from_slice(&4_u16.to_be_bytes());
            bytes.push(1);
            bytes.extend_from_slice(&42_i64.to_be_bytes());
            bytes.extend_from_slice(&1.0_f64.to_be_bytes());
            bytes.extend_from_slice(&2.0_f64.to_be_bytes());
            bytes.extend_from_slice(&3.0_f64.to_be_bytes());
            bytes.extend_from_slice(&4.0_f64.to_be_bytes());
            bytes.extend_from_slice(&5.0_f64.to_be_bytes());
            bytes.extend_from_slice(&6.0_f64.to_be_bytes());
            bytes.extend_from_slice(&96.0_f64.to_be_bytes());
            bytes.extend_from_slice(&350_u32.to_be_bytes());
            bytes
        };
        assert_eq!(
            decode_server_payload(&effect).unwrap(),
            ServerMessage::EffectEvent {
                source_cid: 7,
                skill_id: 4,
                cue_kind: EffectCueKind::Projectile,
                target_cid: Some(42),
                origin: [1.0, 2.0, 3.0],
                target_position: [4.0, 5.0, 6.0],
                radius: 96.0,
                duration_ms: 350,
            }
        );

        let actor_identity = vec![
            0x8E, 0, 0, 0, 0, 0, 1, 0x5f, 0x91, 0x01, 0, 14, b'T', b'r', b'a', b'i', b'n', b'i',
            b'n', b'g', b' ', b'S', b'l', b'i', b'm', b'e',
        ];
        assert_eq!(
            decode_server_payload(&actor_identity).unwrap(),
            ServerMessage::ActorIdentity {
                cid: 90_001,
                kind: ActorKind::Npc,
                name: "Training Slime".into(),
            }
        );
    }

    #[test]
    fn decodes_fast_lane_events() {
        let fast_lane_result = vec![
            0x87, 0, 0, 0, 0, 0, 0, 0, 12, 0x00, 0x71, 0x49, 0, 6, b't', b'i', b'c', b'k', b'e',
            b't',
        ];
        assert_eq!(
            decode_server_payload(&fast_lane_result).unwrap(),
            ServerMessage::FastLaneResult {
                packet_id: 12,
                ok: true,
                udp_port: Some(29_001),
                ticket: Some("ticket".into()),
            }
        );

        let attached = vec![0x88, 0, 0, 0, 0, 0, 0, 0, 13, 0x00];
        assert_eq!(
            decode_server_payload(&attached).unwrap(),
            ServerMessage::FastLaneAttached {
                packet_id: 13,
                ok: true,
            }
        );
    }

    #[test]
    fn decodes_movement_ack() {
        let payload = {
            let mut bytes = vec![0x8B];
            bytes.extend_from_slice(&7_u32.to_be_bytes());
            bytes.extend_from_slice(&11_u32.to_be_bytes());
            bytes.extend_from_slice(&42_i64.to_be_bytes());
            bytes.extend_from_slice(&1.0_f64.to_be_bytes());
            bytes.extend_from_slice(&2.0_f64.to_be_bytes());
            bytes.extend_from_slice(&3.0_f64.to_be_bytes());
            bytes.extend_from_slice(&4.0_f64.to_be_bytes());
            bytes.extend_from_slice(&5.0_f64.to_be_bytes());
            bytes.extend_from_slice(&6.0_f64.to_be_bytes());
            bytes.extend_from_slice(&7.0_f64.to_be_bytes());
            bytes.extend_from_slice(&8.0_f64.to_be_bytes());
            bytes.extend_from_slice(&9.0_f64.to_be_bytes());
            bytes.push(0);
            bytes.extend_from_slice(&3_u32.to_be_bytes());
            // Audit B-M2: trailing fixed_dt_ms u16 BE.
            bytes.extend_from_slice(&100_u16.to_be_bytes());
            bytes
        };

        assert_eq!(
            decode_server_payload(&payload).unwrap(),
            ServerMessage::MovementAck {
                ack_seq: 7,
                auth_tick: 11,
                cid: 42,
                location: [1.0, 2.0, 3.0],
                velocity: [4.0, 5.0, 6.0],
                acceleration: [7.0, 8.0, 9.0],
                movement_mode: 0,
                correction_flags: 3,
                server_fixed_dt_ms: 100,
            }
        );
    }

    #[test]
    fn decodes_player_move_snapshot() {
        let payload = vec![
            0x83, 0, 0, 0, 0, 0, 0, 0, 42, 0, 0, 0, 7, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0,
            0, 0, 0, 0, 0x40, 0x08, 0, 0, 0, 0, 0, 0, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0, 0x40, 0x04, 0,
            0, 0, 0, 0, 0, 0x40, 0x0c, 0, 0, 0, 0, 0, 0, 0x3f, 0xb9, 0x99, 0x99, 0x99, 0x99, 0x99,
            0x9a, 0x3f, 0xc9, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a, 0x3f, 0xd3, 0x33, 0x33, 0x33,
            0x33, 0x33, 0x33, 1,
        ];

        assert_eq!(
            decode_server_payload(&payload).unwrap(),
            ServerMessage::PlayerMove {
                cid: 42,
                server_tick: 7,
                location: [1.0, 2.0, 3.0],
                velocity: [1.5, 2.5, 3.5],
                acceleration: [0.1, 0.2, 0.3],
                movement_mode: 1,
            }
        );
    }

    #[test]
    fn takes_framed_messages() {
        let mut buffer = vec![0, 0, 0, 3, 0x04, 1, 2, 0, 0, 0, 1, 0x05];
        assert_eq!(take_frame(&mut buffer), Some(vec![0x04, 1, 2]));
        assert_eq!(buffer, vec![0, 0, 0, 1, 0x05]);
    }

    // Audit A-S1: short MovementAck must produce a precise, kind-specific
    // error rather than a generic "missing u32 at offset 89".
    #[test]
    fn movement_ack_short_body_is_rejected_with_kind_error() {
        let mut payload = vec![0x8B];
        payload.extend(std::iter::repeat_n(0u8, 50)); // way too short
        let err = decode_server_payload(&payload).unwrap_err();
        let msg = err.0.clone();
        assert!(
            msg.contains("MovementAck"),
            "expected MovementAck-tagged error, got {msg}"
        );
        assert!(
            msg.contains("body too short"),
            "expected body-too-short error, got {msg}"
        );
    }

    // Audit A-L1: every fixed-size variant should reject short bodies with
    // its kind name in the error.
    #[test]
    fn fixed_size_variants_reject_short_bodies() {
        for (msg_type, kind) in [
            (0x81u8, "PlayerEnter"),
            (0x82, "PlayerLeave"),
            (0x83, "PlayerMove"),
            (0x85, "TimeSyncReply"),
            (0x86, "HeartbeatReply"),
            (0x88, "FastLaneAttached"),
            (0x8A, "SkillEvent"),
            (0x8C, "PlayerState"),
            (0x8D, "CombatHit"),
            (0x8F, "EffectEvent"),
        ] {
            let payload = vec![msg_type]; // empty body
            let err = decode_server_payload(&payload).unwrap_err();
            let msg = err.0.clone();
            assert!(
                msg.contains(kind) && msg.contains("body too short"),
                "msg_type {msg_type:#x} ({kind}) expected kind-specific length error, got {msg}"
            );
        }
    }

    // Audit A-M3: EnterSceneResult with ok=success but missing location must
    // surface a ProtocolError instead of silently returning None (which would
    // panic upstream when `expect`-unwrapped).
    #[test]
    fn enter_scene_result_success_without_location_errors() {
        // body = packet_id(8) + ok(1) ; ok=0 means "ok" per protocol, no location.
        let mut payload = vec![0x84];
        payload.extend([0u8; 8]); // packet_id
        payload.push(0); // ok = success
        // intentionally no 24-byte vec3
        let err = decode_server_payload(&payload).unwrap_err();
        let msg = err.0.clone();
        assert!(
            msg.contains("vec3") || msg.contains("missing"),
            "expected vec3/missing-component error, got {msg}"
        );
    }

    #[test]
    fn enter_scene_result_failure_short_body_is_accepted() {
        // ok=1 means failure, no location and no expected_seq expected.
        let mut payload = vec![0x84];
        payload.extend([0u8; 8]);
        payload.push(1); // ok = failure
        let result = decode_server_payload(&payload).unwrap();
        match result {
            ServerMessage::EnterSceneResult {
                ok,
                location,
                expected_seq,
                ..
            } => {
                assert!(!ok);
                assert!(location.is_none());
                assert!(expected_seq.is_none());
            }
            other => panic!("expected EnterSceneResult, got {other:?}"),
        }
    }

    // Audit B-S1 / B-SRV2: success carries the trailing expected_seq u32 BE.
    #[test]
    fn enter_scene_result_success_carries_expected_seq() {
        // body = packet_id(8) + ok(1) + vec3(24) + expected_seq u32 BE
        let mut payload = vec![0x84];
        payload.extend([0u8; 8]); // packet_id = 0
        payload.push(0); // ok = success
        payload.extend([0u8; 24]); // location = (0, 0, 0)
        payload.extend([0, 0, 0, 7]); // expected_seq = 7

        let result = decode_server_payload(&payload).unwrap();
        match result {
            ServerMessage::EnterSceneResult {
                ok,
                location,
                expected_seq,
                ..
            } => {
                assert!(ok);
                assert!(location.is_some());
                assert_eq!(expected_seq, Some(7));
            }
            other => panic!("expected EnterSceneResult, got {other:?}"),
        }
    }
}
