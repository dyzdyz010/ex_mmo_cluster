//! Criterion micro-benchmarks for the client-side predictor and reconciler.
//!
//! Measures:
//!   1. `predictor::step`     — one local f32 prediction tick (per input frame).
//!   2. `reconcile` (accept)  — hot path when the ack matches predicted state.
//!   3. `reconcile` (replay)  — cold path when the ack diverges by >soft but
//!                              <hard threshold, forcing a full replay.
//!   4. `reconcile` (hard_snap) — emergency path when distance > 256 units.
//!
//! Run with `cargo bench --bench predictor_bench` from the bevy_client dir.

use bevy::prelude::Vec3;
use bevy_client::{
    input::commands::MoveInputFrame,
    sim::{
        governance::ReplayGovernance,
        history::{InputHistory, PredictedHistory},
        predictor,
        profile::MovementProfile,
        reconcile::reconcile,
        types::{MovementAck, PredictedMoveState},
    },
};
use criterion::{black_box, criterion_group, criterion_main, Criterion};
use movement_core::MovementMode;

fn make_input(seq: u32, dir: bevy::prelude::Vec2) -> MoveInputFrame {
    MoveInputFrame {
        seq,
        client_tick: seq,
        dt_ms: 100,
        input_dir: dir,
        speed_scale: 1.0,
        movement_flags: 0,
    }
}

fn bench_predictor_step(c: &mut Criterion) {
    let profile = MovementProfile::default();
    let previous = PredictedMoveState::idle(Vec3::ZERO);
    let input = make_input(1, bevy::prelude::Vec2::new(1.0, 0.0));

    c.bench_function("predictor::step single_tick", |b| {
        b.iter(|| {
            let next = predictor::step(
                black_box(&previous),
                black_box(&input),
                black_box(&profile),
            );
            black_box(next);
        });
    });
}

/// Seed a realistic 16-frame prediction history and return (inputs, predicted,
/// reference state after the replay would produce).
fn seed_history(
    profile: &MovementProfile,
    frames: u32,
) -> (InputHistory, PredictedHistory, PredictedMoveState) {
    let mut input_history = InputHistory::new(32);
    let mut predicted_history = PredictedHistory::new(32);

    let origin = PredictedMoveState::idle(Vec3::ZERO);
    predicted_history.push(origin.clone());

    let mut current = origin;
    for seq in 1..=frames {
        let input = make_input(seq, bevy::prelude::Vec2::new(1.0, 0.0));
        current = predictor::step(&current, &input, profile);
        input_history.push(input);
        predicted_history.push(current.clone());
    }
    (input_history, predicted_history, current)
}

fn bench_reconcile_accept(c: &mut Criterion) {
    let profile = MovementProfile::default();
    let governance = ReplayGovernance::default();
    let (input_history_src, predicted_history_src, current) = seed_history(&profile, 16);

    c.bench_function("reconcile accept (0-replay, matching ack)", |b| {
        b.iter(|| {
            // Each iteration rebuilds mutable histories so reconcile can mutate.
            let mut inputs = input_history_src.clone();
            let mut predicted = predicted_history_src.clone();
            let ack = MovementAck {
                ack_seq: 16,
                auth_tick: 16,
                position: current.position,
                velocity: current.velocity,
                acceleration: current.acceleration,
                movement_mode: MovementMode::Grounded,
                correction_flags: 0,
            };
            let result = reconcile(
                black_box(&ack),
                &mut inputs,
                &mut predicted,
                black_box(&profile),
                black_box(&governance),
            );
            black_box(result);
        });
    });
}

fn bench_reconcile_replay_full(c: &mut Criterion) {
    let profile = MovementProfile::default();
    let governance = ReplayGovernance::default();
    let (input_history_src, predicted_history_src, _) = seed_history(&profile, 16);

    c.bench_function("reconcile replay 12-frame (ack at tick 4)", |b| {
        b.iter(|| {
            let mut inputs = input_history_src.clone();
            let mut predicted = predicted_history_src.clone();
            // Ack seq=4, position shifted by 5 units to force divergence < hard-snap.
            let shifted_position = predicted
                .state_at_seq(4)
                .unwrap()
                .position
                + Vec3::new(5.0, 0.0, 0.0);
            let anchor_velocity = predicted.state_at_seq(4).unwrap().velocity;
            let anchor_acceleration = predicted.state_at_seq(4).unwrap().acceleration;
            let ack = MovementAck {
                ack_seq: 4,
                auth_tick: 4,
                position: shifted_position,
                velocity: anchor_velocity,
                acceleration: anchor_acceleration,
                movement_mode: MovementMode::Grounded,
                correction_flags: 0,
            };
            let result = reconcile(
                black_box(&ack),
                &mut inputs,
                &mut predicted,
                black_box(&profile),
                black_box(&governance),
            );
            black_box(result);
        });
    });
}

fn bench_reconcile_hard_snap(c: &mut Criterion) {
    let profile = MovementProfile::default();
    let governance = ReplayGovernance::default();
    let (input_history_src, predicted_history_src, _) = seed_history(&profile, 16);

    c.bench_function("reconcile hard_snap (>256 unit correction)", |b| {
        b.iter(|| {
            let mut inputs = input_history_src.clone();
            let mut predicted = predicted_history_src.clone();
            let ack = MovementAck {
                ack_seq: 4,
                auth_tick: 4,
                position: Vec3::new(1000.0, 0.0, 0.0), // >> 256 hard_snap_distance
                velocity: Vec3::ZERO,
                acceleration: Vec3::ZERO,
                movement_mode: MovementMode::Grounded,
                correction_flags: 0,
            };
            let result = reconcile(
                black_box(&ack),
                &mut inputs,
                &mut predicted,
                black_box(&profile),
                black_box(&governance),
            );
            black_box(result);
        });
    });
}

criterion_group!(
    benches,
    bench_predictor_step,
    bench_reconcile_accept,
    bench_reconcile_replay_full,
    bench_reconcile_hard_snap,
);
criterion_main!(benches);
