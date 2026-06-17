//! Surface-element decal mesher (形态轨 C1): turns an [`AuthorityChunk`]'s
//! `surface_elements` (wire section 0x08) into decal quad geometry — the
//! SurfaceDecal render sub-layer, parallel to the volumetric ChunkMesh layer.
//!
//! Design (client implementation + verification plan):
//!   * Surface elements are **zero-volume** — they never enter the greedy voxel
//!     mesher and never affect occupancy/adjacency. Each is its own quad bound
//!     to one macro face.
//!   * The quad sits on the host macro face, pushed out by a small ε along the
//!     face normal to avoid z-fighting with the host block's own face.
//!   * `hide_when_neighbor_occupied` (the terrain-bypass invariant, mirrored
//!     from the server `SurfaceCatalog` / `TagPhysics`): a decal whose covered
//!     face is occluded by an occupied neighbor is **culled at generation time**
//!     (no quad emitted), not hidden at render time. `always_visible` types
//!     (torch / lever fixtures) always emit.
//!
//! Pure data (no Bevy): unit-testable with the [`ChunkMeshData`] Layer-1
//! geometry assertions; the Bevy adapter spawns the result as a mesh entity.

use crate::voxel::authority::{AuthorityChunk, CellState};
use crate::voxel::mesher::ChunkMeshData;

/// Small fraction of a cell to push the decal off the host face (z-fight guard).
const DECAL_OFFSET_FRACTION: f32 = 0.01;

/// Client-side visibility policy mirror of the server `SurfaceCatalog`
/// (append-only ids). The wire carries only `surface_type_id`; the policy
/// (whether a covered face hides) is shared knowledge, like material→color.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SurfaceVisibility {
    /// Decal is culled when the covered face is occluded by an occupied neighbor.
    HideWhenNeighborOccupied,
    /// Decal always renders (fixtures: torch / lever).
    AlwaysVisible,
}

/// Maps a server surface_type_id to its visibility policy. Mirrors
/// `SceneServer.Voxel.SurfaceCatalog` (rust_decal=1 / frost=2 / scorch=3 =
/// passive conditions → hide; torch=4 / lever=5 = fixtures → always visible).
/// Unknown (future) types default to always-visible so they are never silently
/// dropped (forward-compat).
pub fn surface_type_visibility(surface_type_id: u16) -> SurfaceVisibility {
    match surface_type_id {
        // rust_decal=1 / frost=2 / scorch=3 — passive conditions, hide when occluded.
        1..=3 => SurfaceVisibility::HideWhenNeighborOccupied,
        _ => SurfaceVisibility::AlwaysVisible,
    }
}

/// Per-face geometry indexed by the server face ordinal
/// (x_neg=0, x_pos=1, y_neg=2, y_pos=3, z_neg=4, z_pos=5). `delta` is the
/// neighbor cell offset (occlusion test); `normal` is the outward face normal;
/// `corners` are the unit-cube face corners CCW viewed from outside (matching
/// the voxel mesher's winding so decals face the same way).
struct FaceGeom {
    delta: [i32; 3],
    normal: [f32; 3],
    corners: [[f32; 3]; 4],
}

const FACE_GEOM: [FaceGeom; 6] = [
    // 0: x_neg (-X)
    FaceGeom {
        delta: [-1, 0, 0],
        normal: [-1.0, 0.0, 0.0],
        corners: [
            [0.0, 0.0, 0.0],
            [0.0, 0.0, 1.0],
            [0.0, 1.0, 1.0],
            [0.0, 1.0, 0.0],
        ],
    },
    // 1: x_pos (+X)
    FaceGeom {
        delta: [1, 0, 0],
        normal: [1.0, 0.0, 0.0],
        corners: [
            [1.0, 0.0, 1.0],
            [1.0, 0.0, 0.0],
            [1.0, 1.0, 0.0],
            [1.0, 1.0, 1.0],
        ],
    },
    // 2: y_neg (-Y)
    FaceGeom {
        delta: [0, -1, 0],
        normal: [0.0, -1.0, 0.0],
        corners: [
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [1.0, 0.0, 1.0],
            [0.0, 0.0, 1.0],
        ],
    },
    // 3: y_pos (+Y)
    FaceGeom {
        delta: [0, 1, 0],
        normal: [0.0, 1.0, 0.0],
        corners: [
            [0.0, 1.0, 1.0],
            [1.0, 1.0, 1.0],
            [1.0, 1.0, 0.0],
            [0.0, 1.0, 0.0],
        ],
    },
    // 4: z_neg (-Z)
    FaceGeom {
        delta: [0, 0, -1],
        normal: [0.0, 0.0, -1.0],
        corners: [
            [1.0, 0.0, 0.0],
            [0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0],
            [1.0, 1.0, 0.0],
        ],
    },
    // 5: z_pos (+Z)
    FaceGeom {
        delta: [0, 0, 1],
        normal: [0.0, 0.0, 1.0],
        corners: [
            [0.0, 0.0, 1.0],
            [1.0, 0.0, 1.0],
            [1.0, 1.0, 1.0],
            [0.0, 1.0, 1.0],
        ],
    },
];

const FACE_UVS: [[f32; 2]; 4] = [[0.0, 1.0], [1.0, 1.0], [1.0, 0.0], [0.0, 0.0]];

fn is_occupied(cell: &CellState) -> bool {
    !matches!(cell, CellState::Empty)
}

/// Builds the decal quad mesh for a chunk's surface elements. `material_ids`
/// carries each decal's `surface_type_id` (the Bevy adapter maps type → visual).
pub fn surface_decal_mesh(chunk: &AuthorityChunk, voxel_size: f32) -> ChunkMeshData {
    let size = chunk.chunk_size_in_macro as i32;
    let mut mesh = ChunkMeshData::default();
    if size <= 0 {
        return mesh;
    }

    for element in &chunk.surface_elements {
        let ordinal = element.face as usize;
        let Some(face) = FACE_GEOM.get(ordinal) else {
            continue; // unknown face ordinal — skip (forward-compat)
        };

        let (mx, my, mz) = macro_coord(element.macro_index, size);

        if surface_type_visibility(element.surface_type_id)
            == SurfaceVisibility::HideWhenNeighborOccupied
            && neighbor_occupied(chunk, mx, my, mz, face.delta, size)
        {
            continue; // covered face → cull at generation time
        }

        emit_decal_quad(
            &mut mesh,
            mx,
            my,
            mz,
            voxel_size,
            face,
            element.surface_type_id,
        );
    }

    mesh
}

fn macro_coord(macro_index: u16, size: i32) -> (i32, i32, i32) {
    let idx = macro_index as i32;
    let s = size;
    let x = idx % s;
    let y = (idx / s) % s;
    let z = idx / (s * s);
    (x, y, z)
}

fn neighbor_occupied(
    chunk: &AuthorityChunk,
    mx: i32,
    my: i32,
    mz: i32,
    delta: [i32; 3],
    size: i32,
) -> bool {
    let (nx, ny, nz) = (mx + delta[0], my + delta[1], mz + delta[2]);
    if nx < 0 || ny < 0 || nz < 0 || nx >= size || ny >= size || nz >= size {
        // Out of chunk: no in-chunk neighbor info (cross-chunk culling is later).
        return false;
    }
    let idx = (nx + ny * size + nz * size * size) as usize;
    chunk.cell(idx).map(is_occupied).unwrap_or(false)
}

fn emit_decal_quad(
    mesh: &mut ChunkMeshData,
    mx: i32,
    my: i32,
    mz: i32,
    voxel_size: f32,
    face: &FaceGeom,
    surface_type_id: u16,
) {
    let eps = voxel_size * DECAL_OFFSET_FRACTION;
    let base = mesh.positions.len() as u32;
    for (corner, uv) in face.corners.iter().zip(FACE_UVS.iter()) {
        mesh.positions.push([
            (mx as f32 + corner[0]) * voxel_size + face.normal[0] * eps,
            (my as f32 + corner[1]) * voxel_size + face.normal[1] * eps,
            (mz as f32 + corner[2]) * voxel_size + face.normal[2] * eps,
        ]);
        mesh.normals.push(face.normal);
        mesh.uvs.push(*uv);
        mesh.material_ids.push(surface_type_id as u32);
    }
    mesh.indices
        .extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::wire::{NormalBlock, SurfaceElement};

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

    fn idx(x: usize, y: usize, z: usize) -> usize {
        x + y * SIZE + z * SIZE * SIZE
    }

    fn chunk_with(
        cells_setup: impl FnOnce(&mut Vec<CellState>),
        elements: Vec<SurfaceElement>,
    ) -> AuthorityChunk {
        let mut cells = vec![CellState::Empty; SIZE * SIZE * SIZE];
        cells_setup(&mut cells);
        AuthorityChunk {
            chunk_version: 1,
            chunk_size_in_macro: SIZE as u8,
            cells,
            surface_elements: elements,
        }
    }

    fn element(macro_index: u16, face: u8, surface_type_id: u16) -> SurfaceElement {
        SurfaceElement {
            macro_index,
            face,
            surface_type_id,
            attribute_set_ref: 0,
            tag_set_ref: 0,
            owner_actor_id: 0,
        }
    }

    #[test]
    fn empty_surface_elements_mesh_to_nothing() {
        let chunk = chunk_with(|_| {}, vec![]);
        assert!(surface_decal_mesh(&chunk, 1.0).is_empty());
    }

    #[test]
    fn torch_emits_one_quad_on_its_face_with_correct_normal_and_offset() {
        // Torch (type 4, always_visible) on the +X face (ordinal 1) of a solid
        // host at (5,5,5), neighbor +X empty.
        let host = idx(5, 5, 5);
        let chunk = chunk_with(|c| c[host] = solid(9), vec![element(host as u16, 1, 4)]);
        let mesh = surface_decal_mesh(&chunk, 1.0);

        let s = mesh.summary();
        assert_eq!(s.quad_count, 1);
        assert!(s.structural_ok);
        // material id == surface_type_id (torch=4).
        assert_eq!(*s.area_by_material.keys().next().unwrap(), 4u32);
        // All vertices have normal +X.
        assert!(mesh.normals.iter().all(|n| *n == [1.0, 0.0, 0.0]));
        // Quad sits just outside the host +X face (x = 6 + eps).
        assert!(mesh.positions.iter().all(|p| (p[0] - 6.01).abs() < 1e-4));
    }

    #[test]
    fn rust_decal_hides_when_neighbor_occupied() {
        // rust_decal (type 1, hide_when_neighbor_occupied) on +X face of host
        // (5,5,5) whose +X neighbor (6,5,5) is occupied → culled (no quad).
        let host = idx(5, 5, 5);
        let occluded = chunk_with(
            |c| {
                c[host] = solid(5);
                c[idx(6, 5, 5)] = solid(5);
            },
            vec![element(host as u16, 1, 1)],
        );
        assert!(surface_decal_mesh(&occluded, 1.0).is_empty());

        // Same decal, neighbor empty → 1 quad emitted.
        let exposed = chunk_with(|c| c[host] = solid(5), vec![element(host as u16, 1, 1)]);
        assert_eq!(surface_decal_mesh(&exposed, 1.0).quad_count(), 1);
    }

    #[test]
    fn torch_stays_visible_even_when_neighbor_occupied() {
        // always_visible fixture is NOT culled by an occupied neighbor.
        let host = idx(5, 5, 5);
        let chunk = chunk_with(
            |c| {
                c[host] = solid(9);
                c[idx(6, 5, 5)] = solid(9);
            },
            vec![element(host as u16, 1, 4)],
        );
        assert_eq!(surface_decal_mesh(&chunk, 1.0).quad_count(), 1);
    }

    #[test]
    fn multiple_elements_each_emit_a_quad_with_axis_normals() {
        let host = idx(5, 5, 5);
        let chunk = chunk_with(
            |c| c[host] = solid(9),
            vec![
                element(host as u16, 0, 4), // x_neg torch
                element(host as u16, 3, 4), // y_pos torch
                element(host as u16, 5, 2), // z_pos frost (neighbor empty → visible)
            ],
        );
        let mesh = surface_decal_mesh(&chunk, 1.0);
        assert_eq!(mesh.quad_count(), 3);
        assert!(mesh.normals_are_axis_unit());
        assert!(mesh.structural_invariants_hold());
    }

    #[test]
    fn voxel_size_scales_decal_positions() {
        let host = idx(0, 0, 0);
        let chunk = chunk_with(|c| c[host] = solid(9), vec![element(host as u16, 1, 4)]);
        let mesh = surface_decal_mesh(&chunk, 100.0);
        // +X face at x = 100 + 100*0.01 = 101.
        assert!(mesh.positions.iter().all(|p| (p[0] - 101.0).abs() < 1e-2));
    }
}
