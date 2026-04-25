//! `CameraPlugin` — registers the orbit camera resource and the system
//! that follows the local actor while honouring chat-mode mouse capture
//! and `Ctrl + wheel` zoom.

use bevy::ecs::system::SystemParam;
use bevy::input::mouse::{MouseMotion, MouseWheel};
use bevy::prelude::*;

use crate::app::{ChatState, LocalRenderPrediction, WorldState, actor_render_position};
use crate::login::AppState;
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
            .add_systems(Update, update_orbit_camera.run_if(in_state(AppState::Game)));
    }
}

#[derive(SystemParam)]
struct OrbitCameraParams<'w, 's> {
    time: Res<'w, Time>,
    chat_state: Res<'w, ChatState>,
    mouse: Res<'w, ButtonInput<MouseButton>>,
    keyboard: Res<'w, ButtonInput<KeyCode>>,
    motion_reader: MessageReader<'w, 's, MouseMotion>,
    wheel_reader: MessageReader<'w, 's, MouseWheel>,
    world_state: Res<'w, WorldState>,
    local_render_prediction: Res<'w, LocalRenderPrediction>,
    voxel_world: Res<'w, VoxelWorld>,
    orbit: ResMut<'w, OrbitCameraState>,
    camera: Single<'w, 's, &'static mut Transform, With<MainCamera>>,
}

fn update_orbit_camera(mut params: OrbitCameraParams) {
    if !params.chat_state.enabled {
        let rotating =
            params.mouse.pressed(MouseButton::Left) || params.mouse.pressed(MouseButton::Middle);
        if rotating {
            let delta = params
                .motion_reader
                .read()
                .fold(Vec2::ZERO, |acc, event| acc + event.delta);
            params.orbit.yaw -= delta.x * CAMERA_YAW_SENSITIVITY;
            params.orbit.pitch = (params.orbit.pitch + delta.y * CAMERA_PITCH_SENSITIVITY)
                .clamp(CAMERA_MIN_PITCH, CAMERA_MAX_PITCH);
        } else {
            params.motion_reader.clear();
        }

        let control_zoom = params.keyboard.pressed(KeyCode::ControlLeft)
            || params.keyboard.pressed(KeyCode::ControlRight);
        let wheel_delta = params.wheel_reader.read().map(|event| event.y).sum::<f32>();
        if control_zoom && wheel_delta.abs() > f32::EPSILON {
            params.orbit.distance = (params.orbit.distance - wheel_delta * 28.0)
                .clamp(CAMERA_MIN_DISTANCE, CAMERA_MAX_DISTANCE);
        }
    } else {
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

    let target = smooth_translation(
        params.orbit.target,
        desired_target,
        params.time.delta_secs(),
        8.0,
        300.0,
    );
    params.orbit.target = target;
    **params.camera = camera_transform_from_orbit(&params.orbit);
}
