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
}
