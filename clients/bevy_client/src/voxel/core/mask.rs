//! Fixed-size 512-bit micro occupancy mask.

use serde::{Deserialize, Serialize};

use super::coord::{MICRO_MASK_WORDS, MicroCoord, micro_linear_index};

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
}

impl Default for MicroMask {
    fn default() -> Self {
        Self::empty()
    }
}
