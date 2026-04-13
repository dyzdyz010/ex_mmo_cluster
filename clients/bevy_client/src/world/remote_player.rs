use bevy::prelude::Vec3;

use crate::sim::types::RemoteMoveSnapshot;

const MAX_REMOTE_EXTRAPOLATION_SECS: f32 = 0.12;

#[derive(Debug, Clone)]
pub struct RemotePlayerState {
    // TODO(vnext-stage3): replace this single-latest snapshot with a proper
    // snapshot ring buffer + interpolation cursor. The current short-term
    // extrapolation is good enough for Stage 1/2 demos, but future network
    // smoothing should consume buffered snapshots with an explicit playback delay.
    snapshot: RemoteMoveSnapshot,
    received_at_secs: f64,
}

impl RemotePlayerState {
    pub fn seeded(cid: i64, position: Vec3, received_at_secs: f64) -> Self {
        Self {
            snapshot: RemoteMoveSnapshot {
                cid,
                server_tick: 0,
                position,
                velocity: Vec3::ZERO,
                acceleration: Vec3::ZERO,
                movement_mode: crate::sim::types::MovementMode::Grounded,
            },
            received_at_secs,
        }
    }

    pub fn from_snapshot(snapshot: RemoteMoveSnapshot, received_at_secs: f64) -> Self {
        Self {
            snapshot,
            received_at_secs,
        }
    }

    pub fn latest_position(&self) -> Vec3 {
        self.snapshot.position
    }

    pub fn server_tick(&self) -> u32 {
        self.snapshot.server_tick
    }

    pub fn sample_position(&self, now_secs: f64) -> Vec3 {
        let dt =
            ((now_secs - self.received_at_secs) as f32).clamp(0.0, MAX_REMOTE_EXTRAPOLATION_SECS);
        self.snapshot.position
            + self.snapshot.velocity * dt
            + self.snapshot.acceleration * (0.5 * dt * dt)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sim::types::{MovementMode, RemoteMoveSnapshot};

    #[test]
    fn samples_remote_position_with_velocity_and_acceleration() {
        let state = RemotePlayerState::from_snapshot(
            RemoteMoveSnapshot {
                cid: 7,
                server_tick: 11,
                position: Vec3::new(10.0, 0.0, 0.0),
                velocity: Vec3::new(5.0, 0.0, 0.0),
                acceleration: Vec3::new(2.0, 0.0, 0.0),
                movement_mode: MovementMode::Grounded,
            },
            1.0,
        );

        let sampled = state.sample_position(1.1);
        assert!(sampled.x > 10.0);
    }
}
