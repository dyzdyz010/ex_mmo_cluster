//! `VoxelPlugin` — owns the voxel selection ray, voxel edit input,
//! voxel mesh rendering, prefab/boundary preview gizmos, and the
//! `TargetPointMarker` mesh.
//!
//! This is the largest plugin: it drives most of the on-screen voxel
//! interaction and consumes the `MainCamera` (from `crate::camera`),
//! `SceneRenderAssets` (from `crate::app`), `WorldState`, and the voxel
//! world Resource itself.

use std::collections::HashMap;

use bevy::ecs::system::SystemParam;
use bevy::input::mouse::MouseWheel;
use bevy::prelude::*;
use bevy::window::PrimaryWindow;

use crate::app::{
    SceneRenderAssets, WorldState, push_line, ray_from_viewport, sim_to_render_position,
};
use crate::camera::MainCamera;
use crate::chat::ChatState;
use crate::login::AppState;
use crate::net::{NetworkBridge, NetworkCommand};
use crate::observe::ClientObserver;
use crate::voxel::authority::CellState;
use crate::voxel::authority_plugin::{VOXEL_LOGICAL_SCENE_ID, VoxelAuthority};
use crate::voxel::live_pick::pick_voxel;
use crate::voxel::wire::{ACTION_BREAK, ACTION_PLACE};
use crate::voxel::{
    BoundarySnapPreview, BoundarySnapRequest, MacroCoord, MicroCellTarget, MicroCoord,
    NormalBlockData, VoxelMaterialId, VoxelRenderCell, VoxelWorld,
};

const VOXEL_RENDER_CELL_SIZE: f32 = 100.0;
const VOXEL_RENDER_MICRO_SIZE: f32 = VOXEL_RENDER_CELL_SIZE / crate::voxel::MICRO_PER_MACRO as f32;
const VOXEL_RAY_MAX_DISTANCE: f32 = 2_500.0;
/// Default half-height used for camera follow / orbit grounding when the
/// caller doesn't already know the specific actor's cube size. Matches the
/// local-player cube authored in `presentation::plugin` (`scale.y = 90.0` →
/// half = 45). Per-actor grounding (the spawn / update path in
/// `presentation::plugin`) reads `PlayerVisual::base_scale` and passes that
/// half explicitly so remote / NPC cubes ground correctly too.
pub(crate) const ACTOR_HALF_HEIGHT: f32 = 45.0;

/// Resource caching the most recent voxel hit produced by the screen-
/// center ray.
#[derive(Resource, Default, Debug, Clone)]
pub struct VoxelSelectionState {
    pub selection: Option<VoxelRaySelection>,
}

/// One screen-center ray hit decomposed into the voxel cell that was hit
/// and its adjacent (placement) cell, both at macro and micro resolution.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoxelRaySelection {
    pub occupied_macro: MacroCoord,
    pub adjacent_macro: MacroCoord,
    pub face_normal: MacroCoord,
    pub occupied_micro: Option<MicroCellTarget>,
    pub adjacent_micro: Option<MicroCellTarget>,
}

// MicroCellTarget moved to crate::voxel::core::coord (re-exported below).

/// Per-cell render visual marker.
#[derive(Component, Copy, Clone, PartialEq, Eq, Hash)]
pub struct VoxelCellVisual {
    pub macro_coord: MacroCoord,
    pub micro: Option<MicroCoord>,
}

/// Marker for the screen-space target-point cube that visualises the
/// currently selected target point (Shift+RMB).
#[derive(Component)]
pub struct TargetPointMarker;

pub struct VoxelPlugin;

impl Plugin for VoxelPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<VoxelSelectionState>()
            // Always active in-game: the skill-target marker (live gameplay) and
            // the showcase cube sync (which self-cleans once in a live scene).
            .add_systems(
                Update,
                (update_target_point_marker, sync_voxel_visuals).run_if(in_state(AppState::Game)),
            )
            // The offline local `VoxelWorld` showcase guides + offline edit input
            // are only meaningful before joining a server scene. Once in a live
            // scene the server-authoritative `VoxelChunkRenderPlugin` owns the
            // voxels, so gate them off (they otherwise overlay a translucent
            // debug grid + selection box on the live view).
            .add_systems(
                Update,
                (update_voxel_selection, handle_voxel_input)
                    .chain()
                    .run_if(in_state(AppState::Game))
                    .run_if(offline_voxel_showcase_active),
            )
            .add_systems(
                Update,
                draw_voxel_guides
                    .run_if(in_state(AppState::Game))
                    .run_if(offline_voxel_showcase_active),
            )
            // Construction system (C1.4): in a live scene, building is
            // server-authoritative — raycast the authority chunks and send a
            // VoxelEditIntent; the resulting ChunkDelta renders the edit.
            .add_systems(
                Update,
                handle_live_voxel_build
                    .run_if(in_state(AppState::Game))
                    .run_if(live_voxel_build_active),
            );
    }
}

/// The offline `VoxelWorld` showcase renders only before a live scene is joined;
/// in a live scene the server-authoritative chunk renderer owns the voxels.
fn offline_voxel_showcase_active(world_state: Res<WorldState>) -> bool {
    !world_state.scene_joined
}

/// Live (server-authoritative) building is active once a scene is joined.
fn live_voxel_build_active(world_state: Res<WorldState>) -> bool {
    world_state.scene_joined
}

#[derive(SystemParam)]
struct VoxelInputParams<'w, 's> {
    mouse: Res<'w, ButtonInput<MouseButton>>,
    keyboard: Res<'w, ButtonInput<KeyCode>>,
    wheel_reader: MessageReader<'w, 's, MouseWheel>,
    chat_state: Res<'w, ChatState>,
    observer: Res<'w, ClientObserver>,
    selection_state: Res<'w, VoxelSelectionState>,
    voxel_world: ResMut<'w, VoxelWorld>,
    world_state: ResMut<'w, WorldState>,
}

fn update_voxel_selection(
    windows: Query<&Window, With<PrimaryWindow>>,
    camera: Single<(&Camera, &GlobalTransform), With<MainCamera>>,
    voxel_world: Res<VoxelWorld>,
    mut selection_state: ResMut<VoxelSelectionState>,
) {
    let Ok(window) = windows.single() else {
        selection_state.selection = None;
        return;
    };
    let center = Vec2::new(window.width() * 0.5, window.height() * 0.5);
    let (camera, camera_transform) = *camera;
    selection_state.selection = ray_from_viewport(camera, camera_transform, center)
        .and_then(|ray| find_voxel_selection_from_ray(&voxel_world, ray.origin, ray.direction));
}

fn handle_voxel_input(params: VoxelInputParams) {
    let VoxelInputParams {
        mouse,
        keyboard,
        mut wheel_reader,
        chat_state,
        observer,
        selection_state,
        mut voxel_world,
        mut world_state,
    } = params;

    if chat_state.enabled {
        return;
    }

    for (key, index) in [
        (KeyCode::Digit1, 0),
        (KeyCode::Digit2, 1),
        (KeyCode::Digit3, 2),
        (KeyCode::Digit4, 3),
        (KeyCode::Digit5, 4),
        (KeyCode::Digit6, 5),
        (KeyCode::Digit7, 6),
    ] {
        if keyboard.just_pressed(key) && voxel_world.select_hotbar_index(index).is_ok() {
            observer.emit(
                "voxel",
                "hotbar_select",
                &[
                    ("index", (index + 1).to_string()),
                    ("selected", voxel_world.hotbar().selected.label),
                    ("source", "keyboard".to_string()),
                ],
            );
        }
    }

    let wheel_delta = wheel_reader.read().map(|event| event.y).sum::<f32>();
    let control_zoom =
        keyboard.pressed(KeyCode::ControlLeft) || keyboard.pressed(KeyCode::ControlRight);
    if wheel_delta.abs() > f32::EPSILON && !control_zoom {
        let len = voxel_world.hotbar().entries.len();
        let current = voxel_world.hotbar().selected_index;
        let next = if wheel_delta < 0.0 {
            (current + 1) % len
        } else {
            (current + len - 1) % len
        };
        let _ = voxel_world.select_hotbar_index(next);
        observer.emit(
            "voxel",
            "hotbar_select",
            &[
                ("index", (next + 1).to_string()),
                ("selected", voxel_world.hotbar().selected.label),
                ("source", "wheel".to_string()),
            ],
        );
    }

    let place_requested = keyboard.just_pressed(KeyCode::KeyF)
        || (mouse.just_pressed(MouseButton::Right)
            && !keyboard.pressed(KeyCode::ShiftLeft)
            && !keyboard.pressed(KeyCode::ShiftRight));
    let break_requested =
        keyboard.just_pressed(KeyCode::KeyG) || mouse.just_pressed(MouseButton::Left);
    if !place_requested && !break_requested {
        return;
    }

    let Some(selection) = selection_state.selection.clone() else {
        observer.emit(
            "voxel",
            "edit_rejected",
            &[("reason", "no_selection".to_string())],
        );
        return;
    };

    if break_requested {
        let coord = selection.occupied_macro;
        let ok = voxel_world.break_block(coord);
        observer.emit(
            "voxel",
            if ok { "break" } else { "break_rejected" },
            &[
                ("coord", crate::voxel::format_macro_coord(coord)),
                (
                    "face_normal",
                    crate::voxel::format_macro_coord(selection.face_normal),
                ),
                ("source", "center_ray".to_string()),
            ],
        );
        push_line(
            &mut world_state.logs,
            format!(
                "voxel break {} ok={ok}",
                crate::voxel::format_macro_coord(coord)
            ),
        );
    }

    if place_requested {
        let selected = voxel_world.hotbar().selected;
        let coord = selection.adjacent_macro;
        let (ok, label, event) = if let Some(material) = selected.material_id {
            (
                voxel_world.place_block(coord, NormalBlockData::new(material)),
                material.label().to_string(),
                "place",
            )
        } else if let Some(prefab_name) = selected.prefab_name {
            // Prefab micro-snap (design 2026-04-26): pass the user's
            // adjacent_micro hit so the prefab is anchored at micro
            // precision (and can span macros). Falls back to the legacy
            // macro-aligned path when adjacent_micro is None.
            let request = BoundarySnapRequest {
                prefab_name: prefab_name.clone(),
                hit_macro: selection.occupied_macro,
                face_normal: selection.face_normal,
                rotation: selected.rotation,
                anchor_micro: selection.adjacent_micro,
            };
            let snap = voxel_world.place_prefab_boundary_snap(&request);
            let ok = if snap.ok {
                true
            } else {
                let reason = snap
                    .preview
                    .as_ref()
                    .and_then(|preview| preview.reject_reason.as_deref())
                    .unwrap_or("preview_unavailable");
                if should_fallback_to_macro_prefab_place(reason) {
                    voxel_world
                        .place_prefab(&prefab_name, coord, selected.rotation)
                        .ok
                } else {
                    false
                }
            };
            (ok, prefab_name, "prefab_place_snap")
        } else {
            (false, selected.label, "place")
        };
        observer.emit(
            "voxel",
            if ok { event } else { "place_rejected" },
            &[
                ("coord", crate::voxel::format_macro_coord(coord)),
                (
                    "hit_coord",
                    crate::voxel::format_macro_coord(selection.occupied_macro),
                ),
                (
                    "face_normal",
                    crate::voxel::format_macro_coord(selection.face_normal),
                ),
                ("selected", label.clone()),
                ("source", "center_ray".to_string()),
            ],
        );
        push_line(
            &mut world_state.logs,
            format!(
                "voxel place {} selected={} ok={ok}",
                crate::voxel::format_macro_coord(coord),
                label
            ),
        );
    }
}

#[derive(SystemParam)]
struct LiveBuildParams<'w, 's> {
    mouse: Res<'w, ButtonInput<MouseButton>>,
    keyboard: Res<'w, ButtonInput<KeyCode>>,
    wheel_reader: MessageReader<'w, 's, MouseWheel>,
    chat_state: Res<'w, ChatState>,
    observer: Res<'w, ClientObserver>,
    windows: Query<'w, 's, &'static Window, With<PrimaryWindow>>,
    camera: Query<'w, 's, (&'static Camera, &'static GlobalTransform), With<MainCamera>>,
    voxel_world: ResMut<'w, VoxelWorld>,
    authority: Res<'w, VoxelAuthority>,
    bridge: Option<Res<'w, NetworkBridge>>,
}

/// True if the global macro cell is occupied in the authority store (solid or
/// refined). Empty / unloaded → false.
fn authority_macro_occupied(authority: &VoxelAuthority, g: [i32; 3]) -> bool {
    let chunk_coord = [g[0].div_euclid(16), g[1].div_euclid(16), g[2].div_euclid(16)];
    let (lx, ly, lz) = (
        g[0].rem_euclid(16),
        g[1].rem_euclid(16),
        g[2].rem_euclid(16),
    );
    let idx = (lx + ly * 16 + lz * 256) as usize;
    authority
        .store
        .chunk(chunk_coord)
        .and_then(|chunk| chunk.cell(idx))
        .is_some_and(|cell| !matches!(cell, CellState::Empty))
}

/// Construction system live build: raycast the authority chunks from screen center
/// and send a server-authoritative `VoxelEditIntent` (place/break). No local
/// mutation — the returned `ChunkDelta` is what renders.
fn handle_live_voxel_build(params: LiveBuildParams) {
    let LiveBuildParams {
        mouse,
        keyboard,
        mut wheel_reader,
        chat_state,
        observer,
        windows,
        camera,
        mut voxel_world,
        authority,
        bridge,
    } = params;

    if chat_state.enabled {
        return;
    }

    // Hotbar selection works in live scenes too (shared material palette).
    for (key, index) in [
        (KeyCode::Digit1, 0),
        (KeyCode::Digit2, 1),
        (KeyCode::Digit3, 2),
        (KeyCode::Digit4, 3),
        (KeyCode::Digit5, 4),
        (KeyCode::Digit6, 5),
        (KeyCode::Digit7, 6),
    ] {
        if keyboard.just_pressed(key) {
            let _ = voxel_world.select_hotbar_index(index);
        }
    }
    let wheel_delta = wheel_reader.read().map(|event| event.y).sum::<f32>();
    let control_zoom =
        keyboard.pressed(KeyCode::ControlLeft) || keyboard.pressed(KeyCode::ControlRight);
    if wheel_delta.abs() > f32::EPSILON && !control_zoom {
        let len = voxel_world.hotbar().entries.len();
        let current = voxel_world.hotbar().selected_index;
        let next = if wheel_delta < 0.0 {
            (current + 1) % len
        } else {
            (current + len - 1) % len
        };
        let _ = voxel_world.select_hotbar_index(next);
    }

    let place_requested = keyboard.just_pressed(KeyCode::KeyF)
        || (mouse.just_pressed(MouseButton::Right)
            && !keyboard.pressed(KeyCode::ShiftLeft)
            && !keyboard.pressed(KeyCode::ShiftRight));
    let break_requested =
        keyboard.just_pressed(KeyCode::KeyG) || mouse.just_pressed(MouseButton::Left);
    if !place_requested && !break_requested {
        return;
    }

    let Some(bridge) = bridge else {
        return;
    };
    let Ok(window) = windows.single() else {
        return;
    };
    let Ok((cam, cam_tf)) = camera.single() else {
        return;
    };
    let center = Vec2::new(window.width() * 0.5, window.height() * 0.5);
    let Some(ray) = ray_from_viewport(cam, cam_tf, center) else {
        return;
    };

    let Some(pick) = pick_voxel(
        [ray.origin.x, ray.origin.y, ray.origin.z],
        [ray.direction.x, ray.direction.y, ray.direction.z],
        VOXEL_RAY_MAX_DISTANCE,
        |g| authority_macro_occupied(&authority, g),
    ) else {
        observer.emit(
            "voxel",
            "live_edit_rejected",
            &[("reason", "no_target".to_string())],
        );
        return;
    };

    if break_requested {
        bridge.send(NetworkCommand::EditVoxel {
            logical_scene_id: VOXEL_LOGICAL_SCENE_ID,
            action: ACTION_BREAK,
            target_macro: pick.occupied_macro,
            material_id: 0,
        });
        observer.emit(
            "voxel",
            "live_break_sent",
            &[("coord", format!("{:?}", pick.occupied_macro))],
        );
    }

    if place_requested {
        let selected = voxel_world.hotbar().selected;
        match selected.material_id {
            Some(material) => {
                let target = pick.adjacent_macro();
                bridge.send(NetworkCommand::EditVoxel {
                    logical_scene_id: VOXEL_LOGICAL_SCENE_ID,
                    action: ACTION_PLACE,
                    target_macro: target,
                    material_id: material as u16,
                });
                observer.emit(
                    "voxel",
                    "live_place_sent",
                    &[
                        ("coord", format!("{target:?}")),
                        ("material", material.label().to_string()),
                    ],
                );
            }
            None => {
                // Prefab placement over the network is C5; macro materials only here.
                observer.emit(
                    "voxel",
                    "live_place_rejected",
                    &[("reason", "prefab_not_wired".to_string())],
                );
            }
        }
    }
}

fn sync_voxel_visuals(
    mut commands: Commands,
    world_state: Res<WorldState>,
    voxel_world: Res<VoxelWorld>,
    assets: Res<SceneRenderAssets>,
    mut existing: Query<(
        Entity,
        &VoxelCellVisual,
        &mut Transform,
        &mut MeshMaterial3d<StandardMaterial>,
    )>,
) {
    // In a live scene the server-authoritative chunk renderer owns the voxels;
    // despawn any offline showcase cubes spawned before joining and stop.
    if world_state.scene_joined {
        for (entity, _, _, _) in &existing {
            commands.entity(entity).despawn();
        }
        return;
    }

    let desired = voxel_world
        .render_cells_3d()
        .into_iter()
        .map(|cell| ((cell.macro_coord, cell.micro), cell))
        .collect::<HashMap<_, _>>();

    let mut remaining = desired.clone();
    for (entity, visual, mut transform, mut material) in &mut existing {
        let key = (visual.macro_coord, visual.micro);
        if let Some(cell) = desired.get(&key) {
            transform.translation = voxel_render_translation(*cell);
            transform.scale = voxel_render_scale(*cell);
            *material = MeshMaterial3d(voxel_material_handle(&assets, cell.material_id));
            remaining.remove(&key);
        } else {
            commands.entity(entity).despawn();
        }
    }

    for cell in remaining.values().copied() {
        commands.spawn((
            VoxelCellVisual {
                macro_coord: cell.macro_coord,
                micro: cell.micro,
            },
            Mesh3d(assets.cube_mesh.clone()),
            MeshMaterial3d(voxel_material_handle(&assets, cell.material_id)),
            Transform::from_translation(voxel_render_translation(cell))
                .with_scale(voxel_render_scale(cell)),
        ));
    }
}

fn update_target_point_marker(
    world_state: Res<WorldState>,
    mut marker: Single<(&mut Transform, &mut Visibility), With<TargetPointMarker>>,
) {
    if let Some(point) = world_state.selected_target_point {
        *marker.1 = Visibility::Visible;
        marker.0.translation = sim_to_render_position(point) + Vec3::Y * 6.0;
    } else {
        *marker.1 = Visibility::Hidden;
    }
}

fn draw_voxel_guides(
    voxel_world: Res<VoxelWorld>,
    selection_state: Res<VoxelSelectionState>,
    mut gizmos: Gizmos,
) {
    let grid_extent = VOXEL_RENDER_CELL_SIZE * 24.0;
    let grid_color = Color::srgba(0.32, 0.38, 0.44, 0.36);
    for index in -12..=12 {
        let offset = index as f32 * VOXEL_RENDER_CELL_SIZE;
        gizmos.line(
            Vec3::new(-grid_extent, 0.0, offset),
            Vec3::new(grid_extent, 0.0, offset),
            grid_color,
        );
        gizmos.line(
            Vec3::new(offset, 0.0, -grid_extent),
            Vec3::new(offset, 0.0, grid_extent),
            grid_color,
        );
    }

    let Some(selection) = selection_state.selection.as_ref() else {
        return;
    };

    let (hit_min, hit_max) = selection_bounds(selection);
    draw_face_outline(
        &mut gizmos,
        hit_min,
        hit_max,
        selection.face_normal,
        Color::srgb(1.0, 0.95, 0.35),
    );

    let selected = voxel_world.hotbar().selected;
    if selected.material_id.is_some() {
        let (min, max) = macro_bounds(selection.adjacent_macro);
        draw_box_wire(&mut gizmos, min, max, Color::srgba(0.35, 1.0, 0.55, 0.72));
        return;
    }

    if let Some(prefab_name) = selected.prefab_name {
        let request = BoundarySnapRequest {
            prefab_name,
            hit_macro: selection.occupied_macro,
            face_normal: selection.face_normal,
            rotation: selected.rotation,
            anchor_micro: selection.adjacent_micro,
        };
        let preview = voxel_world.preview_prefab_boundary_snap(&request);
        if preview.ok {
            draw_prefab_preview(&mut gizmos, &preview, Color::srgba(0.45, 0.9, 1.0, 0.7));
        } else if preview
            .reject_reason
            .as_deref()
            .is_some_and(should_fallback_to_macro_prefab_place)
        {
            let (min, max) = macro_bounds(selection.adjacent_macro);
            draw_box_wire(&mut gizmos, min, max, Color::srgba(0.45, 0.9, 1.0, 0.5));
        }
    }
}

pub(crate) fn surface_center_y_at_render_xz(
    voxel_world: &VoxelWorld,
    render_x: f32,
    render_z: f32,
    half_height: f32,
    fallback_y: f32,
) -> f32 {
    let mut top_y = None::<f32>;
    for cell in voxel_world.render_cells_3d() {
        let (min, max) = voxel_cell_bounds(cell);
        if render_x >= min.x && render_x <= max.x && render_z >= min.z && render_z <= max.z {
            top_y = Some(top_y.map_or(max.y, |current| current.max(max.y)));
        }
    }
    top_y
        .map(|top| top + half_height)
        .unwrap_or(fallback_y)
        .max(fallback_y)
}

/// Audit C-M1: returns the distance from `origin` along `direction`
/// (must be a unit vector) to the nearest voxel hit, or `None` if no
/// voxel intersects within `max_distance`. Used by the camera follow
/// logic to clamp the orbit distance against terrain so the third-person
/// camera never clips inside a wall / hill.
pub(crate) fn voxel_ray_first_hit_distance(
    voxel_world: &VoxelWorld,
    origin: Vec3,
    direction: Vec3,
    max_distance: f32,
) -> Option<f32> {
    let direction = direction.try_normalize()?;
    let mut nearest: Option<f32> = None;
    for cell in voxel_world.render_cells_3d() {
        let (min, max) = voxel_cell_bounds(cell);
        if let Some((distance, _normal)) =
            ray_intersect_aabb(origin, direction, min, max, max_distance)
            && nearest.as_ref().is_none_or(|best| distance < *best)
        {
            nearest = Some(distance);
        }
    }
    nearest
}

pub(crate) fn find_voxel_selection_from_ray(
    voxel_world: &VoxelWorld,
    origin: Vec3,
    direction: Vec3,
) -> Option<VoxelRaySelection> {
    let direction = direction.try_normalize()?;
    let mut best = None::<(f32, VoxelRenderCell, MacroCoord, Vec3)>;

    for cell in voxel_world.render_cells_3d() {
        let (min, max) = voxel_cell_bounds(cell);
        if let Some((distance, face_normal)) =
            ray_intersect_aabb(origin, direction, min, max, VOXEL_RAY_MAX_DISTANCE)
            && best
                .as_ref()
                .is_none_or(|(best_distance, _, _, _)| distance < *best_distance)
        {
            best = Some((distance, cell, face_normal, origin + direction * distance));
        }
    }

    let (_distance, cell, face_normal, hit_point) = best?;
    let adjacent_macro = MacroCoord::new(
        cell.macro_coord.x + face_normal.x,
        cell.macro_coord.y + face_normal.y,
        cell.macro_coord.z + face_normal.z,
    );
    let occupied_micro = match cell.micro {
        Some(micro) => Some(MicroCellTarget {
            macro_coord: cell.macro_coord,
            micro,
        }),
        None => micro_target_from_render_point(hit_point - macro_coord_to_vec3(face_normal) * 0.01),
    };
    let adjacent_micro =
        micro_target_from_render_point(hit_point + macro_coord_to_vec3(face_normal) * 0.01);

    Some(VoxelRaySelection {
        occupied_macro: cell.macro_coord,
        adjacent_macro,
        face_normal,
        occupied_micro,
        adjacent_micro,
    })
}

fn ray_intersect_aabb(
    origin: Vec3,
    direction: Vec3,
    min: Vec3,
    max: Vec3,
    max_distance: f32,
) -> Option<(f32, MacroCoord)> {
    let mut t_min = 0.0_f32;
    let mut t_max = max_distance;
    let mut normal = MacroCoord::new(0, 0, 0);

    for axis in 0..3 {
        let origin_axis = origin[axis];
        let direction_axis = direction[axis];
        let min_axis = min[axis];
        let max_axis = max[axis];

        if direction_axis.abs() <= f32::EPSILON {
            if origin_axis < min_axis || origin_axis > max_axis {
                return None;
            }
            continue;
        }

        let (near_plane, far_plane, near_normal, _far_normal) = if direction_axis > 0.0 {
            (
                min_axis,
                max_axis,
                negative_axis_normal(axis),
                positive_axis_normal(axis),
            )
        } else {
            (
                max_axis,
                min_axis,
                positive_axis_normal(axis),
                negative_axis_normal(axis),
            )
        };
        let t_near = (near_plane - origin_axis) / direction_axis;
        let t_far = (far_plane - origin_axis) / direction_axis;

        if t_near > t_min {
            t_min = t_near;
            normal = near_normal;
        }
        t_max = t_max.min(t_far);
        if t_min > t_max {
            return None;
        }
    }

    (t_min >= 0.0 && t_min <= max_distance).then_some((t_min, normal))
}

fn positive_axis_normal(axis: usize) -> MacroCoord {
    match axis {
        0 => MacroCoord::new(1, 0, 0),
        1 => MacroCoord::new(0, 1, 0),
        _ => MacroCoord::new(0, 0, 1),
    }
}

fn negative_axis_normal(axis: usize) -> MacroCoord {
    match axis {
        0 => MacroCoord::new(-1, 0, 0),
        1 => MacroCoord::new(0, -1, 0),
        _ => MacroCoord::new(0, 0, -1),
    }
}

fn macro_coord_to_vec3(coord: MacroCoord) -> Vec3 {
    Vec3::new(coord.x as f32, coord.y as f32, coord.z as f32)
}

pub(crate) fn voxel_cell_bounds(cell: VoxelRenderCell) -> (Vec3, Vec3) {
    if let Some(micro) = cell.micro {
        micro_bounds(MicroCellTarget {
            macro_coord: cell.macro_coord,
            micro,
        })
    } else {
        macro_bounds(cell.macro_coord)
    }
}

fn macro_bounds(coord: MacroCoord) -> (Vec3, Vec3) {
    let min = Vec3::new(
        coord.x as f32 * VOXEL_RENDER_CELL_SIZE,
        coord.y as f32 * VOXEL_RENDER_CELL_SIZE,
        coord.z as f32 * VOXEL_RENDER_CELL_SIZE,
    );
    (min, min + Vec3::splat(VOXEL_RENDER_CELL_SIZE))
}

fn micro_bounds(target: MicroCellTarget) -> (Vec3, Vec3) {
    let min = Vec3::new(
        target.macro_coord.x as f32 * VOXEL_RENDER_CELL_SIZE
            + target.micro.x as f32 * VOXEL_RENDER_MICRO_SIZE,
        target.macro_coord.y as f32 * VOXEL_RENDER_CELL_SIZE
            + target.micro.y as f32 * VOXEL_RENDER_MICRO_SIZE,
        target.macro_coord.z as f32 * VOXEL_RENDER_CELL_SIZE
            + target.micro.z as f32 * VOXEL_RENDER_MICRO_SIZE,
    );
    (min, min + Vec3::splat(VOXEL_RENDER_MICRO_SIZE))
}

fn micro_target_from_render_point(point: Vec3) -> Option<MicroCellTarget> {
    let macro_coord = MacroCoord::new(
        (point.x / VOXEL_RENDER_CELL_SIZE).floor() as i32,
        (point.y / VOXEL_RENDER_CELL_SIZE).floor() as i32,
        (point.z / VOXEL_RENDER_CELL_SIZE).floor() as i32,
    );
    let macro_min = Vec3::new(
        macro_coord.x as f32 * VOXEL_RENDER_CELL_SIZE,
        macro_coord.y as f32 * VOXEL_RENDER_CELL_SIZE,
        macro_coord.z as f32 * VOXEL_RENDER_CELL_SIZE,
    );
    let local = point - macro_min;
    let micro = MicroCoord::new(
        (local.x / VOXEL_RENDER_MICRO_SIZE)
            .floor()
            .clamp(0.0, (crate::voxel::MICRO_PER_MACRO - 1) as f32) as i32,
        (local.y / VOXEL_RENDER_MICRO_SIZE)
            .floor()
            .clamp(0.0, (crate::voxel::MICRO_PER_MACRO - 1) as f32) as i32,
        (local.z / VOXEL_RENDER_MICRO_SIZE)
            .floor()
            .clamp(0.0, (crate::voxel::MICRO_PER_MACRO - 1) as f32) as i32,
    );
    Some(MicroCellTarget { macro_coord, micro })
}

fn selection_bounds(selection: &VoxelRaySelection) -> (Vec3, Vec3) {
    selection
        .occupied_micro
        .map(micro_bounds)
        .unwrap_or_else(|| macro_bounds(selection.occupied_macro))
}

fn draw_prefab_preview(gizmos: &mut Gizmos, preview: &BoundarySnapPreview, color: Color) {
    for cell in &preview.cells {
        for x in 0..crate::voxel::MICRO_PER_MACRO {
            for y in 0..crate::voxel::MICRO_PER_MACRO {
                for z in 0..crate::voxel::MICRO_PER_MACRO {
                    let micro = MicroCoord::new(x, y, z);
                    if cell.data.micro_occupancy_mask.contains(micro) {
                        let (min, max) = micro_bounds(MicroCellTarget {
                            macro_coord: cell.macro_coord,
                            micro,
                        });
                        draw_box_wire(gizmos, min, max, color);
                    }
                }
            }
        }
    }
}

fn draw_face_outline(gizmos: &mut Gizmos, min: Vec3, max: Vec3, normal: MacroCoord, color: Color) {
    let corners = if normal.x != 0 {
        let x = if normal.x > 0 { max.x } else { min.x };
        [
            Vec3::new(x, min.y, min.z),
            Vec3::new(x, max.y, min.z),
            Vec3::new(x, max.y, max.z),
            Vec3::new(x, min.y, max.z),
        ]
    } else if normal.y != 0 {
        let y = if normal.y > 0 { max.y } else { min.y };
        [
            Vec3::new(min.x, y, min.z),
            Vec3::new(max.x, y, min.z),
            Vec3::new(max.x, y, max.z),
            Vec3::new(min.x, y, max.z),
        ]
    } else {
        let z = if normal.z > 0 { max.z } else { min.z };
        [
            Vec3::new(min.x, min.y, z),
            Vec3::new(max.x, min.y, z),
            Vec3::new(max.x, max.y, z),
            Vec3::new(min.x, max.y, z),
        ]
    };
    for index in 0..4 {
        gizmos.line(corners[index], corners[(index + 1) % 4], color);
    }
}

fn draw_box_wire(gizmos: &mut Gizmos, min: Vec3, max: Vec3, color: Color) {
    let corners = [
        Vec3::new(min.x, min.y, min.z),
        Vec3::new(max.x, min.y, min.z),
        Vec3::new(max.x, max.y, min.z),
        Vec3::new(min.x, max.y, min.z),
        Vec3::new(min.x, min.y, max.z),
        Vec3::new(max.x, min.y, max.z),
        Vec3::new(max.x, max.y, max.z),
        Vec3::new(min.x, max.y, max.z),
    ];
    for (a, b) in [
        (0, 1),
        (1, 2),
        (2, 3),
        (3, 0),
        (4, 5),
        (5, 6),
        (6, 7),
        (7, 4),
        (0, 4),
        (1, 5),
        (2, 6),
        (3, 7),
    ] {
        gizmos.line(corners[a], corners[b], color);
    }
}

fn voxel_render_translation(cell: VoxelRenderCell) -> Vec3 {
    let mut x = cell.macro_coord.x as f32 * VOXEL_RENDER_CELL_SIZE + VOXEL_RENDER_CELL_SIZE * 0.5;
    let mut y = cell.macro_coord.y as f32 * VOXEL_RENDER_CELL_SIZE + VOXEL_RENDER_CELL_SIZE * 0.5;
    let mut z = cell.macro_coord.z as f32 * VOXEL_RENDER_CELL_SIZE + VOXEL_RENDER_CELL_SIZE * 0.5;
    if let Some(micro) = cell.micro {
        x = cell.macro_coord.x as f32 * VOXEL_RENDER_CELL_SIZE
            + (micro.x as f32 + 0.5) * VOXEL_RENDER_MICRO_SIZE;
        y = cell.macro_coord.y as f32 * VOXEL_RENDER_CELL_SIZE
            + (micro.y as f32 + 0.5) * VOXEL_RENDER_MICRO_SIZE;
        z = cell.macro_coord.z as f32 * VOXEL_RENDER_CELL_SIZE
            + (micro.z as f32 + 0.5) * VOXEL_RENDER_MICRO_SIZE;
    }
    Vec3::new(x, y, z)
}

fn voxel_render_scale(cell: VoxelRenderCell) -> Vec3 {
    // GUI-smoke 2026-04-26 follow-up: previously each cube was rendered
    // at 95-96% of its cell size, leaving a visible 4-5% gap on every
    // edge. Used to be a debug aid for cube-boundary visibility but it
    // looks like seam noise to a user expecting a solid voxel surface.
    // Render at full size so adjacent cubes tile without gaps.
    let size = if cell.refined {
        VOXEL_RENDER_MICRO_SIZE
    } else {
        VOXEL_RENDER_CELL_SIZE
    };
    Vec3::splat(size)
}

pub(crate) fn voxel_material_color(material_id: VoxelMaterialId) -> Color {
    // Refined micro cells share the same opaque colour as their macro
    // parents — the previous half-transparent tint produced severe
    // depth-sort flicker because hundreds of `AlphaMode::Blend` cubes
    // overlap inside one prefab. The web client (`chunkRenderer.ts`)
    // also uses opaque `MeshStandardMaterial` for everything.
    match material_id {
        VoxelMaterialId::Dirt => Color::srgb(0.45, 0.34, 0.22),
        VoxelMaterialId::Stone => Color::srgb(0.48, 0.52, 0.56),
        VoxelMaterialId::Wood => Color::srgb(0.64, 0.42, 0.22),
        VoxelMaterialId::Ice => Color::srgb(0.52, 0.82, 0.95),
    }
}

fn voxel_material_handle(
    assets: &SceneRenderAssets,
    material_id: VoxelMaterialId,
) -> Handle<StandardMaterial> {
    // Both macro blocks and refined micro cells use the same opaque
    // material per material id. Two parallel handles existed historically
    // (with the refined variant configured `AlphaMode::Blend`) but that
    // produced flicker (see `voxel_material_color` doc-comment).
    match material_id {
        VoxelMaterialId::Dirt => assets.dirt_material.clone(),
        VoxelMaterialId::Stone => assets.stone_material.clone(),
        VoxelMaterialId::Wood => assets.wood_material.clone(),
        VoxelMaterialId::Ice => assets.ice_material.clone(),
    }
}

fn should_fallback_to_macro_prefab_place(reason: &str) -> bool {
    matches!(reason, "no_target_boundary" | "no_contact" | "empty_prefab")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::{NormalBlockData, VoxelMaterialId};

    #[test]
    fn voxel_3d_ray_selects_hit_face_and_adjacent_macro() {
        let mut world = VoxelWorld::new();
        world.place_block(
            MacroCoord::new(0, 0, 0),
            NormalBlockData::new(VoxelMaterialId::Dirt),
        );

        let selection = find_voxel_selection_from_ray(
            &world,
            Vec3::new(50.0, 260.0, 50.0),
            Vec3::new(0.0, -1.0, 0.0),
        )
        .expect("top face hit");

        assert_eq!(selection.occupied_macro, MacroCoord::new(0, 0, 0));
        assert_eq!(selection.face_normal, MacroCoord::new(0, 1, 0));
        assert_eq!(selection.adjacent_macro, MacroCoord::new(0, 1, 0));
        assert_eq!(selection.occupied_micro.unwrap().micro.y, 7);
        assert_eq!(
            selection.adjacent_micro.unwrap().macro_coord,
            MacroCoord::new(0, 1, 0)
        );
    }
}
