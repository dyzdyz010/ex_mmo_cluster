//! Ring-buffer history types for input replay and predicted-state lookup.

use crate::{input::commands::MoveInputFrame, sim::types::PredictedMoveState};
use std::collections::VecDeque;

#[derive(Debug, Clone)]
/// Bounded history of sent local input frames.
pub struct InputHistory {
    capacity: usize,
    frames: VecDeque<MoveInputFrame>,
}

impl InputHistory {
    /// Creates a bounded input history buffer.
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity,
            frames: VecDeque::with_capacity(capacity),
        }
    }

    /// Pushes one new input frame, discarding the oldest when full.
    pub fn push(&mut self, frame: MoveInputFrame) {
        if self.frames.len() == self.capacity {
            self.frames.pop_front();
        }
        self.frames.push_back(frame);
    }

    /// Drops all frames up to and including the acknowledged sequence number.
    pub fn drop_through(&mut self, ack_seq: u32) {
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
}

#[derive(Debug, Clone)]
/// Bounded history of predicted movement states indexed by tick.
pub struct PredictedHistory {
    capacity: usize,
    states: VecDeque<PredictedMoveState>,
}

impl PredictedHistory {
    /// Creates a bounded predicted-state history buffer.
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity,
            states: VecDeque::with_capacity(capacity),
        }
    }

    /// Pushes one predicted state snapshot.
    pub fn push(&mut self, state: PredictedMoveState) {
        if self.states.len() == self.capacity {
            self.states.pop_front();
        }
        self.states.push_back(state);
    }

    /// Looks up the predicted state for an exact tick.
    pub fn state_at_tick(&self, tick: u32) -> Option<&PredictedMoveState> {
        self.states.iter().find(|state| state.tick == tick)
    }

    /// Drops predicted states newer than the provided authoritative tick.
    pub fn truncate_after(&mut self, tick: u32) {
        while matches!(self.states.back(), Some(state) if state.tick > tick) {
            self.states.pop_back();
        }
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
    fn input_history_drops_acknowledged_frames() {
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

        history.drop_through(1);

        assert_eq!(history.len(), 1);
        assert_eq!(history.frames_after_tick(0).next().unwrap().seq, 2);
    }

    #[test]
    fn predicted_history_can_lookup_and_truncate() {
        let mut history = PredictedHistory::new(8);
        history.push(PredictedMoveState {
            tick: 1,
            position: Vec3::new(1.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
        });
        history.push(PredictedMoveState {
            tick: 2,
            position: Vec3::new(2.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
        });

        assert_eq!(history.state_at_tick(2).unwrap().position.x, 2.0);

        history.truncate_after(1);
        assert!(history.state_at_tick(2).is_none());
    }
}
