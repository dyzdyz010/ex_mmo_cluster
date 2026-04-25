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
    let mut mask = MicroMask::empty();
    for x in 0..MICRO_PER_MACRO {
        for y in 0..MICRO_PER_MACRO {
            for z in 0..MICRO_PER_MACRO {
                let max_y = ((z + 1) * MICRO_PER_MACRO / MICRO_PER_MACRO).max(1);
                if y <= max_y && (1..=6).contains(&x) {
                    mask.set(MicroCoord::new(x, y, z));
                }
            }
        }
    }
    mask
}
