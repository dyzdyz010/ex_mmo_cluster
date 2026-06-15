//! Chunk mesh rendering (M2b): turns the voxel authority store's dirty chunks
//! into Bevy chunk-mesh entities — the on-screen payoff of the exposed-face
//! mesher, replacing the naive per-voxel cube entities for server-authoritative
//! voxels.
//!
//! Each subscribed chunk becomes ONE `Mesh3d` entity (a single AABB-bounded
//! mesh, so Bevy's frustum culling becomes effective), re-meshed only when the
//! authority store marks it dirty. Material is baked into per-vertex colors
//! (one shared `StandardMaterial`), so a chunk is one draw batch; a real
//! texture array is M6 polish.
//!
//! Coordinate/scale note: chunks are placed at `chunk_coord * chunk_size *
//! MACRO_RENDER_SIZE` in render space. Exact alignment with the existing
//! offline renderer + the sim→render axis convention is a live-tuning step
//! (needs a running server + GUI); the store is empty until subscribed, so this
//! system is inert (and harmless) until then.

use bevy::asset::RenderAssetUsages;
use bevy::mesh::{Indices, PrimitiveTopology};
use bevy::prelude::*;
use std::collections::{HashMap, HashSet};

use crate::app::schedule::ClientSet;
use crate::login::AppState;
use crate::voxel::authority::{ChunkCoord, VoxelAuthorityStore};
use crate::voxel::authority_plugin::VoxelAuthority;
use crate::voxel::mesher::{ChunkMeshData, ChunkNeighbors, greedy_mesh_chunk_with_neighbors};

/// Render-space size of one macro cell.
const MACRO_RENDER_SIZE: f32 = 1.0;

/// Maps each rendered chunk coord to its Bevy entity, so re-meshes update in
/// place and invalidated chunks despawn.
#[derive(Resource, Default)]
pub struct VoxelChunkEntities(HashMap<ChunkCoord, Entity>);

/// Shared material handle for all authority chunk meshes (vertex-colored).
#[derive(Resource)]
pub struct VoxelChunkMaterial(Handle<StandardMaterial>);

pub struct VoxelChunkRenderPlugin;

impl Plugin for VoxelChunkRenderPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<VoxelChunkEntities>()
            .add_systems(Startup, setup_chunk_material)
            .add_systems(
                Update,
                render_dirty_chunks
                    .in_set(ClientSet::Render)
                    .run_if(in_state(AppState::Game)),
            );
    }
}

fn setup_chunk_material(mut commands: Commands, mut materials: ResMut<Assets<StandardMaterial>>) {
    // White base so per-vertex colors come through unattenuated; lit.
    let handle = materials.add(StandardMaterial {
        base_color: Color::WHITE,
        perceptual_roughness: 0.9,
        ..default()
    });
    commands.insert_resource(VoxelChunkMaterial(handle));
}

fn render_dirty_chunks(
    mut commands: Commands,
    mut authority: ResMut<VoxelAuthority>,
    mut entities: ResMut<VoxelChunkEntities>,
    mut meshes: ResMut<Assets<Mesh>>,
    material: Option<Res<VoxelChunkMaterial>>,
) {
    let Some(material) = material else {
        return; // material not ready yet (first frame ordering)
    };
    let dirty = authority.store.take_dirty();
    if dirty.is_empty() {
        return;
    }

    // Re-mesh dirty chunks AND their loaded neighbors: a change to one chunk can
    // expose/cull faces on the shared boundary of its neighbors (cross-chunk
    // culling). A despawned (invalidated) chunk's coord stays in the set so its
    // neighbors re-grow their boundary faces.
    let mut to_remesh: HashSet<ChunkCoord> = HashSet::new();
    for &coord in &dirty {
        to_remesh.insert(coord);
        for neighbor in neighbor_coords(coord) {
            if authority.store.chunk(neighbor).is_some() {
                to_remesh.insert(neighbor);
            }
        }
    }

    for coord in to_remesh {
        match authority.store.chunk(coord) {
            Some(chunk) => {
                let neighbors = build_neighbors(&authority.store, coord);
                let data = greedy_mesh_chunk_with_neighbors(chunk, MACRO_RENDER_SIZE, &neighbors);
                if data.is_empty() {
                    despawn_chunk(&mut commands, &mut entities, coord);
                    continue;
                }
                let mesh_handle = meshes.add(build_mesh(&data));
                match entities.0.get(&coord).copied() {
                    Some(entity) => {
                        commands.entity(entity).insert(Mesh3d(mesh_handle));
                    }
                    None => {
                        let entity = commands
                            .spawn((
                                Mesh3d(mesh_handle),
                                MeshMaterial3d(material.0.clone()),
                                Transform::from_translation(chunk_translation(coord)),
                                Visibility::default(),
                            ))
                            .id();
                        entities.0.insert(coord, entity);
                    }
                }
            }
            // Chunk dropped (invalidate) → remove its entity.
            None => despawn_chunk(&mut commands, &mut entities, coord),
        }
    }
}

fn despawn_chunk(commands: &mut Commands, entities: &mut VoxelChunkEntities, coord: ChunkCoord) {
    if let Some(entity) = entities.0.remove(&coord) {
        commands.entity(entity).despawn();
    }
}

/// The six axis-neighbor chunk coords (+x,-x,+y,-y,+z,-z).
fn neighbor_coords(c: ChunkCoord) -> [ChunkCoord; 6] {
    [
        [c[0] + 1, c[1], c[2]],
        [c[0] - 1, c[1], c[2]],
        [c[0], c[1] + 1, c[2]],
        [c[0], c[1] - 1, c[2]],
        [c[0], c[1], c[2] + 1],
        [c[0], c[1], c[2] - 1],
    ]
}

/// Looks up the six axis neighbors in the store for cross-chunk face culling.
/// `pos[d]`/`neg[d]` are the +/- neighbor along axis `d` (0=x,1=y,2=z).
fn build_neighbors(store: &VoxelAuthorityStore, c: ChunkCoord) -> ChunkNeighbors<'_> {
    ChunkNeighbors {
        pos: [
            store.chunk([c[0] + 1, c[1], c[2]]),
            store.chunk([c[0], c[1] + 1, c[2]]),
            store.chunk([c[0], c[1], c[2] + 1]),
        ],
        neg: [
            store.chunk([c[0] - 1, c[1], c[2]]),
            store.chunk([c[0], c[1] - 1, c[2]]),
            store.chunk([c[0], c[1], c[2] - 1]),
        ],
    }
}

fn chunk_translation(coord: ChunkCoord) -> Vec3 {
    const CHUNK_SPAN: f32 = 16.0 * MACRO_RENDER_SIZE;
    Vec3::new(
        coord[0] as f32 * CHUNK_SPAN,
        coord[1] as f32 * CHUNK_SPAN,
        coord[2] as f32 * CHUNK_SPAN,
    )
}

/// Converts pure mesh data into a Bevy `Mesh` (positions / normals / uvs /
/// per-vertex colors / indices).
pub fn build_mesh(data: &ChunkMeshData) -> Mesh {
    let colors: Vec<[f32; 4]> = data
        .material_ids
        .iter()
        .map(|&id| material_color(id))
        .collect();
    let mut mesh = Mesh::new(
        PrimitiveTopology::TriangleList,
        RenderAssetUsages::default(),
    );
    mesh.insert_attribute(Mesh::ATTRIBUTE_POSITION, data.positions.clone());
    mesh.insert_attribute(Mesh::ATTRIBUTE_NORMAL, data.normals.clone());
    mesh.insert_attribute(Mesh::ATTRIBUTE_UV_0, data.uvs.clone());
    mesh.insert_attribute(Mesh::ATTRIBUTE_COLOR, colors);
    mesh.insert_indices(Indices::U32(data.indices.clone()));
    mesh
}

/// Placeholder material palette (ids mirror `MaterialCatalog`). Replaced by a
/// texture array in M6; unknown ids render magenta to be obvious.
fn material_color(material_id: u32) -> [f32; 4] {
    match material_id {
        1 => [0.55, 0.40, 0.25, 1.0],  // dirt
        2 => [0.50, 0.50, 0.50, 1.0],  // stone
        3 => [0.60, 0.40, 0.20, 1.0],  // wood
        4 => [0.70, 0.85, 1.00, 1.0],  // ice
        5 => [0.60, 0.60, 0.65, 1.0],  // iron
        6 => [0.90, 0.80, 0.20, 1.0],  // power_block
        7 => [0.85, 0.55, 0.25, 1.0],  // electric_load
        8 => [0.20, 0.40, 0.80, 1.0],  // water
        9 => [0.85, 0.85, 0.90, 1.0],  // steam
        10 => [0.25, 0.25, 0.25, 1.0], // ash
        _ => [1.0, 0.0, 1.0, 1.0],     // unknown → magenta
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::authority::{AuthorityChunk, CellState};
    use crate::voxel::wire::NormalBlock;

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

    #[test]
    fn build_mesh_carries_all_attributes() {
        let size = 16usize;
        let mut cells = vec![CellState::Empty; size * size * size];
        cells[0] = solid(2);
        let chunk = AuthorityChunk {
            chunk_version: 1,
            chunk_size_in_macro: size as u8,
            cells,
        };
        let data = crate::voxel::mesher::greedy_mesh_chunk(&chunk, MACRO_RENDER_SIZE);
        let mesh = build_mesh(&data);

        // A lone solid cell can't merge → 6 faces × 4 verts = 24 vertices.
        assert_eq!(mesh.count_vertices(), 24);
        assert!(mesh.attribute(Mesh::ATTRIBUTE_POSITION).is_some());
        assert!(mesh.attribute(Mesh::ATTRIBUTE_NORMAL).is_some());
        assert!(mesh.attribute(Mesh::ATTRIBUTE_UV_0).is_some());
        assert!(mesh.attribute(Mesh::ATTRIBUTE_COLOR).is_some());
        assert_eq!(mesh.indices().map(|i| i.len()), Some(36));
    }

    #[test]
    fn stone_maps_to_gray_not_magenta() {
        assert_eq!(material_color(2), [0.50, 0.50, 0.50, 1.0]);
        assert_eq!(material_color(9999), [1.0, 0.0, 1.0, 1.0]);
    }

    #[test]
    fn chunk_translation_scales_by_span() {
        assert_eq!(chunk_translation([1, 0, -2]), Vec3::new(16.0, 0.0, -32.0));
    }
}
