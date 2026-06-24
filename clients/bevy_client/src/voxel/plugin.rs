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
use bevy::gizmos::config::{GizmoConfigGroup, GizmoConfigStore};
use bevy::input::mouse::MouseWheel;
use bevy::prelude::*;
use bevy::window::PrimaryWindow;

use crate::app::{
    SceneRenderAssets, WorldState, push_line, ray_from_viewport, sim_to_render_position,
};
use crate::camera::{MainCamera, OrbitCameraState};
use crate::chat::ChatState;
use crate::login::AppState;
use crate::net::{NetworkBridge, NetworkCommand};
use crate::observe::ClientObserver;
use crate::voxel::authority::CellState;
use crate::voxel::authority_plugin::{VOXEL_LOGICAL_SCENE_ID, VoxelAuthority};
use crate::voxel::live_pick::pick_voxel;
use crate::voxel::wire::ACTION_BREAK;
use crate::voxel::{
    BoundarySnapPreview, BoundarySnapRequest, MacroCoord, MicroCellTarget, MicroCoord,
    NormalBlockData, VoxelMaterialId, VoxelRenderCell, VoxelWorld,
};

const VOXEL_RENDER_CELL_SIZE: f32 = 100.0;
const VOXEL_RENDER_MICRO_SIZE: f32 = VOXEL_RENDER_CELL_SIZE / crate::voxel::MICRO_PER_MACRO as f32;
const VOXEL_RAY_MAX_DISTANCE: f32 = 2_500.0;
/// Build/break **reach**: max render-space distance from the player to a hittable
/// voxel. Measured from the camera's orbit target (= the player's render position)
/// so it is independent of third-person zoom — unlike the raw camera-ray cap
/// `VOXEL_RAY_MAX_DISTANCE`, which only bounds the DDA march. One macro cell is
/// `VOXEL_RENDER_CELL_SIZE` (100) units, so this is ~7 cells of reach.
const VOXEL_REACH: f32 = 1_200.0;

/// The voxel currently under the crosshair in a live scene (server-authoritative
/// occupancy), within [`VOXEL_REACH`]. Shared truth for the hit-face highlight
/// gizmo (`draw_live_hit`) and the place/break action (`handle_live_voxel_build`),
/// so the box you see highlighted is exactly the cell an edit targets.
#[derive(Resource, Default)]
pub(crate) struct LiveHit {
    pub pick: Option<crate::voxel::live_pick::LivePick>,
}

/// Dedicated gizmo group for the build-target highlight. Configured with a
/// negative `depth_bias` (see `setup_hit_gizmos`) so the wire box renders ON TOP
/// of the solid terrain instead of being occluded by the very block it outlines.
#[derive(Default, Reflect, GizmoConfigGroup)]
struct HitGizmos {}
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
            .init_resource::<crate::voxel::build_palette::BuildPalette>()
            .init_resource::<LiveHit>()
            .init_gizmo_group::<HitGizmos>()
            .add_systems(Startup, setup_hit_gizmos)
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
            // server-authoritative — `update_live_hit` raycasts the authority
            // chunks each frame into `LiveHit`; `draw_live_hit` outlines the
            // targeted cell + face; `handle_live_voxel_build` reads the SAME hit
            // and sends a VoxelEditIntent on click. Chained so the highlight and
            // the edit always agree on the target.
            .add_systems(
                Update,
                (update_live_hit, draw_live_hit, handle_live_voxel_build)
                    .chain()
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
    palette: ResMut<'w, crate::voxel::build_palette::BuildPalette>,
    // The crosshair hit (shared with the highlight gizmo) — what a place/break
    // targets. Computed by `update_live_hit` which runs first in the chain.
    hit: Res<'w, LiveHit>,
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

/// Each frame in a live scene: DDA-raymarch the centre-crosshair ray against the
/// server-authoritative chunk occupancy, then keep the hit only if its cell sits
/// within [`VOXEL_REACH`] of the player (the camera's orbit target). Result goes
/// into [`LiveHit`] for the highlight gizmo and the place/break action to share.
fn update_live_hit(
    windows: Query<&Window, With<PrimaryWindow>>,
    camera: Query<(&Camera, &GlobalTransform), With<MainCamera>>,
    orbit: Res<OrbitCameraState>,
    authority: Res<VoxelAuthority>,
    mut hit: ResMut<LiveHit>,
) {
    hit.pick = compute_live_hit(&windows, &camera, &orbit, &authority);
}

fn compute_live_hit(
    windows: &Query<&Window, With<PrimaryWindow>>,
    camera: &Query<(&Camera, &GlobalTransform), With<MainCamera>>,
    orbit: &OrbitCameraState,
    authority: &VoxelAuthority,
) -> Option<crate::voxel::live_pick::LivePick> {
    let window = windows.single().ok()?;
    let (cam, cam_tf) = camera.single().ok()?;
    let center = Vec2::new(window.width() * 0.5, window.height() * 0.5);
    let ray = ray_from_viewport(cam, cam_tf, center)?;
    let pick = pick_voxel(
        [ray.origin.x, ray.origin.y, ray.origin.z],
        [ray.direction.x, ray.direction.y, ray.direction.z],
        VOXEL_RAY_MAX_DISTANCE,
        |g| authority_macro_occupied(authority, g),
    )?;
    // Reach gate: distance from the player (orbit target) to the cell centre.
    let coord = MacroCoord::new(
        pick.occupied_macro[0],
        pick.occupied_macro[1],
        pick.occupied_macro[2],
    );
    let (min, max) = macro_bounds(coord);
    let cell_center = (min + max) * 0.5;
    (cell_center.distance(orbit.target) <= VOXEL_REACH).then_some(pick)
}

/// `depth_bias = -1.0` forces the [`HitGizmos`] group to draw in front of all
/// geometry, so the build-target outline is visible on the block it highlights
/// rather than being occluded by it (and its solid neighbours).
fn setup_hit_gizmos(mut store: ResMut<GizmoConfigStore>) {
    store.config_mut::<HitGizmos>().0.depth_bias = -1.0;
}

/// Outlines the cell under the crosshair (cyan wire box) and the face the ray
/// entered through (bright white) so the player sees exactly what a place/break
/// targets. Drawn only when a valid in-reach hit exists.
fn draw_live_hit(hit: Res<LiveHit>, mut gizmos: Gizmos<HitGizmos>) {
    let Some(pick) = hit.pick else {
        return;
    };
    let coord = MacroCoord::new(
        pick.occupied_macro[0],
        pick.occupied_macro[1],
        pick.occupied_macro[2],
    );
    let (min, max) = macro_bounds(coord);
    draw_box_wire(&mut gizmos, min, max, Color::srgba(0.15, 0.85, 1.0, 0.9));
    let normal = MacroCoord::new(pick.face_normal[0], pick.face_normal[1], pick.face_normal[2]);
    draw_face_outline(&mut gizmos, min, max, normal, Color::WHITE);
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
        mut palette,
        hit,
        bridge,
    } = params;

    if chat_state.enabled {
        return;
    }

    // Build palette selection (construction system): digit keys 1-9 pick a slot,
    // wheel cycles the full fixed component list.
    for (key, index) in [
        (KeyCode::Digit1, 0),
        (KeyCode::Digit2, 1),
        (KeyCode::Digit3, 2),
        (KeyCode::Digit4, 3),
        (KeyCode::Digit5, 4),
        (KeyCode::Digit6, 5),
        (KeyCode::Digit7, 6),
        (KeyCode::Digit8, 7),
        (KeyCode::Digit9, 8),
    ] {
        if keyboard.just_pressed(key) && palette.select(index) {
            observer.emit(
                "voxel",
                "build_palette_select",
                &[("selected", palette.selected().label.to_string())],
            );
        }
    }
    let wheel_delta = wheel_reader.read().map(|event| event.y).sum::<f32>();
    let control_zoom =
        keyboard.pressed(KeyCode::ControlLeft) || keyboard.pressed(KeyCode::ControlRight);
    if wheel_delta.abs() > f32::EPSILON && !control_zoom {
        palette.cycle(if wheel_delta < 0.0 { 1 } else { -1 });
        observer.emit(
            "voxel",
            "build_palette_select",
            &[("selected", palette.selected().label.to_string())],
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

    let Some(bridge) = bridge else {
        return;
    };

    // Reads the same hit the highlight gizmo drew (computed by `update_live_hit`,
    // already reach-gated) — so an edit only lands on the cell you can see boxed.
    let Some(pick) = hit.pick else {
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
        // C5.1:一套调色板跨三种放置路径 —— block / prefab / 贴面元件,选中项决定发哪种 intent。
        let selected = palette.selected();
        let command = crate::voxel::build_palette::build_place_command(selected.kind, &pick);
        let placed_at = match &command {
            NetworkCommand::PlaceSurfaceElement { host_macro, face, .. } => {
                format!("host={host_macro:?} face={face}")
            }
            NetworkCommand::PlacePrefab { anchor_macro, .. } => format!("anchor={anchor_macro:?}"),
            NetworkCommand::EditVoxel { target_macro, .. } => format!("{target_macro:?}"),
            _ => String::new(),
        };
        bridge.send(command);
        observer.emit(
            "voxel",
            "live_place_sent",
            &[
                ("coord", placed_at),
                ("component", selected.label.to_string()),
            ],
        );
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
    authority: &VoxelAuthority,
    scene_joined: bool,
    render_x: f32,
    render_z: f32,
    half_height: f32,
    fallback_y: f32,
) -> f32 {
    let mut top_y = None::<f32>;
    // Offline showcase geometry: only meaningful PRE-join. Once joined, the
    // server-authoritative store is the sole truth — the showcase is despawned
    // visually but its `VoxelWorld.cells` linger (never cleared), so reading it
    // in a live scene would ground the avatar onto an invisible origin plane.
    // Skip it when joined (the audit's phantom-floor finding).
    if !scene_joined {
        for cell in voxel_world.render_cells_3d() {
            let (min, max) = voxel_cell_bounds(cell);
            if render_x >= min.x && render_x <= max.x && render_z >= min.z && render_z <= max.z {
                top_y = Some(top_y.map_or(max.y, |current| current.max(max.y)));
            }
        }
    }
    // Live scene: ground against the server-authoritative chunk terrain. The
    // offline VoxelWorld holds no live terrain, so without this the avatar floats
    // at the raw spawn height, which on the noise terrain is *below* the surface
    // (the reported "character is below the world"). Macro coords map directly to
    // render space (macro Y = up), matching `macro_bounds`.
    let mx = (render_x / VOXEL_RENDER_CELL_SIZE).floor() as i32;
    let mz = (render_z / VOXEL_RENDER_CELL_SIZE).floor() as i32;
    if let Some(macro_y) = authority.store.column_top_macro_y(mx, mz) {
        let authority_top = (macro_y + 1) as f32 * VOXEL_RENDER_CELL_SIZE;
        top_y = Some(top_y.map_or(authority_top, |current| current.max(authority_top)));
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
///
/// In a live scene the terrain is the server-authoritative chunk store, NOT the
/// offline `VoxelWorld` (which holds only the stale pre-join showcase). Reading
/// the offline store while joined both missed every real hill AND clamped the
/// camera against an invisible origin plane (audit). So when `scene_joined` we
/// march the authority macro grid (cheap macro-DDA, ≤ `max_distance/100` steps,
/// reusing the build raycast); pre-join we AABB-test the offline showcase.
pub(crate) fn voxel_ray_first_hit_distance(
    voxel_world: &VoxelWorld,
    authority: &VoxelAuthority,
    scene_joined: bool,
    origin: Vec3,
    direction: Vec3,
    max_distance: f32,
) -> Option<f32> {
    let direction = direction.try_normalize()?;
    if scene_joined {
        // Live terrain: DDA over authority macro cells; the hit macro's near-face
        // entry distance (via its render AABB) is what the camera clamps to.
        let pick = pick_voxel(
            [origin.x, origin.y, origin.z],
            [direction.x, direction.y, direction.z],
            max_distance,
            |g| authority_macro_occupied(authority, g),
        )?;
        let m = pick.occupied_macro;
        let (min, max) = macro_bounds(MacroCoord::new(m[0], m[1], m[2]));
        return ray_intersect_aabb(origin, direction, min, max, max_distance).map(|(d, _)| d);
    }
    // Pre-join showcase: AABB-test the offline VoxelWorld cells.
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

fn draw_face_outline<C: GizmoConfigGroup>(
    gizmos: &mut Gizmos<C>,
    min: Vec3,
    max: Vec3,
    normal: MacroCoord,
    color: Color,
) {
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

fn draw_box_wire<C: GizmoConfigGroup>(gizmos: &mut Gizmos<C>, min: Vec3, max: Vec3, color: Color) {
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

    // Regression for the "character is below the world" bug: in a live scene the
    // offline VoxelWorld is empty, so grounding MUST consult the authority chunk
    // store, else the avatar floats at the raw spawn height (185), which is below
    // the noise terrain (top render Y ≥ 200). Mirrors the runtime observer proof
    // (185 → terrain_top+half).
    #[test]
    fn surface_center_grounds_onto_authority_terrain_not_raw_spawn() {
        use crate::voxel::authority::{AuthorityChunk, CellState};
        use crate::voxel::authority_plugin::VoxelAuthority;
        use crate::voxel::wire::NormalBlock;

        // Build a chunk (0,0,0) with a 4-high solid stack at local column (7,7) —
        // i.e. the render XZ (750,750) spawn column. Top occupied macro Y = 3 →
        // top render Y = 4*100 = 400.
        let solid = NormalBlock {
            material_id: 2,
            state_flags: 0,
            health: 100,
            temperature_delta: 0,
            moisture_delta: 0,
            attribute_set_ref: 0,
            tag_set_ref: 0,
        };
        let mut cells = vec![CellState::Empty; 16 * 16 * 16];
        for ly in 0..4 {
            cells[(7 + ly * 16 + 7 * 256) as usize] = CellState::Solid(solid.clone());
        }
        let chunk = AuthorityChunk {
            chunk_version: 1,
            chunk_size_in_macro: 16,
            cells,
            surface_elements: Vec::new(),
        };
        let mut authority = VoxelAuthority::default();
        authority.store.insert_chunk_for_test([0, 0, 0], chunk);

        let empty_world = VoxelWorld::new();
        let half_height = 45.0;
        let raw_spawn_y = 185.0;

        // At the spawn column the avatar grounds onto the terrain top (400) + half
        // (45) = 445, NOT the buggy raw spawn 185. scene_joined = true (live).
        let grounded = surface_center_y_at_render_xz(
            &empty_world,
            &authority,
            true,
            750.0,
            750.0,
            half_height,
            raw_spawn_y,
        );
        assert_eq!(grounded, 445.0, "must stand on terrain, not underground");

        // An empty column (no terrain loaded there) → falls back to spawn height.
        let no_terrain = surface_center_y_at_render_xz(
            &empty_world,
            &authority,
            true,
            50.0,
            50.0,
            half_height,
            raw_spawn_y,
        );
        assert_eq!(no_terrain, raw_spawn_y);
    }

    // Regression: in a live scene the third-person camera collision must clamp
    // against the AUTHORITY terrain, not the (empty) offline VoxelWorld — else it
    // clips through every real hill. Mirrors the grounding fix.
    #[test]
    fn camera_collision_hits_authority_terrain_in_live_scene() {
        use crate::voxel::authority::{AuthorityChunk, CellState};
        use crate::voxel::authority_plugin::VoxelAuthority;
        use crate::voxel::wire::NormalBlock;

        let solid = NormalBlock {
            material_id: 2,
            state_flags: 0,
            health: 100,
            temperature_delta: 0,
            moisture_delta: 0,
            attribute_set_ref: 0,
            tag_set_ref: 0,
        };
        // One solid macro at local (5,0,5) → idx = 5 + 0*16 + 5*256 = 1285;
        // render AABB [500,0,500]..[600,100,600].
        let mut cells = vec![CellState::Empty; 16 * 16 * 16];
        cells[1285] = CellState::Solid(solid);
        let chunk = AuthorityChunk {
            chunk_version: 1,
            chunk_size_in_macro: 16,
            cells,
            surface_elements: Vec::new(),
        };
        let mut authority = VoxelAuthority::default();
        authority.store.insert_chunk_for_test([0, 0, 0], chunk);
        let empty_world = VoxelWorld::new();

        // Ray from render (550,50,0) toward +Z hits the macro's near face at Z=500.
        let hit = voxel_ray_first_hit_distance(
            &empty_world,
            &authority,
            true,
            Vec3::new(550.0, 50.0, 0.0),
            Vec3::new(0.0, 0.0, 1.0),
            1000.0,
        );
        assert_eq!(hit, Some(500.0), "camera must clamp against live terrain");

        // A ray that misses all terrain → no clamp.
        let miss = voxel_ray_first_hit_distance(
            &empty_world,
            &authority,
            true,
            Vec3::new(550.0, 50.0, 0.0),
            Vec3::new(0.0, 1.0, 0.0),
            1000.0,
        );
        assert_eq!(miss, None);

        // Pre-join (scene_joined = false) with an empty offline world → no clamp,
        // and crucially the authority terrain is NOT consulted (offline showcase
        // owns collision before join).
        let pre_join = voxel_ray_first_hit_distance(
            &empty_world,
            &authority,
            false,
            Vec3::new(550.0, 50.0, 0.0),
            Vec3::new(0.0, 0.0, 1.0),
            1000.0,
        );
        assert_eq!(pre_join, None);
    }
}
