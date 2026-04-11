use std::fmt;

pub type NetVec3 = [f64; 3];

#[derive(Debug, Clone, PartialEq)]
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
    Movement {
        request_id: u64,
        cid: i64,
        timestamp: u64,
        location: NetVec3,
        velocity: NetVec3,
        acceleration: NetVec3,
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
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum ServerMessage {
    Result {
        packet_id: u64,
        ok: bool,
        movement: Option<(i64, NetVec3)>,
    },
    EnterSceneResult {
        packet_id: u64,
        ok: bool,
        location: Option<NetVec3>,
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
        location: NetVec3,
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
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProtocolError(pub String);

impl fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ProtocolError {}

pub fn encode_client_frame(message: &ClientMessage) -> Vec<u8> {
    let payload = encode_client_payload(message);
    let mut frame = Vec::with_capacity(4 + payload.len());
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(&payload);
    frame
}

pub fn decode_server_payload(payload: &[u8]) -> Result<ServerMessage, ProtocolError> {
    if payload.is_empty() {
        return Err(ProtocolError("empty payload".into()));
    }

    let msg_type = payload[0];
    let body = &payload[1..];

    match msg_type {
        0x80 => decode_result(body),
        0x81 => Ok(ServerMessage::PlayerEnter {
            cid: read_i64(body, 0)?,
            location: read_vec3(body, 8)?,
        }),
        0x82 => Ok(ServerMessage::PlayerLeave {
            cid: read_i64(body, 0)?,
        }),
        0x83 => Ok(ServerMessage::PlayerMove {
            cid: read_i64(body, 0)?,
            location: read_vec3(body, 8)?,
        }),
        0x84 => {
            let packet_id = read_u64(body, 0)?;
            let ok = read_u8(body, 8)? == 0;
            let location = if ok && body.len() >= 33 {
                Some(read_vec3(body, 9)?)
            } else {
                None
            };

            Ok(ServerMessage::EnterSceneResult {
                packet_id,
                ok,
                location,
            })
        }
        0x87 => {
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
        0x88 => Ok(ServerMessage::FastLaneAttached {
            packet_id: read_u64(body, 0)?,
            ok: read_u8(body, 8)? == 0,
        }),
        0x85 => Ok(ServerMessage::TimeSyncReply {
            packet_id: read_u64(body, 0)?,
            client_send_ts: read_u64(body, 8)?,
            server_recv_ts: read_u64(body, 16)?,
            server_send_ts: read_u64(body, 24)?,
        }),
        0x86 => Ok(ServerMessage::HeartbeatReply {
            timestamp: read_u64(body, 0)?,
        }),
        0x89 => {
            let cid = read_i64(body, 0)?;
            let (username, after_name) = read_string(body, 8)?;
            let (text, _) = read_string(body, after_name)?;
            Ok(ServerMessage::ChatMessage {
                cid,
                username,
                text,
            })
        }
        0x8A => Ok(ServerMessage::SkillEvent {
            cid: read_i64(body, 0)?,
            skill_id: read_u16(body, 8)?,
            location: read_vec3(body, 10)?,
        }),
        other => Err(ProtocolError(format!(
            "unknown server message type: {other:#x}"
        ))),
    }
}

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
        ClientMessage::Movement {
            request_id,
            cid,
            timestamp,
            location,
            velocity,
            acceleration,
        } => {
            let mut payload = vec![0x01];
            payload.extend_from_slice(&request_id.to_be_bytes());
            payload.extend_from_slice(&cid.to_be_bytes());
            payload.extend_from_slice(&timestamp.to_be_bytes());
            write_vec3(&mut payload, location);
            write_vec3(&mut payload, velocity);
            write_vec3(&mut payload, acceleration);
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
        } => {
            let mut payload = vec![0x09];
            payload.extend_from_slice(&request_id.to_be_bytes());
            payload.extend_from_slice(&skill_id.to_be_bytes());
            payload
        }
    }
}

fn decode_result(body: &[u8]) -> Result<ServerMessage, ProtocolError> {
    match body.len() {
        9 => Ok(ServerMessage::Result {
            packet_id: read_u64(body, 0)?,
            ok: read_u8(body, 8)? == 0,
            movement: None,
        }),
        33 => Ok(ServerMessage::Result {
            packet_id: read_u64(body, 0)?,
            ok: read_u8(body, 8)? == 0,
            movement: Some((read_i64(body, 9)?, read_vec3(body, 17)?)),
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

fn write_vec3(buffer: &mut Vec<u8>, value: &NetVec3) {
    buffer.extend_from_slice(&value[0].to_be_bytes());
    buffer.extend_from_slice(&value[1].to_be_bytes());
    buffer.extend_from_slice(&value[2].to_be_bytes());
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
        });
        assert_eq!(skill, vec![0, 0, 0, 11, 0x09, 0, 0, 0, 0, 0, 0, 0, 8, 0, 1]);
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
    fn takes_framed_messages() {
        let mut buffer = vec![0, 0, 0, 3, 0x04, 1, 2, 0, 0, 0, 1, 0x05];
        assert_eq!(take_frame(&mut buffer), Some(vec![0x04, 1, 2]));
        assert_eq!(buffer, vec![0, 0, 0, 1, 0x05]);
    }
}
