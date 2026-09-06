//! C++ WorldGen 的整数哈希、value noise、fbm 与逐 octave 的严格盒上界。
pub(crate) const CAVE: [(f64, f64); 3] = [(96.0, 1.0), (48.0, 0.55), (24.0, 0.28)];
pub(crate) const VEIN: [(f64, f64); 3] = [(112.0, 1.0), (44.0, 0.5), (19.0, 0.28)];
pub(crate) const CAVE_SALT: u32 = 0x43415645;
pub(crate) const VEIN_SALT: u32 = 0x5645494e;
const LOWLAND: [(f64, f64); 5] = [
    (4096.0, 1.0),
    (1024.0, 0.7),
    (256.0, 0.45),
    (64.0, 0.25),
    (16.0, 0.1),
];
const MOUNTAIN: [(f64, f64); 3] = [(4096.0, 1.0), (2048.0, 0.55), (1024.0, 0.28)];

pub(crate) fn squirrel(mut n: u32, seed: u32) -> u32 {
    n = n.wrapping_mul(0x68e31da4).wrapping_add(seed);
    n ^= n >> 8;
    n = n.wrapping_add(0xb5297a4d);
    n ^= n << 8;
    n = n.wrapping_mul(0x1b56c4e9);
    n ^ (n >> 8)
}
fn lattice2(x: i64, z: i64, seed: u32) -> f64 {
    squirrel(
        (x as u32).wrapping_add(198491317u32.wrapping_mul(z as u32)),
        seed,
    ) as f64
        / 4294967296.0
}
fn lattice3(x: i64, y: i64, z: i64, seed: u32) -> f64 {
    let x = squirrel(x as u32, seed ^ 0xa511e9b3);
    let y = squirrel(y as u32, x ^ 0x63d835d9);
    squirrel(z as u32, y ^ 0xb5297a4d) as f64 / 4294967296.0
}
pub(crate) fn smooth(t: f64) -> f64 {
    t * t * (3.0 - 2.0 * t)
}
fn fade(t: f64) -> f64 {
    t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}
fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}
pub(crate) fn noise2(x: f64, z: f64, seed: u32) -> f64 {
    let ix = x.floor() as i64;
    let iz = z.floor() as i64;
    let sx = smooth(x - ix as f64);
    let sz = smooth(z - iz as f64);
    lerp(
        lerp(lattice2(ix, iz, seed), lattice2(ix + 1, iz, seed), sx),
        lerp(
            lattice2(ix, iz + 1, seed),
            lattice2(ix + 1, iz + 1, seed),
            sx,
        ),
        sz,
    )
}
fn noise3(x: f64, y: f64, z: f64, seed: u32) -> f64 {
    let ix = x.floor() as i64;
    let iy = y.floor() as i64;
    let iz = z.floor() as i64;
    let sx = fade(x - ix as f64);
    let sy = fade(y - iy as f64);
    let sz = fade(z - iz as f64);
    let z0 = lerp(
        lerp(
            lattice3(ix, iy, iz, seed),
            lattice3(ix + 1, iy, iz, seed),
            sx,
        ),
        lerp(
            lattice3(ix, iy + 1, iz, seed),
            lattice3(ix + 1, iy + 1, iz, seed),
            sx,
        ),
        sy,
    );
    let z1 = lerp(
        lerp(
            lattice3(ix, iy, iz + 1, seed),
            lattice3(ix + 1, iy, iz + 1, seed),
            sx,
        ),
        lerp(
            lattice3(ix, iy + 1, iz + 1, seed),
            lattice3(ix + 1, iy + 1, iz + 1, seed),
            sx,
        ),
        sy,
    );
    lerp(z0, z1, sz)
}
pub(crate) fn lowland(x: f64, z: f64, seed: u32) -> f64 {
    let mut sum = 0.0;
    let mut norm = 0.0;
    for (i, &(w, a)) in LOWLAND.iter().enumerate() {
        sum += noise2(x / w, z / w, seed.wrapping_add(i as u32)) * a;
        norm += a;
    }
    (sum / norm).clamp(0.0, 1.0)
}
pub(crate) fn ridged(x: f64, z: f64, seed: u32) -> f64 {
    let mut sum = 0.0;
    let mut norm = 0.0;
    for (i, &(w, a)) in MOUNTAIN.iter().enumerate() {
        let ridge = 1.0 - (2.0 * noise2(x / w, z / w, seed.wrapping_add(i as u32)) - 1.0).abs();
        sum += ridge * ridge * a;
        norm += a;
    }
    (sum / norm).clamp(0.0, 1.0)
}
pub(crate) fn climate(x: f64, z: f64, wavelength: f64, seed: u32) -> f64 {
    let mut sum = 0.0;
    let mut norm = 0.0;
    for (i, (w, a)) in [(1.0, 1.0), (1.0 / 3.0, 0.4)].into_iter().enumerate() {
        let w = wavelength * w;
        sum += noise2(
            x / w,
            z / w,
            seed.wrapping_add((i as u32).wrapping_mul(0x9e3779b9)),
        ) * a;
        norm += a;
    }
    (sum / norm).clamp(0.0, 1.0)
}
pub(crate) fn fbm3(octaves: &[(f64, f64)], p: [i32; 3], seed: u32) -> f64 {
    let mut sum = 0.0;
    let mut norm = 0.0;
    for (i, &(w, a)) in octaves.iter().enumerate() {
        sum += noise3(
            p[0] as f64 / w,
            p[1] as f64 / w,
            p[2] as f64 / w,
            seed.wrapping_add((i as u32).wrapping_mul(0x9e3779b9)),
        ) * a;
        norm += a;
    }
    (sum / norm).clamp(0.0, 1.0)
}

pub(crate) fn upper_bound(
    octaves: &[(f64, f64); 3],
    min: [i32; 3],
    max: [i32; 3],
    seed: u32,
) -> f64 {
    // L0–L5 的盒边最多 32 米；每轴至多八个候选平面，无需历史预算分支。
    let mut candidates = [[0.0; 12]; 3];
    let mut count = [2; 3];
    for axis in 0..3 {
        candidates[axis][0] = min[axis] as f64;
        candidates[axis][1] = max[axis] as f64;
        for &(w, _) in octaves {
            let first = (min[axis] as f64 / w).floor() as i64 + 1;
            let last = (max[axis] as f64 / w).floor() as i64;
            for plane in first..=last {
                candidates[axis][count[axis]] = plane as f64 * w;
                count[axis] += 1;
            }
        }
        candidates[axis][..count[axis]].sort_unstable_by(f64::total_cmp);
    }
    let stride = count[0];
    let slice = stride * count[1];
    let mut values = [[0.0; 12 * 12 * 12]; 3];
    let mut norm = 0.0;
    for (i, &(w, a)) in octaves.iter().enumerate() {
        norm += a;
        let s = seed.wrapping_add((i as u32).wrapping_mul(0x9e3779b9));
        for z in 0..count[2] {
            for y in 0..count[1] {
                for x in 0..count[0] {
                    values[i][x + stride * y + slice * z] = noise3(
                        candidates[0][x] / w,
                        candidates[1][y] / w,
                        candidates[2][z] / w,
                        s,
                    );
                }
            }
        }
    }
    let mut best = 0.0f64;
    for z in 0..count[2] - 1 {
        for y in 0..count[1] - 1 {
            for x in 0..count[0] - 1 {
                let mut sum = 0.0;
                for (i, &(_, a)) in octaves.iter().enumerate() {
                    let mut vmax = 0.0f64;
                    for corner in 0..8 {
                        vmax = vmax.max(
                            values[i][x
                                + (corner & 1)
                                + stride * (y + ((corner >> 1) & 1))
                                + slice * (z + ((corner >> 2) & 1))],
                        );
                    }
                    sum += vmax * a;
                }
                best = best.max(sum / norm);
            }
        }
    }
    best.min(1.0) + 1e-9
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn octave_sum_bound_contains_every_integer_sample() {
        // 非谐波矿脉、负坐标和跨格点盒，锁住“先各自取最大再求和”的严格性。
        let mut state = 1337u32;
        for (octaves, salt) in [(&CAVE, CAVE_SALT), (&VEIN, VEIN_SALT)] {
            for _ in 0..24 {
                let min = std::array::from_fn(|_| {
                    state = squirrel(state, 123);
                    (state % 2048) as i32 - 1024
                });
                let width = 1 + (state % 32) as i32;
                let max = min.map(|v| v + width - 1);
                let bound = upper_bound(octaves, min, max, state ^ salt);
                for z in min[2]..=max[2] {
                    for y in min[1]..=max[1] {
                        for x in min[0]..=max[0] {
                            assert!(
                                fbm3(octaves, [x, y, z], state ^ salt) <= bound,
                                "min={min:?} width={width}"
                            );
                        }
                    }
                }
            }
        }
    }
}
