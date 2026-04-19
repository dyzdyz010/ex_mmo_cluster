//! Remote actor motion buffering and interpolation.

use bevy::prelude::Vec3;
use std::collections::VecDeque;

use crate::sim::types::RemoteMoveSnapshot;

const MAX_BUFFERED_SNAPSHOTS: usize = 32;
const SNAPSHOT_TICK_SECS: f64 = 0.1;
// Interp delay ≈ 2.2 × snapshot interval lets a single late/lost packet stay
// inside the buffer instead of falling out into extrapolation territory.
const INTERPOLATION_DELAY_SECS: f64 = 0.22;
const MAX_REMOTE_EXTRAPOLATION_SECS: f64 = 0.25;

#[derive(Debug, Clone)]
struct BufferedSnapshot {
    snapshot: RemoteMoveSnapshot,
    received_at_secs: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
/// Presentation-layer motion sample produced from buffered remote snapshots.
pub struct RemoteMotionSample {
    pub position: Vec3,
    pub velocity: Vec3,
}

#[derive(Debug, Clone)]
/// Buffered remote actor motion state used for interpolation/extrapolation.
pub struct RemotePlayerState {
    snapshots: VecDeque<BufferedSnapshot>,
}

impl RemotePlayerState {
    /// Seeds a new remote actor state from an initial position.
    pub fn seeded(cid: i64, position: Vec3, received_at_secs: f64) -> Self {
        Self::from_snapshot(
            RemoteMoveSnapshot {
                cid,
                server_tick: 0,
                position,
                velocity: Vec3::ZERO,
                acceleration: Vec3::ZERO,
                movement_mode: crate::sim::types::MovementMode::Grounded,
            },
            received_at_secs,
        )
    }

    /// Creates a remote actor state from the first received snapshot.
    pub fn from_snapshot(snapshot: RemoteMoveSnapshot, received_at_secs: f64) -> Self {
        let mut snapshots = VecDeque::with_capacity(MAX_BUFFERED_SNAPSHOTS);
        snapshots.push_back(BufferedSnapshot {
            snapshot,
            received_at_secs,
        });
        Self { snapshots }
    }

    /// Pushes a newer authoritative remote snapshot into the interpolation buffer.
    pub fn push_snapshot(&mut self, snapshot: RemoteMoveSnapshot, received_at_secs: f64) {
        if self
            .snapshots
            .back()
            .map(|current| snapshot.server_tick <= current.snapshot.server_tick)
            .unwrap_or(false)
        {
            return;
        }

        if self.snapshots.len() == MAX_BUFFERED_SNAPSHOTS {
            self.snapshots.pop_front();
        }

        self.snapshots.push_back(BufferedSnapshot {
            snapshot,
            received_at_secs,
        });
    }

    /// Returns the latest known authoritative position.
    pub fn latest_position(&self) -> Vec3 {
        self.snapshots
            .back()
            .map(|entry| entry.snapshot.position)
            .unwrap_or(Vec3::ZERO)
    }

    /// Returns the latest server tick seen for this remote actor.
    pub fn server_tick(&self) -> u32 {
        self.snapshots
            .back()
            .map(|entry| entry.snapshot.server_tick)
            .unwrap_or(0)
    }

    /// Samples a presentation-friendly remote motion state at the provided local time.
    pub fn sample_motion(&self, now_secs: f64) -> RemoteMotionSample {
        if self.snapshots.len() == 1 {
            return extrapolate_single(self.snapshots.back().expect("snapshot"), now_secs);
        }

        let latest = self.snapshots.back().expect("latest snapshot");
        let latest_server_time = snapshot_time_secs(latest.snapshot.server_tick);
        let estimated_server_time = latest_server_time
            + (now_secs - latest.received_at_secs).clamp(0.0, MAX_REMOTE_EXTRAPOLATION_SECS);
        let playback_server_time = estimated_server_time - INTERPOLATION_DELAY_SECS;

        if let Some((previous, next)) =
            pair_for_playback_time(&self.snapshots, playback_server_time)
        {
            return interpolate_pair(previous, next, playback_server_time);
        }

        if let Some(oldest) = self.snapshots.front() {
            if playback_server_time <= snapshot_time_secs(oldest.snapshot.server_tick) {
                return RemoteMotionSample {
                    position: oldest.snapshot.position,
                    velocity: oldest.snapshot.velocity,
                };
            }
        }

        extrapolate_single(latest, now_secs)
    }
}

fn pair_for_playback_time(
    snapshots: &VecDeque<BufferedSnapshot>,
    playback_server_time: f64,
) -> Option<(&BufferedSnapshot, &BufferedSnapshot)> {
    for index in 0..snapshots.len().saturating_sub(1) {
        let previous = &snapshots[index];
        let next = &snapshots[index + 1];
        let previous_time = snapshot_time_secs(previous.snapshot.server_tick);
        let next_time = snapshot_time_secs(next.snapshot.server_tick);

        if playback_server_time >= previous_time && playback_server_time <= next_time {
            return Some((previous, next));
        }
    }

    None
}

fn interpolate_pair(
    previous: &BufferedSnapshot,
    next: &BufferedSnapshot,
    playback_server_time: f64,
) -> RemoteMotionSample {
    let previous_time = snapshot_time_secs(previous.snapshot.server_tick);
    let next_time = snapshot_time_secs(next.snapshot.server_tick);
    let duration = (next_time - previous_time).max(1.0e-6);
    let t = ((playback_server_time - previous_time) / duration).clamp(0.0, 1.0) as f32;

    let position = hermite_position(
        previous.snapshot.position,
        previous.snapshot.velocity,
        next.snapshot.position,
        next.snapshot.velocity,
        duration as f32,
        t,
    );
    let velocity = previous.snapshot.velocity.lerp(next.snapshot.velocity, t);

    RemoteMotionSample { position, velocity }
}

fn extrapolate_single(snapshot: &BufferedSnapshot, now_secs: f64) -> RemoteMotionSample {
    let dt = ((now_secs - snapshot.received_at_secs) as f32)
        .clamp(0.0, MAX_REMOTE_EXTRAPOLATION_SECS as f32);
    RemoteMotionSample {
        position: snapshot.snapshot.position
            + snapshot.snapshot.velocity * dt
            + snapshot.snapshot.acceleration * (0.5 * dt * dt),
        velocity: snapshot.snapshot.velocity + snapshot.snapshot.acceleration * dt,
    }
}

fn hermite_position(p0: Vec3, v0: Vec3, p1: Vec3, v1: Vec3, duration_secs: f32, t: f32) -> Vec3 {
    let t2 = t * t;
    let t3 = t2 * t;
    let h00 = 2.0 * t3 - 3.0 * t2 + 1.0;
    let h10 = t3 - 2.0 * t2 + t;
    let h01 = -2.0 * t3 + 3.0 * t2;
    let h11 = t3 - t2;
    let m0 = v0 * duration_secs;
    let m1 = v1 * duration_secs;

    p0 * h00 + m0 * h10 + p1 * h01 + m1 * h11
}

fn snapshot_time_secs(server_tick: u32) -> f64 {
    server_tick as f64 * SNAPSHOT_TICK_SECS
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

        let sampled = state.sample_motion(1.1);
        assert!(sampled.position.x > 10.0);
    }

    #[test]
    fn interpolates_between_buffered_snapshots() {
        let mut state = RemotePlayerState::from_snapshot(
            RemoteMoveSnapshot {
                cid: 7,
                server_tick: 10,
                position: Vec3::new(0.0, 0.0, 0.0),
                velocity: Vec3::new(10.0, 0.0, 0.0),
                acceleration: Vec3::ZERO,
                movement_mode: MovementMode::Grounded,
            },
            1.0,
        );

        state.push_snapshot(
            RemoteMoveSnapshot {
                cid: 7,
                server_tick: 11,
                position: Vec3::new(10.0, 0.0, 0.0),
                velocity: Vec3::new(10.0, 0.0, 0.0),
                acceleration: Vec3::ZERO,
                movement_mode: MovementMode::Grounded,
            },
            1.1,
        );

        let sample = state.sample_motion(1.15);
        assert!(sample.position.x >= 0.0);
        assert!(sample.position.x <= 10.0);
    }
}
