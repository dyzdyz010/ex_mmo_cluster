//! Authoritative movement correction payload and its flag vocabulary.
//!
//! `CorrectionFlags` is the semantic channel riding inside the already-wired
//! `MovementAck.correction_flags: u32`. The server OR-combines flags before
//! emitting the ack so the client can branch on intent (teleport, collision
//! push, status override, anti-cheat) instead of inferring it from distance.
//!
//! Bit layout is a two-way contract — keep in sync with
//! `apps/scene_server/lib/scene_server/movement/correction_flags.ex` and
//! `clients/bevy_client/src/sim/correction.rs`.

use crate::mode::MovementMode;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(transparent)]
/// Typed wrapper over the raw `u32` bitfield carried in `MovementAck`.
pub struct CorrectionFlags(pub u32);

impl CorrectionFlags {
    pub const NONE: Self = Self(0);

    /// Scripted teleport, respawn, or cross-scene transition.
    pub const TELEPORT: Self = Self(0x0000_0001);
    /// Physics pushed the avatar against the input direction (wall / knockback).
    pub const COLLISION_PUSH: Self = Self(0x0000_0002);
    /// Status effect overrides velocity or movement mode (stun, root, buff).
    pub const STATUS_OVERRIDE: Self = Self(0x0000_0004);
    /// Anti-cheat rejected the client-reported trajectory.
    pub const ANTI_CHEAT_REJECT: Self = Self(0x0000_0008);

    pub const fn from_bits(bits: u32) -> Self {
        Self(bits)
    }

    pub const fn bits(self) -> u32 {
        self.0
    }

    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }

    pub const fn contains(self, other: Self) -> bool {
        (self.0 & other.0) == other.0 && other.0 != 0
    }

    pub const fn is_teleport(self) -> bool {
        self.contains(Self::TELEPORT)
    }

    pub const fn is_collision_push(self) -> bool {
        self.contains(Self::COLLISION_PUSH)
    }

    pub const fn is_status_override(self) -> bool {
        self.contains(Self::STATUS_OVERRIDE)
    }

    pub const fn is_anti_cheat_reject(self) -> bool {
        self.contains(Self::ANTI_CHEAT_REJECT)
    }
}

impl std::ops::BitOr for CorrectionFlags {
    type Output = Self;
    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}

impl std::ops::BitOrAssign for CorrectionFlags {
    fn bitor_assign(&mut self, rhs: Self) {
        self.0 |= rhs.0;
    }
}

impl From<u32> for CorrectionFlags {
    fn from(bits: u32) -> Self {
        Self(bits)
    }
}

impl From<CorrectionFlags> for u32 {
    fn from(flags: CorrectionFlags) -> Self {
        flags.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct MovementAck {
    pub ack_seq: u32,
    pub auth_tick: u32,
    pub position: [f64; 3],
    pub velocity: [f64; 3],
    pub acceleration: [f64; 3],
    pub movement_mode: MovementMode,
    /// Raw bitfield — interpret via `CorrectionFlags::from_bits`.
    pub correction_flags: u32,
}

impl MovementAck {
    pub fn flags(&self) -> CorrectionFlags {
        CorrectionFlags::from_bits(self.correction_flags)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn none_is_empty_and_no_queries_match() {
        let flags = CorrectionFlags::NONE;
        assert!(flags.is_empty());
        assert!(!flags.is_teleport());
        assert!(!flags.is_collision_push());
        assert!(!flags.is_status_override());
        assert!(!flags.is_anti_cheat_reject());
    }

    #[test]
    fn bit_values_match_wire_contract() {
        assert_eq!(CorrectionFlags::TELEPORT.bits(), 0x01);
        assert_eq!(CorrectionFlags::COLLISION_PUSH.bits(), 0x02);
        assert_eq!(CorrectionFlags::STATUS_OVERRIDE.bits(), 0x04);
        assert_eq!(CorrectionFlags::ANTI_CHEAT_REJECT.bits(), 0x08);
    }

    #[test]
    fn bitor_combines_flags_and_queries_narrow_correctly() {
        let combined = CorrectionFlags::TELEPORT | CorrectionFlags::COLLISION_PUSH;
        assert!(combined.is_teleport());
        assert!(combined.is_collision_push());
        assert!(!combined.is_status_override());
        assert_eq!(combined.bits(), 0x03);
    }

    #[test]
    fn bitor_assign_accumulates() {
        let mut flags = CorrectionFlags::NONE;
        flags |= CorrectionFlags::COLLISION_PUSH;
        flags |= CorrectionFlags::STATUS_OVERRIDE;
        assert!(!flags.is_teleport());
        assert!(flags.is_collision_push());
        assert!(flags.is_status_override());
    }

    #[test]
    fn contains_requires_non_empty_probe() {
        let flags = CorrectionFlags::TELEPORT;
        assert!(flags.contains(CorrectionFlags::TELEPORT));
        assert!(!flags.contains(CorrectionFlags::NONE));
    }

    #[test]
    fn movement_ack_flags_roundtrip_through_u32() {
        let ack = MovementAck {
            ack_seq: 1,
            auth_tick: 2,
            position: [0.0, 0.0, 0.0],
            velocity: [0.0, 0.0, 0.0],
            acceleration: [0.0, 0.0, 0.0],
            movement_mode: MovementMode::default(),
            correction_flags: (CorrectionFlags::TELEPORT | CorrectionFlags::STATUS_OVERRIDE).bits(),
        };
        let flags = ack.flags();
        assert!(flags.is_teleport());
        assert!(flags.is_status_override());
        assert!(!flags.is_collision_push());
    }
}
