//! Reconciliation of predicted local movement against authoritative acks.
//!
//! The reconciler prefers matching by `auth_tick` (the server's fixed-step
//! counter) and falls back to `ack_seq` for older histories. Server acks can
//! legitimately advance idle/latched frames without a new client input; in
//! that case `ack_seq` stays pinned while `auth_tick` is the precise replay
//! anchor.

use crate::input::commands::MoveInputFrame;
use crate::sim::{
    correction::CorrectionKind,
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
    let kind = CorrectionKind::from_bits(ack.correction_flags);

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

    // Semantic dispatch: the server tells us *why* this correction happened.
    // Honour intent before any distance-based branching — scripted teleports
    // and anti-cheat rejections must wipe history regardless of delta size;
    // status overrides apply the ack without replay; collision push forces
    // a replay even under the soft threshold.
    match kind {
        CorrectionKind::Teleport | CorrectionKind::AntiCheatReject => {
            return Some(dispatch_teleport(
                authoritative,
                input_history,
                predicted_history,
                pending_inputs,
            ));
        }
        CorrectionKind::StatusOverride => {
            return Some(dispatch_status_override(
                ack,
                authoritative,
                predicted_history,
                pending_inputs,
            ));
        }
        CorrectionKind::CollisionPush | CorrectionKind::None => {}
    }

    let force_replay = matches!(kind, CorrectionKind::CollisionPush);

    // Look up the predicted state that corresponds to this ack. Server acks
    // can legitimately advance `auth_tick` while `ack_seq` stays latched to
    // the last real input (airborne/idle continuation frames). In that case a
    // synthetic local prediction for the exact authoritative tick is the best
    // comparison point; `ack_seq` remains the fallback for older histories that
    // do not contain server-synthesized ticks.
    let predicted_match = predicted_history
        .state_at_tick(ack.auth_tick)
        .cloned()
        .or_else(|| predicted_history.state_at_seq(ack.ack_seq).cloned());

    let Some(predicted) = predicted_match else {
        // No matching predicted entry. This happens when history was
        // truncated by a previous HardSnap or when the client only just
        // connected. Decide by real distance instead of blindly snapping.
        return reconcile_without_match(
            authoritative,
            input_history,
            predicted_history,
            pending_frames,
            pending_inputs,
            profile,
            governance,
            force_replay,
        );
    };

    let correction_distance = predicted.position.distance(authoritative.position);

    if correction_distance <= governance.soft_position_error && !force_replay {
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
    } else if force_replay {
        ReplayAction::ForcedReplay
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

fn dispatch_teleport(
    authoritative: PredictedMoveState,
    input_history: &mut InputHistory,
    predicted_history: &mut PredictedHistory,
    pending_inputs: usize,
) -> ReconcileResult {
    let correction_distance = predicted_history
        .latest()
        .map(|latest| latest.position.distance(authoritative.position))
        .unwrap_or(0.0);

    input_history.clear();
    predicted_history.clear();
    predicted_history.push(authoritative.clone());

    ReconcileResult {
        action: ReplayAction::Teleport,
        latest_state: authoritative,
        replayed_frames: 0,
        pending_inputs,
        correction_distance,
    }
}

/// Handles a `StatusOverride` correction.
///
/// Audit B-L2: clarifies the contract that was previously implicit.
/// `StatusOverride` (e.g. `mounted`, `frozen`, `disabled`) means the
/// server has decided the avatar is no longer subject to the input the
/// client just sent. We therefore:
/// - Truncate any predicted state past the ack point (pre-override
///   inputs would be re-applied on top of stale assumptions).
/// - **Discard** the pending input frames at the call site by reporting
///   them via `pending_inputs` for the stats but letting the caller's
///   `drop_through_seq` already-applied prior to dispatch take effect:
///   we do not call `input_history.frames_after_seq_cloned` again, so
///   the unsent frames sit in the input history but are not replayed
///   against the override-affected authoritative state. Subsequent
///   reconciliations / movement_input calls will resume with whatever
///   the user is pressing *after* the override, which matches the UE
///   CMC convention for one-shot status overrides.
///
/// New input frames that arrive *after* the override pass through the
/// normal predictor path on top of the post-override authoritative
/// state — see `apply_local_input` in `world::local_player`.
fn dispatch_status_override(
    ack: &MovementAck,
    authoritative: PredictedMoveState,
    predicted_history: &mut PredictedHistory,
    pending_inputs: usize,
) -> ReconcileResult {
    let correction_distance = predicted_history
        .latest()
        .map(|latest| latest.position.distance(authoritative.position))
        .unwrap_or(0.0);

    // Truncate predictions past the ack — they were based on pre-override
    // assumptions (e.g. normal velocity) that no longer hold. Future
    // predictor steps resume from the authoritative sample.
    if ack.ack_seq > 0 {
        predicted_history.truncate_after_seq(ack.ack_seq);
    } else {
        predicted_history.truncate_after(ack.auth_tick);
    }
    predicted_history.push(authoritative.clone());

    ReconcileResult {
        action: ReplayAction::StatusOverride,
        latest_state: authoritative,
        replayed_frames: 0,
        pending_inputs,
        correction_distance,
    }
}

#[allow(clippy::too_many_arguments)]
fn reconcile_without_match(
    authoritative: PredictedMoveState,
    input_history: &mut InputHistory,
    predicted_history: &mut PredictedHistory,
    pending_frames: Vec<MoveInputFrame>,
    pending_inputs: usize,
    profile: &MovementProfile,
    governance: &ReplayGovernance,
    force_replay: bool,
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

    // Audit B-S2: previously this path silently pushed the authoritative
    // state and returned, *throwing away* any pending input frames the
    // client has queued past the ack. The next predictor step would then
    // start from `authoritative` with no replay context, accumulating
    // drift on every subsequent ack until the user releases keys. Now
    // we replay the pending inputs on top of the authoritative state —
    // the same algorithm the matched-history path runs — so the post-ack
    // predicted tip stays consistent with what the user actually pressed.
    predicted_history.push(authoritative.clone());

    let mut replay_state = authoritative.clone();
    let mut replay_frames = pending_frames;
    let trimmed = if replay_frames.len() > governance.max_replay_frames {
        let start = replay_frames.len() - governance.max_replay_frames;
        replay_frames = replay_frames.split_off(start);
        input_history.retain_recent(governance.max_pending_inputs);
        true
    } else {
        false
    };

    for frame in &replay_frames {
        replay_state = predictor::step(&replay_state, frame, profile);
        predicted_history.push(replay_state.clone());
    }

    let action = if trimmed {
        ReplayAction::WindowTrimmed
    } else if force_replay || !replay_frames.is_empty() {
        ReplayAction::ForcedReplay
    } else {
        ReplayAction::Accepted
    };
    let latest_state = if replay_frames.is_empty() {
        latest.unwrap_or(replay_state)
    } else {
        replay_state
    };
    Some(ReconcileResult {
        action,
        latest_state,
        replayed_frames: replay_frames.len(),
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
        ground_z: ack.position.z,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        input::commands::{MOVEMENT_FLAG_BRAKE, MOVEMENT_FLAG_JUMP, MoveInputFrame},
        sim::{
            correction::CorrectionFlags,
            types::{MovementMode, PredictedMoveState},
        },
    };
    use bevy::prelude::{Vec2, Vec3};

    /// Builds a standard MoveInputFrame with +x direction and 100 ms dt.
    fn make_input(seq: u32) -> MoveInputFrame {
        MoveInputFrame {
            seq,
            client_tick: seq,
            dt_ms: 100,
            input_dir: Vec2::new(1.0, 0.0),
            speed_scale: 1.0,
            movement_flags: 0,
        }
    }

    /// Builds a perfectly-matching MovementAck for a given PredictedMoveState.
    fn ack_for_state(state: &PredictedMoveState) -> MovementAck {
        MovementAck {
            ack_seq: state.seq,
            auth_tick: state.tick,
            position: state.position,
            velocity: state.velocity,
            acceleration: state.acceleration,
            movement_mode: state.movement_mode,
            correction_flags: 0,
        }
    }

    /// Seed predicted history with states at the given seqs, each moving +x by
    /// `step_x` units per entry.  Returns the vec of inserted states so callers
    /// can derive authoritative payloads from them.
    fn seed_history(
        predicted_history: &mut PredictedHistory,
        seqs: &[u32],
        step_x: f32,
    ) -> Vec<PredictedMoveState> {
        let mut states = Vec::new();
        for (i, &seq) in seqs.iter().enumerate() {
            let state = PredictedMoveState {
                seq,
                tick: seq,
                position: Vec3::new((i as f32 + 1.0) * step_x, 0.0, 0.0),
                velocity: Vec3::ZERO,
                acceleration: Vec3::ZERO,
                movement_mode: MovementMode::Grounded,
                ground_z: 0.0,
            };
            predicted_history.push(state.clone());
            states.push(state);
        }
        states
    }

    // -----------------------------------------------------------------------
    // Test 1: stale ack (seq < smallest retained seq) must not regress the
    // rendered anchor tick below the current latest.
    // -----------------------------------------------------------------------
    #[test]
    fn stale_ack_older_than_latest_is_ignored() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(32);
        let mut predicted_history = PredictedHistory::new(32);

        // Seed states at seqs [10, 11, 12, 13]; the stale ack refers to seq 8
        // which was never in history (already acked/truncated away).
        let seqs = [10u32, 11, 12, 13];
        let states = seed_history(&mut predicted_history, &seqs, 10.0);

        // The latest predicted state is at seq=13 / tick=13.
        let latest_before = predicted_history.latest().unwrap().clone();
        assert_eq!(latest_before.seq, 13);

        // ack_seq=8 is stale — not in history.  Position chosen so that the
        // distance to the current latest (seq=13, x=40) is within the default
        // soft_position_error (2.0) — we want Accepted, not a HardSnap.
        // We deliberately put the auth position close to the latest prediction.
        let ack = MovementAck {
            ack_seq: 8,
            auth_tick: 8,
            position: states.last().unwrap().position, // same x as seq=13
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
            correction_flags: 0,
        };

        let governance = ReplayGovernance::default();
        let result = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &governance,
        )
        .expect("reconcile must return Some");

        // Must not hard-snap or rewind below tick 13.
        assert_ne!(
            result.action,
            ReplayAction::HardSnap,
            "stale ack must not hard-snap"
        );
        assert!(
            result.latest_state.tick >= latest_before.tick,
            "rendered anchor tick must not regress: got {}, had {}",
            result.latest_state.tick,
            latest_before.tick
        );
    }

    // -----------------------------------------------------------------------
    // Test 2: two consecutive Accepted reconciles for the identical ack must
    // leave history and pending-input count unchanged on the second call.
    // -----------------------------------------------------------------------
    #[test]
    fn duplicate_ack_same_seq_is_idempotent() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(32);
        let mut predicted_history = PredictedHistory::new(32);

        // Build two steps: predict seq 1 → seq 2.
        let origin = PredictedMoveState::idle(Vec3::ZERO);
        predicted_history.push(origin.clone());

        let f1 = make_input(1);
        let f2 = make_input(2);
        input_history.push(f1.clone());
        let s1 = predictor::step(&origin, &f1, &profile);
        predicted_history.push(s1.clone());

        input_history.push(f2.clone());
        let s2 = predictor::step(&s1, &f2, &profile);
        predicted_history.push(s2.clone());

        // Ack for seq=1 that perfectly matches the prediction → Accepted.
        let ack = ack_for_state(&s1);

        let governance = ReplayGovernance::default();

        let result1 = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &governance,
        )
        .expect("first reconcile");
        assert_eq!(result1.action, ReplayAction::Accepted);

        let pending_after_first = result1.pending_inputs;
        let latest_after_first = result1.latest_state.clone();

        // Second call with the identical ack.
        let result2 = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &governance,
        )
        .expect("second reconcile");

        assert_eq!(result2.action, ReplayAction::Accepted);
        // Pending input count must not grow or shrink.
        assert_eq!(
            result2.pending_inputs, pending_after_first,
            "pending inputs must be stable after duplicate ack"
        );
        // Latest state must not drift: position should be identical.
        assert!(
            result2
                .latest_state
                .position
                .distance(latest_after_first.position)
                < 1e-4,
            "latest_state drifted after duplicate ack: {:?} vs {:?}",
            result2.latest_state.position,
            latest_after_first.position
        );
    }

    // -----------------------------------------------------------------------
    // Test 3: an older ack arriving after a newer one must not rewind history.
    // -----------------------------------------------------------------------
    #[test]
    fn out_of_order_ack_seq_does_not_rewind_history() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(32);
        let mut predicted_history = PredictedHistory::new(32);

        // Build a chain of 13 steps (seqs 1..=13).
        let origin = PredictedMoveState::idle(Vec3::ZERO);
        predicted_history.push(origin.clone());
        let mut prev = origin.clone();
        let mut states: Vec<PredictedMoveState> = vec![origin.clone()];
        for seq in 1u32..=13 {
            let f = make_input(seq);
            input_history.push(f.clone());
            let s = predictor::step(&prev, &f, &profile);
            predicted_history.push(s.clone());
            states.push(s.clone());
            prev = s;
        }

        let governance = ReplayGovernance::default();

        // First: process ack_seq=12 — perfect match, Accepted.
        let ack12 = ack_for_state(&states[12]); // states[12] is seq=12
        let result12 = reconcile(
            &ack12,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &governance,
        )
        .expect("reconcile seq=12");
        assert_eq!(result12.action, ReplayAction::Accepted);
        let latest_after_12 = predicted_history.latest().unwrap().clone();

        // Second: out-of-order ack_seq=10 that perfectly matches the retained
        // historical entry.  Since we only Accepted seq=12 (no truncation), the
        // seq=10 entry should still be in history.
        let ack10 = ack_for_state(&states[10]); // states[10] is seq=10
        let result10 = reconcile(
            &ack10,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &governance,
        )
        .expect("reconcile seq=10");

        // (a) Must not hard-snap.
        assert_ne!(
            result10.action,
            ReplayAction::HardSnap,
            "out-of-order ack must not hard-snap"
        );

        // (b) History latest must not have regressed below what seq=12 left us.
        let latest_after_10 = predicted_history.latest().unwrap().clone();
        assert!(
            latest_after_10.tick >= latest_after_12.tick,
            "history tip regressed after out-of-order ack: tick {} < {}",
            latest_after_10.tick,
            latest_after_12.tick
        );

        // (c) Entries for seq 11 and 12 must BOTH still be reachable — a
        //     stale out-of-order ack must never truncate newer entries.
        //     Checking with OR previously masked the case where one of them
        //     was wiped; split into two hard assertions.
        assert!(
            predicted_history.state_at_seq(11).is_some(),
            "seq=11 entry was wiped by the out-of-order ack"
        );
        assert!(
            predicted_history.state_at_seq(12).is_some(),
            "seq=12 entry was wiped by the out-of-order ack"
        );
    }

    // -----------------------------------------------------------------------
    // Test 4: a full replay after an authoritative correction must reproduce
    // the same kinematic delta as a continuous integration.
    //
    // Precision note: the client-side predictor runs on Bevy's `Vec3` (f32),
    // so 16-tick accumulations diverge from a theoretical f64 reference by
    // up to ~1e-5 per coordinate. The `< 1e-4` tolerance at the bottom of
    // this test reflects f32 roundoff — it is NOT a loosening of a
    // bit-exact invariant. The authoritative NIF path (f64) is verified
    // separately in `integrator_golden_test.exs` under `@eps 1.0e-9`.
    // -----------------------------------------------------------------------
    #[test]
    fn full_replay_matches_continuous_integration() {
        let profile = MovementProfile::default();

        // Build 16 inputs at dt=100ms, +x direction, speed_scale=1.
        let inputs: Vec<MoveInputFrame> = (1u32..=16).map(make_input).collect();

        // --- Reference path: integrate all 16 ticks from the origin. ---
        let origin = PredictedMoveState::idle(Vec3::ZERO);
        let mut reference_states: Vec<PredictedMoveState> = vec![origin.clone()];
        let mut prev = origin.clone();
        for input in &inputs {
            let s = predictor::step(&prev, input, &profile);
            reference_states.push(s.clone());
            prev = s;
        }
        // reference_states[k] is the state AFTER tick k (seqs 1..16).
        let reference_final = reference_states[16].position; // after all 16
        let reference_at_4 = reference_states[4].position; // after tick 4

        // --- Simulation path ---
        // Client predicted 4 ticks cleanly, then a server ack for tick=4
        // arrives with a position shifted by 5 units on X vs the prediction.
        let auth_anchor_position = reference_states[4].position + Vec3::new(5.0, 0.0, 0.0);

        let auth_anchor = PredictedMoveState {
            seq: 4,
            tick: 4,
            position: auth_anchor_position,
            velocity: reference_states[4].velocity,
            acceleration: reference_states[4].acceleration,
            movement_mode: MovementMode::Grounded,
            ground_z: auth_anchor_position.z,
        };

        // Build histories as a client would after 16 ticks (all inputs sent,
        // all predicted states recorded).
        let mut input_history = InputHistory::new(32);
        let mut predicted_history = PredictedHistory::new(32);
        predicted_history.push(origin.clone());
        for (i, input) in inputs.iter().enumerate() {
            input_history.push(input.clone());
            predicted_history.push(reference_states[i + 1].clone());
        }

        // Craft the ack: ack_seq=4, position differs from prediction by 5 units.
        let ack = MovementAck {
            ack_seq: 4,
            auth_tick: 4,
            position: auth_anchor_position,
            velocity: auth_anchor.velocity,
            acceleration: auth_anchor.acceleration,
            movement_mode: MovementMode::Grounded,
            correction_flags: 0,
        };

        let governance = ReplayGovernance::default();
        let result = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &governance,
        )
        .expect("reconcile result");

        // Expect a replay (correction distance = 5, within soft but above 0,
        // below hard_snap of 256 — but 5 > soft_position_error of 2, so Replayed).
        assert!(
            matches!(
                result.action,
                ReplayAction::Replayed | ReplayAction::WindowTrimmed
            ),
            "expected replay action, got {:?}",
            result.action
        );

        // The replayed final position should equal:
        //   authoritative_anchor + (reference_final - reference_at_4)
        // i.e. same kinematic delta as the continuous integration.
        let expected_delta = reference_final - reference_at_4;
        let expected_final = auth_anchor_position + expected_delta;
        let actual_final = result.latest_state.position;

        assert!(
            (actual_final - expected_final).length() < 1e-4,
            "replayed position {:?} differs from expected {:?} by {:?} (> 1e-4)",
            actual_final,
            expected_final,
            (actual_final - expected_final).length()
        );
    }

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
            ground_z: 0.0,
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

        let governance = crate::sim::governance::ReplayGovernance {
            hard_snap_distance: 64.0,
            ..Default::default()
        };

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
    fn reconcile_prefers_matching_auth_tick_when_seq_is_latched_across_airborne_ticks() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(16);
        let mut predicted_history = PredictedHistory::new(16);

        let origin = PredictedMoveState::idle(Vec3::new(0.0, 0.0, 100.0));
        predicted_history.push(origin.clone());

        let jump = MoveInputFrame {
            seq: 8,
            client_tick: 9,
            dt_ms: 100,
            input_dir: Vec2::ZERO,
            speed_scale: 1.0,
            movement_flags: MOVEMENT_FLAG_JUMP,
        };
        let airborne_tick_9 = predictor::step(&origin, &jump, &profile);
        predicted_history.push(airborne_tick_9.clone());

        let synthetic_airborne_tick = MoveInputFrame {
            seq: 0,
            client_tick: 10,
            dt_ms: 100,
            input_dir: Vec2::ZERO,
            speed_scale: 1.0,
            movement_flags: MOVEMENT_FLAG_BRAKE,
        };
        let airborne_tick_10 =
            predictor::step(&airborne_tick_9, &synthetic_airborne_tick, &profile);
        predicted_history.push(airborne_tick_10.clone());

        let ack = MovementAck {
            ack_seq: 8,
            auth_tick: 10,
            position: airborne_tick_10.position,
            velocity: airborne_tick_10.velocity,
            acceleration: airborne_tick_10.acceleration,
            movement_mode: airborne_tick_10.movement_mode,
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
        assert_eq!(result.correction_distance, 0.0);
        assert_eq!(result.latest_state.tick, 10);
        assert_eq!(result.latest_state.position, airborne_tick_10.position);
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
            ground_z: 0.0,
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

    // -----------------------------------------------------------------------
    // C.2 semantic-flag dispatch
    // -----------------------------------------------------------------------

    /// TELEPORT forces a hard snap even when the positional delta would
    /// otherwise be accepted under `soft_position_error`.
    #[test]
    fn teleport_flag_hard_snaps_regardless_of_distance() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(16);
        let mut predicted_history = PredictedHistory::new(16);

        let origin = PredictedMoveState::idle(Vec3::ZERO);
        predicted_history.push(origin.clone());

        let f1 = make_input(1);
        input_history.push(f1.clone());
        let s1 = predictor::step(&origin, &f1, &profile);
        predicted_history.push(s1.clone());

        // Position delta of 0.5 would normally be Accepted (soft=2.0), but
        // TELEPORT must still hard-snap and clear history.
        let ack = MovementAck {
            ack_seq: 1,
            auth_tick: 1,
            position: s1.position + Vec3::new(0.5, 0.0, 0.0),
            velocity: s1.velocity,
            acceleration: s1.acceleration,
            movement_mode: s1.movement_mode,
            correction_flags: CorrectionFlags::TELEPORT.bits(),
        };

        let result = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &ReplayGovernance::default(),
        )
        .expect("reconcile result");

        assert_eq!(result.action, ReplayAction::Teleport);
        assert_eq!(input_history.len(), 0, "TELEPORT must clear input history");
        assert_eq!(result.latest_state.position, ack.position);
        // The single retained predicted entry is the authoritative sample.
        assert_eq!(predicted_history.latest().unwrap().position, ack.position);
    }

    /// ANTI_CHEAT_REJECT has teleport-level severity: same hard-snap path.
    #[test]
    fn anti_cheat_reject_flag_takes_teleport_path() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(16);
        let mut predicted_history = PredictedHistory::new(16);

        let origin = PredictedMoveState::idle(Vec3::ZERO);
        predicted_history.push(origin.clone());
        let f1 = make_input(1);
        input_history.push(f1.clone());
        let s1 = predictor::step(&origin, &f1, &profile);
        predicted_history.push(s1.clone());

        let ack = MovementAck {
            ack_seq: 1,
            auth_tick: 1,
            position: s1.position + Vec3::new(0.1, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: s1.movement_mode,
            correction_flags: CorrectionFlags::ANTI_CHEAT_REJECT.bits(),
        };

        let result = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &ReplayGovernance::default(),
        )
        .expect("reconcile result");

        assert_eq!(result.action, ReplayAction::Teleport);
        assert_eq!(input_history.len(), 0);
    }

    /// COLLISION_PUSH forces a replay even when the positional delta is
    /// under `soft_position_error` (being pressed into a wall keeps the
    /// server position near the predicted position but the client must
    /// still re-step pending inputs against the authoritative velocity).
    #[test]
    fn collision_flag_forces_replay_below_soft_threshold() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(16);
        let mut predicted_history = PredictedHistory::new(16);

        let origin = PredictedMoveState::idle(Vec3::ZERO);
        predicted_history.push(origin.clone());

        let f1 = make_input(1);
        let f2 = make_input(2);
        input_history.push(f1.clone());
        let s1 = predictor::step(&origin, &f1, &profile);
        predicted_history.push(s1.clone());
        input_history.push(f2.clone());
        let s2 = predictor::step(&s1, &f2, &profile);
        predicted_history.push(s2.clone());

        // Tiny position delta — normally Accepted, but the flag forces
        // ReplayAction::ForcedReplay and re-runs pending inputs against
        // the authoritative (zero) velocity.
        let ack = MovementAck {
            ack_seq: 1,
            auth_tick: 1,
            position: s1.position + Vec3::new(0.1, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: s1.movement_mode,
            correction_flags: CorrectionFlags::COLLISION_PUSH.bits(),
        };

        let result = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &ReplayGovernance::default(),
        )
        .expect("reconcile result");

        assert_eq!(
            result.action,
            ReplayAction::ForcedReplay,
            "collision push with pending inputs must force replay"
        );
        assert_eq!(
            result.replayed_frames, 1,
            "the single pending input after ack_seq=1 must be replayed"
        );
        assert!(
            result.correction_distance < 1.0,
            "correction distance was {}, expected small value",
            result.correction_distance
        );
    }

    /// STATUS_OVERRIDE applies the authoritative sample without replaying
    /// pending inputs; predictions past the ack are truncated so subsequent
    /// steps resume from the overridden state.
    #[test]
    fn status_override_flag_applies_auth_without_replay() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(16);
        let mut predicted_history = PredictedHistory::new(16);

        let origin = PredictedMoveState::idle(Vec3::ZERO);
        predicted_history.push(origin.clone());
        let f1 = make_input(1);
        let f2 = make_input(2);
        input_history.push(f1.clone());
        let s1 = predictor::step(&origin, &f1, &profile);
        predicted_history.push(s1.clone());
        input_history.push(f2.clone());
        let s2 = predictor::step(&s1, &f2, &profile);
        predicted_history.push(s2.clone());

        let override_position = s1.position + Vec3::new(2.5, 0.0, 0.0);
        let ack = MovementAck {
            ack_seq: 1,
            auth_tick: 1,
            position: override_position,
            // Stun zeroes velocity.
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: MovementMode::Grounded,
            correction_flags: CorrectionFlags::STATUS_OVERRIDE.bits(),
        };

        let result = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &ReplayGovernance::default(),
        )
        .expect("reconcile result");

        assert_eq!(result.action, ReplayAction::StatusOverride);
        assert_eq!(
            result.replayed_frames, 0,
            "status override must not replay pending inputs"
        );
        assert_eq!(result.latest_state.position, override_position);
        assert_eq!(result.latest_state.velocity, Vec3::ZERO);
        // Predictions past the ack tick must have been truncated: the tip
        // now carries the overridden velocity rather than the pre-override
        // prediction at s2.
        let tip = predicted_history.latest().unwrap();
        assert_eq!(tip.velocity, Vec3::ZERO);
        assert_eq!(tip.position, override_position);
    }

    /// Semantic priority — AntiCheatReject wins when multiple bits coexist.
    #[test]
    fn combined_anti_cheat_plus_collision_takes_teleport_path() {
        let profile = MovementProfile::default();
        let mut input_history = InputHistory::new(16);
        let mut predicted_history = PredictedHistory::new(16);

        let origin = PredictedMoveState::idle(Vec3::ZERO);
        predicted_history.push(origin.clone());
        let f1 = make_input(1);
        input_history.push(f1.clone());
        let s1 = predictor::step(&origin, &f1, &profile);
        predicted_history.push(s1.clone());

        let bits =
            CorrectionFlags::ANTI_CHEAT_REJECT.bits() | CorrectionFlags::COLLISION_PUSH.bits();
        let ack = MovementAck {
            ack_seq: 1,
            auth_tick: 1,
            position: s1.position + Vec3::new(0.05, 0.0, 0.0),
            velocity: Vec3::ZERO,
            acceleration: Vec3::ZERO,
            movement_mode: s1.movement_mode,
            correction_flags: bits,
        };

        let result = reconcile(
            &ack,
            &mut input_history,
            &mut predicted_history,
            &profile,
            &ReplayGovernance::default(),
        )
        .expect("reconcile result");

        assert_eq!(result.action, ReplayAction::Teleport);
        assert_eq!(input_history.len(), 0);
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
            ground_z: 0.0,
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

        let governance = ReplayGovernance {
            hard_snap_distance: 64.0,
            ..Default::default()
        };

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
