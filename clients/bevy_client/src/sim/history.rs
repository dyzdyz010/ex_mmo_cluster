//! Ring-buffer history types for input replay and predicted-state lookup.

use crate::{input::commands::MoveInputFrame, sim::types::PredictedMoveState};
use std::collections::VecDeque;

#[derive(Debug, Clone)]
/// Bounded history of sent local input frames.
pub struct InputHistory {
    capacity: usize,
    frames: VecDeque<MoveInputFrame>,
    /// Cumulative number of frames evicted because the buffer was full.
    /// Audit B-M3: previously the eviction was completely silent.
    overflow_drops: u64,
}

impl InputHistory {
    /// Creates a bounded input history buffer.
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity,
            frames: VecDeque::with_capacity(capacity),
            overflow_drops: 0,
        }
    }

    /// Pushes one new input frame, discarding the oldest when full.
    pub fn push(&mut self, frame: MoveInputFrame) {
        if self.frames.len() == self.capacity {
            self.frames.pop_front();
            self.overflow_drops = self.overflow_drops.saturating_add(1);
        }
        self.frames.push_back(frame);
    }

    /// Returns true once the buffer has reached the high-water mark
    /// (≥ 80 % full). Audit B-M3: surfaces "we are about to start losing
    /// inputs" before reconcile actually misses an ack.
    pub fn is_at_high_water(&self) -> bool {
        self.capacity > 0 && self.frames.len() * 5 >= self.capacity * 4
    }

    /// Cumulative number of frames dropped due to overflow. See `push`.
    pub fn overflow_drops(&self) -> u64 {
        self.overflow_drops
    }

    /// Drops all frames up to and including the provided tick.
    ///
    /// This is the compatibility path for acks that do not carry a client
    /// input seq. Normal reconciliation uses [`Self::drop_through_seq`]
    /// because input history is keyed by client-issued input numbers.
    pub fn drop_through_tick(&mut self, auth_tick: u32) {
        while matches!(self.frames.front(), Some(frame) if frame.client_tick <= auth_tick) {
            self.frames.pop_front();
        }
    }

    /// Drops all frames up to and including the acknowledged input seq.
    ///
    /// Preferred over `drop_through_tick` because `seq` lives in the client's
    /// own input-numbering space; `auth_tick` on the other hand is the
    /// server's fixed-step counter, which advances even when the client did
    /// not produce an input (server-synthesized idle frames).
    pub fn drop_through_seq(&mut self, ack_seq: u32) {
        while matches!(self.frames.front(), Some(frame) if frame.seq <= ack_seq) {
            self.frames.pop_front();
        }
    }

    /// Iterates over frames newer than the provided tick.
    pub fn frames_after_tick(&self, tick: u32) -> impl Iterator<Item = &MoveInputFrame> {
        self.frames
            .iter()
            .filter(move |frame| frame.client_tick > tick)
    }

    /// Clones frames newer than the provided tick into a replay-ready vector.
    pub fn frames_after_tick_cloned(&self, tick: u32) -> Vec<MoveInputFrame> {
        self.frames_after_tick(tick).cloned().collect()
    }

    /// Clones frames whose seq is strictly newer than the provided seq.
    pub fn frames_after_seq_cloned(&self, ack_seq: u32) -> Vec<MoveInputFrame> {
        self.frames
            .iter()
            .filter(|frame| frame.seq > ack_seq)
            .cloned()
            .collect()
    }

    /// Retains only the newest `max_frames` inputs.
    pub fn retain_recent(&mut self, max_frames: usize) {
        while self.frames.len() > max_frames {
            self.frames.pop_front();
        }
    }

    /// Clears all buffered input.
    pub fn clear(&mut self) {
        self.frames.clear();
    }

    /// Returns the number of buffered input frames.
    pub fn len(&self) -> usize {
        self.frames.len()
    }

    /// Returns whether the buffer has no input frames.
    pub fn is_empty(&self) -> bool {
        self.frames.is_empty()
    }
}

#[derive(Debug, Clone)]
/// Bounded history of predicted movement states indexed by tick.
pub struct PredictedHistory {
    capacity: usize,
    states: VecDeque<PredictedMoveState>,
    overflow_drops: u64,
}

impl PredictedHistory {
    /// Creates a bounded predicted-state history buffer.
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity,
            states: VecDeque::with_capacity(capacity),
            overflow_drops: 0,
        }
    }

    /// Pushes one predicted state snapshot.
    pub fn push(&mut self, state: PredictedMoveState) {
        if self.states.len() == self.capacity {
            self.states.pop_front();
            self.overflow_drops = self.overflow_drops.saturating_add(1);
        }
        self.states.push_back(state);
    }

    /// Audit B-M3: see InputHistory::is_at_high_water — same idea for
    /// the predicted-state ring.
    pub fn is_at_high_water(&self) -> bool {
        self.capacity > 0 && self.states.len() * 5 >= self.capacity * 4
    }

    pub fn overflow_drops(&self) -> u64 {
        self.overflow_drops
    }

    /// Looks up the predicted state for an exact tick.
    pub fn state_at_tick(&self, tick: u32) -> Option<&PredictedMoveState> {
        self.states.iter().find(|state| state.tick == tick)
    }

    /// Looks up the predicted state for an exact input seq.
    ///
    /// Used as a fallback when exact `auth_tick` history is unavailable.
    /// Multiple server ticks can share the same latched `ack_seq`, so the
    /// reconciler prefers [`Self::state_at_tick`] when possible.
    pub fn state_at_seq(&self, seq: u32) -> Option<&PredictedMoveState> {
        if seq == 0 {
            return None;
        }
        self.states.iter().find(|state| state.seq == seq)
    }

    /// Drops predicted states newer than the provided authoritative tick.
    pub fn truncate_after(&mut self, tick: u32) {
        while matches!(self.states.back(), Some(state) if state.tick > tick) {
            self.states.pop_back();
        }
    }

    /// Drops predicted states whose seq is strictly newer than the acked seq.
    pub fn truncate_after_seq(&mut self, seq: u32) {
        while matches!(self.states.back(), Some(state) if state.seq > seq) {
            self.states.pop_back();
        }
    }

    /// Returns the newest predicted state currently retained.
    pub fn latest(&self) -> Option<&PredictedMoveState> {
        self.states.back()
    }

    /// Clears all predicted-state history.
    pub fn clear(&mut self) {
        self.states.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sim::types::MovementMode;
    use bevy::prelude::{Vec2, Vec3};

    #[test]
    fn input_history_drops_frames_through_authoritative_tick() {
        let mut history = InputHistory::new(8);
        history.push(MoveInputFrame {
            seq: 1,
            client_tick: 1,
            dt_ms: 16,
            input_dir: Vec2::new(1.0, 0.0),
            speed_scale: 1.0,
            movement_flags: 0,
        });
        history.push(MoveInputFrame {
            seq: 2,
            client_tick: 2,
            dt_ms: 16,
            input_dir: Vec2::new(0.0, 1.0),
            speed_scale: 1.0,
            movement_flags: 0,
        });

        history.drop_through_tick(1);

        assert_eq!(history.len(), 1);
        assert_eq!(history.frames_after_tick(0).next().unwrap().seq, 2);
    }

    #[test]
    fn predicted_history_can_lookup_and_truncate() {
        let mut history = PredictedHistory::new(8);
        history.push(PredictedMoveState {
            seq: 1,
            tick: 1,
            position: Vec3::new(1.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
            ground_z: 0.0,
        });
        history.push(PredictedMoveState {
            seq: 2,
            tick: 2,
            position: Vec3::new(2.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
            ground_z: 0.0,
        });

        assert_eq!(history.state_at_tick(2).unwrap().position.x, 2.0);

        history.truncate_after(1);
        assert!(history.state_at_tick(2).is_none());
    }

    #[test]
    fn predicted_history_exposes_latest_state() {
        let mut history = PredictedHistory::new(8);
        history.push(PredictedMoveState {
            seq: 1,
            tick: 1,
            position: Vec3::new(1.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
            ground_z: 0.0,
        });
        history.push(PredictedMoveState {
            seq: 2,
            tick: 2,
            position: Vec3::new(2.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
            ground_z: 0.0,
        });

        assert_eq!(history.latest().unwrap().tick, 2);
    }

    #[test]
    fn predicted_history_lookup_by_seq_matches_exact_client_input_number() {
        let mut history = PredictedHistory::new(8);
        history.push(PredictedMoveState {
            seq: 10,
            tick: 1,
            position: Vec3::new(1.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
            ground_z: 0.0,
        });
        history.push(PredictedMoveState {
            seq: 11,
            tick: 2,
            position: Vec3::new(2.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
            ground_z: 0.0,
        });

        assert_eq!(history.state_at_seq(11).unwrap().position.x, 2.0);
        assert!(history.state_at_seq(0).is_none());
        assert!(history.state_at_seq(999).is_none());
    }

    #[test]
    fn predicted_history_truncate_after_seq_drops_only_newer_entries() {
        let mut history = PredictedHistory::new(8);
        for i in 1..=4u32 {
            history.push(PredictedMoveState {
                seq: i,
                tick: i,
                position: Vec3::new(i as f32, 0.0, 0.0),
                velocity: Vec3::ZERO,
                acceleration: Vec3::ZERO,
                movement_mode: MovementMode::Grounded,
                ground_z: 0.0,
            });
        }

        history.truncate_after_seq(2);

        assert_eq!(history.latest().unwrap().seq, 2);
        assert!(history.state_at_seq(3).is_none());
    }
}
