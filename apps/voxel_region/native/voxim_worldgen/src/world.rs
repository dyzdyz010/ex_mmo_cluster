//! 列画像、自然洞口、矿脉与粗层递归剪枝；所有生成路径共用同一分类规则。
use crate::{
    noise::*,
    skin::{self, Value, EXTENT, OWNED},
};

/// 与 FVoxelWorldGenConfig 同序的八项世界配置。
#[derive(Clone, Copy, Debug)]
pub struct Config {
    /// 世界种子，整数噪声使用低 32 位。
    pub seed: i64,
    /// 列高下界。
    pub min_height: i32,
    /// 海平面与基岩分带参考高度。
    pub sea_level: i32,
    /// 列高上界。
    pub max_height: i32,
    /// 从地表起计算的土层深度。
    pub soil_depth: i32,
    /// 低地振幅，米。
    pub lowland_amplitude: f64,
    /// 山脉振幅，米。
    pub mountain_amplitude: f64,
    /// 洞穴与矿脉最大深度。
    pub cave_max_depth: i32,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            seed: 1337,
            min_height: 4,
            sea_level: 64,
            max_height: 512,
            soil_depth: 4,
            lowland_amplitude: 50.0,
            mountain_amplitude: 100.0,
            cave_max_depth: 96,
        }
    }
}
const CAVE_MIN_Y: i32 = -384;
const CAVE_COVER: i32 = 12;
const CAVE_THRESHOLD: f64 = 0.69;
const VEIN_THRESHOLD: f64 = 0.745;
const GRID: i32 = 128;
const MOUTH_DEPTH: i32 = 2;
const INNER_DEPTH: i32 = 36;
const TUNNEL_RADIUS: i32 = 6;
const CHAMBER_RADIUS: i32 = 12;
const SLOPE_BASELINE: i32 = 4;
const GRANITE_DEPTH: i32 = 96;
const BASALT_DEPTH: i32 = 288;
const ENTRANCE_SALT: u32 = 0x454e5452;

fn column_height(x: i32, z: i32, c: &Config) -> i32 {
    let x = x as f64;
    let z = z as f64;
    let seed = c.seed as u32;
    let low = c.sea_level as f64 + (lowland(x, z, seed) - 0.5) * c.lowland_amplitude;
    let mask = noise2(x / 3000.0, z / 3000.0, seed.wrapping_add(100));
    let gate = smooth(((mask - 0.38) / (0.66 - 0.38)).clamp(0.0, 1.0));
    let mountain = c.mountain_amplitude * gate * ridged(x, z, seed.wrapping_add(200)).powf(1.6);
    // UE RoundToInt：负半值也向正无穷取整。
    let height = (low + mountain + 0.5).floor() as i32;
    if height < c.min_height {
        c.min_height
    } else if height < c.max_height {
        height
    } else {
        c.max_height
    }
}
#[derive(Clone, Copy)]
struct Profile {
    height: i32,
    cover: u16,
    soil: u16,
    province: u16,
}
fn profile(x: i32, z: i32, height: i32, slope: i32, c: &Config) -> Profile {
    let seed = c.seed as u32;
    let temperature = climate(x as f64, z as f64, 1536.0, seed.wrapping_add(300))
        - (height - c.sea_level) as f64 * 0.0008;
    let moisture = climate(x as f64, z as f64, 768.0, seed.wrapping_add(400));
    let desert = temperature >= 0.22 && moisture < 0.30;
    let mut cover = 1;
    let mut soil = 7;
    if slope < 5 {
        if slope >= 3 {
            cover = 6;
        } else if temperature < 0.10 {
            cover = 4;
        } else if temperature < 0.22 {
            cover = 3;
        } else if desert {
            cover = 5;
            soil = 5;
        } else if moisture < 0.42 {
            cover = 2;
        } else if moisture >= 0.60 {
            soil = 8;
        }
    }
    let noise = climate(x as f64, z as f64, 1024.0, seed.wrapping_add(500));
    let province = if desert {
        9
    } else if noise < 0.34 {
        10
    } else if noise < 0.60 {
        11
    } else if noise < 0.80 {
        14
    } else {
        12
    };
    if slope >= 5 {
        cover = province;
        soil = province;
    }
    Profile {
        height,
        cover,
        soil,
        province,
    }
}
#[derive(Clone, Copy)]
struct Entrance {
    mouth: [i32; 2],
    inner: [i32; 2],
}
impl Entrance {
    fn new(gx: i32, gz: i32, c: &Config) -> Self {
        let ox = gx * GRID;
        let oz = gz * GRID;
        let mut hash = squirrel(gx as u32, c.seed as u32 ^ ENTRANCE_SALT);
        hash = squirrel(gz as u32, hash ^ 0x9e3779b9);
        let edge = hash & 3;
        hash = squirrel(hash, ENTRANCE_SALT ^ 0xa511e9b3);
        let along = 24 + (hash % ((GRID - 48) as u32)) as i32;
        hash = squirrel(hash, ENTRANCE_SALT ^ 0x63d835d9);
        let dx = (hash % 17) as i32 - 8;
        hash = squirrel(hash, ENTRANCE_SALT ^ 0xb5297a4d);
        let dz = (hash % 17) as i32 - 8;
        let mouth = match edge {
            0 => [ox + 8, oz + along],
            1 => [ox + GRID - 9, oz + along],
            2 => [ox + along, oz + 8],
            _ => [ox + along, oz + GRID - 9],
        };
        Self {
            mouth,
            inner: [ox + GRID / 2 + dx, oz + GRID / 2 + dz],
        }
    }
    fn segment(&self) -> [f64; 3] {
        [
            (self.inner[0] - self.mouth[0]) as f64,
            (INNER_DEPTH - MOUTH_DEPTH) as f64,
            (self.inner[1] - self.mouth[1]) as f64,
        ]
    }
    fn air(&self, x: i32, depth: i64, z: i32) -> bool {
        let s = self.segment();
        let p = [
            (x - self.mouth[0]) as f64,
            (depth - MOUTH_DEPTH as i64) as f64,
            (z - self.mouth[1]) as f64,
        ];
        let t = ((p[0] * s[0] + p[1] * s[1] + p[2] * s[2])
            / (s[0] * s[0] + s[1] * s[1] + s[2] * s[2]))
            .clamp(0.0, 1.0);
        let d = [p[0] - s[0] * t, p[1] - s[1] * t, p[2] - s[2] * t];
        if d[0] * d[0] + d[1] * d[1] + d[2] * d[2] <= (TUNNEL_RADIUS * TUNNEL_RADIUS) as f64 {
            return true;
        }
        let d = [
            (x - self.inner[0]) as f64,
            (depth - INNER_DEPTH as i64) as f64,
            (z - self.inner[1]) as f64,
        ];
        d[0] * d[0] + d[1] * d[1] + d[2] * d[2] <= (CHAMBER_RADIUS * CHAMBER_RADIUS) as f64
    }
    fn may_intersect(&self, min: [i32; 3], max: [i32; 3], dmin: i64, dmax: i64) -> bool {
        let distance = |p: [f64; 3]| {
            let dx = (min[0] as f64 - p[0]).max(p[0] - max[0] as f64).max(0.0);
            let dd = (dmin as f64 - p[1]).max(p[1] - dmax as f64).max(0.0);
            let dz = (min[2] as f64 - p[2]).max(p[2] - max[2] as f64).max(0.0);
            dx * dx + dd * dd + dz * dz
        };
        if distance([
            self.inner[0] as f64,
            INNER_DEPTH as f64,
            self.inner[1] as f64,
        ]) <= (CHAMBER_RADIUS * CHAMBER_RADIUS) as f64
        {
            return true;
        }
        let s = self.segment();
        let length = (s[0] * s[0] + s[1] * s[1] + s[2] * s[2]).sqrt();
        let steps = (length / TUNNEL_RADIUS as f64).ceil().max(1.0) as i32;
        let threshold = TUNNEL_RADIUS as f64 + length / steps as f64;
        (0..=steps).any(|step| {
            let t = step as f64 / steps as f64;
            distance([
                self.mouth[0] as f64 + s[0] * t,
                MOUTH_DEPTH as f64 + s[1] * t,
                self.mouth[1] as f64 + s[2] * t,
            ]) <= threshold * threshold
        })
    }
}
struct Entrances {
    gx: i32,
    gz: i32,
    nx: i32,
    entries: Vec<Entrance>,
}
impl Entrances {
    fn new(origin: [i32; 3], span: i32, c: &Config) -> Self {
        let gx = origin[0].div_euclid(GRID);
        let gz = origin[2].div_euclid(GRID);
        let ex = (origin[0] + span - 1).div_euclid(GRID);
        let ez = (origin[2] + span - 1).div_euclid(GRID);
        let mut entries = Vec::new();
        for z in gz..=ez {
            for x in gx..=ex {
                entries.push(Entrance::new(x, z, c));
            }
        }
        Self {
            gx,
            gz,
            nx: ex - gx + 1,
            entries,
        }
    }
    fn grid(&self, gx: i32, gz: i32) -> &Entrance {
        &self.entries[((gx - self.gx) + self.nx * (gz - self.gz)) as usize]
    }
    fn at(&self, x: i32, z: i32) -> &Entrance {
        self.grid(x.div_euclid(GRID), z.div_euclid(GRID))
    }
    fn may_intersect(&self, min: [i32; 3], max: [i32; 3], dmin: i64, dmax: i64) -> bool {
        if dmin > (INNER_DEPTH + CHAMBER_RADIUS) as i64 {
            return false;
        }
        for gz in min[2].div_euclid(GRID)..=max[2].div_euclid(GRID) {
            for gx in min[0].div_euclid(GRID)..=max[0].div_euclid(GRID) {
                if self.grid(gx, gz).may_intersect(min, max, dmin, dmax) {
                    return true;
                }
            }
        }
        false
    }
}
fn classify(
    p: [i32; 3],
    profile: Profile,
    entrance: &Entrance,
    c: &Config,
    free: [bool; 3],
) -> u16 {
    let [x, y, z] = p;
    if y >= profile.height {
        return 0;
    }
    let depth = profile.height as i64 - y as i64;
    if !free[1] && depth <= (INNER_DEPTH + CHAMBER_RADIUS) as i64 && entrance.air(x, depth, z) {
        return 0;
    }
    if !free[0]
        && y >= CAVE_MIN_Y
        && depth > CAVE_COVER as i64
        && depth <= c.cave_max_depth as i64
        && fbm3(&CAVE, p, c.seed as u32 ^ CAVE_SALT) > CAVE_THRESHOLD
    {
        return 0;
    }
    if depth == 1 {
        return profile.cover;
    }
    if depth <= c.soil_depth as i64 {
        return profile.soil;
    }
    if !free[2]
        && depth <= c.cave_max_depth as i64
        && fbm3(&VEIN, p, c.seed as u32 ^ VEIN_SALT) > VEIN_THRESHOLD
    {
        return if depth <= 24 {
            15
        } else if depth <= 52 {
            16
        } else if depth <= 80 {
            17
        } else {
            18
        };
    }
    if y < c.sea_level - BASALT_DEPTH {
        13
    } else if y < c.sea_level - GRANITE_DEPTH {
        12
    } else {
        profile.province
    }
}
#[derive(Clone, Copy)]
struct Node {
    hmin: i32,
    hmax: i32,
    min: [u16; 3],
    max: [u16; 3],
}
impl Node {
    fn from(p: Profile) -> Self {
        Self {
            hmin: p.height,
            hmax: p.height,
            min: [p.cover, p.soil, p.province],
            max: [p.cover, p.soil, p.province],
        }
    }
    fn combine(a: Self, b: Self) -> Self {
        Self {
            hmin: a.hmin.min(b.hmin),
            hmax: a.hmax.max(b.hmax),
            min: std::array::from_fn(|i| a.min[i].min(b.min[i])),
            max: std::array::from_fn(|i| a.max[i].max(b.max[i])),
        }
    }
}
struct Columns {
    origin: [i32; 3],
    span: usize,
    profiles: Vec<Profile>,
    pyramid: Vec<Vec<Node>>,
}
impl Columns {
    fn new(origin: [i32; 3], span: usize, level: i32, c: &Config) -> Self {
        let d = SLOPE_BASELINE as usize;
        let hspan = span + 2 * d;
        let mut heights = Vec::with_capacity(hspan * hspan);
        for z in 0..hspan {
            for x in 0..hspan {
                heights.push(column_height(
                    origin[0] + x as i32 - d as i32,
                    origin[2] + z as i32 - d as i32,
                    c,
                ));
            }
        }
        let mut profiles = Vec::with_capacity(span * span);
        let mut nodes = Vec::with_capacity(span * span);
        for z in 0..span {
            for x in 0..span {
                let i = x + d + hspan * (z + d);
                let h = heights[i];
                let slope = [
                    heights[i - d],
                    heights[i + d],
                    heights[i - d * hspan],
                    heights[i + d * hspan],
                ]
                .map(|n| (n - h).abs())
                .into_iter()
                .max()
                .unwrap();
                let p = profile(origin[0] + x as i32, origin[2] + z as i32, h, slope, c);
                profiles.push(p);
                nodes.push(Node::from(p));
            }
        }
        let mut pyramid = vec![nodes];
        for l in 1..=level {
            let fine = span >> (l - 1);
            let res = span >> l;
            let prev = &pyramid[(l - 1) as usize];
            let mut nodes = Vec::with_capacity(res * res);
            for z in 0..res {
                for x in 0..res {
                    let i = 2 * x + fine * 2 * z;
                    nodes.push(Node::combine(
                        Node::combine(prev[i], prev[i + 1]),
                        Node::combine(prev[i + fine], prev[i + fine + 1]),
                    ));
                }
            }
            pyramid.push(nodes);
        }
        Self {
            origin,
            span,
            profiles,
            pyramid,
        }
    }
    fn profile(&self, x: i32, z: i32) -> Profile {
        self.profiles[(x - self.origin[0]) as usize + self.span * (z - self.origin[2]) as usize]
    }
    fn node(&self, l: i32, cell: [i32; 3]) -> Node {
        self.pyramid[l as usize][(cell[0] - (self.origin[0] >> l)) as usize
            + (self.span >> l) * (cell[2] - (self.origin[2] >> l)) as usize]
    }
}
struct Evaluator<'a> {
    c: &'a Config,
    columns: Columns,
    entrances: Entrances,
    deep: i32,
}
impl Evaluator<'_> {
    fn rock(&self, min: [i32; 3], max: [i32; 3], node: Node) -> u16 {
        let basalt = self.c.sea_level - BASALT_DEPTH;
        let granite = self.c.sea_level - GRANITE_DEPTH;
        if max[1] < basalt {
            13
        } else if min[1] < basalt {
            0
        } else if max[1] < granite {
            12
        } else if min[1] < granite {
            0
        } else if node.min[2] == node.max[2] {
            node.min[2]
        } else {
            0
        }
    }
    fn evaluate(&self, l: i32, cell: [i32; 3], mut free: [bool; 3]) -> Value {
        let scale = 1 << l;
        let min = cell.map(|v| v * scale);
        let max = min.map(|v| v + scale - 1);
        let node = self.columns.node(l, cell);
        if min[1] >= node.hmax {
            return Value::uniform(0);
        }
        if max[1] < node.hmin - self.deep {
            let rock = self.rock(min, max, node);
            if rock != 0 {
                return Value::uniform(rock);
            }
        }
        if l == 0 {
            return Value::uniform(classify(
                cell,
                self.columns.profile(cell[0], cell[2]),
                self.entrances.at(cell[0], cell[2]),
                self.c,
                free,
            ));
        }
        let dmin = node.hmin as i64 - max[1] as i64;
        let dmax = node.hmax as i64 - min[1] as i64;
        if !free[1] {
            free[1] = !self.entrances.may_intersect(min, max, dmin, dmax);
        }
        if !free[0] {
            free[0] = max[1] < CAVE_MIN_Y
                || dmax <= CAVE_COVER as i64
                || dmin > self.c.cave_max_depth as i64
                || upper_bound(&CAVE, min, max, self.c.seed as u32 ^ CAVE_SALT) <= CAVE_THRESHOLD;
        }
        if !free[2] {
            free[2] = dmax <= self.c.soil_depth as i64
                || dmin > self.c.cave_max_depth as i64
                || upper_bound(&VEIN, min, max, self.c.seed as u32 ^ VEIN_SALT) <= VEIN_THRESHOLD;
        }
        if free[0] && free[1] && max[1] < node.hmin {
            if dmin > self.c.soil_depth as i64 {
                if free[2] {
                    let rock = self.rock(min, max, node);
                    if rock != 0 {
                        return Value::uniform(rock);
                    }
                }
            } else if dmax <= 1 {
                if node.min[0] == node.max[0] {
                    return Value::uniform(node.min[0]);
                }
            } else if dmin > 1 && dmax <= self.c.soil_depth as i64 && node.min[1] == node.max[1] {
                return Value::uniform(node.min[1]);
            }
        }
        let children = std::array::from_fn(|octant| {
            self.evaluate(
                l - 1,
                std::array::from_fn(|axis| cell[axis] * 2 + ((octant >> axis) & 1) as i32),
                free,
            )
        });
        skin::reduce(&children, l)
    }
}

/// 生成完整 66³ cells 与六向表皮，并编码为既有未压缩 body；level 为 0–5。
pub fn generate_body(level: i32, coord: [i32; 3], config: &Config) -> Vec<u8> {
    let origin = coord.map(|v| v * OWNED - 1);
    let canonical = origin.map(|v| v * (1 << level));
    let span = EXTENT << level;
    let evaluator = Evaluator {
        c: config,
        columns: Columns::new(canonical, span, level, config),
        entrances: Entrances::new(canonical, span as i32, config),
        deep: config
            .cave_max_depth
            .max(INNER_DEPTH + CHAMBER_RADIUS)
            .max(config.soil_depth),
    };
    let mut cells = Vec::with_capacity(EXTENT.pow(3));
    let mut records = Vec::new();
    for z in 0..EXTENT {
        for y in 0..EXTENT {
            for x in 0..EXTENT {
                let cell = [
                    origin[0] + x as i32,
                    origin[1] + y as i32,
                    origin[2] + z as i32,
                ];
                let value = evaluator.evaluate(level, cell, [false; 3]);
                if !value.skins.trivial(value.material) {
                    records.push((cells.len(), value.skins));
                }
                cells.push(value.material);
            }
        }
    }
    skin::encode(&cells, &records, level)
}
