//! `SkillPlugin` — keyboard skill hotkeys, target/point picking, and
//! outbound skill dispatch.

use bevy::prelude::*;
use bevy::window::PrimaryWindow;

use crate::app::{WorldState, push_line, render_to_sim_position};
use crate::camera::MainCamera;
use crate::chat::ChatState;
use crate::login::AppState;
use crate::net::{NetworkBridge, NetworkCommand};
use crate::observe::ClientObserver;

use super::targeting::prepare_skill_dispatch;

pub struct SkillPlugin;

impl Plugin for SkillPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(
            Update,
            (
                handle_skill_input,
                handle_target_selection_input,
                handle_point_target_input,
            )
                .run_if(in_state(AppState::Game)),
        );
    }
}

fn handle_skill_input(
    keyboard: Res<ButtonInput<KeyCode>>,
    bridge: Res<NetworkBridge>,
    observer: Res<ClientObserver>,
    chat_state: Res<ChatState>,
    mut world_state: ResMut<WorldState>,
) {
    if chat_state.enabled {
        return;
    }

    let skill_modifier =
        keyboard.pressed(KeyCode::ShiftLeft) || keyboard.pressed(KeyCode::ShiftRight);
    if !skill_modifier {
        return;
    }

    if keyboard.just_pressed(KeyCode::Digit1) {
        send_targeted_skill(&bridge, &observer, &mut world_state, 1);
    }

    if keyboard.just_pressed(KeyCode::Digit2) {
        send_targeted_skill(&bridge, &observer, &mut world_state, 2);
    }

    if keyboard.just_pressed(KeyCode::Digit3) {
        send_targeted_skill(&bridge, &observer, &mut world_state, 3);
    }

    if keyboard.just_pressed(KeyCode::Digit4) {
        send_targeted_skill(&bridge, &observer, &mut world_state, 4);
    }
}

fn handle_target_selection_input(
    keyboard: Res<ButtonInput<KeyCode>>,
    mut world_state: ResMut<WorldState>,
    observer: Res<ClientObserver>,
) {
    if !keyboard.just_pressed(KeyCode::Tab) {
        return;
    }

    let mut cids = world_state
        .remote_actor_identity
        .keys()
        .copied()
        .collect::<Vec<_>>();
    cids.sort_unstable();

    if cids.is_empty() {
        world_state.selected_target_cid = None;
        return;
    }

    let next = match world_state.selected_target_cid {
        Some(current) => {
            let index = cids
                .iter()
                .position(|cid| *cid == current)
                .unwrap_or(usize::MAX);
            cids.get((index + 1) % cids.len()).copied()
        }
        None => cids.first().copied(),
    };

    world_state.selected_target_cid = next;
    world_state.selected_target_point = None;
    if let Some(cid) = next {
        observer.emit("input", "target_selected", &[("cid", cid.to_string())]);
    }
}

fn handle_point_target_input(
    mouse: Res<ButtonInput<MouseButton>>,
    keyboard: Res<ButtonInput<KeyCode>>,
    windows: Query<&Window, With<PrimaryWindow>>,
    camera: Single<(&Camera, &GlobalTransform), With<MainCamera>>,
    mut world_state: ResMut<WorldState>,
    observer: Res<ClientObserver>,
) {
    let target_modifier =
        keyboard.pressed(KeyCode::ShiftLeft) || keyboard.pressed(KeyCode::ShiftRight);
    if mouse.just_pressed(MouseButton::Right) && target_modifier {
        let Ok(window) = windows.single() else {
            return;
        };

        if let Some(cursor) = window.cursor_position() {
            let (camera, camera_transform) = *camera;
            let Some(render_point) =
                crate::app::ray_from_viewport(camera, camera_transform, cursor).and_then(|ray| {
                    crate::app::ray_intersection_with_y_plane(ray.origin, ray.direction, 0.0)
                })
            else {
                return;
            };
            let sim_point = render_to_sim_position(render_point);
            world_state.selected_target_point = Some(sim_point);
            world_state.selected_target_cid = None;
            observer.emit(
                "input",
                "target_point_selected",
                &[(
                    "point",
                    format!("{:.1},{:.1},{:.1}", sim_point.x, sim_point.y, sim_point.z),
                )],
            );
        }
    }
}

fn send_targeted_skill(
    bridge: &NetworkBridge,
    observer: &ClientObserver,
    world_state: &mut WorldState,
    skill_id: u16,
) {
    let selected_target_point = world_state
        .selected_target_point
        .map(|point| [point.x as f64, point.y as f64, point.z as f64]);
    let visible_actor_count = world_state.remote_players.len();

    let dispatch = match prepare_skill_dispatch(
        skill_id,
        world_state.selected_target_cid,
        selected_target_point,
        visible_actor_count,
    ) {
        Ok(dispatch) => dispatch,
        Err(block) => {
            let message = format!("skill {skill_id} blocked: {}", block.reason);
            world_state.status = message.clone();
            push_line(&mut world_state.logs, format!("{message} ({})", block.hint));
            observer.emit(
                "input",
                "skill_blocked",
                &[
                    ("skill_id", skill_id.to_string()),
                    ("reason", block.reason.to_string()),
                    ("hint", block.hint.to_string()),
                ],
            );
            return;
        }
    };

    bridge.send(NetworkCommand::CastSkillTargeted {
        skill_id,
        target_cid: dispatch.target_cid,
        target_position: dispatch.target_position,
    });

    observer.emit(
        "input",
        "skill_key",
        &[
            ("skill_id", skill_id.to_string()),
            (
                "target_cid",
                dispatch
                    .target_cid
                    .map(|value: i64| value.to_string())
                    .unwrap_or_else(|| "auto".to_string()),
            ),
            (
                "target_point",
                dispatch
                    .target_position
                    .map(|value| format!("{:.1},{:.1},{:.1}", value[0], value[1], value[2]))
                    .unwrap_or_else(|| "n/a".to_string()),
            ),
        ],
    );
}
