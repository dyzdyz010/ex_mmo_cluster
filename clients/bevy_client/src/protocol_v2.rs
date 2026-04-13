use bevy::prelude::{Vec2, Vec3};

use crate::{
    input::commands::MoveInputFrame,
    protocol::{ClientMessage, ServerMessage},
    sim::types::{MovementAck, MovementMode, RemoteMoveSnapshot},
};

#[derive(Debug, Clone, PartialEq)]
pub struct WireMoveInputFrame {
    pub seq: u32,
    pub client_tick: u32,
    pub dt_ms: u16,
    pub input_dir: Vec2,
    pub speed_scale: f32,
    pub movement_flags: u16,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WireMovementAck {
    pub ack_seq: u32,
    pub auth_tick: u32,
    pub position: Vec3,
    pub velocity: Vec3,
    pub acceleration: Vec3,
    pub movement_mode: u8,
    pub correction_flags: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WireRemoteMoveSnapshot {
    pub cid: i64,
    pub server_tick: u32,
    pub position: Vec3,
    pub velocity: Vec3,
    pub acceleration: Vec3,
    pub movement_mode: u8,
}

impl From<MoveInputFrame> for WireMoveInputFrame {
    fn from(value: MoveInputFrame) -> Self {
        Self {
            seq: value.seq,
            client_tick: value.client_tick,
            dt_ms: value.dt_ms,
            input_dir: value.input_dir,
            speed_scale: value.speed_scale,
            movement_flags: value.movement_flags,
        }
    }
}

impl From<WireMoveInputFrame> for ClientMessage {
    fn from(value: WireMoveInputFrame) -> Self {
        Self::MovementInput {
            seq: value.seq,
            client_tick: value.client_tick,
            dt_ms: value.dt_ms,
            input_dir: [value.input_dir.x, value.input_dir.y],
            speed_scale: value.speed_scale,
            movement_flags: value.movement_flags,
        }
    }
}

impl From<WireMovementAck> for MovementAck {
    fn from(value: WireMovementAck) -> Self {
        Self {
            ack_seq: value.ack_seq,
            auth_tick: value.auth_tick,
            position: value.position,
            velocity: value.velocity,
            acceleration: value.acceleration,
            movement_mode: decode_mode(value.movement_mode),
            correction_flags: value.correction_flags,
        }
    }
}

impl From<WireRemoteMoveSnapshot> for RemoteMoveSnapshot {
    fn from(value: WireRemoteMoveSnapshot) -> Self {
        Self {
            cid: value.cid,
            server_tick: value.server_tick,
            position: value.position,
            velocity: value.velocity,
            acceleration: value.acceleration,
            movement_mode: decode_mode(value.movement_mode),
        }
    }
}

pub fn movement_ack_from_server(message: &ServerMessage) -> Option<MovementAck> {
    match message {
        ServerMessage::MovementAck {
            ack_seq,
            auth_tick,
            location,
            velocity,
            acceleration,
            movement_mode,
            correction_flags,
            ..
        } => Some(
            WireMovementAck {
                ack_seq: *ack_seq,
                auth_tick: *auth_tick,
                position: Vec3::new(location[0] as f32, location[1] as f32, location[2] as f32),
                velocity: Vec3::new(velocity[0] as f32, velocity[1] as f32, velocity[2] as f32),
                acceleration: Vec3::new(
                    acceleration[0] as f32,
                    acceleration[1] as f32,
                    acceleration[2] as f32,
                ),
                movement_mode: *movement_mode,
                correction_flags: *correction_flags,
            }
            .into(),
        ),
        _ => None,
    }
}

pub fn remote_move_snapshot_from_server(message: &ServerMessage) -> Option<RemoteMoveSnapshot> {
    match message {
        ServerMessage::PlayerMove {
            cid,
            server_tick,
            location,
            velocity,
            acceleration,
            movement_mode,
        } => Some(
            WireRemoteMoveSnapshot {
                cid: *cid,
                server_tick: *server_tick,
                position: Vec3::new(location[0] as f32, location[1] as f32, location[2] as f32),
                velocity: Vec3::new(velocity[0] as f32, velocity[1] as f32, velocity[2] as f32),
                acceleration: Vec3::new(
                    acceleration[0] as f32,
                    acceleration[1] as f32,
                    acceleration[2] as f32,
                ),
                movement_mode: *movement_mode,
            }
            .into(),
        ),
        _ => None,
    }
}

fn decode_mode(raw: u8) -> MovementMode {
    match raw {
        1 => MovementMode::Airborne,
        2 => MovementMode::Disabled,
        _ => MovementMode::Grounded,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input::commands::MoveInputFrame;

    #[test]
    fn converts_move_input_frame_to_wire() {
        let frame = MoveInputFrame {
            seq: 9,
            client_tick: 18,
            dt_ms: 33,
            input_dir: Vec2::new(1.0, 0.0),
            speed_scale: 1.2,
            movement_flags: 3,
        };

        let wire = WireMoveInputFrame::from(frame);
        assert_eq!(wire.seq, 9);
        assert_eq!(wire.client_tick, 18);
        assert_eq!(wire.dt_ms, 33);
        assert!(matches!(
            ClientMessage::from(wire),
            ClientMessage::MovementInput { .. }
        ));
    }

    #[test]
    fn converts_ack_and_snapshot_modes() {
        let ack = MovementAck::from(WireMovementAck {
            ack_seq: 1,
            auth_tick: 2,
            position: Vec3::ZERO,
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: 1,
            correction_flags: 0,
        });

        assert_eq!(ack.movement_mode, MovementMode::Airborne);
    }

    #[test]
    fn extracts_remote_snapshot_from_server_message() {
        let snapshot = remote_move_snapshot_from_server(&ServerMessage::PlayerMove {
            cid: 42,
            server_tick: 7,
            location: [1.0, 2.0, 3.0],
            velocity: [4.0, 5.0, 6.0],
            acceleration: [0.1, 0.2, 0.3],
            movement_mode: 2,
        })
        .expect("remote snapshot");

        assert_eq!(snapshot.cid, 42);
        assert_eq!(snapshot.server_tick, 7);
        assert_eq!(snapshot.movement_mode, MovementMode::Disabled);
    }
}
