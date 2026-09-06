//! 六向表皮递归归约，以及既有 payload 的 CSR 体序列化。
use std::collections::HashMap;

pub(crate) const EXTENT: usize = 66;
pub(crate) const OWNED: i32 = 64;
pub(crate) const MAX_MAP: usize = 4;
pub(crate) fn map_extent(level: i32) -> usize {
    (1usize << level).min(MAX_MAP)
}

#[derive(Clone, Copy)]
pub(crate) struct Skins {
    pub extent: usize,
    pub ids: [u16; 6],
    pub texels: [[u8; MAX_MAP * MAX_MAP]; 6],
}
impl Skins {
    fn uniform(material: u16) -> Self {
        Self {
            extent: 1,
            ids: [material; 6],
            texels: [[0; 16]; 6],
        }
    }
    pub fn texel(&self, face: usize, u: usize, v: usize) -> u16 {
        if self.extent == 1 {
            self.ids[face]
        } else {
            self.texels[face][v * self.extent + u] as u16
        }
    }
    fn face_uniform(&self, face: usize) -> bool {
        self.extent == 1
            || self.texels[face][..self.extent * self.extent]
                .iter()
                .all(|&m| m as u16 == self.ids[face])
    }
    pub fn trivial(&self, material: u16) -> bool {
        (0..6).all(|face| self.ids[face] == material && self.face_uniform(face))
    }
}
#[derive(Clone, Copy)]
pub(crate) struct Value {
    pub material: u16,
    pub skins: Skins,
}
impl Value {
    pub fn uniform(material: u16) -> Self {
        Self {
            material,
            skins: Skins::uniform(material),
        }
    }
}
fn mode<T: Copy + Into<u16>>(values: &[T]) -> u16 {
    let mut counts = [0u8; 256];
    let mut best = 0;
    let mut votes = 0;
    for &value in values {
        let id = value.into();
        if id != 0 {
            counts[id as usize] += 1;
            let n = counts[id as usize];
            if n > votes || (n == votes && id < best) {
                best = id;
                votes = n;
            }
        }
    }
    best
}
pub(crate) fn reduce(children: &[Value; 8], level: i32) -> Value {
    let materials = children.map(|child| child.material);
    let material = if materials.iter().filter(|&&m| m != 0).count() >= 5 {
        mode(&materials)
    } else {
        0
    };
    let child_extent = map_extent(level - 1);
    let extent = map_extent(level);
    let mut skins = Skins::uniform(0);
    if children.iter().all(|c| c.skins.extent == 1) {
        let mut columns = [[0u16; 4]; 6];
        let mut uniform = true;
        for (face, column) in columns.iter_mut().enumerate() {
            let axis = face / 2;
            let outer = face & 1;
            let u = (axis + 1) % 3;
            let v = (axis + 2) % 3;
            for octant in 0..8 {
                if (octant >> axis) & 1 != outer {
                    continue;
                }
                let a = children[octant].skins.ids[face];
                column[((octant >> v) & 1) * 2 + ((octant >> u) & 1)] = if a != 0 {
                    a
                } else {
                    children[octant ^ (1 << axis)].skins.ids[face]
                };
            }
            skins.ids[face] = mode(column);
            uniform &= column.iter().all(|&m| m == column[0]);
        }
        if !uniform {
            skins.extent = extent;
            for (face, column) in columns.iter().enumerate() {
                for v in 0..extent {
                    for u in 0..extent {
                        skins.texels[face][v * extent + u] =
                            column[(v / (extent / 2)) * 2 + u / (extent / 2)] as u8;
                    }
                }
            }
        }
    } else {
        let combined = 2 * child_extent;
        skins.extent = extent;
        for face in 0..6 {
            let axis = face / 2;
            let outer = face & 1;
            let u = (axis + 1) % 3;
            let v = (axis + 2) % 3;
            let mut merged = [0u8; 64];
            for octant in 0..8 {
                if (octant >> axis) & 1 != outer {
                    continue;
                }
                let cu = (octant >> u) & 1;
                let cv = (octant >> v) & 1;
                for j in 0..child_extent {
                    for i in 0..child_extent {
                        let a = children[octant].skins.texel(face, i, j);
                        let m = if a != 0 {
                            a
                        } else {
                            children[octant ^ (1 << axis)].skins.texel(face, i, j)
                        };
                        merged[(cv * child_extent + j) * combined + cu * child_extent + i] =
                            m as u8;
                    }
                }
            }
            if combined == extent {
                skins.texels[face][..extent * extent].copy_from_slice(&merged[..extent * extent]);
            } else {
                for j in 0..extent {
                    for i in 0..extent {
                        let p = 2 * j * combined + 2 * i;
                        skins.texels[face][j * extent + i] = mode(&[
                            merged[p],
                            merged[p + 1],
                            merged[p + combined],
                            merged[p + combined + 1],
                        ]) as u8;
                    }
                }
            }
            skins.ids[face] = mode(&skins.texels[face][..extent * extent]);
        }
    }
    Value { material, skins }
}

/// v4 body（Voxim `SerializeRegionBody`，全部 little-endian）：
/// cells `n u32 + u16×n` · Extent i32×3 · MapExtent i32 · RowStart `n u32 + i32×n` · ColX `n u32 + u16×n` ·
/// RecordCount u32 + 六个 face id 平面（各 u8×n）+ MapMask 平面（u16×n）· FaceMapIndex `n u32 + u16×n` · Maps `n u32 + u8×n`。
/// 记录的 FaceMapBase = 之前所有记录 mask popcount 之和（读方重算）；贴图 hash 不传。
pub(crate) fn encode(cells: &[u16], records: &[(usize, Skins)], level: i32) -> Vec<u8> {
    let extent = map_extent(level);
    let n = records.len();
    let mut rows = vec![0u32; EXTENT * EXTENT + 1];
    let mut cols = Vec::with_capacity(n);
    let mut faces = vec![0u8; 6 * n];
    let mut masks = Vec::with_capacity(2 * n);
    let mut indices = Vec::<u16>::new();
    let mut maps = Vec::<u8>::new();
    let mut pool = HashMap::<Vec<u8>, u16>::new();
    for (k, &(index, skins)) in records.iter().enumerate() {
        rows[index / EXTENT + 1] += 1;
        cols.push((index % EXTENT) as u16);
        let mut mask = 0u16;
        for face in 0..6 {
            faces[face * n + k] = skins.ids[face] as u8;
            if skins.face_uniform(face) {
                continue;
            }
            mask |= 1 << face;
            let map = &skins.texels[face][..extent * extent];
            let next = pool.len() as u16;
            let id = *pool.entry(map.to_vec()).or_insert_with(|| {
                maps.extend_from_slice(map);
                next
            });
            indices.push(id);
        }
        masks.extend_from_slice(&mask.to_le_bytes());
    }
    for row in 1..rows.len() {
        rows[row] += rows[row - 1];
    }
    if records.is_empty() {
        rows.clear();
    }
    let mut out = Vec::with_capacity(cells.len() * 2 + 8 * n + 2 * indices.len() + maps.len());
    fn count(out: &mut Vec<u8>, n: usize) {
        out.extend_from_slice(&(n as u32).to_le_bytes());
    }
    count(&mut out, cells.len());
    for m in cells {
        out.extend_from_slice(&m.to_le_bytes());
    }
    let field_extent = if records.is_empty() { 0 } else { EXTENT };
    for _ in 0..3 {
        count(&mut out, field_extent);
    }
    count(&mut out, if records.is_empty() { 1 } else { extent });
    count(&mut out, rows.len());
    for row in rows {
        out.extend_from_slice(&row.to_le_bytes());
    }
    count(&mut out, cols.len());
    for col in cols {
        out.extend_from_slice(&col.to_le_bytes());
    }
    count(&mut out, n);
    out.extend_from_slice(&faces);
    out.extend_from_slice(&masks);
    count(&mut out, indices.len());
    for index in indices {
        out.extend_from_slice(&index.to_le_bytes());
    }
    count(&mut out, maps.len());
    out.extend_from_slice(&maps);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn every_occupancy_mask_preserves_six_directional_surfaces() {
        for mask in 0u32..256 {
            let children = std::array::from_fn(|i| {
                Value::uniform(if mask & (1 << i) != 0 {
                    (i + 1) as u16
                } else {
                    0
                })
            });
            let value = reduce(&children, 1);
            assert_eq!(value.material != 0, mask.count_ones() >= 5);
            for face in 0..6 {
                let axis = face / 2;
                let u = (axis + 1) % 3;
                let v = (axis + 2) % 3;
                for j in 0..2 {
                    for i in 0..2 {
                        let outer = ((face & 1) << axis) | (i << u) | (j << v);
                        let a = children[outer].material;
                        let expected = if a != 0 {
                            a
                        } else {
                            children[outer ^ (1 << axis)].material
                        };
                        assert_eq!(
                            value.skins.texel(face, i, j),
                            expected,
                            "mask={mask} face={face}"
                        );
                    }
                }
            }
        }
    }
    #[test]
    fn material_mode_ignores_air_and_breaks_ties_by_smallest_id() {
        assert_eq!(mode(&[0u16, 0, 0, 7, 3]), 3);
        assert_eq!(mode(&[7u16, 3, 7, 3, 9]), 3);
        assert_eq!(mode(&[0u16; 8]), 0);
    }
}
