//! `SkillPlugin` — keyboard skill hotkeys, target/point picking, and
//! outbound skill dispatch.

use bevy::prelude::*;
use bevy::window::PrimaryWindow;

use crate::app::{WorldState, push_line, render_to_sim_position};
use crate::session::ConnectionState;
use crate::camera::MainCamera;
use crate::chat::ChatState;
use crate::login::AppState;
use crate::net::{NetworkBridge, NetworkCommand};
use crate::observe::ClientObserver;

use super::TargetSelection;
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
    remote: Res<crate::world::RemotePlayers>,
    mut connection: ResMut<ConnectionState>,
    mut logs: ResMut<crate::hud::GameLogs>,
    target: Res<TargetSelection>,
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
        send_targeted_skill(&bridge, &observer, &remote, &mut connection, &mut logs, &target, 1);
    }

    if keyboard.just_pressed(KeyCode::Digit2) {
        send_targeted_skill(&bridge, &observer, &remote, &mut connection, &mut logs, &target, 2);
    }

    if keyboard.just_pressed(KeyCode::Digit3) {
        send_targeted_skill(&bridge, &observer, &remote, &mut connection, &mut logs, &target, 3);
    }

    if keyboard.just_pressed(KeyCode::Digit4) {
        send_targeted_skill(&bridge, &observer, &remote, &mut connection, &mut logs, &target, 4);
    }
}

fn handle_target_selection_input(
    keyboard: Res<ButtonInput<KeyCode>>,
    remote: Res<crate::world::RemotePlayers>,
    mut target: ResMut<TargetSelection>,
    observer: Res<ClientObserver>,
) {
    if !keyboard.just_pressed(KeyCode::Tab) {
        return;
    }

    let mut cids = remote
        .identity
        .keys()
        .copied()
        .collect::<Vec<_>>();
    cids.sort_unstable();

    if cids.is_empty() {
        target.cid = None;
        return;
    }

    let next = cycle_target_cid(&cids, target.cid);

    target.cid = next;
    target.point = None;
    if let Some(cid) = next {
        observer.emit("input", "target_selected", &[("cid", cid.to_string())]);
    }
}

/// Max ray length (render units) for the Shift+RMB ground pick.
const POINT_PICK_MAX_DISTANCE: f32 = 10_000.0;

/// Next target cid in a sorted cycle. Overflow-safe: a `current` that is NOT in
/// `cids` (e.g. a stale cid set via stdio `target <cid>` that was never in the
/// AOI) restarts the cycle from the first entry. The old inline form
/// `position(..).unwrap_or(usize::MAX)` then `(index + 1) % len` computed
/// `usize::MAX + 1`, panicking in debug builds.
fn cycle_target_cid(cids: &[i64], current: Option<i64>) -> Option<i64> {
    match current.and_then(|c| cids.iter().position(|cid| *cid == c)) {
        Some(index) => cids.get((index + 1) % cids.len()).copied(),
        None => cids.first().copied(),
    }
}

#[allow(clippy::too_many_arguments)]
fn handle_point_target_input(
    mouse: Res<ButtonInput<MouseButton>>,
    keyboard: Res<ButtonInput<KeyCode>>,
    windows: Query<&Window, With<PrimaryWindow>>,
    camera: Single<(&Camera, &GlobalTransform), With<MainCamera>>,
    voxel_world: Res<crate::voxel::VoxelWorld>,
    authority: Res<crate::voxel::authority_plugin::VoxelAuthority>,
    world_state: Res<WorldState>,
    connection: Res<ConnectionState>,
    mut target: ResMut<TargetSelection>,
    observer: Res<ClientObserver>,
) {
    let target_modifier =
        keyboard.pressed(KeyCode::ShiftLeft) || keyboard.pressed(KeyCode::ShiftRight);
    if !(mouse.just_pressed(MouseButton::Right) && target_modifier) {
        return;
    }
    let Ok(window) = windows.single() else {
        return;
    };
    let Some(cursor) = window.cursor_position() else {
        return;
    };
    let (camera, camera_transform) = *camera;
    let Some(ray) = crate::app::ray_from_viewport(camera, camera_transform, cursor) else {
        return;
    };
    let scene_joined = connection.scene_joined;
    let dir = ray.direction.normalize_or_zero();

    // Pick the actual ground the cursor is over (server-authoritative terrain in a
    // live scene), NOT a fixed render-Y=0 plane. The world floor sits ~185 render
    // units up, so the old Y=0 pick forced the point's vertical to ~185 below the
    // surface → the server's 3D range/AOE checks missed and the point skill hit
    // nobody. Reuse the same authority macro-DDA as the build/camera paths.
    let render_point = crate::voxel::plugin::voxel_ray_first_hit_distance(
        &voxel_world,
        &authority,
        scene_joined,
        ray.origin,
        ray.direction,
        POINT_PICK_MAX_DISTANCE,
    )
    .map(|dist| ray.origin + dir * dist)
    .or_else(|| {
        // No terrain under the cursor (aiming past the world): fall back to a
        // horizontal plane at the local player's grounded render height (their
        // feet plane), so the point still lands near the visible surface.
        let player_y = world_state.local_position.map(|p| {
            let r = crate::app::sim_to_render_position(p);
            crate::voxel::plugin::surface_center_y_at_render_xz(
                &voxel_world,
                &authority,
                scene_joined,
                r.x,
                r.z,
                0.0,
                r.y,
            )
        })?;
        crate::app::ray_intersection_with_y_plane(ray.origin, ray.direction, player_y)
    });
    let Some(render_point) = render_point else {
        return;
    };
    let sim_point = render_to_sim_position(render_point);
    target.point = Some(sim_point);
    target.cid = None;
    observer.emit(
        "input",
        "target_point_selected",
        &[(
            "point",
            format!("{:.1},{:.1},{:.1}", sim_point.x, sim_point.y, sim_point.z),
        )],
    );
}

#[allow(clippy::too_many_arguments)]
fn send_targeted_skill(
    bridge: &NetworkBridge,
    observer: &ClientObserver,
    remote: &crate::world::RemotePlayers,
    connection: &mut ConnectionState,
    logs: &mut crate::hud::GameLogs,
    target: &TargetSelection,
    skill_id: u16,
) {
    let selected_target_point = target
        .point
        .map(|point| [point.x as f64, point.y as f64, point.z as f64]);
    let visible_actor_count = remote.players.len();

    let dispatch = match prepare_skill_dispatch(
        skill_id,
        target.cid,
        selected_target_point,
        visible_actor_count,
    ) {
        Ok(dispatch) => dispatch,
        Err(block) => {
            let message = format!("skill {skill_id} blocked: {}", block.reason);
            connection.status = message.clone();
            push_line(&mut logs.general, format!("{message} ({})", block.hint));
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

#[cfg(test)]
mod tests {
    use super::cycle_target_cid;

    #[test]
    fn cycle_target_is_overflow_safe_and_wraps() {
        let cids = [10i64, 20, 30];
        assert_eq!(cycle_target_cid(&cids, None), Some(10)); // no selection → first
        assert_eq!(cycle_target_cid(&cids, Some(10)), Some(20));
        assert_eq!(cycle_target_cid(&cids, Some(30)), Some(10)); // wraps
        // Stale/unknown cid (e.g. stdio `target 90001` never in AOI) → restart at
        // first, NOT usize::MAX + 1 (which panicked in debug).
        assert_eq!(cycle_target_cid(&cids, Some(90001)), Some(10));
        assert_eq!(cycle_target_cid(&[], Some(5)), None);
        assert_eq!(cycle_target_cid(&[], None), None);
    }
}
