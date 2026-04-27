//! Fixed-size 512-bit micro occupancy mask.

use serde::{Deserialize, Serialize};

use super::coord::{
    MICRO_MASK_WORDS, MICRO_PER_MACRO, MacroCoord, MicroCoord, micro_coord_from_index,
    micro_linear_index,
};

/// Fixed 512-bit micro occupancy mask stored as eight little-endian u64 words.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MicroMask {
    words: [u64; MICRO_MASK_WORDS],
}

impl MicroMask {
    /// Empty occupancy.
    pub const fn empty() -> Self {
        Self {
            words: [0; MICRO_MASK_WORDS],
        }
    }

    /// Full macro occupancy.
    pub const fn full() -> Self {
        Self {
            words: [u64::MAX; MICRO_MASK_WORDS],
        }
    }

    /// Returns true when no micro slots are occupied.
    pub fn is_empty(self) -> bool {
        self.words.iter().all(|word| *word == 0)
    }

    /// Counts occupied micro slots.
    pub fn occupied_slot_count(self) -> u32 {
        self.words.iter().map(|word| word.count_ones()).sum()
    }

    /// Returns whether a local micro coord is occupied.
    pub fn contains(self, coord: MicroCoord) -> bool {
        let Some(index) = micro_linear_index(coord) else {
            return false;
        };
        self.contains_index(index)
    }

    pub(crate) fn contains_index(self, index: usize) -> bool {
        let word = index / 64;
        let bit = index % 64;
        (self.words[word] & (1_u64 << bit)) != 0
    }

    pub(crate) fn set(&mut self, coord: MicroCoord) -> bool {
        let Some(index) = micro_linear_index(coord) else {
            return false;
        };
        self.set_index(index);
        true
    }

    pub(crate) fn set_index(&mut self, index: usize) {
        let word = index / 64;
        let bit = index % 64;
        self.words[word] |= 1_u64 << bit;
    }

    pub(crate) fn clear(&mut self, coord: MicroCoord) -> bool {
        let Some(index) = micro_linear_index(coord) else {
            return false;
        };
        let word = index / 64;
        let bit = index % 64;
        self.words[word] &= !(1_u64 << bit);
        true
    }

    pub(crate) fn overlaps(self, other: Self) -> bool {
        self.words
            .iter()
            .zip(other.words)
            .any(|(left, right)| (*left & right) != 0)
    }

    pub(crate) fn overlap_count(self, other: Self) -> u32 {
        self.words
            .iter()
            .zip(other.words)
            .map(|(left, right)| (*left & right).count_ones())
            .sum()
    }

    pub(crate) fn union(self, other: Self) -> Self {
        let mut words = [0; MICRO_MASK_WORDS];
        for (index, word) in words.iter_mut().enumerate() {
            *word = self.words[index] | other.words[index];
        }
        Self { words }
    }

    pub(crate) fn indices(self) -> impl Iterator<Item = usize> {
        self.words
            .into_iter()
            .enumerate()
            .flat_map(|(word_index, word)| {
                (0..64).filter_map(move |bit| {
                    ((word & (1_u64 << bit)) != 0).then_some(word_index * 64 + bit)
                })
            })
    }

    /// Shifts every set micro slot by `shift_x/y/z` and returns one mask
    /// per destination macro the slots fall into. Used by prefab
    /// micro-snap (design 2026-04-26): a single source macro's mask can
    /// straddle up to 8 destination macros once shifted.
    ///
    /// Returns `(macro_offset_relative_to_source, sub_mask)` pairs.
    /// `macro_offset` is signed because negative shifts are valid.
    pub fn shift_to_neighbours(
        self,
        shift_x: i32,
        shift_y: i32,
        shift_z: i32,
    ) -> Vec<(MacroCoord, MicroMask)> {
        let mut buckets: std::collections::BTreeMap<MacroCoord, MicroMask> =
            std::collections::BTreeMap::new();
        for index in self.indices() {
            let Some(local) = micro_coord_from_index(index) else {
                continue;
            };
            let nx = local.x + shift_x;
            let ny = local.y + shift_y;
            let nz = local.z + shift_z;
            let macro_off = MacroCoord::new(
                nx.div_euclid(MICRO_PER_MACRO),
                ny.div_euclid(MICRO_PER_MACRO),
                nz.div_euclid(MICRO_PER_MACRO),
            );
            let dest = MicroCoord::new(
                nx.rem_euclid(MICRO_PER_MACRO),
                ny.rem_euclid(MICRO_PER_MACRO),
                nz.rem_euclid(MICRO_PER_MACRO),
            );
            buckets
                .entry(macro_off)
                .or_insert_with(MicroMask::empty)
                .set(dest);
        }
        buckets.into_iter().collect()
    }
}

impl Default for MicroMask {
    fn default() -> Self {
        Self::empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mask_with(coords: &[(i32, i32, i32)]) -> MicroMask {
        let mut mask = MicroMask::empty();
        for &(x, y, z) in coords {
            mask.set(MicroCoord::new(x, y, z));
        }
        mask
    }

    #[test]
    fn shift_zero_returns_single_bucket_at_origin() {
        let mask = mask_with(&[(0, 0, 0), (3, 4, 5), (7, 7, 7)]);
        let result = mask.shift_to_neighbours(0, 0, 0);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].0, MacroCoord::new(0, 0, 0));
        assert_eq!(result[0].1, mask);
    }

    #[test]
    fn shift_within_bounds_stays_in_origin_macro() {
        let mask = mask_with(&[(0, 0, 0)]);
        let result = mask.shift_to_neighbours(3, 0, 0);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].0, MacroCoord::new(0, 0, 0));
        assert!(result[0].1.contains(MicroCoord::new(3, 0, 0)));
        assert_eq!(result[0].1.occupied_slot_count(), 1);
    }

    #[test]
    fn shift_crossing_positive_boundary_splits_into_neighbour_macro() {
        let mask = mask_with(&[(7, 0, 0)]);
        let result = mask.shift_to_neighbours(1, 0, 0);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].0, MacroCoord::new(1, 0, 0));
        assert!(result[0].1.contains(MicroCoord::new(0, 0, 0)));
    }

    #[test]
    fn shift_crossing_negative_boundary_uses_div_euclid() {
        // local (0,0,0) shifted by (-1,0,0) → macro (-1,0,0), micro (7,0,0)
        let mask = mask_with(&[(0, 0, 0)]);
        let result = mask.shift_to_neighbours(-1, 0, 0);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].0, MacroCoord::new(-1, 0, 0));
        assert!(result[0].1.contains(MicroCoord::new(7, 0, 0)));
    }

    #[test]
    fn full_mask_shift_5_along_x_splits_into_two_macros_with_correct_counts() {
        let result = MicroMask::full().shift_to_neighbours(5, 0, 0);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].0, MacroCoord::new(0, 0, 0));
        assert_eq!(result[1].0, MacroCoord::new(1, 0, 0));
        // local x in 0..3 stays in origin macro at micro x in 5..8 → 3 columns
        // each column has 8*8 = 64 slots, total 192
        // local x in 3..8 moves to next macro at micro x in 0..5 → 5 columns
        // each column has 64 slots, total 320
        assert_eq!(result[0].1.occupied_slot_count(), 3 * 64);
        assert_eq!(result[1].1.occupied_slot_count(), 5 * 64);
        // Sum reproduces the full 512 slots.
        assert_eq!(
            result[0].1.occupied_slot_count() + result[1].1.occupied_slot_count(),
            512
        );
    }

    #[test]
    fn full_mask_shift_diagonal_splits_into_eight_macros() {
        let result = MicroMask::full().shift_to_neighbours(5, 3, 7);
        assert_eq!(result.len(), 8);
        // Total slots conserved.
        let total: u32 = result
            .iter()
            .map(|(_, mask)| mask.occupied_slot_count())
            .sum();
        assert_eq!(total, 512);
    }
}
