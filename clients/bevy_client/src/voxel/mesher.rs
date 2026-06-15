//! Exposed-face chunk mesher (M2): turns an [`AuthorityChunk`]'s per-cell state
//! into compact, interior-culled, indexed mesh data — the change that lets the
//! bevy client render voxels at scale instead of one cube entity per voxel.
//!
//! Strategy (the chosen M2 path, 1:1 with web `chunkMesher.ts`): for each
//! occupied macro cell, emit a quad per face only when the neighbor in that
//! direction is NOT occupying (so interior faces between solid voxels are
//! dropped — the ~80% geometry win). Quads are indexed (4 verts / face, shared
//! index buffer) rather than 24-vert cubes. Greedy merging of coplanar
//! same-material quads is the fast-follow (M6).
//!
//! This is pure data (no Bevy types) so it is unit-testable and can run off the
//! main schedule on `AsyncComputeTaskPool` (M2 render plugin). Refined cells are
//! treated as full macro cubes for occupancy + material here; true sub-voxel
//! (8³) micro meshing is a follow-up (M2b).
//!
//! Cross-chunk border culling is deferred: faces on the chunk boundary are
//! currently always emitted (a cell at the chunk edge has no in-chunk neighbor).
//! M2b threads neighbor-chunk borders to cull these.

use crate::voxel::authority::{AuthorityChunk, CellState};

/// Compact indexed mesh data for one chunk. `material_ids` is per-vertex (the
/// texture-array layer / material index), filled in M2's render adapter.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ChunkMeshData {
    pub positions: Vec<[f32; 3]>,
    pub normals: Vec<[f32; 3]>,
    pub uvs: Vec<[f32; 2]>,
    pub material_ids: Vec<u32>,
    pub indices: Vec<u32>,
}

impl ChunkMeshData {
    pub fn is_empty(&self) -> bool {
        self.indices.is_empty()
    }

    /// Number of emitted (un-culled) faces.
    pub fn quad_count(&self) -> usize {
        self.indices.len() / 6
    }

    pub fn vertex_count(&self) -> usize {
        self.positions.len()
    }
}

struct Face {
    /// Neighbor cell offset for occlusion testing.
    delta: [i32; 3],
    normal: [f32; 3],
    /// 4 corner offsets (unit cube), CCW when viewed from outside the face.
    corners: [[f32; 3]; 4],
}

// Cube corner offsets used below:
//   (x,y,z) ∈ {0,1}^3 relative to the cell's min corner.
const FACES: [Face; 6] = [
    // +X
    Face {
        delta: [1, 0, 0],
        normal: [1.0, 0.0, 0.0],
        corners: [
            [1.0, 0.0, 1.0],
            [1.0, 0.0, 0.0],
            [1.0, 1.0, 0.0],
            [1.0, 1.0, 1.0],
        ],
    },
    // -X
    Face {
        delta: [-1, 0, 0],
        normal: [-1.0, 0.0, 0.0],
        corners: [
            [0.0, 0.0, 0.0],
            [0.0, 0.0, 1.0],
            [0.0, 1.0, 1.0],
            [0.0, 1.0, 0.0],
        ],
    },
    // +Y
    Face {
        delta: [0, 1, 0],
        normal: [0.0, 1.0, 0.0],
        corners: [
            [0.0, 1.0, 1.0],
            [1.0, 1.0, 1.0],
            [1.0, 1.0, 0.0],
            [0.0, 1.0, 0.0],
        ],
    },
    // -Y
    Face {
        delta: [0, -1, 0],
        normal: [0.0, -1.0, 0.0],
        corners: [
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [1.0, 0.0, 1.0],
            [0.0, 0.0, 1.0],
        ],
    },
    // +Z
    Face {
        delta: [0, 0, 1],
        normal: [0.0, 0.0, 1.0],
        corners: [
            [0.0, 0.0, 1.0],
            [1.0, 0.0, 1.0],
            [1.0, 1.0, 1.0],
            [0.0, 1.0, 1.0],
        ],
    },
    // -Z
    Face {
        delta: [0, 0, -1],
        normal: [0.0, 0.0, -1.0],
        corners: [
            [1.0, 0.0, 0.0],
            [0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0],
            [1.0, 1.0, 0.0],
        ],
    },
];

const FACE_UVS: [[f32; 2]; 4] = [[0.0, 1.0], [1.0, 1.0], [1.0, 0.0], [0.0, 0.0]];

/// Whether a cell occupies (occludes) its macro volume for face culling.
fn occupies(cell: &CellState) -> bool {
    matches!(cell, CellState::Solid(_) | CellState::Refined(_))
}

/// The material id a face of this cell renders with.
fn cell_material(cell: &CellState) -> u32 {
    match cell {
        CellState::Solid(block) => block.material_id as u32,
        // Refined: approximate with the first layer's material (M2b: per-slot).
        CellState::Refined(refined) => refined
            .layers
            .first()
            .map(|layer| layer.material_id as u32)
            .unwrap_or(0),
        CellState::Empty => 0,
    }
}

/// Meshes one chunk via exposed-face culling. `voxel_size` is the render-unit
/// size of one macro cell.
pub fn mesh_chunk(chunk: &AuthorityChunk, voxel_size: f32) -> ChunkMeshData {
    let size = chunk.chunk_size_in_macro as i32;
    let mut mesh = ChunkMeshData::default();
    if size <= 0 {
        return mesh;
    }

    let index_of = |x: i32, y: i32, z: i32| -> usize { (x + y * size + z * size * size) as usize };
    let in_bounds = |v: i32| v >= 0 && v < size;

    for z in 0..size {
        for y in 0..size {
            for x in 0..size {
                let cell = &chunk.cells[index_of(x, y, z)];
                if !occupies(cell) {
                    continue;
                }
                let material_id = cell_material(cell);

                for face in &FACES {
                    let (nx, ny, nz) = (x + face.delta[0], y + face.delta[1], z + face.delta[2]);
                    // Cull only when an in-chunk neighbor occupies that side.
                    // Chunk-boundary faces are emitted (cross-chunk culling: M2b).
                    if in_bounds(nx)
                        && in_bounds(ny)
                        && in_bounds(nz)
                        && occupies(&chunk.cells[index_of(nx, ny, nz)])
                    {
                        continue;
                    }
                    emit_quad(&mut mesh, x, y, z, voxel_size, face, material_id);
                }
            }
        }
    }

    mesh
}

/// Greedy mesher: like [`mesh_chunk`] (exposed-face culling) but merges
/// coplanar, same-material exposed faces into larger quads — the big vertex /
/// draw-call reduction for large scale. A fully-solid 16³ chunk drops from 1536
/// quads (`mesh_chunk`) to **6** (one merged quad per outer face).
///
/// Winding is derived systematically from the axis triple `(u,v,d)` with
/// `u=(d+1)%3, v=(d+2)%3` so `u×v = +d`; for a single cell it produces the same
/// CCW face cycle as [`mesh_chunk`] (cross-validated in tests), so `mesh_chunk`
/// serves as the reference oracle.
/// The six axis-neighbor chunks of a chunk being meshed, for cross-chunk border
/// face culling. `None` = neighbor not loaded → that boundary face is emitted
/// (conservative). `pos[d]`/`neg[d]` are the +/- neighbor along axis `d`.
#[derive(Default, Clone, Copy)]
pub struct ChunkNeighbors<'a> {
    pub pos: [Option<&'a AuthorityChunk>; 3],
    pub neg: [Option<&'a AuthorityChunk>; 3],
}

impl<'a> ChunkNeighbors<'a> {
    /// Is the cell just across the chunk boundary (direction `(d, sign)`, at the
    /// boundary slice, lateral coords `u,v`) occupied?
    fn occluded_across(&self, d: usize, sign: i32, u: i32, v: i32, size: i32) -> bool {
        let neighbor = if sign > 0 { self.pos[d] } else { self.neg[d] };
        match neighbor {
            Some(chunk) if chunk.chunk_size_in_macro as i32 == size => {
                // +sign neighbor's near face is its s=0 slice; -sign neighbor's
                // far face is its s=size-1 slice.
                let s = if sign > 0 { 0 } else { size - 1 };
                occupies(cell_at(chunk, size, d, s, u, v))
            }
            _ => false,
        }
    }
}

pub fn greedy_mesh_chunk(chunk: &AuthorityChunk, voxel_size: f32) -> ChunkMeshData {
    greedy_mesh_chunk_with_neighbors(chunk, voxel_size, &ChunkNeighbors::default())
}

/// Greedy mesher with cross-chunk border culling: boundary faces are culled
/// when the adjacent loaded chunk occupies the touching cell.
pub fn greedy_mesh_chunk_with_neighbors(
    chunk: &AuthorityChunk,
    voxel_size: f32,
    neighbors: &ChunkNeighbors,
) -> ChunkMeshData {
    let size = chunk.chunk_size_in_macro as i32;
    let mut mesh = ChunkMeshData::default();
    if size <= 0 {
        return mesh;
    }

    // Per face direction: axis d ∈ {0,1,2} and sign ∈ {+1,-1}.
    for d in 0..3usize {
        let u_axis = (d + 1) % 3;
        let v_axis = (d + 2) % 3;
        for &sign in &[1i32, -1i32] {
            // For each slice along d (the cell's d-coordinate).
            for s in 0..size {
                // Build a size×size mask of exposed-face materials in this slice.
                // mask[v * size + u].
                let mut mask: Vec<Option<u32>> = vec![None; (size * size) as usize];
                for v in 0..size {
                    for u in 0..size {
                        let cell = cell_at(chunk, size, d, s, u, v);
                        if !occupies(cell) {
                            continue;
                        }
                        let ns = s + sign;
                        let occluded = if ns >= 0 && ns < size {
                            occupies(cell_at(chunk, size, d, ns, u, v))
                        } else {
                            // Chunk boundary: consult the neighbor chunk.
                            neighbors.occluded_across(d, sign, u, v, size)
                        };
                        if !occluded {
                            mask[(v * size + u) as usize] = Some(cell_material(cell));
                        }
                    }
                }

                // The face plane's d-value: far side (s+1) for +sign, near (s) for -.
                let plane_d = if sign > 0 { s + 1 } else { s };
                greedy_merge(&mut mask, size, |u0, v0, w, h, material_id| {
                    emit_greedy_quad(
                        &mut mesh,
                        voxel_size,
                        d,
                        u_axis,
                        v_axis,
                        sign,
                        plane_d,
                        u0,
                        v0,
                        w,
                        h,
                        material_id,
                    );
                });
            }
        }
    }

    mesh
}

/// Accesses a cell by (axis-d coordinate, u coordinate, v coordinate).
fn cell_at(chunk: &AuthorityChunk, size: i32, d: usize, s: i32, u: i32, v: i32) -> &CellState {
    let u_axis = (d + 1) % 3;
    let v_axis = (d + 2) % 3;
    let mut coord = [0i32; 3];
    coord[d] = s;
    coord[u_axis] = u;
    coord[v_axis] = v;
    let index = coord[0] + coord[1] * size + coord[2] * size * size;
    &chunk.cells[index as usize]
}

/// Greedily merges equal-value rectangles out of a `size×size` mask, calling
/// `emit(u0, v0, w, h, value)` per merged rectangle. Consumes the mask.
fn greedy_merge(
    mask: &mut [Option<u32>],
    size: i32,
    mut emit: impl FnMut(i32, i32, i32, i32, u32),
) {
    let at = |u: i32, v: i32| (v * size + u) as usize;
    for v in 0..size {
        let mut u = 0;
        while u < size {
            match mask[at(u, v)] {
                None => u += 1,
                Some(material_id) => {
                    // Extend width while same material.
                    let mut w = 1;
                    while u + w < size && mask[at(u + w, v)] == Some(material_id) {
                        w += 1;
                    }
                    // Extend height while every cell in the row matches.
                    let mut h = 1;
                    'height: while v + h < size {
                        for k in 0..w {
                            if mask[at(u + k, v + h)] != Some(material_id) {
                                break 'height;
                            }
                        }
                        h += 1;
                    }
                    // Consume the merged rectangle.
                    for dv in 0..h {
                        for du in 0..w {
                            mask[at(u + du, v + dv)] = None;
                        }
                    }
                    emit(u, v, w, h, material_id);
                    u += w;
                }
            }
        }
    }
}

/// Emits one merged greedy quad. Corner order is CCW for the outward normal:
/// `+sign` → P00,P10,P11,P01 (so `u×v = +d`); `-sign` → reversed.
#[allow(clippy::too_many_arguments)]
fn emit_greedy_quad(
    mesh: &mut ChunkMeshData,
    voxel_size: f32,
    d: usize,
    u_axis: usize,
    v_axis: usize,
    sign: i32,
    plane_d: i32,
    u0: i32,
    v0: i32,
    w: i32,
    h: i32,
    material_id: u32,
) {
    let point = |u: i32, v: i32| -> [f32; 3] {
        let mut p = [0f32; 3];
        p[d] = plane_d as f32 * voxel_size;
        p[u_axis] = u as f32 * voxel_size;
        p[v_axis] = v as f32 * voxel_size;
        p
    };
    let (p00, p10, p11, p01) = (
        point(u0, v0),
        point(u0 + w, v0),
        point(u0 + w, v0 + h),
        point(u0, v0 + h),
    );
    let mut normal = [0f32; 3];
    normal[d] = sign as f32;
    // +sign: CCW from outside is P00→P10→P11→P01; -sign reverses.
    let corners = if sign > 0 {
        [p00, p10, p11, p01]
    } else {
        [p00, p01, p11, p10]
    };
    let uvs = [
        [0.0, 0.0],
        [w as f32, 0.0],
        [w as f32, h as f32],
        [0.0, h as f32],
    ];

    let base = mesh.positions.len() as u32;
    for (corner, uv) in corners.iter().zip(uvs.iter()) {
        mesh.positions.push(*corner);
        mesh.normals.push(normal);
        mesh.uvs.push(*uv);
        mesh.material_ids.push(material_id);
    }
    mesh.indices
        .extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
}

fn emit_quad(
    mesh: &mut ChunkMeshData,
    x: i32,
    y: i32,
    z: i32,
    voxel_size: f32,
    face: &Face,
    material_id: u32,
) {
    let base = mesh.positions.len() as u32;
    for (corner, uv) in face.corners.iter().zip(FACE_UVS.iter()) {
        mesh.positions.push([
            (x as f32 + corner[0]) * voxel_size,
            (y as f32 + corner[1]) * voxel_size,
            (z as f32 + corner[2]) * voxel_size,
        ]);
        mesh.normals.push(face.normal);
        mesh.uvs.push(*uv);
        mesh.material_ids.push(material_id);
    }
    mesh.indices
        .extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::wire::NormalBlock;

    const SIZE: usize = 16;

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

    fn empty_chunk() -> AuthorityChunk {
        AuthorityChunk {
            chunk_version: 1,
            chunk_size_in_macro: SIZE as u8,
            cells: vec![CellState::Empty; SIZE * SIZE * SIZE],
        }
    }

    fn idx(x: usize, y: usize, z: usize) -> usize {
        x + y * SIZE + z * SIZE * SIZE
    }

    #[test]
    fn empty_chunk_meshes_to_nothing() {
        let mesh = mesh_chunk(&empty_chunk(), 1.0);
        assert!(mesh.is_empty());
        assert_eq!(mesh.quad_count(), 0);
    }

    #[test]
    fn single_solid_cell_emits_six_faces() {
        let mut chunk = empty_chunk();
        chunk.cells[idx(8, 8, 8)] = solid(3);
        let mesh = mesh_chunk(&chunk, 1.0);
        // 6 faces = 6 quads = 24 verts = 36 indices, all material 3.
        assert_eq!(mesh.quad_count(), 6);
        assert_eq!(mesh.vertex_count(), 24);
        assert_eq!(mesh.indices.len(), 36);
        assert!(mesh.material_ids.iter().all(|&m| m == 3));
    }

    #[test]
    fn adjacent_solids_cull_the_shared_interior_faces() {
        let mut chunk = empty_chunk();
        chunk.cells[idx(8, 8, 8)] = solid(1);
        chunk.cells[idx(9, 8, 8)] = solid(1);
        // Two cubes sharing one face: 12 faces total - 2 interior = 10 exposed.
        let mesh = mesh_chunk(&chunk, 1.0);
        assert_eq!(mesh.quad_count(), 10);
    }

    #[test]
    fn boundary_faces_are_emitted_without_neighbor_info() {
        // A cell at the chunk corner has out-of-chunk neighbors on 3 sides;
        // those faces are still emitted (cross-chunk culling is M2b).
        let mut chunk = empty_chunk();
        chunk.cells[idx(0, 0, 0)] = solid(2);
        let mesh = mesh_chunk(&chunk, 1.0);
        assert_eq!(mesh.quad_count(), 6);
    }

    #[test]
    fn voxel_size_scales_positions() {
        let mut chunk = empty_chunk();
        chunk.cells[idx(0, 0, 0)] = solid(1);
        let mesh = mesh_chunk(&chunk, 100.0);
        // The +X face has corners at x=100 (1 * voxel_size).
        assert!(mesh.positions.iter().any(|p| (p[0] - 100.0).abs() < 1e-3));
        assert!(mesh.positions.iter().all(|p| p[0] <= 100.0 + 1e-3));
    }

    #[test]
    fn fully_solid_chunk_only_meshes_its_outer_shell() {
        // A completely filled chunk: all interior faces culled, only the 6 outer
        // faces of the size³ block remain = 6 * size² quads.
        let chunk = AuthorityChunk {
            chunk_version: 1,
            chunk_size_in_macro: SIZE as u8,
            cells: vec![solid(5); SIZE * SIZE * SIZE],
        };
        let mesh = mesh_chunk(&chunk, 1.0);
        assert_eq!(mesh.quad_count(), 6 * SIZE * SIZE);
    }

    // ── Greedy mesher (cross-validated against the exposed-face oracle) ──

    fn total_area(mesh: &ChunkMeshData) -> f32 {
        fn sub(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
            [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
        }
        fn cross(u: [f32; 3], v: [f32; 3]) -> [f32; 3] {
            [
                u[1] * v[2] - u[2] * v[1],
                u[2] * v[0] - u[0] * v[2],
                u[0] * v[1] - u[1] * v[0],
            ]
        }
        fn len(v: [f32; 3]) -> f32 {
            (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt()
        }
        let mut area = 0.0;
        for t in mesh.indices.chunks(3) {
            let a = mesh.positions[t[0] as usize];
            let b = mesh.positions[t[1] as usize];
            let c = mesh.positions[t[2] as usize];
            area += 0.5 * len(cross(sub(b, a), sub(c, a)));
        }
        area
    }

    #[test]
    fn greedy_fully_solid_chunk_is_six_quads() {
        // The headline scale win: a full 16³ chunk → 6 merged quads (one per
        // outer face) instead of 6*16²=1536.
        let chunk = AuthorityChunk {
            chunk_version: 1,
            chunk_size_in_macro: SIZE as u8,
            cells: vec![solid(5); SIZE * SIZE * SIZE],
        };
        let greedy = greedy_mesh_chunk(&chunk, 1.0);
        assert_eq!(greedy.quad_count(), 6);
        // Same total surface area as the exposed-face oracle (6 * size²).
        let exposed = mesh_chunk(&chunk, 1.0);
        assert!((total_area(&greedy) - exposed.quad_count() as f32).abs() < 1e-2);
    }

    #[test]
    fn greedy_single_cell_matches_exposed_face() {
        let mut chunk = empty_chunk();
        chunk.cells[idx(8, 8, 8)] = solid(3);
        let greedy = greedy_mesh_chunk(&chunk, 1.0);
        let exposed = mesh_chunk(&chunk, 1.0);
        // Can't merge a lone cell → 6 quads, same coverage as exposed-face.
        assert_eq!(greedy.quad_count(), 6);
        assert_eq!(greedy.quad_count(), exposed.quad_count());
        assert!((total_area(&greedy) - total_area(&exposed)).abs() < 1e-3);
        assert!(greedy.material_ids.iter().all(|&m| m == 3));
    }

    #[test]
    fn greedy_merges_a_flat_floor_and_never_exceeds_exposed_face() {
        // A full y=0 layer: top + bottom faces each merge to 1 big quad.
        let mut chunk = empty_chunk();
        for z in 0..SIZE {
            for x in 0..SIZE {
                chunk.cells[idx(x, 0, z)] = solid(2);
            }
        }
        let greedy = greedy_mesh_chunk(&chunk, 1.0);
        let exposed = mesh_chunk(&chunk, 1.0);
        assert!(greedy.quad_count() <= exposed.quad_count());
        assert!(
            greedy.quad_count() < exposed.quad_count(),
            "greedy must merge"
        );
        // Identical covered surface area as the oracle.
        assert!((total_area(&greedy) - total_area(&exposed)).abs() < 1e-2);
    }

    #[test]
    fn greedy_empty_chunk_is_empty() {
        assert!(greedy_mesh_chunk(&empty_chunk(), 1.0).is_empty());
    }

    fn full_chunk(material: u16) -> AuthorityChunk {
        AuthorityChunk {
            chunk_version: 1,
            chunk_size_in_macro: SIZE as u8,
            cells: vec![solid(material); SIZE * SIZE * SIZE],
        }
    }

    #[test]
    fn greedy_culls_boundary_face_against_occupied_neighbor() {
        // Fully solid chunk with a fully solid +X neighbor: the +X boundary
        // shell face is culled (axis d=0, sign=+) → 5 outer quads, not 6.
        let chunk = full_chunk(2);
        let pos_x = full_chunk(2);
        let neighbors = ChunkNeighbors {
            pos: [Some(&pos_x), None, None],
            neg: [None, None, None],
        };
        let mesh = greedy_mesh_chunk_with_neighbors(&chunk, 1.0, &neighbors);
        assert_eq!(mesh.quad_count(), 5);
    }

    #[test]
    fn greedy_keeps_boundary_face_against_empty_or_absent_neighbor() {
        let chunk = full_chunk(2);
        let empty = empty_chunk();
        // Empty neighbor on +X, nothing elsewhere → no boundary culled.
        let neighbors = ChunkNeighbors {
            pos: [Some(&empty), None, None],
            neg: [None, None, None],
        };
        assert_eq!(
            greedy_mesh_chunk_with_neighbors(&chunk, 1.0, &neighbors).quad_count(),
            6
        );
        // All-absent neighbors == plain greedy_mesh_chunk.
        assert_eq!(greedy_mesh_chunk(&chunk, 1.0).quad_count(), 6);
    }

    #[test]
    fn greedy_culls_all_six_boundaries_when_fully_surrounded() {
        let chunk = full_chunk(2);
        let n = full_chunk(2);
        let neighbors = ChunkNeighbors {
            pos: [Some(&n), Some(&n), Some(&n)],
            neg: [Some(&n), Some(&n), Some(&n)],
        };
        // Surrounded on all sides → no exposed faces at all.
        assert!(greedy_mesh_chunk_with_neighbors(&chunk, 1.0, &neighbors).is_empty());
    }
}
