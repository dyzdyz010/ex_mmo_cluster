//! 服务端 canonical XYZ 地形噪声 NIF。
//!
//! `worldgen_density_v2@1` 在 DirtyCpu NIF 中生成固定 16³ 材质体：历史二维高度模型
//! 只提供地表基底，世界坐标连续的三维 value noise 负责 cheese-cave。已归档 heightmap
//! 离线迁移工具继续共用同一地表公式；在线运行时不读取 heightmap。
//!
//! 地表沿用从 Elixir 移植的分层 value-noise 模型（常量/公式逐字对齐）：
//! lowland 基底（平缓滚动、凹陷成盆地）+ 稀疏高山（低频 mask 选区 + ridged 分形）。
//!
//! SquirrelNoise（Squirrel Eiserloh）整数哈希全程使用 u32 wrapping，与 Elixir 的
//! `band(_, 0xFFFFFFFF)` 行为一致；Rust 原生 u32 环绕无需显式掩码。

use rustler::{Binary, Env, Error, NifResult, OwnedBinary};

rustler::init!("Elixir.SceneServer.Native.WorldGenNoise");

// ── 噪声常量(与 Elixir 模块属性逐字对齐)─────────────────────────────────────
const NOISE1: u32 = 0x68E3_1DA4;
const NOISE2: u32 = 0xB529_7A4D;
const NOISE3: u32 = 0x1B56_C4E9;
const LATTICE_PRIME: i64 = 198_491_317;

/// canonical XYZ material-volume 算法身份。任何改变材质输出的公式或常量都必须换版本。
const WORLDGEN_ALGORITHM_VERSION: &str = "worldgen_density_v2@1";
const CHUNK_EDGE: usize = 16;
const CHUNK_CELL_COUNT: usize = CHUNK_EDGE * CHUNK_EDGE * CHUNK_EDGE;

// ── 地形带(macro 单位 ≈ 米)────────────────────────────────────────────────
const LOWLAND_AMPLITUDE: f64 = 150.0;

const MOUNTAIN_AMPLITUDE: f64 = 1400.0;
const MOUNTAIN_WAVELENGTH: f64 = 9000.0;
const MOUNTAIN_MASK_LO: f64 = 0.62;
const MOUNTAIN_MASK_HI: f64 = 0.9;
const RIDGE_POWER: f64 = 2.2;

// 低地基底分形 octave:`{wavelength_in_macros, amplitude}`。
const OCTAVES: [(f64, f64); 5] = [
    (4096.0, 1.0),
    (1024.0, 0.7),
    (256.0, 0.45),
    (64.0, 0.25),
    (16.0, 0.1),
];

// 高山 ridged 分形 octave(仅宽 octave,保证山脊宽阔而非逐格尖刺)。
const MOUNTAIN_OCTAVES: [(f64, f64); 3] = [(4096.0, 1.0), (2048.0, 0.55), (1024.0, 0.28)];

// v2@1 只加入 cheese-cave 密度层。有限垂直带保留深层 uniform-solid 快路径，
// 固定地表盖层避免第一版连续噪声形成密集针孔；自然入口由后续独立 carver 负责。
const CAVE_MIN_WORLD_Y: i64 = -384;
const CAVE_MAX_DEPTH: i64 = 320;
const CAVE_SURFACE_COVER: i64 = 12;
const CAVE_THRESHOLD: f64 = 0.69;
const CAVE_SEED_SALT: u32 = 0x4341_5645;
const CAVE_OCTAVES: [(f64, f64); 3] = [(96.0, 1.0), (48.0, 0.55), (24.0, 0.28)];

// ── SquirrelNoise 整数哈希 ─────────────────────────────────────────────────

/// SquirrelNoise 整数 mix。Rust u32 native wrapping == Elixir `band(_, 0xFFFFFFFF)`。
#[inline]
fn squirrel(n: u32, seed: u32) -> u32 {
    let mut n = n.wrapping_mul(NOISE1);
    n = n.wrapping_add(seed);
    n ^= n >> 8;
    n = n.wrapping_add(NOISE2);
    n ^= n << 8;
    n = n.wrapping_mul(NOISE3);
    n ^ (n >> 8)
}

/// 晶格值 ∈ [0, 1):把 2D 整数坐标合成一个 u32 位置再过 squirrel。
///
/// Elixir 里 `band(ix + @lattice_prime*iz, @u32)` 是一个可能为负的 i64 的低 32 位;
/// 这里用 i64 wrapping 运算后 `as u32` 取低 32 位,与之对齐。
#[inline]
fn lattice(ix: i64, iz: i64, seed: u32) -> f64 {
    let pos = ix.wrapping_add(LATTICE_PRIME.wrapping_mul(iz)) as u32;
    f64::from(squirrel(pos, seed)) / 4_294_967_296.0
}

// ── 连续噪声原语 ────────────────────────────────────────────────────────────

/// 负坐标向下取整(等价 Elixir `trunc(:math.floor(value))`)。
#[inline]
fn floor_int(value: f64) -> i64 {
    value.floor() as i64
}

#[inline]
fn smoothstep(t: f64) -> f64 {
    t * t * (3.0 - 2.0 * t)
}

#[inline]
fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

/// 连续 (x, z) 处 2D value noise:smoothstep 插值四角晶格哈希。
fn value_noise(x: f64, z: f64, seed: u32) -> f64 {
    let ix = floor_int(x);
    let iz = floor_int(z);
    let fx = x - ix as f64;
    let fz = z - iz as f64;

    let v00 = lattice(ix, iz, seed);
    let v10 = lattice(ix + 1, iz, seed);
    let v01 = lattice(ix, iz + 1, seed);
    let v11 = lattice(ix + 1, iz + 1, seed);

    let sx = smoothstep(fx);
    let sz = smoothstep(fz);

    lerp(lerp(v00, v10, sx), lerp(v01, v11, sx), sz)
}

/// 三维晶格值。逐轴 hash 避免新增一组坐标合成素数，并让负坐标显式取各轴低 32 位。
#[inline]
fn lattice_3d(ix: i64, iy: i64, iz: i64, seed: u32) -> f64 {
    let x = squirrel(ix as u32, seed ^ 0xA511_E9B3);
    let y = squirrel(iy as u32, x ^ 0x63D8_35D9);
    let z = squirrel(iz as u32, y ^ 0xB529_7A4D);
    f64::from(z) / 4_294_967_296.0
}

/// Perlin improved-noise 参考使用的五次 fade；端点一、二阶导数为零，跨晶格更平滑。
#[inline]
fn improved_fade(t: f64) -> f64 {
    t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}

/// 世界坐标三维 value noise：采样单位立方体八角并逐轴插值。
fn value_noise_3d(x: f64, y: f64, z: f64, seed: u32) -> f64 {
    let ix = floor_int(x);
    let iy = floor_int(y);
    let iz = floor_int(z);
    let fx = x - ix as f64;
    let fy = y - iy as f64;
    let fz = z - iz as f64;
    let sx = improved_fade(fx);
    let sy = improved_fade(fy);
    let sz = improved_fade(fz);

    let z0 = lerp(
        lerp(
            lattice_3d(ix, iy, iz, seed),
            lattice_3d(ix + 1, iy, iz, seed),
            sx,
        ),
        lerp(
            lattice_3d(ix, iy + 1, iz, seed),
            lattice_3d(ix + 1, iy + 1, iz, seed),
            sx,
        ),
        sy,
    );
    let z1 = lerp(
        lerp(
            lattice_3d(ix, iy, iz + 1, seed),
            lattice_3d(ix + 1, iy, iz + 1, seed),
            sx,
        ),
        lerp(
            lattice_3d(ix, iy + 1, iz + 1, seed),
            lattice_3d(ix + 1, iy + 1, iz + 1, seed),
            sx,
        ),
        sy,
    );
    lerp(z0, z1, sz)
}

// ── 分形 ────────────────────────────────────────────────────────────────────

/// value-noise octave 分形和,归一化到 ~[0, 1]。
fn fbm(wx: f64, wz: f64, seed: i64) -> f64 {
    let mut sum = 0.0;
    let mut norm = 0.0;
    for (octave, &(wavelength, amplitude)) in OCTAVES.iter().enumerate() {
        let s = seed.wrapping_add(octave as i64) as u32;
        let v = value_noise(wx / wavelength, wz / wavelength, s) * amplitude;
        sum += v;
        norm += amplitude;
    }
    (sum / norm).max(0.0).min(1.0)
}

/// ridged 分形 ∈ ~[0,1]:每 octave 折成山脊 (1-|2v-1|) 再平方,仅用宽 octave。
fn ridged_fbm(wx: f64, wz: f64, seed: i64) -> f64 {
    let mut sum = 0.0;
    let mut norm = 0.0;
    for (octave, &(wavelength, amplitude)) in MOUNTAIN_OCTAVES.iter().enumerate() {
        let s = seed.wrapping_add(octave as i64) as u32;
        let v = value_noise(wx / wavelength, wz / wavelength, s);
        let ridge = 1.0 - (2.0 * v - 1.0).abs();
        sum += ridge * ridge * amplitude;
        norm += amplitude;
    }
    (sum / norm).max(0.0).min(1.0)
}

/// v2 cheese-cave 连续密度场。所有 octave 只读取绝对 world XYZ，chunk 边界没有局部相位。
fn cave_fbm(wx: f64, wy: f64, wz: f64, seed: i64) -> f64 {
    let mut sum = 0.0;
    let mut norm = 0.0;
    let base_seed = (seed as u32) ^ CAVE_SEED_SALT;
    for (octave, &(wavelength, amplitude)) in CAVE_OCTAVES.iter().enumerate() {
        let octave_seed = base_seed.wrapping_add((octave as u32).wrapping_mul(0x9E37_79B9));
        sum += value_noise_3d(
            wx / wavelength,
            wy / wavelength,
            wz / wavelength,
            octave_seed,
        ) * amplitude;
        norm += amplitude;
    }
    (sum / norm).max(0.0).min(1.0)
}

/// Hermite smoothstep:x 在 [lo, hi] 之外分别取 0 / 1(山地 mask gate)。
fn smoothstep_range(x: f64, lo: f64, hi: f64) -> f64 {
    let t = ((x - lo) / (hi - lo)).max(0.0).min(1.0);
    t * t * (3.0 - 2.0 * t)
}

// ── 列高度模型 ──────────────────────────────────────────────────────────────

/// 列 (wx, wz) 的地表高度(第一个 air world-y),确定于 (wx, wz, seed)。
fn column_height_impl(wx: i64, wz: i64, seed: i64, sea_level: i64, max_height: i64) -> i64 {
    let wxf = wx as f64;
    let wzf = wz as f64;

    // 1) 平缓 LOWLAND 基底,以海平面为中心 → 凹陷成盆地/河谷、抬升成缓丘。
    let base = fbm(wxf, wzf, seed);
    let lowland = sea_level as f64 + (base - 0.5) * LOWLAND_AMPLITUDE;

    // 2) 稀疏高山:宽低频 mask 选出少数成山区域;区域内 ridged 分形抬到一个幂
    //    → 山峰尖锐稀疏,直冲 @mountain_amplitude(>1 km)。
    let mask = value_noise(
        wxf / MOUNTAIN_WAVELENGTH,
        wzf / MOUNTAIN_WAVELENGTH,
        seed.wrapping_add(100) as u32,
    );
    let gate = smoothstep_range(mask, MOUNTAIN_MASK_LO, MOUNTAIN_MASK_HI);
    let ridge = ridged_fbm(wxf, wzf, seed.wrapping_add(200));
    let mountain = MOUNTAIN_AMPLITUDE * gate * ridge.powf(RIDGE_POWER);

    // Elixir round/1 是 half away from zero;f64::round 同。
    let h = (lowland + mountain).round() as i64;
    h.max(0).min(max_height)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CellKind {
    NaturalAir,
    CaveAir,
    Surface,
    Subsurface,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct ChunkMaterialStats {
    solid_cells: u64,
    cave_air_cells: u64,
    surface_cells: u64,
    subsurface_cells: u64,
}

#[inline]
fn cell_kind(
    wx: i64,
    wy: i64,
    wz: i64,
    column_height: i64,
    seed: i64,
    soil_depth: i64,
) -> CellKind {
    if wy >= column_height {
        return CellKind::NaturalAir;
    }

    let depth = column_height - wy;
    if wy >= CAVE_MIN_WORLD_Y
        && depth > CAVE_SURFACE_COVER
        && depth <= CAVE_MAX_DEPTH
        && cave_fbm(wx as f64, wy as f64, wz as f64, seed) > CAVE_THRESHOLD
    {
        return CellKind::CaveAir;
    }

    if depth <= soil_depth {
        CellKind::Surface
    } else {
        CellKind::Subsurface
    }
}

/// 生成 canonical `x + y*16 + z*256` 顺序的 u16 material id。
fn chunk_materials_impl(
    origin_x: i64,
    origin_y: i64,
    origin_z: i64,
    seed: i64,
    sea_level: i64,
    max_height: i64,
    soil_depth: i64,
    surface_material_id: u16,
    subsurface_material_id: u16,
) -> (Vec<u16>, ChunkMaterialStats) {
    let mut heights = [0i64; CHUNK_EDGE * CHUNK_EDGE];
    for z in 0..CHUNK_EDGE {
        for x in 0..CHUNK_EDGE {
            heights[x + z * CHUNK_EDGE] = column_height_impl(
                origin_x + x as i64,
                origin_z + z as i64,
                seed,
                sea_level,
                max_height,
            );
        }
    }

    let mut materials = vec![0u16; CHUNK_CELL_COUNT];
    let mut stats = ChunkMaterialStats::default();
    for z in 0..CHUNK_EDGE {
        for y in 0..CHUNK_EDGE {
            for x in 0..CHUNK_EDGE {
                let kind = cell_kind(
                    origin_x + x as i64,
                    origin_y + y as i64,
                    origin_z + z as i64,
                    heights[x + z * CHUNK_EDGE],
                    seed,
                    soil_depth,
                );
                let index = x + y * CHUNK_EDGE + z * CHUNK_EDGE * CHUNK_EDGE;
                materials[index] = match kind {
                    CellKind::NaturalAir => 0,
                    CellKind::CaveAir => {
                        stats.cave_air_cells += 1;
                        0
                    }
                    CellKind::Surface => {
                        stats.solid_cells += 1;
                        stats.surface_cells += 1;
                        surface_material_id
                    }
                    CellKind::Subsurface => {
                        stats.solid_cells += 1;
                        stats.subsurface_cells += 1;
                        subsurface_material_id
                    }
                };
            }
        }
    }
    (materials, stats)
}

// ── NIF surface ─────────────────────────────────────────────────────────────

#[rustler::nif]
fn algorithm_version() -> &'static str {
    WORLDGEN_ALGORITHM_VERSION
}

#[rustler::nif]
fn column_height(wx: i64, wz: i64, seed: i64, sea_level: i64, max_height: i64) -> i64 {
    column_height_impl(wx, wz, seed, sea_level, max_height)
}

/// `count_x × count_z` 网格的服务端权威高度图:扁平 big-endian u16,X 优先
/// (index = i + j*count_x),高度 clamp 到 0..65535。
#[rustler::nif]
fn heightmap_region<'a>(
    env: Env<'a>,
    origin_x: i64,
    origin_z: i64,
    stride: i64,
    count_x: i64,
    count_z: i64,
    seed: i64,
    sea_level: i64,
    max_height: i64,
) -> Binary<'a> {
    let cx = count_x.max(0) as usize;
    let cz = count_z.max(0) as usize;
    let mut bin = OwnedBinary::new(2 * cx * cz).expect("alloc heightmap binary");
    let buf = bin.as_mut_slice();

    let mut idx = 0usize;
    for j in 0..cz {
        for i in 0..cx {
            let wx = origin_x + (i as i64) * stride;
            let wz = origin_z + (j as i64) * stride;
            let h = column_height_impl(wx, wz, seed, sea_level, max_height)
                .max(0)
                .min(65535) as u16;
            buf[idx] = (h >> 8) as u8;
            buf[idx + 1] = (h & 0xFF) as u8;
            idx += 2;
        }
    }

    bin.release(env)
}

/// 生成一个固定 16³ canonical XYZ 材质体。返回 big-endian u16 material binary，随后是
/// solid/cave-air/surface/subsurface 计数；调用方可由总格数推导 natural-air。
#[rustler::nif(schedule = "DirtyCpu")]
fn chunk_materials<'a>(
    env: Env<'a>,
    origin_x: i64,
    origin_y: i64,
    origin_z: i64,
    seed: i64,
    sea_level: i64,
    max_height: i64,
    soil_depth: i64,
    surface_material_id: u16,
    subsurface_material_id: u16,
) -> NifResult<(Binary<'a>, u64, u64, u64, u64)> {
    if max_height < 0
        || sea_level < 0
        || sea_level > max_height
        || soil_depth <= 0
        || surface_material_id == 0
        || subsurface_material_id == 0
        || origin_x.checked_add((CHUNK_EDGE - 1) as i64).is_none()
        || origin_y.checked_add((CHUNK_EDGE - 1) as i64).is_none()
        || origin_z.checked_add((CHUNK_EDGE - 1) as i64).is_none()
    {
        return Err(Error::BadArg);
    }

    let (materials, stats) = chunk_materials_impl(
        origin_x,
        origin_y,
        origin_z,
        seed,
        sea_level,
        max_height,
        soil_depth,
        surface_material_id,
        subsurface_material_id,
    );
    let mut binary =
        OwnedBinary::new(CHUNK_CELL_COUNT * 2).expect("alloc worldgen material volume");
    for (index, material_id) in materials.into_iter().enumerate() {
        let offset = index * 2;
        binary.as_mut_slice()[offset] = (material_id >> 8) as u8;
        binary.as_mut_slice()[offset + 1] = (material_id & 0xFF) as u8;
    }

    Ok((
        binary.release(env),
        stats.solid_cells,
        stats.cave_air_cells,
        stats.surface_cells,
        stats.subsurface_cells,
    ))
}

// ── 测试:在 NIF 集成前先验证数学落在合理区间 ──────────────────────────────
#[cfg(test)]
mod tests {
    use super::*;

    const SEED: i64 = 1337;
    const SEA_LEVEL: i64 = 64;
    const MAX_HEIGHT: i64 = 1600;

    fn ch(wx: i64, wz: i64) -> i64 {
        column_height_impl(wx, wz, SEED, SEA_LEVEL, MAX_HEIGHT)
    }

    #[test]
    fn deterministic() {
        assert_eq!(ch(1234, -5678), ch(1234, -5678));
    }

    #[test]
    fn within_band() {
        let mut wx = 0;
        while wx <= 32_000 {
            let mut wz = 0;
            while wz <= 32_000 {
                let h = ch(wx, wz);
                assert!(
                    (0..=1600).contains(&h),
                    "h={} out of band at ({},{})",
                    h,
                    wx,
                    wz
                );
                wz += 331;
            }
            wx += 337;
        }
    }

    #[test]
    fn basins_and_mountains_and_lowland_median() {
        let mut heights = Vec::new();
        let mut wx = 0;
        while wx <= 32_000 {
            let mut wz = 0;
            while wz <= 32_000 {
                heights.push(ch(wx, wz));
                wz += 103;
            }
            wx += 101;
        }
        let min = *heights.iter().min().unwrap();
        let max = *heights.iter().max().unwrap();
        assert!(min < 64, "expected basins below sea level, got min {}", min);
        assert!(max > 500, "expected tall mountains, got max {}", max);

        heights.sort();
        let median = heights[heights.len() / 2];
        assert!(
            median < 256,
            "expected lowland-biased median, got {}",
            median
        );
    }

    #[test]
    fn negative_coords_floor_correctly() {
        // 不 panic、确定、落在带内即可(覆盖负坐标 floor 路径)。
        for &(wx, wz) in &[(-1, -1), (-12345, 6789), (-9000, -9000)] {
            let h = ch(wx, wz);
            assert!((0..=1600).contains(&h));
        }
    }

    #[test]
    fn v2_material_volume_is_deterministic_and_seeded() {
        let args = (0, 0, 0, SEED, SEA_LEVEL, MAX_HEIGHT, 4, 1, 2);
        let first = chunk_materials_impl(
            args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7, args.8,
        );
        let second = chunk_materials_impl(
            args.0, args.1, args.2, args.3, args.4, args.5, args.6, args.7, args.8,
        );
        assert_eq!(first, second);

        let changed_seed = chunk_materials_impl(0, 0, 0, SEED + 1, SEA_LEVEL, MAX_HEIGHT, 4, 1, 2);
        assert_ne!(first.0, changed_seed.0);
    }

    #[test]
    fn v2_seed_derivation_is_defined_at_i64_endpoints() {
        for seed in [i64::MIN, i64::MAX] {
            let (materials, stats) =
                chunk_materials_impl(0, 1760, 0, seed, SEA_LEVEL, MAX_HEIGHT, 4, 1, 2);
            assert!(materials.iter().all(|&material| material == 0));
            assert_eq!(stats, ChunkMaterialStats::default());
        }
    }

    #[test]
    fn v2_caves_exist_but_preserve_the_surface_cover() {
        let (_, cave_stats) = chunk_materials_impl(
            -2 * CHUNK_EDGE as i64,
            -3 * CHUNK_EDGE as i64,
            -8 * CHUNK_EDGE as i64,
            SEED,
            SEA_LEVEL,
            MAX_HEIGHT,
            4,
            1,
            2,
        );
        assert_eq!(cave_stats.cave_air_cells, 24);

        for z in -32..=32 {
            for x in -32..=32 {
                let height = column_height_impl(x, z, SEED, SEA_LEVEL, MAX_HEIGHT);
                for depth in 1..=CAVE_SURFACE_COVER {
                    assert_ne!(
                        cell_kind(x, height - depth, z, height, SEED, 4),
                        CellKind::CaveAir,
                        "surface cover was carved at ({},{},{})",
                        x,
                        height - depth,
                        z
                    );
                }
            }
        }
    }

    #[test]
    fn v2_deep_chunk_stays_uniform_subsurface() {
        let (materials, stats) = chunk_materials_impl(
            -16,
            CAVE_MIN_WORLD_Y - CHUNK_EDGE as i64,
            -16,
            SEED,
            SEA_LEVEL,
            MAX_HEIGHT,
            4,
            1,
            2,
        );
        assert!(materials.iter().all(|&material| material == 2));
        assert_eq!(stats.solid_cells, CHUNK_CELL_COUNT as u64);
        assert_eq!(stats.cave_air_cells, 0);
        assert_eq!(stats.surface_cells, 0);
        assert_eq!(stats.subsurface_cells, CHUNK_CELL_COUNT as u64);
    }

    #[test]
    fn v2_canonical_index_reads_absolute_world_coordinates_across_boundaries() {
        let (left, _) = chunk_materials_impl(-16, -32, -16, SEED, SEA_LEVEL, MAX_HEIGHT, 4, 1, 2);
        let (right, _) = chunk_materials_impl(0, -32, -16, SEED, SEA_LEVEL, MAX_HEIGHT, 4, 1, 2);

        for z in 0..CHUNK_EDGE {
            for y in 0..CHUNK_EDGE {
                let left_index = 15 + y * CHUNK_EDGE + z * CHUNK_EDGE * CHUNK_EDGE;
                let right_index = y * CHUNK_EDGE + z * CHUNK_EDGE * CHUNK_EDGE;
                let world_y = -32 + y as i64;
                let world_z = -16 + z as i64;
                let left_height = column_height_impl(-1, world_z, SEED, SEA_LEVEL, MAX_HEIGHT);
                let right_height = column_height_impl(0, world_z, SEED, SEA_LEVEL, MAX_HEIGHT);
                let expected_left = match cell_kind(-1, world_y, world_z, left_height, SEED, 4) {
                    CellKind::NaturalAir | CellKind::CaveAir => 0,
                    CellKind::Surface => 1,
                    CellKind::Subsurface => 2,
                };
                let expected_right = match cell_kind(0, world_y, world_z, right_height, SEED, 4) {
                    CellKind::NaturalAir | CellKind::CaveAir => 0,
                    CellKind::Surface => 1,
                    CellKind::Subsurface => 2,
                };
                assert_eq!(left[left_index], expected_left);
                assert_eq!(right[right_index], expected_right);
            }
        }
    }
}
