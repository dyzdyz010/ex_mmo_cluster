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
use crate::voxel::wire::RefinedCell;
use std::collections::BTreeMap;

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

/// 顺序无关的几何摘要(客户端实现+验证决策稿 Layer-1/2)。
///
/// 用户看不到画面 → 渲染正确性靠对"将要绘制的几何"做可自动断言的摘要来证。本结构是:
/// (a) Layer-1 CPU 几何断言的载体;(b) Layer-2 跨语言 mesher parity 的 canonical 形态(顺序无关:
/// 面数/总面积/每材质面积/AABB,避开 bevy↔web 角点顺序不同的陷阱);(c) `mesh dump` 调试命令的输出。
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct MeshSummary {
    pub quad_count: usize,
    pub vertex_count: usize,
    pub total_area: f32,
    /// 每 material_id 的三角面积之和(BTreeMap → 稳定有序,可直接 diff)。
    pub area_by_material: BTreeMap<u32, f32>,
    pub aabb_min: Option<[f32; 3]>,
    pub aabb_max: Option<[f32; 3]>,
    /// 结构不变量是否全部成立(等长/索引合法/无退化三角/法线为轴单位向量)。
    pub structural_ok: bool,
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

    /// Appends another mesh's geometry, offsetting its indices. Used to merge
    /// per-refined-cell micro meshes into a chunk's macro mesh (C4).
    pub fn append(&mut self, other: ChunkMeshData) {
        let base = self.positions.len() as u32;
        self.positions.extend(other.positions);
        self.normals.extend(other.normals);
        self.uvs.extend(other.uvs);
        self.material_ids.extend(other.material_ids);
        self.indices
            .extend(other.indices.into_iter().map(|i| i + base));
    }

    /// 所有顶点的轴对齐包围盒(min,max);空 mesh 返回 None。抓 voxel_size 缩放/chunk 平移回归
    /// (几何悄悄移出屏幕)。
    pub fn aabb(&self) -> Option<([f32; 3], [f32; 3])> {
        let first = self.positions.first()?;
        let mut min = *first;
        let mut max = *first;
        for p in &self.positions {
            for a in 0..3 {
                if p[a] < min[a] {
                    min[a] = p[a];
                }
                if p[a] > max[a] {
                    max[a] = p[a];
                }
            }
        }
        Some((min, max))
    }

    /// 三角化总表面积。
    pub fn total_area(&self) -> f32 {
        self.triangles().map(|(a, b, c)| tri_area(a, b, c)).sum()
    }

    /// 按 material_id 分组的三角面积(每三角材质 = 其首顶点的 material_id)。抓材质渗色/错色。
    pub fn area_by_material(&self) -> BTreeMap<u32, f32> {
        let mut by = BTreeMap::new();
        for (t, (a, b, c)) in self.index_triangles().zip(self.triangles()) {
            let material = self.material_ids[t[0] as usize];
            *by.entry(material).or_insert(0.0) += tri_area(a, b, c);
        }
        by
    }

    /// 每条法线是否为轴单位向量(恰一个轴为 ±1、其余 0)。绕序/法线错会让面被背面剔除"消失",
    /// 此断言把"法线方向是 6 轴之一"这一渲染前提变成可测。
    pub fn normals_are_axis_unit(&self) -> bool {
        self.normals.iter().all(|n| {
            let nonzero = n.iter().filter(|c| c.abs() > 1e-4).count();
            nonzero == 1 && n.iter().any(|c| (c.abs() - 1.0).abs() < 1e-4)
        })
    }

    /// 结构不变量:各属性等长、索引为三角列表且越界检查、无退化(零面积)三角、法线为轴单位向量。
    pub fn structural_invariants_hold(&self) -> bool {
        let n = self.positions.len();
        let lengths_ok =
            self.normals.len() == n && self.uvs.len() == n && self.material_ids.len() == n;
        let indices_ok =
            self.indices.len().is_multiple_of(3) && self.indices.iter().all(|&i| (i as usize) < n);

        if !lengths_ok || !indices_ok || !self.normals_are_axis_unit() {
            return false;
        }

        self.triangles().all(|(a, b, c)| tri_area(a, b, c) > 1e-9)
    }

    /// 顺序无关的几何摘要(Layer-1 断言 / Layer-2 parity / mesh dump 共用)。
    pub fn summary(&self) -> MeshSummary {
        let (aabb_min, aabb_max) = match self.aabb() {
            Some((mn, mx)) => (Some(mn), Some(mx)),
            None => (None, None),
        };

        MeshSummary {
            quad_count: self.quad_count(),
            vertex_count: self.vertex_count(),
            total_area: self.total_area(),
            area_by_material: self.area_by_material(),
            aabb_min,
            aabb_max,
            structural_ok: self.structural_invariants_hold(),
        }
    }

    fn index_triangles(&self) -> impl Iterator<Item = [u32; 3]> + '_ {
        self.indices.chunks_exact(3).map(|t| [t[0], t[1], t[2]])
    }

    fn triangles(&self) -> impl Iterator<Item = ([f32; 3], [f32; 3], [f32; 3])> + '_ {
        self.index_triangles().map(move |t| {
            (
                self.positions[t[0] as usize],
                self.positions[t[1] as usize],
                self.positions[t[2] as usize],
            )
        })
    }
}

fn tri_area(a: [f32; 3], b: [f32; 3], c: [f32; 3]) -> f32 {
    let ab = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
    let ac = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
    let cross = [
        ab[1] * ac[2] - ab[2] * ac[1],
        ab[2] * ac[0] - ab[0] * ac[2],
        ab[0] * ac[1] - ab[1] * ac[0],
    ];
    0.5 * (cross[0] * cross[0] + cross[1] * cross[1] + cross[2] * cross[2]).sqrt()
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

/// Meshes one chunk via exposed-face culling. `voxel_size` is the render-unit
/// size of one macro cell.
pub fn mesh_chunk(chunk: &AuthorityChunk, voxel_size: f32) -> ChunkMeshData {
    let size = chunk.chunk_size_in_macro as i32;
    let mut mesh = ChunkMeshData::default();
    // Defense-in-depth: never index `cells` by size^3 unless they actually agree
    // (the ingest layer already rejects mismatches, but the mesher is public API).
    if size <= 0 || chunk.cells.len() != (size as usize).pow(3) {
        return mesh;
    }

    let index_of = |x: i32, y: i32, z: i32| -> usize { (x + y * size + z * size * size) as usize };
    let in_bounds = |v: i32| v >= 0 && v < size;

    for z in 0..size {
        for y in 0..size {
            for x in 0..size {
                // Only SOLID cells emit a macro cube face. Refined cells still
                // occlude their neighbors (via `occupies` in the neighbor check
                // below) but render their actual sub-voxel shape via
                // `refined_micro_mesh` (C4), so emitting a macro cube here too
                // would double-render them.
                let CellState::Solid(block) = &chunk.cells[index_of(x, y, z)] else {
                    continue;
                };
                let material_id = block.material_id as u32;

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
            // Require the neighbor's cells to actually be size^3 too, so `cell_at`
            // (which indexes by size^3) can't panic on a short/mismatched neighbor.
            Some(chunk)
                if chunk.chunk_size_in_macro as i32 == size
                    && chunk.cells.len() == (size as usize).pow(3) =>
            {
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
    // Defense-in-depth (see `mesh_chunk`): bail unless cells length == size^3.
    if size <= 0 || chunk.cells.len() != (size as usize).pow(3) {
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
                        // Only solid cells contribute a macro exposed face;
                        // refined cells occlude (the across-check above) but are
                        // micro-meshed separately (C4), so no macro face here.
                        if !occluded && let CellState::Solid(block) = cell {
                            mask[(v * size + u) as usize] = Some(block.material_id as u32);
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

/// The full render mesh for a chunk (C4): greedy macro faces (solid cells, with
/// cross-chunk culling) **plus** a per-refined-cell micro mesh (sub-voxel shape).
/// Refined cells occlude their neighbors in the macro pass but emit no macro
/// face there; here each is micro-meshed at its macro origin and merged in.
pub fn chunk_render_mesh(
    chunk: &AuthorityChunk,
    voxel_size: f32,
    neighbors: &ChunkNeighbors,
) -> ChunkMeshData {
    let mut data = greedy_mesh_chunk_with_neighbors(chunk, voxel_size, neighbors);

    let size = chunk.chunk_size_in_macro as i32;
    if size > 0 && chunk.cells.len() == (size as usize).pow(3) {
        for (i, cell) in chunk.cells.iter().enumerate() {
            if let CellState::Refined(refined) = cell {
                let i = i as i32;
                let (mx, my, mz) = (i % size, (i / size) % size, i / (size * size));
                let origin = [
                    mx as f32 * voxel_size,
                    my as f32 * voxel_size,
                    mz as f32 * voxel_size,
                ];
                data.append(refined_micro_mesh(refined, origin, voxel_size));
            }
        }
    }

    data
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

/// Emits the 6 faces of an axis-aligned cube at `[min, min+size]` with the given
/// material id. Reuses the canonical [`FACES`] table (winding/normals) so callers
/// (e.g. the FieldView heat-marker overlay, C3) don't re-derive cube geometry.
pub fn push_cube(mesh: &mut ChunkMeshData, min: [f32; 3], size: f32, material_id: u32) {
    for face in &FACES {
        let base = mesh.positions.len() as u32;
        for (corner, uv) in face.corners.iter().zip(FACE_UVS.iter()) {
            mesh.positions.push([
                min[0] + corner[0] * size,
                min[1] + corner[1] * size,
                min[2] + corner[2] * size,
            ]);
            mesh.normals.push(face.normal);
            mesh.uvs.push(*uv);
            mesh.material_ids.push(material_id);
        }
        mesh.indices
            .extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
    }
}

// ── Micro (sub-voxel) meshing of one refined cell (M2b / C4) ──
//
// A refined macro cell carries an 8³ = 512-bit occupancy mask + material layers.
// `refined_micro_mesh` meshes those micro slots at micro resolution
// (exposed-face culling within the cell), so refined cells render their actual
// sub-voxel shape + per-slot material instead of the single first-layer macro
// cube approximation (`cell_material`). Pure data → Layer-1 geometry assertable.
//
// Micro slot indexing mirrors the server (`Types.micro_index`): index =
// mx + my*8 + mz*64; bit = `1 << (index % 64)` in mask word `index / 64`.

/// Micro resolution per macro cell (8³ = 512 micro slots).
pub const MICRO_RES: i32 = 8;

fn micro_bit_set(mask: &[u64; 8], mx: i32, my: i32, mz: i32) -> bool {
    if !(0..MICRO_RES).contains(&mx)
        || !(0..MICRO_RES).contains(&my)
        || !(0..MICRO_RES).contains(&mz)
    {
        return false;
    }
    let i = (mx + my * MICRO_RES + mz * MICRO_RES * MICRO_RES) as usize;
    mask[i / 64] & (1u64 << (i % 64)) != 0
}

fn micro_occupied(refined: &RefinedCell, mx: i32, my: i32, mz: i32) -> bool {
    micro_bit_set(&refined.occupancy_words, mx, my, mz)
}

/// Material of an occupied micro slot = the first layer whose mask owns it
/// (per-slot material, vs the macro `cell_material` first-layer approximation).
///
/// Relies on the server invariant `occupancy == union(layer masks)` (built in
/// `Storage.build_layers_from_pairs`, maintained by `remove_micro_slot`): every
/// occupied micro slot is owned by some layer. The bevy decoder does NOT
/// re-validate this, so if a future delta / object-cover path ever lets
/// occupancy outrun the layers, this would silently paint the unknown-material
/// fallback (material 0 → magenta). We `debug_assert` to surface that loudly in
/// tests/CI rather than shipping a wrong color.
fn micro_material(refined: &RefinedCell, mx: i32, my: i32, mz: i32) -> u32 {
    refined
        .layers
        .iter()
        .find(|layer| micro_bit_set(&layer.mask_words, mx, my, mz))
        .map(|layer| layer.material_id as u32)
        .unwrap_or_else(|| {
            debug_assert!(
                false,
                "refined micro slot ({mx},{my},{mz}) occupied but owned by no layer \
                 (occupancy outran layer masks — server invariant violated)"
            );
            0
        })
}

/// Meshes one refined cell's 8³ micro occupancy at micro resolution, placed at
/// `macro_origin` (the macro cell's render-space min corner). `voxel_size` is
/// the macro cell size; each micro voxel is `voxel_size / 8`. Interior micro
/// faces (between two occupied micro slots) are culled; cell-boundary micro
/// faces are emitted (cross-macro micro culling is a later step, like the macro
/// mesher's chunk-boundary behaviour).
pub fn refined_micro_mesh(
    refined: &RefinedCell,
    macro_origin: [f32; 3],
    voxel_size: f32,
) -> ChunkMeshData {
    let micro = voxel_size / MICRO_RES as f32;
    let mut mesh = ChunkMeshData::default();

    for mz in 0..MICRO_RES {
        for my in 0..MICRO_RES {
            for mx in 0..MICRO_RES {
                if !micro_occupied(refined, mx, my, mz) {
                    continue;
                }
                let material = micro_material(refined, mx, my, mz);
                for face in &FACES {
                    let (nx, ny, nz) = (mx + face.delta[0], my + face.delta[1], mz + face.delta[2]);
                    if micro_occupied(refined, nx, ny, nz) {
                        continue; // interior micro face → culled
                    }
                    emit_micro_quad(&mut mesh, macro_origin, mx, my, mz, micro, face, material);
                }
            }
        }
    }

    mesh
}

#[allow(clippy::too_many_arguments)]
fn emit_micro_quad(
    mesh: &mut ChunkMeshData,
    origin: [f32; 3],
    mx: i32,
    my: i32,
    mz: i32,
    micro: f32,
    face: &Face,
    material_id: u32,
) {
    let base = mesh.positions.len() as u32;
    for (corner, uv) in face.corners.iter().zip(FACE_UVS.iter()) {
        mesh.positions.push([
            origin[0] + (mx as f32 + corner[0]) * micro,
            origin[1] + (my as f32 + corner[1]) * micro,
            origin[2] + (mz as f32 + corner[2]) * micro,
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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

    // ── Layer-1 几何断言(决策稿命门:无人眼时把"将要绘制的几何"逐值/不变量断言) ──

    fn approx(a: f32, b: f32) -> bool {
        (a - b).abs() < 1e-3
    }

    #[test]
    fn single_cell_summary_is_exact() {
        // 单实心格:精确摘要——6 面、24 顶点、总面积 6.0(6 个单位面)、面积全归该材质、
        // AABB 恰为该格单位立方、结构不变量成立。这把"渲染出一个正确立方"变成逐值可断言。
        let mut chunk = empty_chunk();
        chunk.cells[idx(8, 8, 8)] = solid(3);
        let s = mesh_chunk(&chunk, 1.0).summary();

        assert_eq!(s.quad_count, 6);
        assert_eq!(s.vertex_count, 24);
        assert!(approx(s.total_area, 6.0));
        assert_eq!(s.area_by_material.len(), 1);
        assert!(approx(*s.area_by_material.get(&3).unwrap(), 6.0));
        assert_eq!(s.aabb_min, Some([8.0, 8.0, 8.0]));
        assert_eq!(s.aabb_max, Some([9.0, 9.0, 9.0]));
        assert!(s.structural_ok);
    }

    #[test]
    fn full_chunk_summary_shell_area_and_aabb() {
        // 全实心 chunk:外壳面积 = 6·size²、AABB = 整 chunk、单一材质、结构成立。
        let s = mesh_chunk(&full_chunk(5), 1.0).summary();
        assert!(approx(s.total_area, 6.0 * (SIZE * SIZE) as f32));
        assert!(approx(
            *s.area_by_material.get(&5).unwrap(),
            6.0 * (SIZE * SIZE) as f32
        ));
        assert_eq!(s.aabb_min, Some([0.0, 0.0, 0.0]));
        assert_eq!(s.aabb_max, Some([SIZE as f32, SIZE as f32, SIZE as f32]));
        assert!(s.structural_ok);
    }

    #[test]
    fn full_chunk_faces_all_lie_on_boundary_planes() {
        // 水密性/面剔除正确的人眼替代:全实心 chunk 的每个顶点必在某外壳平面(coord==0 或 ==size),
        // 即没有内部面泄漏。这是"穿帮的内部面"一眼可见错误的可测版。
        let mesh = mesh_chunk(&full_chunk(5), 1.0);
        let size = SIZE as f32;
        assert!(!mesh.is_empty());
        for p in &mesh.positions {
            let on_shell = p.iter().any(|&c| approx(c, 0.0) || approx(c, size));
            assert!(on_shell, "顶点 {p:?} 不在外壳平面 → 内部面泄漏(面剔除错误)");
        }
    }

    #[test]
    fn interior_cell_surrounded_emits_no_faces() {
        // 被实心完全包围的内部格:零暴露面(面剔除把它全剔)。
        let mut chunk = empty_chunk();
        for (dx, dy, dz) in [
            (0, 0, 0),
            (1, 0, 0),
            (-1i32, 0, 0),
            (0, 1, 0),
            (0, -1, 0),
            (0, 0, 1),
            (0, 0, -1),
        ] {
            let (x, y, z) = ((8 + dx) as usize, (8 + dy) as usize, (8 + dz) as usize);
            chunk.cells[idx(x, y, z)] = solid(1);
        }
        // 中心格(8,8,8)对外的 6 个面都被邻居挡;整体只剩外圈 6 个邻居各自的暴露面。
        // 断言中心格不贡献任何"朝中心"的内部面:总面积 = 6 邻居 × 5 外露面(各被中心挡 1 面)= 30。
        let s = mesh_chunk(&chunk, 1.0).summary();
        assert!(
            approx(s.total_area, 30.0),
            "内部面未被正确剔除;总面积={}",
            s.total_area
        );
        assert!(s.structural_ok);
    }

    #[test]
    fn all_normals_axis_unit_across_configs() {
        let mut chunk = empty_chunk();
        chunk.cells[idx(2, 3, 4)] = solid(1);
        chunk.cells[idx(2, 4, 4)] = solid(2);
        chunk.cells[idx(10, 10, 10)] = solid(1);
        for mesh in [mesh_chunk(&chunk, 1.0), greedy_mesh_chunk(&chunk, 1.0)] {
            assert!(
                mesh.normals_are_axis_unit(),
                "法线非轴单位向量 → 绕序/法线错"
            );
            assert!(mesh.structural_invariants_hold(), "结构不变量被破坏");
        }
    }

    // ── Micro (sub-voxel) meshing of refined cells (M2b / C4) ──

    use crate::voxel::wire::MicroLayer;

    fn micro_mask(slots: &[usize]) -> [u64; 8] {
        let mut mask = [0u64; 8];
        for &i in slots {
            mask[i / 64] |= 1u64 << (i % 64);
        }
        mask
    }

    fn micro_index(mx: usize, my: usize, mz: usize) -> usize {
        mx + my * 8 + mz * 64
    }

    fn layer(material_id: u16, slots: &[usize]) -> MicroLayer {
        MicroLayer {
            mask_words: micro_mask(slots),
            material_id,
            state_flags: 0,
            health: 0,
            attribute_set_ref: 0,
            tag_set_ref: 0,
            owner_object_id: 0,
            owner_part_id: 0,
        }
    }

    /// Builds a refined cell whose occupancy is the union of its layers' masks.
    fn refined(layers: Vec<MicroLayer>) -> RefinedCell {
        let mut occ = [0u64; 8];
        for l in &layers {
            for (w, word) in l.mask_words.iter().enumerate() {
                occ[w] |= *word;
            }
        }
        RefinedCell {
            occupancy_words: occ,
            boundary_cache: 0,
            layers,
            object_refs: vec![],
        }
    }

    #[test]
    fn single_micro_slot_emits_six_micro_faces() {
        let cell = refined(vec![layer(3, &[micro_index(2, 2, 2)])]);
        let mesh = refined_micro_mesh(&cell, [0.0, 0.0, 0.0], 8.0);
        // micro size = 8/8 = 1.0; one micro cube → 6 faces, area 6 * 1².
        let s = mesh.summary();
        assert_eq!(s.quad_count, 6);
        assert!((s.total_area - 6.0).abs() < 1e-3);
        assert_eq!(*s.area_by_material.keys().next().unwrap(), 3u32);
        // micro cube occupies [2,3]³ in micro units (= render units here).
        assert_eq!(s.aabb_min, Some([2.0, 2.0, 2.0]));
        assert_eq!(s.aabb_max, Some([3.0, 3.0, 3.0]));
        assert!(s.structural_ok);
    }

    #[test]
    fn adjacent_micro_slots_cull_shared_face() {
        let cell = refined(vec![layer(
            3,
            &[micro_index(2, 2, 2), micro_index(3, 2, 2)],
        )]);
        let mesh = refined_micro_mesh(&cell, [0.0, 0.0, 0.0], 8.0);
        // Two adjacent micro cubes: 12 faces − 2 shared interior = 10.
        assert_eq!(mesh.quad_count(), 10);
        assert!(mesh.structural_invariants_hold());
    }

    #[test]
    fn fully_occupied_refined_cell_is_micro_shell() {
        // All 512 micro slots occupied → only the 8³ block's outer shell:
        // 6 faces × 8×8 = 384 micro quads.
        let all: Vec<usize> = (0..512).collect();
        let cell = refined(vec![layer(5, &all)]);
        let mesh = refined_micro_mesh(&cell, [0.0, 0.0, 0.0], 8.0);
        assert_eq!(mesh.quad_count(), 6 * 8 * 8);
        assert!(mesh.normals_are_axis_unit());
    }

    #[test]
    fn micro_material_is_per_slot_not_first_layer() {
        // Two layers, different materials in non-adjacent slots → both appear,
        // each as its own 6-face cube (unlike the macro `cell_material` which
        // would collapse to the first layer only).
        let cell = refined(vec![
            layer(7, &[micro_index(0, 0, 0)]),
            layer(9, &[micro_index(6, 6, 6)]),
        ]);
        let mesh = refined_micro_mesh(&cell, [0.0, 0.0, 0.0], 8.0);
        let s = mesh.summary();
        assert_eq!(s.quad_count, 12);
        assert!((s.area_by_material[&7] - 6.0).abs() < 1e-3);
        assert!((s.area_by_material[&9] - 6.0).abs() < 1e-3);
    }

    #[test]
    fn refined_micro_mesh_honors_macro_origin_and_voxel_size() {
        let cell = refined(vec![layer(3, &[micro_index(0, 0, 0)])]);
        let mesh = refined_micro_mesh(&cell, [100.0, 200.0, 300.0], 16.0);
        // micro = 16/8 = 2.0; slot (0,0,0) cube spans origin..origin+2.
        let s = mesh.summary();
        assert_eq!(s.aabb_min, Some([100.0, 200.0, 300.0]));
        assert_eq!(s.aabb_max, Some([102.0, 202.0, 302.0]));
    }

    #[test]
    fn chunk_render_mesh_micro_meshes_refined_without_double_macro_cube() {
        // Isolated solid (3,0,0) → 6 macro faces; isolated refined (1,0,0) with
        // one micro slot → 6 micro faces (NOT a macro cube too) = 12 total.
        let mut chunk = empty_chunk();
        chunk.cells[idx(1, 0, 0)] =
            CellState::Refined(refined(vec![layer(7, &[micro_index(0, 0, 0)])]));
        chunk.cells[idx(3, 0, 0)] = solid(2);
        let mesh = chunk_render_mesh(&chunk, 8.0, &ChunkNeighbors::default());
        assert_eq!(mesh.quad_count(), 12);
        assert!(mesh.structural_invariants_hold());
        let s = mesh.summary();
        assert!(s.area_by_material.contains_key(&2)); // solid macro
        assert!(s.area_by_material.contains_key(&7)); // refined micro
    }

    #[test]
    fn refined_neighbor_still_occludes_solid_macro_face() {
        // Solid (1,0,0) with a refined +X neighbor (2,0,0): the solid's +X face
        // is culled (refined occupies) → solid emits 5 macro faces, not 6.
        let mut chunk = empty_chunk();
        chunk.cells[idx(1, 0, 0)] = solid(2);
        chunk.cells[idx(2, 0, 0)] =
            CellState::Refined(refined(vec![layer(7, &[micro_index(0, 0, 0)])]));
        let s = chunk_render_mesh(&chunk, 8.0, &ChunkNeighbors::default()).summary();
        // 5 macro faces * 8² = 320 area for the solid material.
        assert!((s.area_by_material[&2] - 5.0 * 64.0).abs() < 1e-2);
    }

    #[test]
    fn macro_only_mesh_matches_server_analytic_oracle() {
        // Layer-2 跨语言 parity:bevy mesher 的输出 ↔ 服务端**独立解析算法**(MeshOracle,
        // gen_voxel_golden_fixtures 写的 *.mesh.json)数值一致 —— 两套独立实现互验"将要绘制的几何"。
        // 比 area/area_by_material(merge/顺序无关),不比 quad_count(bevy greedy 会合并)。
        use crate::voxel::authority::VoxelAuthorityStore;
        use crate::voxel::wire::{ChunkSnapshot, Reader};

        let golden = crate::voxel::wire::fixtures::golden("snapshot_macro_only");
        let snap = ChunkSnapshot::decode(&mut Reader::new(&golden)).unwrap();
        let coord = snap.chunk_coord;
        let mut store = VoxelAuthorityStore::new();
        store.apply_snapshot(&snap).unwrap();
        let chunk = store.chunk(coord).unwrap();

        let summary = chunk_render_mesh(chunk, 1.0, &ChunkNeighbors::default()).summary();

        let mut path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        path.push("../../apps/scene_server/priv/fixtures/voxel/snapshot_macro_only.mesh.json");
        let json: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();

        let expected_total = json["total_area"].as_f64().unwrap() as f32;
        assert!(
            (summary.total_area - expected_total).abs() < 1e-2,
            "total_area parity: bevy {} vs server {}",
            summary.total_area,
            expected_total
        );

        let oracle = json["area_by_material"].as_object().unwrap();
        assert_eq!(
            summary.area_by_material.len(),
            oracle.len(),
            "material set size parity: bevy {:?} vs server {:?}",
            summary.area_by_material,
            oracle
        );
        for (mat, area) in &summary.area_by_material {
            let exp = oracle
                .get(&mat.to_string())
                .unwrap_or_else(|| panic!("material {mat} present in bevy mesh, absent in oracle"))
                .as_f64()
                .unwrap() as f32;
            assert!(
                (area - exp).abs() < 1e-2,
                "material {mat} area parity: bevy {} vs server {}",
                area,
                exp
            );
        }
    }

    #[test]
    fn greedy_and_exposed_share_canonical_summary() {
        // Layer-2 同语言版:greedy 与 exposed-face oracle 对同一 chunk 产出**顺序无关**等价的可见表面
        // (总面积/每材质面积/AABB),即便面数与顶点顺序不同。跨语言(web)parity 后续用同一口径。
        let mut chunk = empty_chunk();
        for z in 0..SIZE {
            for x in 0..SIZE {
                chunk.cells[idx(x, 0, z)] = solid(2);
            }
        }
        chunk.cells[idx(5, 5, 5)] = solid(7);

        let g = greedy_mesh_chunk(&chunk, 1.0).summary();
        let e = mesh_chunk(&chunk, 1.0).summary();

        assert!(
            approx(g.total_area, e.total_area),
            "总面积不一致 g={} e={}",
            g.total_area,
            e.total_area
        );
        assert_eq!(
            g.area_by_material.keys().collect::<Vec<_>>(),
            e.area_by_material.keys().collect::<Vec<_>>()
        );
        for (k, ev) in &e.area_by_material {
            assert!(
                approx(*g.area_by_material.get(k).unwrap(), *ev),
                "材质 {k} 面积不一致"
            );
        }
        assert_eq!(g.aabb_min, e.aabb_min);
        assert_eq!(g.aabb_max, e.aabb_max);
    }
}
