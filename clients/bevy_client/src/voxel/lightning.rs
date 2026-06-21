//! Lightning-bolt geometry + simulation (pure-data port of the web reference's
//! `lightningBoltRenderer.ts`). A bolt is a transient jagged line from a source
//! to a target world point: a jittered main path plus a couple of branches,
//! flickering and fading over a short TTL. This is the visual feedback for an
//! electric DISCHARGE/breakdown (the server's `ElectricDischargeKernel`).
//!
//! Split (like debris / heat_smoke): pure data + geometry here — no Bevy, no GPU
//! — so the segment count, endpoints, jitter bounds, decay, and bolt cap are all
//! Layer-1 assertable. The Bevy adapter builds a `LineList` mesh from
//! `segments()` and an additive/emissive material, advancing it each frame.
//!
//! Determinism: the per-bolt RNG is a stable hash of an explicit `seed` (caller
//! supplies, e.g. from the field tick / a strike counter), so tests pin the exact
//! jittered geometry without a clock. Positions are WORLD units.

/// Reference defaults (web `lightningBoltRenderer`).
pub const DEFAULT_MAX_BOLTS: usize = 6;
pub const DEFAULT_TTL_MS: f32 = 480.0;
const MAIN_SEGMENTS_PER_BOLT: usize = 18;
const BRANCH_COUNT: usize = 2;
const BRANCH_SEGMENTS: usize = 4;

/// World units per macro cell + chunk size (shared with heat_smoke's mapping, so
/// a bolt arcs through the same world space the smoke rises in).
pub const MACRO_WORLD: f32 = 100.0;
const CHUNK_SIZE_MACRO: i32 = 16;

/// A cell counts as on the discharge channel once its ionization byte clears this
/// (matches `field_view`'s `IONIZATION_THRESHOLD` of 8.0 — the plasma-glow floor).
pub const IONIZATION_DISCHARGE_THRESHOLD: u8 = 8;

/// Segments emitted per bolt: one main run + per-branch runs.
pub const SEGMENTS_PER_BOLT: usize = MAIN_SEGMENTS_PER_BOLT + BRANCH_COUNT * BRANCH_SEGMENTS;

/// One live bolt: source→target world points, age, ttl, and the jitter seed.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LightningBolt {
    pub source: [f32; 3],
    pub target: [f32; 3],
    pub age_ms: f32,
    pub ttl_ms: f32,
    pub seed: i32,
}

#[derive(Debug, Clone, Copy)]
pub struct LightningConfig {
    pub max_bolts: usize,
    pub ttl_ms: f32,
}

impl Default for LightningConfig {
    fn default() -> Self {
        Self {
            max_bolts: DEFAULT_MAX_BOLTS,
            ttl_ms: DEFAULT_TTL_MS,
        }
    }
}

/// Pure bolt pool: `strike` adds, `update` ages + expires, `segments` emits the
/// current jagged line geometry. No Bevy.
#[derive(Debug, Default)]
pub struct LightningSimulation {
    bolts: Vec<LightningBolt>,
    config: LightningConfig,
}

impl LightningSimulation {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_config(config: LightningConfig) -> Self {
        Self {
            bolts: Vec::new(),
            config,
        }
    }

    /// Strikes a bolt from `source` to `target` (world units). `seed` drives the
    /// stable per-bolt jitter (e.g. hash of the cells + a counter). Caps the live
    /// bolt count, trimming the oldest (front).
    pub fn strike(&mut self, source: [f32; 3], target: [f32; 3], seed: i32) {
        self.bolts.push(LightningBolt {
            source,
            target,
            age_ms: 0.0,
            ttl_ms: self.config.ttl_ms,
            seed,
        });
        if self.bolts.len() > self.config.max_bolts {
            let overflow = self.bolts.len() - self.config.max_bolts;
            self.bolts.drain(0..overflow);
        }
    }

    /// Ages every bolt by `dt_ms`, dropping those past their (per-bolt) ttl.
    pub fn update(&mut self, dt_ms: f32) {
        if dt_ms <= 0.0 {
            return;
        }
        for bolt in &mut self.bolts {
            bolt.age_ms += dt_ms;
        }
        self.bolts.retain(|b| b.age_ms < b.ttl_ms);
    }

    pub fn active_count(&self) -> usize {
        self.bolts.len()
    }

    pub fn live_bolts(&self) -> &[LightningBolt] {
        &self.bolts
    }

    pub fn reset(&mut self) {
        self.bolts.clear();
    }

    /// Brightness `[0,1]` of the brightest live bolt (fades with age) — the adapter
    /// maps this to overall bolt opacity. 0 when no bolts.
    pub fn max_life(&self) -> f32 {
        self.bolts
            .iter()
            .map(|b| (1.0 - b.age_ms / b.ttl_ms).max(0.0))
            .fold(0.0, f32::max)
    }

    /// All line segments (each a pair of world points) for every live bolt — the
    /// jagged main path plus branches, jittered by age-driven flicker.
    pub fn segments(&self) -> Vec<[[f32; 3]; 2]> {
        let mut out = Vec::with_capacity(self.bolts.len() * SEGMENTS_PER_BOLT);
        for bolt in &self.bolts {
            push_bolt_segments(bolt, &mut out);
        }
        out
    }
}

/// Emits one bolt's main + branch segments into `out` (mirrors `writeBoltSegments`).
fn push_bolt_segments(bolt: &LightningBolt, out: &mut Vec<[[f32; 3]; 2]>) {
    let d = sub(bolt.target, bolt.source);
    let length = norm(d).max(1.0);
    let flicker = (bolt.age_ms / 28.0).floor() as i32;
    let jitter_scale = (length * 0.06).clamp(14.0, 55.0);

    // Main jagged path.
    let mut previous = point_on_bolt(bolt, 0.0, 0, jitter_scale, flicker);
    for index in 1..=MAIN_SEGMENTS_PER_BOLT {
        let t = index as f32 / MAIN_SEGMENTS_PER_BOLT as f32;
        let next = point_on_bolt(bolt, t, index as i32, jitter_scale, flicker);
        out.push([previous, next]);
        previous = next;
    }

    // Branches forking off the main path.
    for branch in 0..BRANCH_COUNT {
        let start_t = 0.28 + branch as f32 * 0.24;
        let mut branch_start = point_on_bolt(
            bolt,
            start_t,
            (MAIN_SEGMENTS_PER_BOLT + branch) as i32,
            jitter_scale,
            flicker,
        );
        let branch_length = length * (0.14 + branch as f32 * 0.04);
        let branch_sign = if branch % 2 == 0 { 1.0 } else { -1.0 };
        for index in 1..=BRANCH_SEGMENTS {
            let branch_t = index as f32 / BRANCH_SEGMENTS as f32;
            let next = [
                branch_start[0]
                    + branch_sign * branch_length * 0.18
                    + branch_sign * branch_t * branch_length * 0.12,
                branch_start[1] - branch_t * branch_length * 0.18,
                branch_start[2] + branch_t * branch_length * 0.22,
            ];
            out.push([branch_start, next]);
            branch_start = next;
        }
    }
}

/// A point along the bolt at parameter `t` (0=source, 1=target), perpendicular-
/// jittered by a hash of (seed, index, flicker), edge-faded by `sin(pi*t)` so the
/// endpoints stay anchored. Mirrors `pointOnBolt`.
fn point_on_bolt(
    bolt: &LightningBolt,
    t: f32,
    index: i32,
    jitter_scale: f32,
    flicker: i32,
) -> [f32; 3] {
    if t <= 0.0 {
        return bolt.source;
    }
    if t >= 1.0 {
        return bolt.target;
    }
    let d = sub(bolt.target, bolt.source);
    let length = norm(d).max(1.0);
    let inv = 1.0 / length;
    let n = [d[0] * inv, d[1] * inv, d[2] * inv];

    // A vector p not parallel to n, then q = n × p gives a perpendicular basis.
    let (px, py, pz) = if n[1].abs() < 0.9 {
        (0.0, 1.0, 0.0)
    } else {
        (1.0, 0.0, 0.0)
    };
    let q = [
        n[1] * pz - n[2] * py,
        n[2] * px - n[0] * pz,
        n[0] * py - n[1] * px,
    ];
    let q_len = norm(q).max(1.0);

    let edge_fade = (std::f32::consts::PI * t).sin();
    let jitter_a =
        (hash_unit(bolt.seed.wrapping_add(index.wrapping_mul(131)).wrapping_add(flicker.wrapping_mul(17))) - 0.5)
            * jitter_scale
            * edge_fade;
    let jitter_b =
        (hash_unit(bolt.seed.wrapping_add(index.wrapping_mul(197)).wrapping_add(flicker.wrapping_mul(31))) - 0.5)
            * jitter_scale
            * edge_fade;

    [
        bolt.source[0] + d[0] * t + px * jitter_a + (q[0] / q_len) * jitter_b,
        bolt.source[1] + d[1] * t + py * jitter_a + (q[1] / q_len) * jitter_b,
        bolt.source[2] + d[2] * t + pz * jitter_a + (q[2] / q_len) * jitter_b,
    ]
}

/// Stable hash of `value` → `[0, 1)` (xorshift, matching web `hashUnit`).
fn hash_unit(value: i32) -> f32 {
    let mut h = value;
    h ^= h << 13;
    h ^= ((h as u32) >> 17) as i32;
    h ^= h << 5;
    ((h as u32) % 10_000) as f32 / 10_000.0
}

/// A stable per-strike seed from source/target macro coords + a salt (mirrors
/// `boltSeed`; the salt replaces the reference's `Math.floor(nowMs)` for
/// determinism — pass e.g. a strike counter or field tick).
pub fn bolt_seed(source: [i32; 3], target: [i32; 3], salt: i32) -> i32 {
    source[0].wrapping_mul(73_856_093)
        ^ source[1].wrapping_mul(19_349_663)
        ^ source[2].wrapping_mul(83_492_791)
        ^ target[0].wrapping_mul(0x9E37_79B1u32 as i32)
        ^ target[1].wrapping_mul(805_459_861)
        ^ target[2].wrapping_mul(367_465_342)
        ^ salt
}

/// A borrowed view of one discharge field snapshot (0x73 with an ionization
/// layer) — the strike-inference input, kept pure / Bevy-free like
/// heat_smoke's `ElectricField`. The bolt arcs across the ionized channel.
pub struct DischargeField<'a> {
    pub region_id: u64,
    pub chunk_coord: [i32; 3],
    pub macro_indices: &'a [u16],
    /// Index-aligned with `macro_indices`; empty if the snapshot had no potential
    /// layer (then the strike falls back to spatial extremes).
    pub electric_potential: &'a [f32],
    /// Index-aligned with `macro_indices`; cells `>= IONIZATION_DISCHARGE_THRESHOLD`
    /// are on the breakdown channel.
    pub ionization: &'a [u8],
}

/// World center of a macro cell `(x,y,z)` within `chunk` (matches heat_smoke's
/// `build_particle` origin mapping, minus the per-axis vertical bias).
fn macro_cell_world(chunk: [i32; 3], cell: [i32; 3]) -> [f32; 3] {
    [
        ((chunk[0] * CHUNK_SIZE_MACRO + cell[0]) as f32 + 0.5) * MACRO_WORLD,
        ((chunk[1] * CHUNK_SIZE_MACRO + cell[1]) as f32 + 0.5) * MACRO_WORLD,
        ((chunk[2] * CHUNK_SIZE_MACRO + cell[2]) as f32 + 0.5) * MACRO_WORLD,
    ]
}

/// Infers a lightning strike from a discharge field: the bolt arcs from the
/// highest-potential ionized cell to the lowest-potential ionized cell (the
/// breakdown gradient). When potential is absent or flat across the channel, it
/// falls back to the two spatially-farthest ionized cells. Returns the source +
/// target world points and a stable jitter seed (so the same snapshot always
/// draws the same bolt), or `None` when fewer than two cells are ionized — no
/// channel to arc across.
///
/// `salt` distinguishes successive strikes on the same channel (pass a per-arrival
/// counter or the region tick), folded into the seed.
pub fn infer_strike(field: &DischargeField, salt: i32) -> Option<([f32; 3], [f32; 3], i32)> {
    // Gather the ionized cells (channel) with their macro coords + potential.
    let mut channel: Vec<([i32; 3], Option<f32>)> = Vec::new();
    for (i, &idx) in field.macro_indices.iter().enumerate() {
        let ion = field.ionization.get(i).copied().unwrap_or(0);
        if ion < IONIZATION_DISCHARGE_THRESHOLD {
            continue;
        }
        let cell = macro_index_to_cell(idx);
        let potential = field
            .electric_potential
            .get(i)
            .copied()
            .filter(|v| v.is_finite());
        channel.push((cell, potential));
    }
    if channel.len() < 2 {
        return None;
    }

    // Prefer the potential gradient: source = max V, target = min V. Usable only
    // if every channel cell carries a (finite) potential AND it isn't flat.
    let all_have_potential = channel.iter().all(|(_, p)| p.is_some());
    let (src_cell, dst_cell) = if all_have_potential {
        let mut hi = channel[0];
        let mut lo = channel[0];
        for &entry in &channel {
            if entry.1 > hi.1 {
                hi = entry;
            }
            if entry.1 < lo.1 {
                lo = entry;
            }
        }
        if hi.1 == lo.1 {
            farthest_pair(&channel)
        } else {
            (hi.0, lo.0)
        }
    } else {
        farthest_pair(&channel)
    };

    let source = macro_cell_world(field.chunk_coord, src_cell);
    let target = macro_cell_world(field.chunk_coord, dst_cell);
    let src_macro = [
        field.chunk_coord[0] * CHUNK_SIZE_MACRO + src_cell[0],
        field.chunk_coord[1] * CHUNK_SIZE_MACRO + src_cell[1],
        field.chunk_coord[2] * CHUNK_SIZE_MACRO + src_cell[2],
    ];
    let dst_macro = [
        field.chunk_coord[0] * CHUNK_SIZE_MACRO + dst_cell[0],
        field.chunk_coord[1] * CHUNK_SIZE_MACRO + dst_cell[1],
        field.chunk_coord[2] * CHUNK_SIZE_MACRO + dst_cell[2],
    ];
    let seed = bolt_seed(src_macro, dst_macro, salt.wrapping_add(field.region_id as i32));
    Some((source, target, seed))
}

/// The two channel cells farthest apart (spatial fallback when potential can't
/// order the endpoints). `channel` is non-empty by the caller's `len() >= 2`.
fn farthest_pair(channel: &[([i32; 3], Option<f32>)]) -> ([i32; 3], [i32; 3]) {
    let mut best = (channel[0].0, channel[1].0);
    let mut best_d2 = -1i64;
    for i in 0..channel.len() {
        for j in (i + 1)..channel.len() {
            let a = channel[i].0;
            let b = channel[j].0;
            let d2 = (a[0] - b[0]) as i64 * (a[0] - b[0]) as i64
                + (a[1] - b[1]) as i64 * (a[1] - b[1]) as i64
                + (a[2] - b[2]) as i64 * (a[2] - b[2]) as i64;
            if d2 > best_d2 {
                best_d2 = d2;
                best = (a, b);
            }
        }
    }
    best
}

/// Macro index → `(x,y,z)` cell within its chunk (4 bits/axis, 16³ chunk — the
/// same packing heat_smoke decodes).
fn macro_index_to_cell(idx: u16) -> [i32; 3] {
    let i = idx as i32;
    [i & 0xf, (i >> 4) & 0xf, (i >> 8) & 0xf]
}

fn sub(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn norm(v: [f32; 3]) -> f32 {
    (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: [f32; 3], b: [f32; 3], eps: f32) -> bool {
        (a[0] - b[0]).abs() < eps && (a[1] - b[1]).abs() < eps && (a[2] - b[2]).abs() < eps
    }

    #[test]
    fn strike_emits_main_plus_branch_segments_anchored_at_endpoints() {
        let mut sim = LightningSimulation::new();
        let source = [0.0, 0.0, 0.0];
        let target = [0.0, 1000.0, 0.0];
        sim.strike(source, target, 12345);
        assert_eq!(sim.active_count(), 1);

        let segs = sim.segments();
        assert_eq!(segs.len(), SEGMENTS_PER_BOLT); // 18 main + 2*4 branches = 26
        // The main path's first segment starts exactly at the source...
        assert!(approx(segs[0][0], source, 1e-3), "first point is source");
        // ...and the main path's last segment ends exactly at the target.
        assert!(
            approx(segs[MAIN_SEGMENTS_PER_BOLT - 1][1], target, 1e-3),
            "last main point is target"
        );
    }

    #[test]
    fn jitter_is_bounded_and_endpoints_unjittered() {
        let mut sim = LightningSimulation::new();
        sim.strike([0.0, 0.0, 0.0], [0.0, 1000.0, 0.0], 999);
        let segs = sim.segments();
        // Interior main points deviate from the straight line by < jitter_scale
        // (length*0.06 = 60, clamped to 55). Endpoints are exact (edge_fade=0).
        for seg in &segs[..MAIN_SEGMENTS_PER_BOLT] {
            for p in seg {
                let lateral = (p[0] * p[0] + p[2] * p[2]).sqrt(); // off the y axis
                assert!(lateral <= 56.0, "jitter within bound; got {lateral}");
            }
        }
    }

    #[test]
    fn deterministic_for_same_seed() {
        let mut a = LightningSimulation::new();
        let mut b = LightningSimulation::new();
        a.strike([1.0, 2.0, 3.0], [10.0, 200.0, 30.0], 42);
        b.strike([1.0, 2.0, 3.0], [10.0, 200.0, 30.0], 42);
        assert_eq!(a.segments(), b.segments());
        // Different seed → different geometry.
        let mut c = LightningSimulation::new();
        c.strike([1.0, 2.0, 3.0], [10.0, 200.0, 30.0], 43);
        assert_ne!(a.segments(), c.segments());
    }

    #[test]
    fn bolts_expire_at_ttl_and_fade() {
        let mut sim = LightningSimulation::with_config(LightningConfig {
            ttl_ms: 480.0,
            ..Default::default()
        });
        sim.strike([0.0, 0.0, 0.0], [0.0, 100.0, 0.0], 1);
        assert!((sim.max_life() - 1.0).abs() < 1e-3); // fresh = full brightness
        sim.update(240.0);
        assert!((sim.max_life() - 0.5).abs() < 1e-2); // half-aged = half bright
        sim.update(240.0); // reaches ttl → expires
        assert_eq!(sim.active_count(), 0);
        assert_eq!(sim.max_life(), 0.0);
    }

    #[test]
    fn bolt_cap_trims_oldest() {
        let mut sim = LightningSimulation::with_config(LightningConfig {
            max_bolts: 3,
            ..Default::default()
        });
        for i in 0..6 {
            sim.strike([i as f32, 0.0, 0.0], [i as f32, 100.0, 0.0], i);
        }
        assert_eq!(sim.active_count(), 3);
        // Oldest (i=0,1,2) trimmed; newest (3,4,5) survive.
        let xs: Vec<f32> = sim.live_bolts().iter().map(|b| b.source[0]).collect();
        assert_eq!(xs, vec![3.0, 4.0, 5.0]);
    }

    #[test]
    fn bolt_seed_is_stable_and_coord_sensitive() {
        let s = bolt_seed([1, 2, 3], [4, 5, 6], 7);
        assert_eq!(s, bolt_seed([1, 2, 3], [4, 5, 6], 7));
        assert_ne!(s, bolt_seed([1, 2, 3], [4, 5, 6], 8)); // salt matters
        assert_ne!(s, bolt_seed([9, 2, 3], [4, 5, 6], 7)); // source matters
    }

    #[test]
    fn infer_strike_arcs_high_to_low_potential() {
        // Three ionized cells along x at chunk (0,0,0): cell 0 (V=200, source),
        // cell 1 (V=50), cell 2 (V=-30, target). Bolt should go cell0 → cell2.
        let indices = [0u16, 1, 2];
        let field = DischargeField {
            region_id: 3,
            chunk_coord: [0, 0, 0],
            macro_indices: &indices,
            electric_potential: &[200.0, 50.0, -30.0],
            ionization: &[200, 180, 160],
        };
        let (source, target, _seed) = infer_strike(&field, 0).expect("two+ ionized cells → strike");
        // cell 0 center = (0.5*100, 0.5*100, 0.5*100); cell 2 center x = 2.5*100.
        assert!((source[0] - 50.0).abs() < 1e-3, "source at high-V cell 0");
        assert!((target[0] - 250.0).abs() < 1e-3, "target at low-V cell 2");
    }

    #[test]
    fn infer_strike_needs_two_ionized_cells() {
        let indices = [0u16, 1];
        // Only one cell clears the ionization floor → no channel to arc.
        let field = DischargeField {
            region_id: 1,
            chunk_coord: [0, 0, 0],
            macro_indices: &indices,
            electric_potential: &[100.0, 0.0],
            ionization: &[200, 1],
        };
        assert!(infer_strike(&field, 0).is_none());
    }

    #[test]
    fn infer_strike_spatial_fallback_without_potential() {
        // No potential layer → endpoints are the two farthest ionized cells.
        // Cells at x=0 and x=5 (index 5 = (5,0,0)) are farthest.
        let indices = [0u16, 1, 5];
        let field = DischargeField {
            region_id: 2,
            chunk_coord: [0, 0, 0],
            macro_indices: &indices,
            electric_potential: &[],
            ionization: &[64, 64, 64],
        };
        let (source, target, _) = infer_strike(&field, 0).expect("spatial fallback strike");
        let span = (source[0] - target[0]).abs();
        assert!((span - 500.0).abs() < 1e-3, "endpoints span cells 0..5 = 500 world units");
    }

    #[test]
    fn infer_strike_offsets_by_chunk_coord() {
        let indices = [0u16, 1];
        let field = DischargeField {
            region_id: 1,
            chunk_coord: [1, 0, 0],
            macro_indices: &indices,
            electric_potential: &[100.0, 0.0],
            ionization: &[200, 200],
        };
        let (source, _target, _) = infer_strike(&field, 0).unwrap();
        // chunk x=1 → macro 16; cell 0 center = (16.5)*100 = 1650.
        assert!((source[0] - 1650.0).abs() < 1e-3);
    }
}
