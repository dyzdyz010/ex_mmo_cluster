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
use bevy::image::{ImageAddressMode, ImageFilterMode, ImageSampler, ImageSamplerDescriptor};
use bevy::mesh::{Indices, PrimitiveTopology};
use bevy::prelude::*;
use bevy::render::render_resource::{Extent3d, TextureDimension, TextureFormat};
use std::collections::{HashMap, HashSet, VecDeque};

use crate::app::schedule::ClientSet;
use crate::login::AppState;
use crate::voxel::authority::{ChunkCoord, VoxelAuthorityStore};
use crate::voxel::authority_plugin::VoxelAuthority;
use crate::voxel::field_view::VoxelFieldStore;
use crate::voxel::mesher::{ChunkMeshData, ChunkNeighbors, chunk_render_mesh_lit};
use crate::voxel::skylight::{Skylight, SkylightConfig};
use crate::voxel::surface_decal::surface_decal_mesh;

/// Sim/render size of one macro cell, in render units. The server's macro cell
/// is 100cm; the offline renderer uses the same 100-unit cell
/// (`VOXEL_RENDER_CELL_SIZE`), so authority chunks tile with it 1:1.
///
/// `pub(crate)` so the FieldView render sub-layer (`field_render`) places its
/// temperature overlay at the exact same macro scale as the chunk mesh.
pub(crate) const MACRO_RENDER_SIZE: f32 = 100.0;

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

fn setup_chunk_material(
    mut commands: Commands,
    mut materials: ResMut<Assets<StandardMaterial>>,
    mut images: ResMut<Assets<Image>>,
) {
    // White base so per-vertex material colors come through; a tiled procedural
    // mosaic texture gives every voxel face a blocky textured surface (sampled
    // grayscale × the per-material vertex color = textured, material-tinted block)
    // instead of a flat color. UVs run 0..w across greedy quads, so the texture
    // tiles once per macro cell.
    let texture = images.add(mosaic_block_texture());
    let handle = materials.add(StandardMaterial {
        base_color: Color::WHITE,
        base_color_texture: Some(texture),
        perceptual_roughness: 0.92,
        ..default()
    });
    commands.insert_resource(VoxelChunkMaterial(handle));
}

// Small deterministic per-texel hash → 0..1 (no rand dep), for the mosaic speckle.
fn tex_hash(x: u32, y: u32) -> f32 {
    let mut h = x
        .wrapping_mul(0x1657_4d2b)
        .wrapping_add(y.wrapping_mul(0x2b3f_61d1))
        .wrapping_add(0x9e37_79b9);
    h ^= h >> 15;
    h = h.wrapping_mul(0x2c1b_3c6d);
    h ^= h >> 12;
    h = h.wrapping_mul(0x297a_2d39);
    h ^= h >> 15;
    (h & 0xffff) as f32 / 65535.0
}

/// Procedural per-voxel mosaic block texture (16×16, `Repeat` + `Nearest` so it
/// tiles crisply once per macro cell): a speckled grid with darker seams, kept
/// near-white so it modulates rather than dims the per-material vertex color —
/// a Minecraft-ish mosaic block surface instead of flat color. `pub(crate)` so
/// the layer3 showcase renders the same textured material.
pub(crate) fn mosaic_block_texture() -> Image {
    const N: u32 = 16;
    let mut data = Vec::with_capacity((N * N * 4) as usize);
    for y in 0..N {
        for x in 0..N {
            let n = tex_hash(x, y); // 0..1 speckle
            let mut v = 0.94 + (n - 0.5) * 0.20; // ~0.84..1.04
            // Darker 1px border → visible block seams between tiled cells.
            if x == 0 || y == 0 || x == N - 1 || y == N - 1 {
                v *= 0.64;
            }
            let g = (v.clamp(0.0, 1.0) * 255.0).round() as u8;
            data.extend_from_slice(&[g, g, g, 255]);
        }
    }
    let mut image = Image::new(
        Extent3d {
            width: N,
            height: N,
            depth_or_array_layers: 1,
        },
        TextureDimension::D2,
        data,
        TextureFormat::Rgba8UnormSrgb,
        RenderAssetUsages::RENDER_WORLD | RenderAssetUsages::MAIN_WORLD,
    );
    image.sampler = ImageSampler::Descriptor(ImageSamplerDescriptor {
        address_mode_u: ImageAddressMode::Repeat,
        address_mode_v: ImageAddressMode::Repeat,
        mag_filter: ImageFilterMode::Nearest,
        min_filter: ImageFilterMode::Nearest,
        mipmap_filter: ImageFilterMode::Nearest,
        ..default()
    });
    image
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
            &authority.field_store,
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
    field_store: &VoxelFieldStore,
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
    // 光可见度 Phase A:逐 cell 光照 = max(天光, 块光) 烤进 mesh 顶点光因子。
    //  · 天光:从权威几何算(露天满亮、洞穴/地下逐格变暗);
    //  · 块光:采样服务端 :light 场(火把/余烬等照亮周围,洞穴里也亮)。
    let neighbors = build_neighbors(store, coord);
    let sky = Skylight::compute(chunk, SkylightConfig::default());
    let size = chunk.chunk_size_in_macro as i32;
    // 块光 grid 仅 16³ chunk 有效(wire macro_index 假定 16³);非标准 size → 仅天光。
    // 含 6 个邻 chunk 的块光 grid:边界面采样的是**跨 chunk 的 air cell**(mesher 取面对侧
    // 邻格),若那格在邻 chunk 且被火把照亮,必须读邻 chunk 的块光,否则接缝处边界面发黑。
    let block_light = if size == 16 {
        field_store.block_light_grid(coord)
    } else {
        None
    };
    let nbr_block: [Option<Vec<u8>>; 6] = if size == 16 {
        [
            field_store.block_light_grid([coord[0] + 1, coord[1], coord[2]]),
            field_store.block_light_grid([coord[0] - 1, coord[1], coord[2]]),
            field_store.block_light_grid([coord[0], coord[1] + 1, coord[2]]),
            field_store.block_light_grid([coord[0], coord[1] - 1, coord[2]]),
            field_store.block_light_grid([coord[0], coord[1], coord[2] + 1]),
            field_store.block_light_grid([coord[0], coord[1], coord[2] - 1]),
        ]
    } else {
        [None, None, None, None, None, None]
    };
    let sample_grid = |grid: &Option<Vec<u8>>, x: i32, y: i32, z: i32| -> f32 {
        if (0..16).contains(&x) && (0..16).contains(&y) && (0..16).contains(&z) {
            grid.as_ref()
                .map_or(0.0, |g| g[(x + y * 16 + z * 256) as usize] as f32 / 255.0)
        } else {
            0.0
        }
    };
    let light_at = |x: i32, y: i32, z: i32| -> f32 {
        let sky_l = if y >= size {
            // 越过本 chunk 顶 = 露天(v1 不看上方邻 chunk)。
            1.0
        } else {
            // 侧/底越界:夹回 chunk 内,取边列同高天光作近似。
            sky.at(x.clamp(0, size - 1), y.clamp(0, size - 1), z.clamp(0, size - 1))
        };
        // 块光:in-bounds → 本 grid;恰一轴越界(边界面)→ 对应邻 chunk grid 的 wrap 格。
        let block_l = if (0..16).contains(&x) && (0..16).contains(&y) && (0..16).contains(&z) {
            sample_grid(&block_light, x, y, z)
        } else if x >= 16 {
            sample_grid(&nbr_block[0], 0, y, z)
        } else if x < 0 {
            sample_grid(&nbr_block[1], 15, y, z)
        } else if y >= 16 {
            sample_grid(&nbr_block[2], x, 0, z)
        } else if y < 0 {
            sample_grid(&nbr_block[3], x, 15, z)
        } else if z >= 16 {
            sample_grid(&nbr_block[4], x, y, 0)
        } else {
            // z < 0
            sample_grid(&nbr_block[5], x, y, 15)
        };
        sky_l.max(block_l)
    };
    let data = chunk_render_mesh_lit(chunk, MACRO_RENDER_SIZE, &neighbors, Some(&light_at));
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
pub(crate) fn chunk_translation(coord: ChunkCoord) -> Vec3 {
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

/// Shared mesh builder: bakes per-vertex colors via `color_for(id)`. `pub(crate)`
/// so the FieldView sub-layer reuses it with the heat-color ramp.
pub(crate) fn build_mesh_with_colors(
    data: &ChunkMeshData,
    color_for: impl Fn(u32) -> [f32; 4],
) -> Mesh {
    // 光可见度 Phase A:lit 网格携带逐顶点光因子 → 乘进顶点色(压暗 RGB,保 alpha)。
    // 空 light(普通/历史路径)→ 不调,逐字节一致。
    let lit = data.light.len() == data.material_ids.len();
    let colors: Vec<[f32; 4]> = data
        .material_ids
        .iter()
        .enumerate()
        .map(|(i, &id)| {
            let c = color_for(id);
            if lit {
                let l = data.light[i];
                [c[0] * l, c[1] * l, c[2] * l, c[3]]
            } else {
                c
            }
        })
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
pub(crate) fn material_color(material_id: u32) -> [f32; 4] {
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
        // 化学扩展(2026-06-21)熔化/多反应物产物 — 补基础色避免 magenta(辉光留待 #24 emissive 轨)。
        14 => [1.00, 0.50, 0.15, 1.0], // molten_iron (iron 熔化 — 炽亮橙红)
        15 => [0.85, 0.30, 0.08, 1.0], // lava (stone 熔化 — 暗炽橙)
        16 => [0.10, 0.08, 0.14, 1.0], // obsidian (lava+water 淬火 — 近黑带蓝紫)
        // 光学正交系统(2026-06-23)光成真机制材料 — 补基础色避免 magenta。
        17 => [0.18, 0.22, 0.30, 1.0], // photo_sensor (光敏元件 — 深蓝灰传感板)
        18 => [0.30, 0.65, 0.25, 1.0], // sprout (光合幼苗 — 嫩绿)
        19 => [0.55, 0.75, 0.95, 1.0], // glowstone (彩色光源 — 冷蓝荧光石)
        // 建设系统 · 半导体梯队 a:电阻(米褐陶体)+ 比较器/阈值门(深青电路板)。
        20 => [0.78, 0.68, 0.50, 1.0], // resistor
        21 => [0.20, 0.55, 0.55, 1.0], // comparator (阈值逻辑门)
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
        // 化学扩展产物 14/15/16 + 光学材料 17/18/19(photo_sensor/sprout/glowstone)同样不可 magenta。
        for id in [11u32, 12, 13, 14, 15, 16, 17, 18, 19] {
            assert_ne!(
                material_color(id),
                magenta,
                "material {id} must not be magenta"
            );
        }
        // rust 与 iron 视觉可区分(氧化后看得出变化)。
        assert_ne!(material_color(12), material_color(5));
        // 熔铁与铁、熔岩与石、黑曜石与石 视觉可区分(相变/淬火看得出变化)。
        assert_ne!(material_color(14), material_color(5));
        assert_ne!(material_color(15), material_color(2));
        assert_ne!(material_color(16), material_color(2));
        // sprout 成熟为 wood 后视觉可区分(嫩绿 → 木棕)。
        assert_ne!(material_color(18), material_color(3));
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
