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
use bevy::window::{CursorGrabMode, CursorOptions, PrimaryWindow, WindowFocused};

use crate::app::{LocalRenderPrediction, WorldState, schedule::ClientSet};
use crate::chat::ChatState;
use crate::login::AppState;
use crate::session::ConnectionState;
use crate::observe::ClientObserver;
use crate::presentation::actor_render_position;
use crate::presentation::smoothing::smooth_translation;
use crate::voxel::VoxelWorld;
use crate::voxel::authority_plugin::VoxelAuthority;
use crate::voxel::plugin::ACTOR_HALF_HEIGHT;

use super::orbit::{
    CAMERA_LOOK_HEIGHT, CAMERA_MAX_DISTANCE, CAMERA_MAX_PITCH, CAMERA_MIN_DISTANCE,
    CAMERA_MIN_PITCH, CAMERA_PITCH_SENSITIVITY, CAMERA_YAW_SENSITIVITY, MainCamera,
    OrbitCameraState, camera_transform_from_orbit,
};

pub struct CameraPlugin;

impl Plugin for CameraPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<OrbitCameraState>()
            .init_resource::<WindowFocusGate>()
            // Audit C-S1: keep window focus state in a resource so
            // `manage_cursor_grab` can release the cursor as soon as we
            // lose focus (Alt-Tab, OS notification, IME popup) without
            // depending on Bevy's per-frame cursor-grab state.
            .add_systems(Update, track_window_focus.in_set(ClientSet::Render))
            // Audit C-M3: re-evaluate cursor grab only when one of the
            // inputs the decision depends on actually changed. Without
            // this `run_if` it ran every frame and re-touched
            // CursorOptions even when nothing was different.
            .add_systems(
                Update,
                manage_cursor_grab.in_set(ClientSet::Render).run_if(
                    state_changed::<AppState>
                        .or_else(resource_changed::<ChatState>)
                        .or_else(resource_changed::<WindowFocusGate>),
                ),
            )
            .add_systems(
                Update,
                update_orbit_camera
                    .in_set(ClientSet::Render)
                    .run_if(in_state(AppState::Game)),
            );
    }
}

/// Audit C-S1: tracks whether the primary window currently has focus.
/// Replaces the previous "always assume focused" assumption that left
/// the cursor locked after Alt-Tab.
#[derive(Resource, Debug, PartialEq, Eq, Clone, Copy)]
pub struct WindowFocusGate {
    pub focused: bool,
}

impl Default for WindowFocusGate {
    fn default() -> Self {
        // Most app launches begin with the window focused; rely on the
        // first WindowFocused event to flip this off if needed.
        Self { focused: true }
    }
}

fn track_window_focus(
    mut focus_events: MessageReader<WindowFocused>,
    mut gate: ResMut<WindowFocusGate>,
) {
    for event in focus_events.read() {
        if gate.focused != event.focused {
            gate.focused = event.focused;
        }
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
    focus: Res<WindowFocusGate>,
    window: Single<(&mut Window, &mut CursorOptions), With<PrimaryWindow>>,
) {
    let (mut window, mut cursor) = window.into_inner();
    let chat_open = chat_state.map(|state| state.enabled).unwrap_or(false);
    // Audit C-S1: even in-game we MUST release the cursor while the
    // window is unfocused — otherwise Alt-Tab leaves the cursor pinned
    // inside the (possibly invisible) Bevy window.
    let want_grabbed = matches!(state.get(), AppState::Game) && !chat_open && focus.focused;

    let desired_grab = if want_grabbed {
        CursorGrabMode::Locked
    } else {
        CursorGrabMode::None
    };

    // We are (re)acquiring the grab this frame (e.g. the window just gained focus
    // after being launched in the background, so the OS cursor may still be sitting
    // OUTSIDE our client area).
    let acquiring_grab = want_grabbed && cursor.grab_mode == CursorGrabMode::None;

    if cursor.grab_mode != desired_grab {
        cursor.grab_mode = desired_grab;
    }
    if cursor.visible == want_grabbed {
        cursor.visible = !want_grabbed;
    }

    // Snap the OS cursor into the window centre the moment we grab. Without this, if
    // the pointer was outside the window before capture, the player's first click can
    // land on whatever was behind it (another window / the desktop) instead of the
    // game — the locked cursor only confines *future* motion, not its starting point.
    // Centring guarantees the cursor — and every click — is inside the window.
    if acquiring_grab {
        let center = Vec2::new(window.width() / 2.0, window.height() / 2.0);
        window.set_cursor_position(Some(center));
    }
}

#[derive(SystemParam)]
struct OrbitCameraParams<'w, 's> {
    time: Res<'w, Time>,
    chat_state: Res<'w, ChatState>,
    keyboard: Res<'w, ButtonInput<KeyCode>>,
    motion_reader: MessageReader<'w, 's, MouseMotion>,
    wheel_reader: MessageReader<'w, 's, MouseWheel>,
    connection: Res<'w, ConnectionState>,
    world_state: Res<'w, WorldState>,
    local_render_prediction: Res<'w, LocalRenderPrediction>,
    voxel_world: Res<'w, VoxelWorld>,
    authority: Res<'w, VoxelAuthority>,
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
            // Audit C-L3: filter out micro-motion observer noise. Mouse
            // events fire at >120 Hz on most desktops; emitting per-frame
            // saturated debug logs and made it hard to spot real motion.
            // 4 px (squared = 16) is below human-noticeable orbit drift
            // but well above sensor noise.
            const ORBIT_MOTION_LOG_THRESHOLD_SQ: f32 = 16.0;
            if params.observer.enabled() && delta.length_squared() >= ORBIT_MOTION_LOG_THRESHOLD_SQ
            {
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
            // Audit C-M1: write to `requested_distance`, not `distance`,
            // so the collision logic below does not see its own ephemeral
            // shorten as the next frame's "user wanted this distance".
            params.orbit.requested_distance = (params.orbit.requested_distance
                - wheel_delta * 28.0)
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
        .map(|state| {
            actor_render_position(
                &params.voxel_world,
                &params.authority,
                params.connection.scene_joined,
                state.position,
                ACTOR_HALF_HEIGHT,
            )
        })
        .or_else(|| {
            params.world_state.local_position.map(|position| {
                actor_render_position(
                    &params.voxel_world,
                    &params.authority,
                    params.connection.scene_joined,
                    position,
                    ACTOR_HALF_HEIGHT,
                )
            })
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

    // Audit C-M1: ray-cast from the camera target outward toward the
    // ideal camera position; if a voxel intersects between, shorten
    // `orbit.distance` so the camera sits in front of the wall instead
    // of clipping into terrain. We restore distance up to the user's
    // chosen wheel-zoom value (`requested_distance`) on subsequent
    // frames once the obstruction is gone.
    const CAMERA_COLLISION_PADDING: f32 = 8.0;
    let requested_distance = params
        .orbit
        .requested_distance
        .clamp(CAMERA_MIN_DISTANCE, CAMERA_MAX_DISTANCE);
    let camera_offset_dir = camera_offset_direction(&params.orbit);
    if let Some(hit_distance) = crate::voxel::plugin::voxel_ray_first_hit_distance(
        &params.voxel_world,
        &params.authority,
        params.connection.scene_joined,
        target,
        camera_offset_dir,
        requested_distance,
    ) {
        let safe_distance = (hit_distance - CAMERA_COLLISION_PADDING)
            .clamp(CAMERA_MIN_DISTANCE, requested_distance);
        params.orbit.distance = safe_distance;
    } else {
        params.orbit.distance = requested_distance;
    }

    **params.camera = camera_transform_from_orbit(&params.orbit);

    // GUI-smoke 2026-04-26: log camera + target every ~1s so we can verify
    // from the observer log that the camera really follows the actor.
    static LAST_LOG_SECS: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(0);
    let now_sec = params.time.elapsed_secs() as i64;
    if params.observer.enabled()
        && LAST_LOG_SECS.swap(now_sec, std::sync::atomic::Ordering::Relaxed) != now_sec
    {
        let cam = params.camera.translation;
        params.observer.emit(
            "camera",
            "follow_state",
            &[
                (
                    "target",
                    format!("{:.0},{:.0},{:.0}", target.x, target.y, target.z),
                ),
                ("camera", format!("{:.0},{:.0},{:.0}", cam.x, cam.y, cam.z)),
                ("distance", format!("{:.0}", params.orbit.distance)),
                (
                    "yaw_pitch",
                    format!("{:.2},{:.2}", params.orbit.yaw, params.orbit.pitch),
                ),
            ],
        );
    }
}

/// Audit C-M1: returns the unit-vector pointing from `target` to the
/// ideal camera position, derived from the same yaw/pitch math used
/// inside `camera_transform_from_orbit`. Splitting it out lets the
/// collision ray-cast use the direction without re-deriving the
/// transform.
fn camera_offset_direction(orbit: &OrbitCameraState) -> Vec3 {
    let horizontal = orbit.pitch.cos();
    Vec3::new(
        horizontal * orbit.yaw.sin(),
        orbit.pitch.sin(),
        horizontal * orbit.yaw.cos(),
    )
    .normalize_or_zero()
}
