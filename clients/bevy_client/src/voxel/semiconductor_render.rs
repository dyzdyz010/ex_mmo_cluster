//! Bevy adapter for the semiconductor / logic debug overlay (C5.3).
//!
//! Per CHUNK (not per field region): when an electric field snapshot/destroy marks
//! a chunk's logic channel dirty, this rebuilds that chunk's overlay — scans the
//! authority chunk for resistor/comparator cells, looks up each cell's electric
//! `(current, potential)` from [`VoxelFieldStore::electric_grids`], and builds the
//! marker mesh via the pure [`semiconductor_overlay_mesh`]. Reuses the FieldView
//! overlay material (unlit + alpha-blend + depth-disable) so the logic readout
//! reads through terrain at full intensity, like the analog field overlays.
//!
//! One entity per chunk coord; rebuilt in place, despawned when the chunk holds no
//! semiconductors. Reads committed authority + field truth only — same discipline
//! as the chunk / field renderers.

use bevy::prelude::*;
use std::collections::HashMap;

use crate::app::schedule::ClientSet;
use crate::login::AppState;
use crate::voxel::authority::CellState;
use crate::voxel::authority_plugin::VoxelAuthority;
use crate::voxel::chunk_render::{MACRO_RENDER_SIZE, build_mesh_with_colors, chunk_translation};
use crate::voxel::field_render::{FieldOverlayMaterial, field_overlay_material};
use crate::voxel::semiconductor_overlay::{
    SemiconductorCell, semiconductor_color, semiconductor_overlay_mesh, COMPARATOR_MATERIAL_ID,
    RESISTOR_MATERIAL_ID,
};

/// One overlay entity per chunk coord that holds at least one semiconductor.
#[derive(Resource, Default)]
struct SemiconductorEntities(HashMap<[i32; 3], Entity>);

/// The (own) handle to the shared FieldView overlay material.
#[derive(Resource)]
struct SemiconductorMaterial(Handle<FieldOverlayMaterial>);

pub struct SemiconductorOverlayPlugin;

impl Plugin for SemiconductorOverlayPlugin {
    fn build(&self, app: &mut App) {
        // The FieldOverlayMaterial MaterialPlugin is registered by
        // VoxelFieldRenderPlugin; we only add our own handle + render system.
        app.init_resource::<SemiconductorEntities>()
            .add_systems(Startup, setup_semiconductor_material)
            .add_systems(
                Update,
                render_dirty_semiconductor_chunks
                    .in_set(ClientSet::Render)
                    .run_if(in_state(AppState::Game)),
            );
    }
}

fn setup_semiconductor_material(
    mut commands: Commands,
    mut materials: ResMut<Assets<FieldOverlayMaterial>>,
) {
    let handle = materials.add(field_overlay_material());
    commands.insert_resource(SemiconductorMaterial(handle));
}

fn render_dirty_semiconductor_chunks(
    mut commands: Commands,
    mut authority: ResMut<VoxelAuthority>,
    mut entities: ResMut<SemiconductorEntities>,
    mut meshes: ResMut<Assets<Mesh>>,
    material: Option<Res<SemiconductorMaterial>>,
) {
    let Some(material) = material else {
        return; // material not ready yet (first frame ordering)
    };

    for chunk_coord in authority.field_store.take_semiconductor_dirty() {
        let cells = scan_semiconductor_cells(&authority, chunk_coord);
        if cells.is_empty() {
            despawn_overlay(&mut commands, &mut entities, chunk_coord);
            continue;
        }
        let grids = authority.field_store.electric_grids(chunk_coord);
        let data = semiconductor_overlay_mesh(&cells, MACRO_RENDER_SIZE, |idx| {
            grids
                .as_ref()
                .map(|(current, potential)| {
                    let i = idx as usize;
                    (
                        current.get(i).copied().unwrap_or(0.0),
                        potential.get(i).copied().unwrap_or(0.0),
                    )
                })
                .unwrap_or((0.0, 0.0))
        });

        if data.is_empty() {
            despawn_overlay(&mut commands, &mut entities, chunk_coord);
            continue;
        }
        let mesh_handle = meshes.add(build_mesh_with_colors(&data, semiconductor_color_or_white));
        let translation = chunk_translation(chunk_coord);
        upsert_overlay(
            &mut commands,
            &mut entities,
            &material,
            chunk_coord,
            mesh_handle,
            translation,
        );
    }
}

/// Scans a loaded chunk's cells for semiconductor blocks (resistor / comparator),
/// returning their `(macro_index, material_id)`. Empty if the chunk isn't loaded or
/// holds none.
fn scan_semiconductor_cells(authority: &VoxelAuthority, chunk_coord: [i32; 3]) -> Vec<SemiconductorCell> {
    let Some(chunk) = authority.store.chunk(chunk_coord) else {
        return Vec::new();
    };
    let mut cells = Vec::new();
    for (idx, cell) in chunk.cells.iter().enumerate() {
        if let CellState::Solid(block) = cell
            && (block.material_id == RESISTOR_MATERIAL_ID
                || block.material_id == COMPARATOR_MATERIAL_ID)
        {
            cells.push(SemiconductorCell {
                macro_index: idx as u16,
                material_id: block.material_id,
            });
        }
    }
    cells
}

/// `build_mesh_with_colors` color fn: dispatch to the semiconductor table, falling
/// back to opaque white for any non-semiconductor id (there should be none — the
/// overlay only bakes semiconductor markers).
fn semiconductor_color_or_white(material_id: u32) -> [f32; 4] {
    semiconductor_color(material_id).unwrap_or([1.0, 1.0, 1.0, 1.0])
}

fn upsert_overlay(
    commands: &mut Commands,
    entities: &mut SemiconductorEntities,
    material: &SemiconductorMaterial,
    chunk_coord: [i32; 3],
    mesh_handle: Handle<Mesh>,
    translation: Vec3,
) {
    match entities.0.get(&chunk_coord).copied() {
        Some(entity) => {
            commands.entity(entity).insert((
                Mesh3d(mesh_handle),
                Transform::from_translation(translation),
            ));
        }
        None => {
            let entity = commands
                .spawn((
                    Mesh3d(mesh_handle),
                    MeshMaterial3d(material.0.clone()),
                    Transform::from_translation(translation),
                    Visibility::default(),
                ))
                .id();
            entities.0.insert(chunk_coord, entity);
        }
    }
}

fn despawn_overlay(
    commands: &mut Commands,
    entities: &mut SemiconductorEntities,
    chunk_coord: [i32; 3],
) {
    if let Some(entity) = entities.0.remove(&chunk_coord) {
        commands.entity(entity).despawn();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::authority::AuthorityChunk;
    use crate::voxel::semiconductor_overlay::{SemiconductorState, SEMICONDUCTOR_MATERIAL_BASE};
    use crate::voxel::wire::{
        FIELD_MASK_ELECTRIC_CURRENT, FieldRegionSnapshot, NormalBlock, VoxelServerMessage,
    };

    /// Headless app with the semiconductor render system + the resources it reads.
    fn test_app() -> App {
        let mut app = App::new();
        app.insert_resource(VoxelAuthority::default())
            .init_resource::<SemiconductorEntities>()
            .insert_resource(Assets::<Mesh>::default())
            .insert_resource(SemiconductorMaterial(Handle::default()))
            .add_systems(Update, render_dirty_semiconductor_chunks);
        app
    }

    fn solid(material_id: u16) -> CellState {
        CellState::Solid(NormalBlock {
            material_id,
            state_flags: 0,
            health: 0,
            temperature_delta: 0,
            moisture_delta: 0,
            attribute_set_ref: 0,
            tag_set_ref: 0,
        })
    }

    /// A 16³ chunk with the given `(macro_index, material_id)` solid cells.
    fn chunk_with(cells: &[(usize, u16)]) -> AuthorityChunk {
        let mut grid = vec![CellState::Empty; 16 * 16 * 16];
        for &(idx, material_id) in cells {
            grid[idx] = solid(material_id);
        }
        AuthorityChunk {
            chunk_version: 1,
            chunk_size_in_macro: 16,
            cells: grid,
            surface_elements: Vec::new(),
        }
    }

    fn insert_chunk(app: &mut App, coord: [i32; 3], cells: &[(usize, u16)]) {
        let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
        authority.store.insert_chunk_for_test(coord, chunk_with(cells));
    }

    fn ingest(app: &mut App, message: VoxelServerMessage) {
        let mut authority = app.world_mut().resource_mut::<VoxelAuthority>();
        authority.enqueue(message);
        authority.drain_inbox();
    }

    fn entity_count(app: &App) -> usize {
        app.world().resource::<SemiconductorEntities>().0.len()
    }

    fn current_region(chunk_coord: [i32; 3], cells: &[(u16, f32)]) -> FieldRegionSnapshot {
        FieldRegionSnapshot {
            logical_scene_id: 1,
            chunk_coord,
            region_id: 1,
            tick_count: 1,
            field_mask: FIELD_MASK_ELECTRIC_CURRENT,
            macro_indices: cells.iter().map(|(i, _)| *i).collect(),
            temperature: vec![],
            electric_potential: vec![],
            electric_current: cells.iter().map(|(_, v)| *v).collect(),
            ionization: vec![],
            light: vec![],
            light_color: vec![],
        }
    }

    #[test]
    fn powered_semiconductor_chunk_spawns_overlay() {
        let mut app = test_app();

        // A chunk with a resistor (idx 0) + comparator (idx 5). Chunk presence alone
        // draws no overlay (the semiconductor channel is field-driven).
        insert_chunk(&mut app, [0, 0, 0], &[(0, RESISTOR_MATERIAL_ID), (5, COMPARATOR_MATERIAL_ID)]);
        app.update();
        assert_eq!(entity_count(&app), 0, "chunk load alone draws no logic overlay");

        // An electric field over the chunk → semiconductor channel dirty → overlay
        // spawns for chunk (0,0,0).
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionSnapshot(current_region([0, 0, 0], &[(0, 5.0)])),
        );
        app.update();
        assert_eq!(entity_count(&app), 1, "powered semiconductor chunk gets a logic overlay");
    }

    #[test]
    fn chunk_with_no_semiconductors_draws_nothing() {
        let mut app = test_app();
        // Plain stone cell + an electric field → no semiconductors → no overlay.
        insert_chunk(&mut app, [0, 0, 0], &[(0, 2)]);
        ingest(
            &mut app,
            VoxelServerMessage::FieldRegionSnapshot(current_region([0, 0, 0], &[(0, 5.0)])),
        );
        app.update();
        assert_eq!(entity_count(&app), 0);
    }

    #[test]
    fn scan_finds_only_semiconductor_materials() {
        let mut app = test_app();
        insert_chunk(
            &mut app,
            [0, 0, 0],
            &[(0, RESISTOR_MATERIAL_ID), (5, COMPARATOR_MATERIAL_ID), (9, 2)],
        );
        let authority = app.world().resource::<VoxelAuthority>();
        let cells = scan_semiconductor_cells(authority, [0, 0, 0]);
        assert_eq!(cells.len(), 2, "the stone cell at idx 9 is not a semiconductor");
        assert!(cells.iter().any(|c| c.macro_index == 0 && c.material_id == RESISTOR_MATERIAL_ID));
        assert!(cells.iter().any(|c| c.macro_index == 5 && c.material_id == COMPARATOR_MATERIAL_ID));
    }

    #[test]
    fn color_fn_round_trips_marker_ids() {
        // The render color fn must reproduce the semiconductor table for baked ids.
        assert_eq!(
            semiconductor_color_or_white(SemiconductorState::ResistorActive.marker_id()),
            semiconductor_color(SEMICONDUCTOR_MATERIAL_BASE + 1).unwrap()
        );
    }
}
