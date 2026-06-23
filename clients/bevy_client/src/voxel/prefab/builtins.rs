//! Hand-written micro masks for the browser-compatible built-in prefabs.
//!
//! Counts must match the browser client (sphere=280 occupied slots,
//! cylinder=416, stairs intentionally not a protocol number) — verified by
//! `tests/voxel_parity.rs::builtin_prefabs_match_web_resolution_and_smoke_counts`.

use crate::voxel::core::mask::MicroMask;
use crate::voxel::core::{MICRO_PER_MACRO, MicroCoord};

pub(crate) fn sphere_mask() -> MicroMask {
    let mut mask = MicroMask::empty();
    let center = MICRO_PER_MACRO as f32 / 2.0;
    let radius = center - 0.1;
    for x in 0..MICRO_PER_MACRO {
        for y in 0..MICRO_PER_MACRO {
            for z in 0..MICRO_PER_MACRO {
                let dx = x as f32 + 0.5 - center;
                let dy = y as f32 + 0.5 - center;
                let dz = z as f32 + 0.5 - center;
                if (dx * dx + dy * dy + dz * dz).sqrt() <= radius {
                    mask.set(MicroCoord::new(x, y, z));
                }
            }
        }
    }
    mask
}

pub(crate) fn cylinder_mask() -> MicroMask {
    let mut mask = MicroMask::empty();
    let center = MICRO_PER_MACRO as f32 / 2.0;
    let radius = center - 0.1;
    for x in 0..MICRO_PER_MACRO {
        for y in 0..MICRO_PER_MACRO {
            for z in 0..MICRO_PER_MACRO {
                let dx = x as f32 + 0.5 - center;
                let dz = z as f32 + 0.5 - center;
                if (dx * dx + dz * dz).sqrt() <= radius {
                    mask.set(MicroCoord::new(x, y, z));
                }
            }
        }
    }
    mask
}

pub(crate) fn stairs_mask() -> MicroMask {
    // Discrete staircase rising along +z: each STEP-wide tread is RISE micros
    // taller than the previous. The old `((z+1)*MICRO_PER_MACRO/MICRO_PER_MACRO)`
    // reduced to the identity `z+1` (the *8/8 cancels), producing a continuous
    // 45° ramp, not stairs.
    const STEP: i32 = 2; // tread width in micros (along z)
    const RISE: i32 = 2; // rise in micros per step (along y)
    let mut mask = MicroMask::empty();
    for z in 0..MICRO_PER_MACRO {
        let height = (((z / STEP) + 1) * RISE).min(MICRO_PER_MACRO); // count of solid y cells
        for y in 0..height {
            for x in 1..=6 {
                mask.set(MicroCoord::new(x, y, z));
            }
        }
    }
    mask
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stairs_is_discrete_steps_not_a_ramp() {
        // STEP=2, RISE=2 → per-z solid-cell heights [2,2,4,4,6,6,8,8], × 6 x-cols
        // (x in 1..=6) = 240 occupied slots. The old `((z+1)*8/8)` ramp produced
        // 258 (heights [2,3,4,5,6,7,8,8]), so 240 locks the staircase shape.
        assert_eq!(stairs_mask().occupied_slot_count(), 240);

        // Tread flatness: two z's of one step share a height; the next step is
        // taller. Cell x=3: z=0 & z=1 fill y=1 (height 2) but NOT y=2; z=2 (next
        // step, height 4) fills y=2.
        let m = stairs_mask();
        assert!(m.contains(MicroCoord::new(3, 1, 0)));
        assert!(m.contains(MicroCoord::new(3, 1, 1)));
        assert!(!m.contains(MicroCoord::new(3, 2, 0)));
        assert!(!m.contains(MicroCoord::new(3, 2, 1)));
        assert!(m.contains(MicroCoord::new(3, 2, 2)));
    }
}
