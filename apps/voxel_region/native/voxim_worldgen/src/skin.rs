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
fn is_trunk(material: u16) -> bool {
    material == 19 || (25..=27).contains(&material) || matches!(material, 57 | 59 | 61 | 63)
}
// 与正式 VoxelMaterialCatalog.lod_dry_sheet?/1、客户端目录逐项一致：
// 液体 21/22，透明 20/21/44/50/74/87，foliage 28..39/58/60/61/62/64，树干，装饰 65..73。
fn is_dry_sheet(material: u16) -> bool {
    material != 0 && !matches!(material, 20 | 21 | 22 | 44 | 50 | 74 | 87)
        && !(28..=39).contains(&material) && !matches!(material, 58 | 60 | 61 | 62 | 64)
        && !is_trunk(material) && !(65..=73).contains(&material)
}
/// 全局系统功能 ReduceCellV2：L1 花草先过滤；旧多数/树干优先，完整水平干片保留；表皮仍为 ReduceSkinsV1。
pub(crate) fn reduce(children: &[Value; 8], level: i32) -> Value {
    let cleared;
    let children = if level == 1 && children.iter().any(|c| (32..=39).contains(&c.material)) {
        cleared = children.clone().map(|c| if (32..=39).contains(&c.material) { Value::uniform(0) } else { c });
        &cleared
    } else {
        children
    };
    let materials = children.clone().map(|child| child.material);
    let mut material = if materials.iter().filter(|&&m| m != 0).count() >= 5 {
        mode(&materials)
    } else {
        0
    };
    // 树干保留（仅 L0→L1）：1 m 粗的竖直树干在 2×2×2 里只占 2 格，按"≥5 格实体"会变成空气、树冠悬空。
    // 实体不足 5 格但树干 ≥ 2 格 → 父格是树干（树干子格的众数，平局最小 id）。表皮照常，空 texel 回落到主体。
    if level == 1 && material == 0 {
        let trunks: Vec<u16> = materials.iter().copied().filter(|&m| is_trunk(m)).collect();
        if trunks.len() >= 2 {
            material = mode(&trunks);
        }
    }
    if material == 0 {
        for phase in [0, 2] {
            let sheet = [0, 1, 4, 5].map(|oct| materials[oct | phase]);
            let other = [0, 1, 4, 5].map(|oct| materials[oct | (phase ^ 2)]);
            if sheet.iter().all(|&m| is_dry_sheet(m)) && other.iter().all(|&m| m == 0) {
                material = mode(&sheet);
                break;
            }
        }
    }
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
    // 只测试：F2a 冻结八格；期望为手算常量，不借另一实现生成。
    #[test]
    fn reduce_cell_v2_frozen_octants() {
        for level in 1..=5 {
            for (ids, expected) in [
                ([0,0,1,1,0,0,1,1],1), ([1,1,0,0,1,1,0,0],1),
                ([11,7,0,0,11,7,0,0],7), ([11,7,0,0,11,11,0,0],11),
                ([1,0,0,1,0,1,1,0],0), ([1,0,1,0,1,0,1,0],0),
                ([1,1,0,0,1,0,0,0],0), ([19,1,0,0,1,1,0,0],0),
                ([1,0,0,0,0,0,0,0],0), ([0;8],0), ([11;8],11),
                ([1,1,1,1,19,0,19,0],1),
            ] {
                assert_eq!(reduce(&ids.map(Value::uniform),level).material,expected,"L{level} {ids:?}");
            }
        }
        let sheet = [19,19,0,0,19,19,0,0].map(Value::uniform);
        assert_eq!(reduce(&sheet,1).material,19);
        assert_eq!(reduce(&sheet,2).material,0);
    }

    #[test]
    fn reduce_cell_v2_exclusions_and_skins() {
        let excluded: Vec<u16> = [20,21,22,44,50,74,87,19,25,26,27].into_iter()
            .chain(28..=39).chain(57..=73).collect();
        for level in [1,2] {
            for &m in &excluded {
                for corner in [0,1,4,5] {
                    let mut ids = [1,1,0,0,1,1,0,0];
                    ids[corner] = m;
                    assert_eq!(reduce(&ids.map(Value::uniform),level).material,0,"L{level} {ids:?}");
                }
                let expected = if level == 1 && [19,25,26,27,57,59,61,63].contains(&m) {m} else {0};
                assert_eq!(reduce(&[m,m,0,0,m,m,0,0].map(Value::uniform),level).material,expected);
            }
        }
        let flora = [1,1,32,32,1,1,32,32].map(Value::uniform);
        let value = reduce(&flora,1);
        assert_eq!(value.material,1);
        for face in 0..6 { for j in 0..2 { for i in 0..2 {
            assert!([0,1].contains(&value.skins.texel(face,i,j)));
        }}}
        assert_eq!(reduce(&flora,2).skins.texel(3,0,0),32);
        let value = reduce(&[0,0,1,1,0,0,1,1].map(Value::uniform),1);
        for face in [2,3] { for j in 0..2 { for i in 0..2 {
            assert_eq!(value.skins.texel(face,i,j),1);
        }}}
        assert_eq!(reduce(&[Value {material: 0, skins: Skins::uniform(1)};8],1).material,0);
    }

    #[test]
    fn reduce_cell_v2_recursive_sheet_phases_and_negative_xyz() {
        for [x0,y,z0] in [[12,504,0],[12,505,0],[12,506,0],[12,507,0],[-4,-3,-4]] {
            let canonical: HashMap<[i32;3],Value> = (z0..z0+4).flat_map(|z|
                (x0..x0+4).map(move |x| ([x,y,z],Value::uniform(1)))).collect();
            let mut field = canonical.clone();
            for level in 1..=2 {
                let parents: std::collections::HashSet<_> = field.keys().map(|p| p.map(|v| v.div_euclid(2))).collect();
                field = parents.into_iter().map(|p| {
                    let children = std::array::from_fn(|oct| {
                        let c = std::array::from_fn(|axis| p[axis]*2+((oct>>axis)&1) as i32);
                        field.get(&c).copied().unwrap_or(Value::uniform(0))
                    });
                    (p,reduce(&children,level))
                }).collect();
                let expected_count = if level == 1 {4} else {1};
                assert_eq!(field.values().filter(|v| v.material==1).count(),expected_count);
                assert_eq!(expected_count*(1usize<<(2*level)),16);
                assert!(field.keys().all(|p| p[1]==y.div_euclid(1<<level)));
            }
            assert_eq!(canonical.len(),16);
            assert!(canonical.iter().all(|(p,v)| p[1]==y && v.material==1));
        }
    }
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
            // V2 只在这两个完整水平 mask 增加主体；其余仍为严格多数。
            assert_eq!(value.material != 0, mask.count_ones() >= 5 || mask == 0x33 || mask == 0xcc);
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
    fn a_one_metre_trunk_survives_l1_but_not_l2_and_never_overrides_a_solid_majority() {
        let cell = |materials: [u16; 8]| materials.map(Value::uniform);
        // 竖直树干：octant = x + 2y + 4z，(0,0,0) 与 (0,1,0) 是 0 和 2。
        assert_eq!(reduce(&cell([25, 0, 25, 0, 0, 0, 0, 0]), 1).material, 25);
        assert_eq!(reduce(&cell([25, 0, 25, 0, 0, 0, 0, 0]), 2).material, 0);
        for trunk in [57, 59, 61, 63] {
            assert_eq!(reduce(&cell([trunk, 0, trunk, 0, 0, 0, 0, 0]), 1).material, trunk);
            assert_eq!(reduce(&cell([trunk, 0, trunk, 0, 0, 0, 0, 0]), 2).material, 0);
            assert_eq!(reduce(&cell([1, 1, 1, 1, trunk, 0, trunk, 0]), 1).material, 1);
        }
        // 单独一格木头不够；树干与花草同格时花草先当空气。
        assert_eq!(reduce(&cell([19, 0, 0, 0, 0, 0, 0, 0]), 1).material, 0);
        assert_eq!(reduce(&cell([19, 35, 19, 32, 0, 0, 0, 0]), 1).material, 19);
        // 实体够 5 格时仍是原来的众数：4 格草 + 2 格树干 = 草。
        assert_eq!(reduce(&cell([1, 1, 1, 1, 26, 0, 26, 0]), 1).material, 1);
        // 两种树干各两格：平局取最小 id。
        assert_eq!(reduce(&cell([27, 19, 27, 19, 0, 0, 0, 0]), 1).material, 19);
    }

    #[test]
    fn material_mode_ignores_air_and_breaks_ties_by_smallest_id() {
        assert_eq!(mode(&[0u16, 0, 0, 7, 3]), 3);
        assert_eq!(mode(&[7u16, 3, 7, 3, 9]), 3);
        assert_eq!(mode(&[0u16; 8]), 0);
    }
}
