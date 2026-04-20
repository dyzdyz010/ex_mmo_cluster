//! Reconciliation of predicted local movement against authoritative acks.
//!
//! The reconciler prefers matching by `ack_seq` (the client's input sequence
//! number) over `auth_tick` (the server's fixed-step counter). Server and
//! client tick spaces can drift independently when the server advances
//! idle/latched frames without a new client input, so `ack_seq` is the only
//! stable identifier in a namespace both sides agree on.

use crate::sim::{
    governance::{ReplayAction, ReplayGovernance},
    history::{InputHistory, PredictedHistory},
    predictor,
    profile::MovementProfile,
    types::{MovementAck, PredictedMoveState},
};

#[derive(Debug, Clone, PartialEq)]
/// Result of applying one authoritative movement acknowledgement locally.
pub struct ReconcileResult {
    pub action: ReplayAction,
    pub latest_state: PredictedMoveState,
    pub replayed_frames: usize,
    pub pending_inputs: usize,
    pub correction_distance: f32,
}

/// Reconciles the current local prediction history against an authoritative ack.
pub fn reconcile(
    ack: &MovementAck,
    input_history: &mut InputHistory,
    predicted_history: &mut PredictedHistory,
    profile: &MovementProfile,
    governance: &ReplayGovernance,
) -> Option<ReconcileResult> {
    let authoritative = authoritative_from_ack(ack);

    // Drop inputs covered by the ack. Prefer seq-space because `auth_tick`
    // is the server's counter — client InputHistory lives in seq-space.
    if ack.ack_seq > 0 {
        input_history.drop_through_seq(ack.ack_seq);
    } else {
        input_history.drop_through_tick(ack.auth_tick);
    }
    let pending_frames = if ack.ack_seq > 0 {
        input_history.frames_after_seq_cloned(ack.ack_seq)
    } else {
        input_history.frames_after_tick_cloned(ack.auth_tick)
    };
    let pending_inputs = pending_frames.len();

    // Look up the predicted state that corresponds to this ack.
    let predicted_match = predicted_history
        .state_at_seq(ack.ack_seq)
        .cloned()
        .or_else(|| predicted_history.state_at_tick(ack.auth_tick).cloned());

    let Some(predicted) = predicted_match else {
        // No matching predicted entry. This happens when history was
        // truncated by a previous HardSnap or when the client only just
        // connected. Decide by real distance instead of blindly snapping.
        return reconcile_without_match(
            authoritative,
            input_history,
            predicted_history,
            pending_inputs,
            governance,
        );
    };

    let correction_distance = predicted.position.distance(authoritative.position);

    if correction_distance <= governance.soft_position_error {
        // Refresh the history tip with the latest authoritative sample so
        // consumers always observe the freshest server state, including the
        // auth_tick advancing past a latched ack_seq.
        let should_push_auth = predicted_history
            .latest()
            .map(|latest| authoritative.tick >= latest.tick)
            .unwrap_or(true);
        if should_push_auth {
            predicted_history.push(authoritative.clone());
        }

        let latest_state = predicted_history
            .latest()
            .cloned()
            .unwrap_or_else(|| authoritative.clone());

        return Some(ReconcileResult {
            action: ReplayAction::Accepted,
            latest_state,
            replayed_frames: 0,
            pending_inputs,
            correction_distance,
        });
    }

    if correction_distance >= governance.hard_snap_distance {
        input_history.clear();
        predicted_history.clear();
        predicted_history.push(authoritative.clone());

        return Some(ReconcileResult {
            action: ReplayAction::HardSnap,
            latest_state: authoritative,
            replayed_frames: 0,
            pending_inputs,
            correction_distance,
        });
    }

    // Truncate branches that diverged from authority, then replay pending inputs.
    if predicted.seq > 0 {
        predicted_history.truncate_after_seq(predicted.seq);
    } else {
        predicted_history.truncate_after(predicted.tick);
    }

    let mut replay_state = authoritative.clone();
    let mut replay_frames = pending_frames;
    let action = if replay_frames.len() > governance.max_replay_frames {
        let start = replay_frames.len() - governance.max_replay_frames;
        replay_frames = replay_frames.split_off(start);
        input_history.retain_recent(governance.max_pending_inputs);
        ReplayAction::WindowTrimmed
    } else {
        ReplayAction::Replayed
    };

    for frame in &replay_frames {
        replay_state = predictor::step(&replay_state, frame, profile);
        predicted_history.push(replay_state.clone());
    }

    Some(ReconcileResult {
        action,
        latest_state: replay_state,
        replayed_frames: replay_frames.len(),
        pending_inputs,
        correction_distance,
    })
}

fn reconcile_without_match(
    authoritative: PredictedMoveState,
    input_history: &mut InputHistory,
    predicted_history: &mut PredictedHistory,
    pending_inputs: usize,
    governance: &ReplayGovernance,
) -> Option<ReconcileResult> {
    let latest = predicted_history.latest().cloned();
    let correction_distance = latest
        .as_ref()
        .map(|state| state.position.distance(authoritative.position))
        .unwrap_or(f32::INFINITY);

    if correction_distance >= governance.hard_snap_distance {
        input_history.clear();
        predicted_history.clear();
        predicted_history.push(authoritative.clone());
        return Some(ReconcileResult {
            action: ReplayAction::HardSnap,
            latest_state: authoritative,
            replayed_frames: 0,
            pending_inputs,
            correction_distance,
        });
    }

    // Small correction without a matching predicted state: keep current
    // prediction, record the authoritative sample for future lookups, and
    // let the visual-smoothing layer blend the drift out.
    predicted_history.push(authoritative.clone());
    let latest_state = latest.unwrap_or(authoritative);
    Some(ReconcileResult {
        action: ReplayAction::Accepted,
        latest_state,
        replayed_frames: 0,
        pending_inputs,
        correction_distance,
    })
}

fn authoritative_from_ack(ack: &MovementAck) -> PredictedMoveState {
    PredictedMoveState {
        seq: ack.ack_seq,
        tick: ack.auth_tick,
        position: ack.position,
        velocity: ack.velocity,
        acceleration: ack.acceleration,
        movement_mode: ack.movement_mode,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        input::commands::MoveInputFrame,
        sim::types::{MovementMode, PredictedMoveState},
    };
    use bevy::prelude::{Vec2, Vec3};

    #[test]
    fn reconcile_replays_future_inputs_when_authoritative_state_diverges() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(16);
        let mut predicted_history = PredictedHistory::new(16);

        let origin = PredictedMoveState::idle(Vec3::ZERO);
        predicted_history.push(origin.clone());

        let first = MoveInputFrame {
            seq: 1,
            client_tick: 1,
            dt_ms: 100,
            input_dir: Vec2::new(1.0, 0.0),
            speed_scale: 1.0,
            movement_flags: 0,
        };
        let second = MoveInputFrame {
            seq: 2,
            client_tick: 2,
            ..first.clone()
        };

        input_history.push(first.clone());
        let predicted_one = predictor::step(&origin, &first, &profile);
        predicted_history.push(predicted_one.clone());

        input_history.push(second.clone());
        let predicted_two = predictor::step(&predicted_one, &second, &profile);
        predicted_history.push(predicted_two.clone());

        let ack = MovementAck {
            ack_seq: 1,
            auth_tick: 1,
            position: Vec3::new(5.0, 0.0, 0.0),
            velocity: Vec3::new(50.0, 0.0, 0.0),
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
            correction_flags: 0,
        };

        let result = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &crate::sim::governance::ReplayGovernance::default(),
        )
        .expect("reconcile result");

        assert_eq!(result.action, ReplayAction::Replayed);
        assert_eq!(input_history.len(), 1);
        assert!(result.latest_state.position.x > ack.position.x);
    }

    #[test]
    fn reconcile_hard_snaps_when_correction_is_too_large() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(16);
        let mut predicted_history = PredictedHistory::new(16);
        let origin = PredictedMoveState::idle(Vec3::ZERO);
        predicted_history.push(origin.clone());
        predicted_history.push(PredictedMoveState {
            seq: 1,
            tick: 1,
            position: Vec3::new(500.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
        });

        let ack = MovementAck {
            ack_seq: 1,
            auth_tick: 1,
            position: Vec3::new(0.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
            correction_flags: 0,
        };

        let mut governance = crate::sim::governance::ReplayGovernance::default();
        governance.hard_snap_distance = 64.0;

        let result = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &governance,
        )
        .expect("reconcile result");

        assert_eq!(result.action, ReplayAction::HardSnap);
        assert_eq!(result.latest_state.position, Vec3::ZERO);
    }

    #[test]
    fn reconcile_keeps_latest_predicted_state_when_ack_matches_older_tick() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(16);
        let mut predicted_history = PredictedHistory::new(16);

        let origin = PredictedMoveState::idle(Vec3::ZERO);
        predicted_history.push(origin.clone());

        let first = MoveInputFrame {
            seq: 1,
            client_tick: 1,
            dt_ms: 100,
            input_dir: Vec2::new(0.0, 1.0),
            speed_scale: 1.0,
            movement_flags: 0,
        };
        let second = MoveInputFrame {
            seq: 2,
            client_tick: 2,
            ..first.clone()
        };

        input_history.push(first.clone());
        let predicted_one = predictor::step(&origin, &first, &profile);
        predicted_history.push(predicted_one.clone());

        input_history.push(second.clone());
        let predicted_two = predictor::step(&predicted_one, &second, &profile);
        predicted_history.push(predicted_two.clone());

        let ack = MovementAck {
            ack_seq: 1,
            auth_tick: 1,
            position: predicted_one.position,
            velocity: predicted_one.velocity,
            acceleration: predicted_one.acceleration,
            movement_mode: predicted_one.movement_mode,
            correction_flags: 0,
        };

        let result = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &ReplayGovernance::default(),
        )
        .expect("reconcile result");

        assert_eq!(result.action, ReplayAction::Accepted);
        assert_eq!(result.pending_inputs, 1);
        assert_eq!(result.latest_state.tick, 2);
        assert_eq!(result.latest_state.position, predicted_two.position);
    }

    #[test]
    fn reconcile_falls_back_gracefully_when_seq_misses_with_small_drift() {
        // Simulates the ack arriving after we truncated history for a prior
        // reconcile. Previously this unconditionally HardSnapped; the new
        // behavior should keep the prediction and just push the auth sample.
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(16);
        let mut predicted_history = PredictedHistory::new(16);
        predicted_history.push(PredictedMoveState {
            seq: 5,
            tick: 5,
            position: Vec3::new(12.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
        });

        let ack = MovementAck {
            ack_seq: 1, // never existed in history (truncated away)
            auth_tick: 1,
            position: Vec3::new(10.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
            correction_flags: 0,
        };

        let result = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &ReplayGovernance::default(),
        )
        .expect("reconcile result");

        assert_eq!(result.action, ReplayAction::Accepted);
        // keeps latest predicted state rather than hard snapping to ack
        assert_eq!(result.latest_state.position, Vec3::new(12.0, 0.0, 0.0));
    }

    #[test]
    fn reconcile_hard_snaps_when_missing_match_and_drift_is_huge() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(16);
        let mut predicted_history = PredictedHistory::new(16);
        predicted_history.push(PredictedMoveState {
            seq: 5,
            tick: 5,
            position: Vec3::new(1000.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
        });

        let ack = MovementAck {
            ack_seq: 1,
            auth_tick: 1,
            position: Vec3::new(0.0, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
            correction_flags: 0,
        };

        let mut governance = ReplayGovernance::default();
        governance.hard_snap_distance = 64.0;

        let result = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &governance,
        )
        .expect("reconcile result");

        assert_eq!(result.action, ReplayAction::HardSnap);
        assert_eq!(result.latest_state.position, Vec3::ZERO);
    }
}
