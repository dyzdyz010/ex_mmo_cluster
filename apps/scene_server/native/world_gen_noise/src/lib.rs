//! 地形噪声 NIF（阶段3 step3.1 重写为 Rust）。
//!
//! 把 `SceneServer.Voxel.WorldGen` 里逐列高度的重计算从 Elixir 移到 Rust——
//! 架构纪律:重计算必须落在 Rust。chunk 生成与已归档 heightmap 离线迁移工具
//! 共用 `column_height`，保证历史产物的确定性；在线运行时不读取 heightmap。
//!
//! 移植自 Elixir 的分层 value-noise 模型(常量/公式逐字对齐):
//!   lowland 基底(平缓滚动,凹陷成盆地) + 稀疏高山(低频 mask 选区 + ridged 分形)。
//!
//! SquirrelNoise(Squirrel Eiserloh)整数哈希全程 u32 wrapping,与 Elixir 里
//! `band(_, 0xFFFFFFFF)` 行为一致;Rust native u32 天然环绕,无需显式掩码。

use rustler::{Binary, Env, OwnedBinary};

rustler::init!("Elixir.SceneServer.Native.WorldGenNoise");

// ── 噪声常量(与 Elixir 模块属性逐字对齐)─────────────────────────────────────
const NOISE1: u32 = 0x68E3_1DA4;
const NOISE2: u32 = 0xB529_7A4D;
const NOISE3: u32 = 0x1B56_C4E9;
const LATTICE_PRIME: i64 = 198_491_317;

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

// ── 分形 ────────────────────────────────────────────────────────────────────

/// value-noise octave 分形和,归一化到 ~[0, 1]。
fn fbm(wx: f64, wz: f64, seed: i64) -> f64 {
    let mut sum = 0.0;
    let mut norm = 0.0;
    for (octave, &(wavelength, amplitude)) in OCTAVES.iter().enumerate() {
        let s = (seed + octave as i64) as u32;
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
        let s = (seed + octave as i64) as u32;
        let v = value_noise(wx / wavelength, wz / wavelength, s);
        let ridge = 1.0 - (2.0 * v - 1.0).abs();
        sum += ridge * ridge * amplitude;
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
        (seed + 100) as u32,
    );
    let gate = smoothstep_range(mask, MOUNTAIN_MASK_LO, MOUNTAIN_MASK_HI);
    let ridge = ridged_fbm(wxf, wzf, seed + 200);
    let mountain = MOUNTAIN_AMPLITUDE * gate * ridge.powf(RIDGE_POWER);

    // Elixir round/1 是 half away from zero;f64::round 同。
    let h = (lowland + mountain).round() as i64;
    h.max(0).min(max_height)
}

// ── NIF surface ─────────────────────────────────────────────────────────────

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
                assert!((0..=1600).contains(&h), "h={} out of band at ({},{})", h, wx, wz);
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
        assert!(median < 256, "expected lowland-biased median, got {}", median);
    }

    #[test]
    fn negative_coords_floor_correctly() {
        // 不 panic、确定、落在带内即可(覆盖负坐标 floor 路径)。
        for &(wx, wz) in &[(-1, -1), (-12345, 6789), (-9000, -9000)] {
            let h = ch(wx, wz);
            assert!((0..=1600).contains(&h));
        }
    }
}
