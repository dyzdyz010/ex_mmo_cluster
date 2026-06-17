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
//! Coordinate/scale note: voxel macro coords map **directly** to render space
//! (macro x fastest; macro Y = Bevy's up; one macro cell = [`MACRO_RENDER_SIZE`]
//! units, matching the server's 100cm macro). This is the same convention as the
//! offline renderer (`voxel/plugin.rs::voxel_render_translation`). No
//! `sim_to_render` Y/Z swap is applied here: the server's macro→sim relation
//! (macro Y = sim Z = up) already cancels the actor-space sim→render swap, so
//! applying it to voxels would tip the ground onto its side (terrain height along
//! macro Y would render horizontally — a wall). The store is empty until
//! subscribed, so this system is inert until then.

use bevy::asset::RenderAssetUsages;
use bevy::mesh::{Indices, PrimitiveTopology};
use bevy::prelude::*;
use std::collections::{HashMap, HashSet, VecDeque};

use crate::app::schedule::ClientSet;
use crate::login::AppState;
use crate::voxel::authority::{ChunkCoord, VoxelAuthorityStore};
use crate::voxel::authority_plugin::VoxelAuthority;
use crate::voxel::mesher::{ChunkMeshData, ChunkNeighbors, chunk_render_mesh};
use crate::voxel::surface_decal::surface_decal_mesh;

/// Sim/render size of one macro cell, in render units. The server's macro cell
/// is 100cm; the offline renderer uses the same 100-unit cell
/// (`VOXEL_RENDER_CELL_SIZE`), so authority chunks tile with it 1:1.
const MACRO_RENDER_SIZE: f32 = 100.0;

/// Max chunks remeshed per frame (each = a greedy mesh + a Bevy mesh-asset
/// upload on the main thread). A burst of incoming snapshots beyond this — e.g.
/// a large subscription radius filling in — defers to later frames instead of
/// stalling one. Async off-thread meshing is a later optimization (see
/// `docs/2026-06-15-bevy-largescale-voxel-rendering.md` §4).
const REMESH_BUDGET_PER_FRAME: usize = 8;

/// Maps each rendered chunk coord to its Bevy entity, so re-meshes update in
/// place and invalidated chunks despawn.
#[derive(Resource, Default)]
pub struct VoxelChunkEntities(HashMap<ChunkCoord, Entity>);

/// Per-chunk SurfaceDecal entity (形态轨 C1): the chunk's surface elements
/// (section 0x08) rendered as a separate zero-volume decal mesh, parallel to the
/// volumetric chunk mesh. Rebuilt in the same dirty-pass as the chunk mesh.
#[derive(Resource, Default)]
pub struct VoxelDecalEntities(HashMap<ChunkCoord, Entity>);

/// Pending remesh queue feeding the per-frame budget. `queued` dedups membership
/// so a chunk dirtied repeatedly (or via several neighbors) is meshed once per
/// pass; `pending` preserves arrival order, so spawn-area chunks paint first.
#[derive(Resource, Default)]
struct VoxelRemeshQueue {
    pending: VecDeque<ChunkCoord>,
    queued: HashSet<ChunkCoord>,
}

/// Shared material handle for all authority chunk meshes (vertex-colored).
#[derive(Resource)]
pub struct VoxelChunkMaterial(Handle<StandardMaterial>);

pub struct VoxelChunkRenderPlugin;

impl Plugin for VoxelChunkRenderPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<VoxelChunkEntities>()
            .init_resource::<VoxelDecalEntities>()
            .init_resource::<VoxelRemeshQueue>()
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
    mut decal_entities: ResMut<VoxelDecalEntities>,
    mut queue: ResMut<VoxelRemeshQueue>,
    mut meshes: ResMut<Assets<Mesh>>,
    material: Option<Res<VoxelChunkMaterial>>,
) {
    let Some(material) = material else {
        return; // material not ready yet (first frame ordering)
    };

    // Fold newly-dirty chunks — and their loaded neighbors, whose shared
    // boundary faces may now be exposed/culled (cross-chunk culling) — into the
    // pending remesh queue. A despawned (invalidated) chunk's coord stays queued
    // so its neighbors re-grow their boundary faces.
    for coord in authority.store.take_dirty() {
        enqueue(&mut queue, coord);
        for neighbor in neighbor_coords(coord) {
            if authority.store.chunk(neighbor).is_some() {
                enqueue(&mut queue, neighbor);
            }
        }
    }

    // Remesh at most a per-frame budget so a burst of snapshots (a large
    // subscription radius filling in) can't stall a single frame; the rest
    // remeshes over subsequent frames, in arrival order.
    let budget = REMESH_BUDGET_PER_FRAME.min(queue.pending.len());
    for _ in 0..budget {
        let Some(coord) = queue.pending.pop_front() else {
            break;
        };
        queue.queued.remove(&coord);
        remesh_chunk(
            &mut commands,
            &authority.store,
            &mut entities,
            &mut decal_entities,
            &mut meshes,
            &material,
            coord,
        );
    }
}

/// Adds a chunk to the pending remesh queue unless it is already queued.
fn enqueue(queue: &mut VoxelRemeshQueue, coord: ChunkCoord) {
    if queue.queued.insert(coord) {
        queue.pending.push_back(coord);
    }
}

/// Re-meshes one chunk: spawn/update its `Mesh3d`, or despawn it when the chunk
/// is gone or now meshes to nothing (fully occluded / emptied).
fn remesh_chunk(
    commands: &mut Commands,
    store: &VoxelAuthorityStore,
    entities: &mut VoxelChunkEntities,
    decal_entities: &mut VoxelDecalEntities,
    meshes: &mut Assets<Mesh>,
    material: &VoxelChunkMaterial,
    coord: ChunkCoord,
) {
    let Some(chunk) = store.chunk(coord) else {
        // Chunk dropped (invalidate) → remove its volumetric + decal entities.
        despawn_chunk(commands, entities, coord);
        despawn_decal(commands, decal_entities, coord);
        return;
    };

    // Volumetric chunk mesh: greedy macro faces (solid) + refined cells' micro
    // sub-voxel meshes, with cross-chunk culling (C4).
    let neighbors = build_neighbors(store, coord);
    let data = chunk_render_mesh(chunk, MACRO_RENDER_SIZE, &neighbors);
    if data.is_empty() {
        despawn_chunk(commands, entities, coord);
    } else {
        let mesh_handle = meshes.add(build_mesh(&data));
        upsert_entity(commands, entities, material, coord, mesh_handle);
    }

    // 形态轨 C1:SurfaceDecal 子层 — 同一 dirty-pass 重建表面元件 decal mesh(零体积,独立实体)。
    let decal_data = surface_decal_mesh(chunk, MACRO_RENDER_SIZE);
    if decal_data.is_empty() {
        despawn_decal(commands, decal_entities, coord);
    } else {
        let decal_handle = meshes.add(build_decal_mesh(&decal_data));
        upsert_decal(commands, decal_entities, material, coord, decal_handle);
    }
}

/// Spawns or updates the chunk's volumetric mesh entity in place.
fn upsert_entity(
    commands: &mut Commands,
    entities: &mut VoxelChunkEntities,
    material: &VoxelChunkMaterial,
    coord: ChunkCoord,
    mesh_handle: Handle<Mesh>,
) {
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

/// Spawns or updates the chunk's decal mesh entity (shares the chunk material;
/// colors are baked per-vertex by surface_type_id).
fn upsert_decal(
    commands: &mut Commands,
    decal_entities: &mut VoxelDecalEntities,
    material: &VoxelChunkMaterial,
    coord: ChunkCoord,
    mesh_handle: Handle<Mesh>,
) {
    match decal_entities.0.get(&coord).copied() {
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
            decal_entities.0.insert(coord, entity);
        }
    }
}

fn despawn_chunk(commands: &mut Commands, entities: &mut VoxelChunkEntities, coord: ChunkCoord) {
    if let Some(entity) = entities.0.remove(&coord) {
        commands.entity(entity).despawn();
    }
}

fn despawn_decal(
    commands: &mut Commands,
    decal_entities: &mut VoxelDecalEntities,
    coord: ChunkCoord,
) {
    if let Some(entity) = decal_entities.0.remove(&coord) {
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

/// Places a chunk at its render-space origin. Voxel macro coords map **directly**
/// to render space (macro Y = Bevy's up) — same convention as the offline
/// renderer (`voxel/plugin.rs::voxel_render_translation`). No `sim_to_render`
/// swap: the server's macro→sim relation (macro Y = sim Z = up) already cancels
/// the actor-space sim→render Y/Z swap, so applying it here would tip the ground
/// onto its side (height along macro Y would render horizontally — a wall).
fn chunk_translation(coord: ChunkCoord) -> Vec3 {
    const CHUNK_SPAN: f32 = 16.0 * MACRO_RENDER_SIZE;
    Vec3::new(
        coord[0] as f32 * CHUNK_SPAN,
        coord[1] as f32 * CHUNK_SPAN,
        coord[2] as f32 * CHUNK_SPAN,
    )
}

/// Converts pure mesh data into a Bevy `Mesh` (positions / normals / uvs /
/// per-vertex colors / indices) with the block material palette. Macro coords
/// map directly to render space (macro Y = up), so no axis swap / winding flip
/// is applied (see `chunk_translation`).
pub fn build_mesh(data: &ChunkMeshData) -> Mesh {
    build_mesh_with_colors(data, material_color)
}

/// Builds the surface-element decal mesh's Bevy `Mesh` (per-vertex decal colors
/// by surface_type_id). Shares the chunk's white-base lit material — the visual
/// distinction is the baked vertex color, so no separate material is needed.
pub fn build_decal_mesh(data: &ChunkMeshData) -> Mesh {
    build_mesh_with_colors(data, decal_color)
}

/// Shared mesh builder: bakes per-vertex colors via `color_for(id)`.
fn build_mesh_with_colors(data: &ChunkMeshData, color_for: impl Fn(u32) -> [f32; 4]) -> Mesh {
    let colors: Vec<[f32; 4]> = data.material_ids.iter().map(|&id| color_for(id)).collect();
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
        // C5:补齐 append-only 材质,使 S4/M5 涌现产物正确显示(此前 11/12/13 渲染成 magenta)。
        11 => [0.40, 0.30, 0.22, 1.0], // door (导电金属门)
        12 => [0.55, 0.27, 0.10, 1.0], // rust (S4 氧化产物 — 锈橙棕)
        13 => [1.00, 0.45, 0.10, 1.0], // ember (M5 火炬热源 — 炽橙)
        _ => [1.0, 0.0, 1.0, 1.0],     // unknown → magenta
    }
}

/// Decal palette keyed by surface_type_id (mirrors server `SurfaceCatalog`:
/// rust_decal=1 / frost=2 / scorch=3 / torch=4 / lever=5). Unknown → magenta.
fn decal_color(surface_type_id: u32) -> [f32; 4] {
    match surface_type_id {
        1 => [0.65, 0.30, 0.12, 1.0], // rust_decal — rusty orange-brown
        2 => [0.80, 0.92, 1.00, 1.0], // frost — pale icy blue
        3 => [0.10, 0.10, 0.10, 1.0], // scorch — charred black
        4 => [1.00, 0.75, 0.20, 1.0], // torch — bright flame
        5 => [0.70, 0.70, 0.75, 1.0], // lever — metallic
        _ => [1.0, 0.0, 1.0, 1.0],    // unknown → magenta
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
            ..Default::default()
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
    fn emergence_product_materials_have_colors_not_magenta() {
        // C5:S4/M5 涌现产物(rust 12 / ember 13)+ door 11 必须有专属色,不能 magenta
        // (否则服务端 iron→rust、火炬 ember 在客户端显示成错误的品红)。
        let magenta = [1.0, 0.0, 1.0, 1.0];
        for id in [11u32, 12, 13] {
            assert_ne!(
                material_color(id),
                magenta,
                "material {id} must not be magenta"
            );
        }
        // rust 与 iron 视觉可区分(氧化后看得出变化)。
        assert_ne!(material_color(12), material_color(5));
    }

    #[test]
    fn decal_palette_distinguishes_known_types_and_flags_unknown() {
        // torch / rust_decal distinct; unknown → magenta (obvious).
        assert_ne!(decal_color(1), decal_color(4));
        assert_eq!(decal_color(9999), [1.0, 0.0, 1.0, 1.0]);
    }

    #[test]
    fn build_decal_mesh_carries_attributes() {
        use crate::voxel::surface_decal::surface_decal_mesh;
        use crate::voxel::wire::SurfaceElement;

        let size = 16usize;
        let mut cells = vec![CellState::Empty; size * size * size];
        cells[0] = solid(5); // host wall
        let chunk = AuthorityChunk {
            chunk_version: 1,
            chunk_size_in_macro: size as u8,
            cells,
            surface_elements: vec![SurfaceElement {
                macro_index: 0,
                face: 1,            // x_pos
                surface_type_id: 4, // torch
                attribute_set_ref: 0,
                tag_set_ref: 0,
                owner_actor_id: 0,
            }],
        };

        let data = surface_decal_mesh(&chunk, MACRO_RENDER_SIZE);
        assert_eq!(data.quad_count(), 1);
        let mesh = build_decal_mesh(&data);
        // One decal quad → 4 verts / 6 indices, all attributes present.
        assert_eq!(mesh.count_vertices(), 4);
        assert!(mesh.attribute(Mesh::ATTRIBUTE_POSITION).is_some());
        assert!(mesh.attribute(Mesh::ATTRIBUTE_NORMAL).is_some());
        assert!(mesh.attribute(Mesh::ATTRIBUTE_COLOR).is_some());
        assert_eq!(mesh.indices().map(|i| i.len()), Some(6));
    }

    #[test]
    fn remesh_queue_dedups_and_preserves_arrival_order() {
        let mut q = VoxelRemeshQueue::default();
        enqueue(&mut q, [0, 0, 0]);
        enqueue(&mut q, [1, 0, 0]);
        enqueue(&mut q, [0, 0, 0]); // duplicate → ignored while still queued
        assert_eq!(q.pending.len(), 2);
        assert_eq!(q.pending.pop_front(), Some([0, 0, 0]));
        assert_eq!(q.pending.pop_front(), Some([1, 0, 0]));
        // Re-enqueuing after it left the queue is allowed again.
        q.queued.remove(&[0, 0, 0]);
        enqueue(&mut q, [0, 0, 0]);
        assert_eq!(q.pending.pop_front(), Some([0, 0, 0]));
    }

    #[test]
    fn chunk_translation_maps_macro_coords_directly() {
        // Direct macro→render (no swap): chunk (1,0,-2) * (16*100) = (1600,0,-3200).
        assert_eq!(
            chunk_translation([1, 0, -2]),
            Vec3::new(1600.0, 0.0, -3200.0)
        );
    }
}
