//! Criterion micro-benchmarks for the authoritative movement integrator.
//!
//! Measures three hot paths:
//!   1. `step_single_tick`     -- one authoritative tick, the cost paid per
//!                                entity per 10 Hz server tick.
//!   2. `replay_100_frames`    -- 100-frame replay, the cost a client pays
//!                                when reconciling a 10-second drift.
//!   3. `step_brake_to_rest`   -- braking path where the jerk limiter kicks
//!                                in every tick, representative worst-case.
//!
//! Run with `cargo bench` from `apps/scene_server/native/movement_core`.
//! Results are written to `target/criterion/` and can be opened in a browser.

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use movement_core::{
    integrator, InputFrame, MovementMode, MovementProfile, MovementState,
    MOVEMENT_FLAG_BRAKE,
};

fn make_input(seq: u32, dir: [f64; 2], flags: u16) -> InputFrame {
    InputFrame {
        seq,
        client_tick: seq,
        dt_ms: 100,
        input_dir: dir,
        speed_scale: 1.0,
        movement_flags: flags,
        movement_mode: MovementMode::Grounded,
    }
}

fn bench_step_single_tick(c: &mut Criterion) {
    let profile = MovementProfile::default();
    let state = MovementState::idle([0.0, 0.0, 0.0]);
    let input = make_input(1, [1.0, 0.0], 0);

    c.bench_function("integrator::step single_tick (grounded, +x)", |b| {
        b.iter(|| {
            let next = integrator::step(
                black_box(&state),
                black_box(&input),
                black_box(&profile),
            );
            black_box(next);
        });
    });
}

fn bench_step_brake_to_rest(c: &mut Criterion) {
    let profile = MovementProfile::default();
    let state = MovementState {
        position: [0.0, 0.0, 0.0],
        velocity: [profile.max_speed, 0.0, 0.0],
        acceleration: [0.0, 0.0, 0.0],
        movement_mode: MovementMode::Grounded,
        tick: 0,
        seq: 0,
    };
    let input = make_input(1, [0.0, 0.0], MOVEMENT_FLAG_BRAKE);

    c.bench_function("integrator::step brake_from_max_speed", |b| {
        b.iter(|| {
            let next = integrator::step(
                black_box(&state),
                black_box(&input),
                black_box(&profile),
            );
            black_box(next);
        });
    });
}

fn bench_replay_100_frames(c: &mut Criterion) {
    let profile = MovementProfile::default();
    let anchor = MovementState::idle([0.0, 0.0, 0.0]);
    let inputs: Vec<InputFrame> = (1u32..=100)
        .map(|seq| make_input(seq, [1.0, 0.0], 0))
        .collect();

    c.bench_function("integrator::replay 100_frames", |b| {
        b.iter(|| {
            let out = integrator::replay(
                black_box(&anchor),
                black_box(&inputs),
                black_box(&profile),
            );
            black_box(out);
        });
    });
}

fn bench_replay_1000_frames(c: &mut Criterion) {
    let profile = MovementProfile::default();
    let anchor = MovementState::idle([0.0, 0.0, 0.0]);
    let inputs: Vec<InputFrame> = (1u32..=1_000)
        .map(|seq| {
            let dx = if seq % 20 < 10 { 1.0 } else { -1.0 };
            make_input(seq, [dx, 0.0], 0)
        })
        .collect();

    c.bench_function("integrator::replay 1000_frames_alternating", |b| {
        b.iter(|| {
            let out = integrator::replay(
                black_box(&anchor),
                black_box(&inputs),
                black_box(&profile),
            );
            black_box(out);
        });
    });
}

criterion_group!(
    benches,
    bench_step_single_tick,
    bench_step_brake_to_rest,
    bench_replay_100_frames,
    bench_replay_1000_frames,
);
criterion_main!(benches);
