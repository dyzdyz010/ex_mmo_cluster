//! Local predicted-player runtime state and reconciliation orchestration.

use bevy::prelude::{Vec2, Vec3};

use crate::{
    input::commands::MoveInputFrame,
    sim::{
        governance::{ReplayAction, ReplayGovernance, ReplayGovernanceStats},
        history::{InputHistory, PredictedHistory},
        jitter::JitterEstimator,
        predictor,
        profile::MovementProfile,
        reconcile::{ReconcileResult, reconcile},
        types::{MovementAck, PredictedMoveState},
    },
};

/// Audit B-L1: stale-data threshold for the jitter estimator. After this
/// many seconds of no RTT samples, the next sample resets the EWMA so an
/// old jitter spike does not pollute a now-quiet network.
pub const JITTER_STALE_RESET_SECS: f32 = 5.0;

#[derive(Debug, Clone)]
/// Local prediction runtime that owns input history, predicted history, and reconciliation stats.
pub struct LocalPredictionRuntime {
    next_seq: u32,
    next_tick: u32,
    current_state: Option<PredictedMoveState>,
    last_input_frame: Option<MoveInputFrame>,
    input_history: InputHistory,
    predicted_history: PredictedHistory,
    profile: MovementProfile,
    governance: ReplayGovernance,
    governance_stats: ReplayGovernanceStats,
    jitter: JitterEstimator,
    last_rtt_observe_secs: Option<f64>,
}

impl Default for LocalPredictionRuntime {
    fn default() -> Self {
        Self {
            next_seq: 1,
            next_tick: 1,
            current_state: None,
            last_input_frame: None,
            input_history: InputHistory::new(128),
            predicted_history: PredictedHistory::new(256),
            profile: MovementProfile::default(),
            governance: ReplayGovernance::default(),
            governance_stats: ReplayGovernanceStats::default(),
            last_rtt_observe_secs: None,
            jitter: JitterEstimator::default(),
        }
    }
}

impl LocalPredictionRuntime {
    /// Resets local prediction around a fresh authoritative spawn position.
    /// `next_seq` defaults to 1 — see [`reset_with_seq`] for the variant
    /// used during reconnect/handshake.
    pub fn reset(&mut self, position: Vec3, profile: Option<MovementProfile>) {
        self.reset_with_seq(position, profile, 1);
    }

    /// Resets local prediction with an explicit `next_seq`.
    ///
    /// Audit B-S1 / B-SRV1: server hands the client its expected next
    /// movement-input `seq` in `EnterSceneResult.expected_seq`. Plumbing
    /// it through here means we no longer rely on the implicit "both
    /// sides start at 1" contract — if a future server change introduces
    /// session reuse, the client automatically picks up the right value.
    pub fn reset_with_seq(
        &mut self,
        position: Vec3,
        profile: Option<MovementProfile>,
        next_seq: u32,
    ) {
        self.next_seq = next_seq.max(1);
        self.next_tick = 1;
        self.input_history = InputHistory::new(128);
        self.predicted_history = PredictedHistory::new(256);
        self.governance_stats = ReplayGovernanceStats::default();
        self.last_input_frame = None;
        // Audit B-L1: enter-scene is a fresh start — drop any historic
        // jitter so we don't carry pre-handshake noise into the new scene.
        self.jitter.reset();
        self.last_rtt_observe_secs = None;
        if let Some(profile) = profile {
            self.profile = profile;
        }

        let state = PredictedMoveState::idle(position);
        self.predicted_history.push(state.clone());
        self.current_state = Some(state);
    }

    /// Clears local prediction state after disconnect/scene leave.
    pub fn clear(&mut self) {
        self.current_state = None;
        self.input_history = InputHistory::new(128);
        self.predicted_history = PredictedHistory::new(256);
        self.next_seq = 1;
        self.next_tick = 1;
        self.governance_stats = ReplayGovernanceStats::default();
        self.last_input_frame = None;
    }

    /// Builds the next local input frame using monotonic local sequence/tick counters.
    pub fn build_input_frame(
        &mut self,
        input_dir: Vec2,
        dt_ms: u16,
        speed_scale: f32,
        movement_flags: u16,
    ) -> MoveInputFrame {
        let frame = MoveInputFrame {
            seq: self.next_seq,
            client_tick: self.next_tick,
            dt_ms,
            input_dir,
            speed_scale,
            movement_flags,
        };

        self.next_seq += 1;
        self.next_tick += 1;
        frame
    }

    /// Applies one locally generated input frame to the predicted timeline.
    pub fn apply_local_input(&mut self, frame: MoveInputFrame) -> Option<PredictedMoveState> {
        let current = self.current_state.clone()?;
        self.input_history.push(frame.clone());
        self.last_input_frame = Some(frame.clone());
        let next = predictor::step(&current, &frame, &self.profile);
        self.predicted_history.push(next.clone());
        self.current_state = Some(next.clone());
        Some(next)
    }

    /// Applies one authoritative movement acknowledgement and reconciles local prediction.
    pub fn apply_ack(&mut self, ack: MovementAck) -> Option<ReconcileResult> {
        self.extend_prediction_through(ack.auth_tick);
        self.next_tick = self.next_tick.max(ack.auth_tick + 1);

        if let Some(result) = reconcile(
            &ack,
            &mut self.input_history,
            &mut self.predicted_history,
            &self.profile,
            &self.governance,
        ) {
            self.governance_stats.record(
                result.action,
                result.replayed_frames,
                result.pending_inputs,
                result.correction_distance,
            );
            self.current_state = Some(result.latest_state.clone());
            return Some(result);
        }

        let authoritative = PredictedMoveState {
            seq: ack.ack_seq,
            tick: ack.auth_tick,
            position: ack.position,
            velocity: ack.velocity,
            acceleration: ack.acceleration,
            movement_mode: ack.movement_mode,
            ground_z: ack.position.z,
        };

        self.predicted_history.push(authoritative.clone());
        self.current_state = Some(authoritative.clone());

        Some(ReconcileResult {
            action: ReplayAction::Accepted,
            latest_state: authoritative,
            replayed_frames: 0,
            pending_inputs: 0,
            correction_distance: 0.0,
        })
    }

    /// Returns the current predicted state, if any.
    pub fn current_state(&self) -> Option<&PredictedMoveState> {
        self.current_state.as_ref()
    }

    /// Returns the latest replay-governance stats.
    pub fn governance_stats(&self) -> &ReplayGovernanceStats {
        &self.governance_stats
    }

    /// Feeds a fresh RTT sample (ms) into the jitter estimator and updates
    /// the adaptive soft-position threshold so the next reconcile call sees
    /// the jitter-inflated value.
    pub fn observe_rtt(&mut self, rtt_ms: f32) {
        let jitter_ms = self.jitter.observe(rtt_ms);
        self.governance.apply_jitter(jitter_ms);
    }

    /// Same as `observe_rtt` but auto-resets the jitter EWMA when no
    /// sample has been seen in `JITTER_STALE_RESET_SECS`. Audit B-L1.
    pub fn observe_rtt_at(&mut self, rtt_ms: f32, now_secs: f64) {
        if let Some(prev_secs) = self.last_rtt_observe_secs {
            let elapsed = (now_secs - prev_secs) as f32;
            self.jitter.reset_if_stale(elapsed, JITTER_STALE_RESET_SECS);
        }
        self.last_rtt_observe_secs = Some(now_secs);
        let jitter_ms = self.jitter.observe(rtt_ms);
        self.governance.apply_jitter(jitter_ms);
    }

    /// Audit B-M3: returns true once either history ring is at the
    /// 80 % high-water mark. Caller (network plugin) can emit a log so
    /// that "old inputs are silently dropping" is observable before the
    /// first ack actually misses its history slot.
    pub fn history_at_high_water(&self) -> bool {
        self.input_history.is_at_high_water() || self.predicted_history.is_at_high_water()
    }

    pub fn input_history_overflow_drops(&self) -> u64 {
        self.input_history.overflow_drops()
    }

    pub fn predicted_history_overflow_drops(&self) -> u64 {
        self.predicted_history.overflow_drops()
    }

    /// Returns the currently-estimated one-way jitter (ms).
    pub fn current_jitter_ms(&self) -> f32 {
        self.jitter.current()
    }

    /// Returns the currently-effective soft-position threshold.
    pub fn current_soft_position_error(&self) -> f32 {
        self.governance.soft_position_error
    }

    fn extend_prediction_through(&mut self, auth_tick: u32) {
        if self.current_state.is_none() {
            return;
        }

        // When the server's auth_tick jumps past our last predicted tick it
        // means the server advanced internal idle frames without a matching
        // client input. Replaying the last issued direction here would push
        // the predicted position further from authority on every ack, so we
        // synthesise idle (zero-input, braking) frames instead. The server
        // does the same on its side for latched idle ticks.
        while self
            .current_state
            .as_ref()
            .is_some_and(|state| state.tick < auth_tick)
        {
            let current = match self.current_state.clone() {
                Some(current) => current,
                None => return,
            };

            // `seq: 0` is a sentinel marking a synthetic idle frame that is
            // never sent to the server (real input frames start at seq=1 and
            // are monotonic). It only feeds the local predictor so prediction
            // can advance through latched idle ticks. See audit D-L2.
            let idle_frame = MoveInputFrame {
                seq: 0,
                client_tick: current.tick + 1,
                dt_ms: self.profile.fixed_dt_ms,
                input_dir: Vec2::ZERO,
                speed_scale: 1.0,
                movement_flags: crate::input::commands::MOVEMENT_FLAG_BRAKE,
            };

            let next = predictor::step(&current, &idle_frame, &self.profile);
            self.predicted_history.push(next.clone());
            self.current_state = Some(next);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sim::{governance::ReplayAction, profile::MovementProfile};

    #[test]
    fn runtime_builds_frames_and_applies_prediction() {
        let mut runtime = LocalPredictionRuntime::default();
        runtime.reset(Vec3::ZERO, None);

        let frame = runtime.build_input_frame(Vec2::new(1.0, 0.0), 100, 1.0, 0);
        let state = runtime.apply_local_input(frame).expect("predicted state");

        assert_eq!(state.tick, 1);
        assert!(state.position.x > 0.0);
    }

    #[test]
    fn observe_rtt_inflates_soft_threshold_then_clamps() {
        let mut runtime = LocalPredictionRuntime::default();
        let base = runtime.current_soft_position_error();

        // Seed RTT so the EWMA has a previous sample to compare against.
        runtime.observe_rtt(40.0);
        assert!((runtime.current_jitter_ms() - 0.0).abs() < 1e-6);
        assert!((runtime.current_soft_position_error() - base).abs() < 1e-6);

        // 140 ms spike → |Δ| = 100, EWMA at α=0.15 → 15 ms jitter →
        // +0.02 * 15 = +0.3 bump above the 2.0 floor.
        runtime.observe_rtt(140.0);
        let after_spike = runtime.current_soft_position_error();
        assert!(after_spike > base, "soft threshold should inflate");
        assert!(after_spike <= 8.0, "soft threshold must stay clamped");

        // Saturate the adaptive path and confirm the cap is honored.
        for _ in 0..200 {
            runtime.observe_rtt(1_000.0);
            runtime.observe_rtt(0.0);
        }
        assert!(runtime.current_soft_position_error() <= 8.0 + 1e-6);
    }

    #[test]
    fn runtime_extends_prediction_when_ack_tick_advances_past_last_sent_frame() {
        let mut runtime = LocalPredictionRuntime::default();
        runtime.reset(Vec3::ZERO, None);

        let frame = runtime.build_input_frame(Vec2::new(0.0, 1.0), 100, 1.0, 0);
        let predicted_one = runtime
            .apply_local_input(frame.clone())
            .expect("predicted state");

        let frame_tick_two = MoveInputFrame {
            client_tick: 2,
            ..frame.clone()
        };
        let predicted_two =
            predictor::step(&predicted_one, &frame_tick_two, &MovementProfile::default());

        let ack = MovementAck {
            ack_seq: frame.seq,
            auth_tick: 2,
            position: predicted_two.position,
            velocity: predicted_two.velocity,
            acceleration: predicted_two.acceleration,
            movement_mode: predicted_two.movement_mode,
            correction_flags: 0,
        };

        let result = runtime.apply_ack(ack).expect("ack result");

        assert_ne!(result.action, ReplayAction::HardSnap);
        assert_eq!(result.latest_state.tick, 2);
        assert_eq!(result.latest_state.position, predicted_two.position);
    }
}
