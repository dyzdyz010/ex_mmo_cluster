//! `CameraPlugin` — third-person follow camera.
//!
//! In gameplay (`AppState::Game`, chat closed) the cursor is grabbed and
//! hidden, and any mouse motion rotates the orbit around the local actor
//! free-look style — the same convention as WoW / FFXIV / Source-engine
//! third-person modes. Opening chat (`Enter`) or returning to the login
//! screen releases the cursor so users can interact with text input or
//! the egui login panel. `Ctrl + wheel` zooms toward / away from the
//! actor; the wheel without `Ctrl` is reserved for the voxel hotbar.

use bevy::ecs::system::SystemParam;
use bevy::input::mouse::{MouseMotion, MouseWheel};
use bevy::prelude::*;
use bevy::window::{CursorGrabMode, CursorOptions, PrimaryWindow};

use crate::app::{LocalRenderPrediction, WorldState};
use crate::chat::ChatState;
use crate::login::AppState;
use crate::observe::ClientObserver;
use crate::presentation::actor_render_position;
use crate::presentation::smoothing::smooth_translation;
use crate::voxel::VoxelWorld;

use super::orbit::{
    CAMERA_LOOK_HEIGHT, CAMERA_MAX_DISTANCE, CAMERA_MAX_PITCH, CAMERA_MIN_DISTANCE,
    CAMERA_MIN_PITCH, CAMERA_PITCH_SENSITIVITY, CAMERA_YAW_SENSITIVITY, MainCamera,
    OrbitCameraState, camera_transform_from_orbit,
};

pub struct CameraPlugin;

impl Plugin for CameraPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<OrbitCameraState>()
            // Cursor lock management runs every frame regardless of state
            // so the egui login panel keeps the cursor visible and the
            // game state grabs it as soon as the user clicks past login.
            .add_systems(Update, manage_cursor_grab)
            .add_systems(Update, update_orbit_camera.run_if(in_state(AppState::Game)));
    }
}

/// Grab + hide the cursor while we're in `AppState::Game` and chat input
/// is closed. Anything else (login screen, chat-open) keeps the cursor
/// visible so the user can drive the egui panel or watch their typing.
///
/// In Bevy 0.18 `CursorOptions` is a separate component on the window
/// entity (Bevy auto-adds it via `#[require(CursorOptions)]` on
/// `Window`).
fn manage_cursor_grab(
    state: Res<State<AppState>>,
    chat_state: Option<Res<ChatState>>,
    cursor: Single<&mut CursorOptions, With<PrimaryWindow>>,
) {
    let mut cursor = cursor.into_inner();
    let chat_open = chat_state.map(|state| state.enabled).unwrap_or(false);
    let want_grabbed = matches!(state.get(), AppState::Game) && !chat_open;

    let desired_grab = if want_grabbed {
        CursorGrabMode::Locked
    } else {
        CursorGrabMode::None
    };
    if cursor.grab_mode != desired_grab {
        cursor.grab_mode = desired_grab;
    }
    if cursor.visible == want_grabbed {
        cursor.visible = !want_grabbed;
    }
}

#[derive(SystemParam)]
struct OrbitCameraParams<'w, 's> {
    time: Res<'w, Time>,
    chat_state: Res<'w, ChatState>,
    keyboard: Res<'w, ButtonInput<KeyCode>>,
    motion_reader: MessageReader<'w, 's, MouseMotion>,
    wheel_reader: MessageReader<'w, 's, MouseWheel>,
    world_state: Res<'w, WorldState>,
    local_render_prediction: Res<'w, LocalRenderPrediction>,
    voxel_world: Res<'w, VoxelWorld>,
    orbit: ResMut<'w, OrbitCameraState>,
    observer: Res<'w, ClientObserver>,
    camera: Single<'w, 's, &'static mut Transform, With<MainCamera>>,
}

fn update_orbit_camera(mut params: OrbitCameraParams) {
    if !params.chat_state.enabled {
        // Cursor is grabbed (`manage_cursor_grab`) so every motion event
        // is camera-rotation. Web-browser pointer-lock equivalents and
        // the WoW / Source / FFXIV third-person feel.
        let delta = params
            .motion_reader
            .read()
            .fold(Vec2::ZERO, |acc, event| acc + event.delta);
        if delta.length_squared() > 0.0 {
            let pre_yaw = params.orbit.yaw;
            let pre_pitch = params.orbit.pitch;
            params.orbit.yaw -= delta.x * CAMERA_YAW_SENSITIVITY;
            params.orbit.pitch = (params.orbit.pitch + delta.y * CAMERA_PITCH_SENSITIVITY)
                .clamp(CAMERA_MIN_PITCH, CAMERA_MAX_PITCH);
            if params.observer.enabled() {
                params.observer.emit(
                    "camera",
                    "orbit_motion",
                    &[
                        ("delta", format!("{:.2},{:.2}", delta.x, delta.y)),
                        ("pre_yaw", format!("{pre_yaw:.3}")),
                        ("post_yaw", format!("{:.3}", params.orbit.yaw)),
                        ("pre_pitch", format!("{pre_pitch:.3}")),
                        ("post_pitch", format!("{:.3}", params.orbit.pitch)),
                    ],
                );
            }
        }

        let control_zoom = params.keyboard.pressed(KeyCode::ControlLeft)
            || params.keyboard.pressed(KeyCode::ControlRight);
        let wheel_delta = params.wheel_reader.read().map(|event| event.y).sum::<f32>();
        if control_zoom && wheel_delta.abs() > f32::EPSILON {
            params.orbit.distance = (params.orbit.distance - wheel_delta * 28.0)
                .clamp(CAMERA_MIN_DISTANCE, CAMERA_MAX_DISTANCE);
        }
    } else {
        // Chat is open: drop pending mouse motion + wheel events so a
        // rapid type-burst does not snap the camera the moment chat
        // closes.
        params.motion_reader.clear();
        params.wheel_reader.clear();
    }

    let desired_target = params
        .local_render_prediction
        .render_state
        .as_ref()
        .map(|state| actor_render_position(&params.voxel_world, state.position))
        .or_else(|| {
            params
                .world_state
                .local_position
                .map(|position| actor_render_position(&params.voxel_world, position))
        })
        .map(|position| position + Vec3::Y * CAMERA_LOOK_HEIGHT)
        .unwrap_or(params.orbit.target);

    // Audit D-S3: these tuned constants are intentionally distinct from the
    // older orbital constants in `presentation::camera`. They control the
    // third-person follow feel — gentle 8.0 follow speed (slower than the
    // 12.0 orbital camera so swing/strafe doesn't whip the view) and a
    // larger 300.0 snap radius (third-person camera sits farther from the
    // actor, so what feels "too large to ease" is bigger). See
    // `presentation::camera` module doc for the boundary.
    const THIRD_PERSON_FOLLOW_SPEED: f32 = 8.0;
    const THIRD_PERSON_SNAP_DISTANCE: f32 = 300.0;
    let target = smooth_translation(
        params.orbit.target,
        desired_target,
        params.time.delta_secs(),
        THIRD_PERSON_FOLLOW_SPEED,
        THIRD_PERSON_SNAP_DISTANCE,
    );
    params.orbit.target = target;
    **params.camera = camera_transform_from_orbit(&params.orbit);
}
