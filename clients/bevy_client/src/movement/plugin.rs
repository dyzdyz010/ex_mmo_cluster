//! `MovementSyncPlugin` — owns the keyboard movement-input sampling, the
//! configured uplink tick, and the local render-prediction integration.

use bevy::ecs::system::SystemParam;
use bevy::input::keyboard::{Key, KeyboardInput};
use bevy::prelude::*;

use crate::app::{
    FINAL_STOP_SYNC_SPEED_EPSILON, LocalRenderPrediction, MovementDispatchState, MovementIntent,
    VISUAL_CORRECTION_EPSILON_SQ, WorldState, schedule::ClientSet,
};
use crate::camera::{OrbitCameraState, orbit::input_to_world_direction};
use crate::chat::ChatState;
use crate::config::ClientConfig;
use crate::input::commands::{MOVEMENT_FLAG_BRAKE, MOVEMENT_FLAG_JUMP, MoveInputFrame};
use crate::login::AppState;
use crate::net::{NetworkBridge, NetworkCommand};
use crate::observe::ClientObserver;
use crate::sim::{predictor, types::PredictedMoveState};

/// Audit C-L1: speed scale baked into every uplink movement sample.
///
/// `1.0` is the only value the integrator currently consumes — the field
/// remains in the wire format for forward compat (sprint / slow / status
/// effect modifiers). Centralising it here means a future change has one
/// edit instead of a grep across all callers.
const DEFAULT_MOVEMENT_SPEED_SCALE: f32 = 1.0;

pub struct MovementSyncPlugin;

impl Plugin for MovementSyncPlugin {
    fn build(&self, app: &mut App) {
        let interval_ms = app
            .world()
            .get_resource::<ClientConfig>()
            .map(|cfg| cfg.movement_interval_ms)
            .unwrap_or(50);

        app.init_resource::<InputTraceState>()
            .insert_resource(MovementTick(Timer::from_seconds(
                interval_ms as f32 / 1_000.0,
                TimerMode::Repeating,
            )))
            .add_systems(
                Update,
                sample_movement_input
                    .in_set(ClientSet::Input)
                    .run_if(in_state(AppState::Game)),
            )
            .add_systems(
                Update,
                (advance_local_render_prediction, movement_sender)
                    .chain()
                    .in_set(ClientSet::Sync)
                    .run_if(in_state(AppState::Game)),
            );
    }
}

#[derive(Resource)]
pub(crate) struct MovementTick(pub Timer);

#[derive(Resource, Default)]
pub(crate) struct InputTraceState {
    pub last_direction_label: String,
}

#[derive(SystemParam)]
struct MovementSendParams<'w> {
    time: Res<'w, Time>,
    bridge: Res<'w, NetworkBridge>,
    config: Res<'w, ClientConfig>,
    observer: Res<'w, ClientObserver>,
    world_state: Res<'w, WorldState>,
    movement_intent: ResMut<'w, MovementIntent>,
    movement_dispatch: ResMut<'w, MovementDispatchState>,
    tick: ResMut<'w, MovementTick>,
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn sample_movement_input(
    time: Res<Time>,
    keyboard: Res<ButtonInput<KeyCode>>,
    mut keyboard_input_reader: MessageReader<KeyboardInput>,
    chat_state: Res<ChatState>,
    orbit: Res<OrbitCameraState>,
    observer: Res<ClientObserver>,
    mut input_trace: ResMut<InputTraceState>,
    mut movement_intent: ResMut<MovementIntent>,
) {
    if chat_state.enabled {
        movement_intent.direction = Vec2::ZERO;
        movement_intent.expires_at = 0.0;
        movement_intent.jump_requested = false;
        maybe_log_direction_change(&observer, &mut input_trace, movement_intent.direction);
        return;
    }

    if keyboard.just_pressed(KeyCode::Space) {
        movement_intent.jump_requested = true;
        observer.emit(
            "input",
            "jump_pressed",
            &[("source", "keyboard".to_string())],
        );
    }

    let raw_direction = current_movement_direction(&keyboard);

    // `expires_at` belongs to stdio-driven timed moves. Keyboard intent must
    // track `ButtonInput::pressed()` exactly — extending a 250 ms latch on
    // every held frame would keep the unit sliding (and the predictor
    // rotating residual velocity toward the last direction) for frames
    // after every key release.
    //
    // WASD inputs are camera-relative (W = "walk where the camera is
    // pointing"); `input_to_world_direction` rotates them into the
    // sim-space world axis the server's movement integrator expects. The
    // stdio Move command writes `movement_intent.direction` directly and
    // is treated as already-world-axis (automation flows specify their
    // own direction).
    if raw_direction.length_squared() > 0.0 {
        movement_intent.direction = input_to_world_direction(raw_direction, orbit.yaw);
        movement_intent.expires_at = 0.0;
        maybe_log_direction_change(&observer, &mut input_trace, movement_intent.direction);
        return;
    }

    for keyboard_input in keyboard_input_reader.read() {
        if !keyboard_input.state.is_pressed() {
            continue;
        }

        let raw_direction = movement_direction_from_key(&keyboard_input.logical_key);
        if raw_direction.length_squared() > 0.0 {
            movement_intent.direction = input_to_world_direction(raw_direction, orbit.yaw);
            movement_intent.expires_at = 0.0;
            maybe_log_direction_change(&observer, &mut input_trace, movement_intent.direction);
            return;
        }
    }

    if time.elapsed_secs_f64() >= movement_intent.expires_at {
        movement_intent.direction = Vec2::ZERO;
    }

    maybe_log_direction_change(&observer, &mut input_trace, movement_intent.direction);
}

fn movement_sender(params: MovementSendParams) {
    let MovementSendParams {
        time,
        bridge,
        config,
        observer,
        world_state,
        mut movement_intent,
        mut movement_dispatch,
        mut tick,
    } = params;

    if !world_state.scene_joined {
        return;
    }

    if !tick.0.tick(time.delta()).just_finished() {
        return;
    }

    let direction = movement_intent.direction;
    let jump_requested = movement_intent.jump_requested;
    let movement_flags = movement_flags_for_intent(direction, jump_requested);

    let should_send_stop_sync_now = should_send_stop_sync(
        direction,
        world_state.local_velocity,
        movement_dispatch.stop_sent,
    );

    if direction.length_squared() == 0.0 && !should_send_stop_sync_now && !jump_requested {
        return;
    }

    bridge.send(NetworkCommand::MoveInputSample {
        input_dir: [direction.x, direction.y],
        dt_ms: config.movement_interval_ms as u16,
        speed_scale: DEFAULT_MOVEMENT_SPEED_SCALE,
        movement_flags,
    });

    observer.emit(
        "input",
        "movement_sample_queued",
        &[
            (
                "direction",
                format!("{:.2},{:.2}", direction.x, direction.y),
            ),
            ("movement_flags", movement_flags.to_string()),
            ("dt_ms", config.movement_interval_ms.to_string()),
            (
                "should_send_stop_sync",
                should_send_stop_sync_now.to_string(),
            ),
            (
                "local_position",
                world_state
                    .local_position
                    .map(|value| format!("{:.1},{:.1},{:.1}", value.x, value.y, value.z))
                    .unwrap_or_else(|| "n/a".to_string()),
            ),
            (
                "local_velocity",
                format!(
                    "{:.1},{:.1},{:.1}",
                    world_state.local_velocity.x,
                    world_state.local_velocity.y,
                    world_state.local_velocity.z
                ),
            ),
        ],
    );

    movement_intent.jump_requested = false;
    movement_dispatch.stop_sent = direction.length_squared() == 0.0
        && world_state.local_velocity.length() <= FINAL_STOP_SYNC_SPEED_EPSILON;
}

fn advance_local_render_prediction(
    time: Res<Time>,
    config: Res<ClientConfig>,
    movement_intent: Res<MovementIntent>,
    mut local_render_prediction: ResMut<LocalRenderPrediction>,
) {
    let Some(anchor) = local_render_prediction.anchor_state.clone() else {
        return;
    };

    let dt_secs = time.delta_secs();

    // Unreal-style exponential decay: `x(t) = x0 * exp(-rate * t)` drives the
    // outstanding visual correction toward zero without ever teleporting.
    let decay = (-local_render_prediction.smoothing_rate_hz * dt_secs).exp();
    local_render_prediction.pending_correction *= decay;
    if local_render_prediction.pending_correction.length_squared() < VISUAL_CORRECTION_EPSILON_SQ {
        local_render_prediction.pending_correction = Vec3::ZERO;
    }

    local_render_prediction.partial_elapsed_secs = (local_render_prediction.partial_elapsed_secs
        + dt_secs)
        .clamp(0.0, config.movement_interval_ms as f32 / 1_000.0);

    let direction = movement_intent.direction;
    let movement_flags = movement_flags_for_intent(direction, movement_intent.jump_requested);

    let partial_elapsed = local_render_prediction.partial_elapsed_secs;
    let stepped_anchor = if partial_elapsed <= f32::EPSILON {
        anchor.clone()
    } else {
        let partial_frame = MoveInputFrame {
            seq: 0,
            client_tick: anchor.tick,
            dt_ms: (partial_elapsed * 1_000.0)
                .round()
                .clamp(1.0, config.movement_interval_ms as f32) as u16,
            input_dir: Vec2::new(direction.x, direction.y),
            speed_scale: 1.0,
            movement_flags,
        };
        predictor::step(&anchor, &partial_frame, &local_render_prediction.profile)
    };

    let render_pos = stepped_anchor.position + local_render_prediction.pending_correction;
    local_render_prediction.render_state = Some(PredictedMoveState {
        position: render_pos,
        ..stepped_anchor
    });
}

pub(crate) fn current_movement_direction(keyboard: &ButtonInput<KeyCode>) -> Vec2 {
    let mut direction = Vec2::ZERO;

    if keyboard.pressed(KeyCode::KeyW) || keyboard.pressed(KeyCode::ArrowUp) {
        direction.y += 1.0;
    }
    if keyboard.pressed(KeyCode::KeyS) || keyboard.pressed(KeyCode::ArrowDown) {
        direction.y -= 1.0;
    }
    if keyboard.pressed(KeyCode::KeyA) || keyboard.pressed(KeyCode::ArrowLeft) {
        direction.x -= 1.0;
    }
    if keyboard.pressed(KeyCode::KeyD) || keyboard.pressed(KeyCode::ArrowRight) {
        direction.x += 1.0;
    }

    direction
}

pub(crate) fn movement_direction_from_key(key: &Key) -> Vec2 {
    match key {
        Key::Character(value) if value.eq_ignore_ascii_case("w") => Vec2::new(0.0, 1.0),
        Key::Character(value) if value.eq_ignore_ascii_case("s") => Vec2::new(0.0, -1.0),
        Key::Character(value) if value.eq_ignore_ascii_case("a") => Vec2::new(-1.0, 0.0),
        Key::Character(value) if value.eq_ignore_ascii_case("d") => Vec2::new(1.0, 0.0),
        Key::ArrowUp => Vec2::new(0.0, 1.0),
        Key::ArrowDown => Vec2::new(0.0, -1.0),
        Key::ArrowLeft => Vec2::new(-1.0, 0.0),
        Key::ArrowRight => Vec2::new(1.0, 0.0),
        _ => Vec2::ZERO,
    }
}

pub(crate) fn maybe_log_direction_change(
    observer: &ClientObserver,
    input_trace: &mut InputTraceState,
    direction: Vec2,
) {
    if !observer.enabled() {
        return;
    }

    let label = direction_label(direction);
    if input_trace.last_direction_label != label {
        observer.emit(
            "input",
            "movement_direction_changed",
            &[("direction", label.clone())],
        );
        input_trace.last_direction_label = label;
    }
}

fn direction_label(direction: Vec2) -> String {
    if direction == Vec2::ZERO {
        return "idle".to_string();
    }

    format!("{:.1},{:.1}", direction.x, direction.y)
}

pub(crate) fn should_send_stop_sync(
    direction: Vec2,
    local_velocity: Vec3,
    stop_sent: bool,
) -> bool {
    if direction.length_squared() > 0.0 {
        return true;
    }

    // Keep emitting zero-input brake frames until the local prediction has
    // actually settled. Otherwise the authoritative path can stop on a
    // non-zero residual velocity snapshot, which causes the local and remote
    // final positions to drift apart after longer movement bursts.
    !stop_sent || local_velocity.length() > FINAL_STOP_SYNC_SPEED_EPSILON
}

pub(crate) fn movement_flags_for_intent(direction: Vec2, jump_requested: bool) -> u16 {
    let mut movement_flags = if direction.length_squared() == 0.0 {
        MOVEMENT_FLAG_BRAKE
    } else {
        0
    };

    if jump_requested {
        movement_flags |= MOVEMENT_FLAG_JUMP;
    }

    movement_flags
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::ChatState;
    use crate::observe::ClientObserver;

    #[test]
    fn movement_direction_maps_wasd_and_arrows() {
        let mut keyboard = ButtonInput::<KeyCode>::default();
        keyboard.press(KeyCode::KeyW);
        keyboard.press(KeyCode::ArrowLeft);

        let direction = current_movement_direction(&keyboard);

        assert_eq!(direction, Vec2::new(-1.0, 1.0));
    }

    #[test]
    fn movement_direction_from_logical_key_supports_wasd_and_arrows() {
        assert_eq!(
            movement_direction_from_key(&Key::Character("w".into())),
            Vec2::new(0.0, 1.0)
        );
        assert_eq!(
            movement_direction_from_key(&Key::Character("A".into())),
            Vec2::new(-1.0, 0.0)
        );
        assert_eq!(
            movement_direction_from_key(&Key::ArrowRight),
            Vec2::new(1.0, 0.0)
        );
    }

    #[test]
    fn stop_sync_continues_while_local_velocity_is_nonzero() {
        assert!(should_send_stop_sync(
            Vec2::ZERO,
            Vec3::new(8.0, 0.0, 0.0),
            true
        ));
        assert!(should_send_stop_sync(Vec2::ZERO, Vec3::ZERO, false));
        assert!(!should_send_stop_sync(Vec2::ZERO, Vec3::ZERO, true));
    }

    fn camera_at_zero_yaw() -> OrbitCameraState {
        OrbitCameraState {
            yaw: 0.0,
            pitch: 0.5,
            distance: 400.0,
            requested_distance: 400.0,
            target: Vec3::ZERO,
        }
    }

    /// Regression: releasing every movement key must zero the intent on the
    /// very next system tick. The non-zero direction during the W press is
    /// the camera-relative-rotated value: at yaw=0 forward = -Y sim, so
    /// W produces (0, -1).
    #[test]
    fn releasing_all_keys_zeroes_intent_immediately() {
        let mut app = App::new();
        app.init_resource::<Time>()
            .init_resource::<ButtonInput<KeyCode>>()
            .add_message::<KeyboardInput>()
            .insert_resource(ChatState::default())
            .insert_resource(ClientObserver::default())
            .insert_resource(InputTraceState::default())
            .insert_resource(MovementIntent::default())
            .insert_resource(camera_at_zero_yaw())
            .add_systems(Update, sample_movement_input);

        app.world_mut()
            .resource_mut::<ButtonInput<KeyCode>>()
            .press(KeyCode::KeyW);
        app.update();

        {
            let intent = app.world().resource::<MovementIntent>();
            assert!((intent.direction.x - 0.0).abs() < 1e-6);
            assert!((intent.direction.y - (-1.0)).abs() < 1e-6);
            assert_eq!(intent.expires_at, 0.0);
        }

        app.world_mut()
            .resource_mut::<ButtonInput<KeyCode>>()
            .release_all();
        app.world_mut()
            .resource_mut::<Messages<KeyboardInput>>()
            .clear();
        app.world_mut()
            .resource_mut::<Time>()
            .advance_by(std::time::Duration::from_millis(16));
        app.update();

        let intent = app.world().resource::<MovementIntent>();
        assert_eq!(intent.direction, Vec2::ZERO);
    }

    #[test]
    fn pressing_space_sets_one_shot_jump_intent_and_flag() {
        let mut app = App::new();
        app.init_resource::<Time>()
            .init_resource::<ButtonInput<KeyCode>>()
            .add_message::<KeyboardInput>()
            .insert_resource(ChatState::default())
            .insert_resource(ClientObserver::default())
            .insert_resource(InputTraceState::default())
            .insert_resource(MovementIntent::default())
            .insert_resource(camera_at_zero_yaw())
            .add_systems(Update, sample_movement_input);

        app.world_mut()
            .resource_mut::<ButtonInput<KeyCode>>()
            .press(KeyCode::Space);
        app.update();

        let intent = app.world().resource::<MovementIntent>();
        assert!(intent.jump_requested);
        assert_eq!(
            movement_flags_for_intent(Vec2::ZERO, true),
            MOVEMENT_FLAG_BRAKE | crate::input::commands::MOVEMENT_FLAG_JUMP
        );
    }

    /// Camera-relative input: pressing W while the camera has yawed 90°
    /// must walk the player along sim -X, not sim -Y. Direct test of the
    /// `sample_movement_input` glue (the math is unit-tested in
    /// `crate::camera::orbit::tests`).
    #[test]
    fn w_press_rotates_input_by_camera_yaw() {
        let mut app = App::new();
        app.init_resource::<Time>()
            .init_resource::<ButtonInput<KeyCode>>()
            .add_message::<KeyboardInput>()
            .insert_resource(ChatState::default())
            .insert_resource(ClientObserver::default())
            .insert_resource(InputTraceState::default())
            .insert_resource(MovementIntent::default())
            .insert_resource(OrbitCameraState {
                yaw: std::f32::consts::FRAC_PI_2,
                pitch: 0.5,
                distance: 400.0,
                requested_distance: 400.0,
                target: Vec3::ZERO,
            })
            .add_systems(Update, sample_movement_input);

        app.world_mut()
            .resource_mut::<ButtonInput<KeyCode>>()
            .press(KeyCode::KeyW);
        app.update();

        let intent = app.world().resource::<MovementIntent>();
        assert!(
            (intent.direction.x - (-1.0)).abs() < 1e-6,
            "W at yaw=π/2 must rotate to sim -X, got {}",
            intent.direction.x,
        );
        assert!((intent.direction.y - 0.0).abs() < 1e-6);
    }
}
