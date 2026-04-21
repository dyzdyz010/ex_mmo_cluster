//! Client-side classification of server correction intent.
//!
//! The server emits `MovementAck.correction_flags: u32` as a bitfield defined
//! by `movement_core::CorrectionFlags`. This module adds a `CorrectionKind`
//! classifier that picks a single dispatch branch when multiple bits coexist,
//! letting the reconciler branch on intent (teleport, collision push, status
//! override, anti-cheat reject) instead of inferring it from raw distance.
//!
//! Severity priority — AntiCheatReject > Teleport > StatusOverride >
//! CollisionPush > None — so bad-trajectory and scene-change branches
//! always wipe history before less-destructive branches run.

pub use movement_core::CorrectionFlags;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CorrectionKind {
    None,
    Teleport,
    AntiCheatReject,
    StatusOverride,
    CollisionPush,
}

impl CorrectionKind {
    pub fn classify(flags: CorrectionFlags) -> Self {
        if flags.is_anti_cheat_reject() {
            CorrectionKind::AntiCheatReject
        } else if flags.is_teleport() {
            CorrectionKind::Teleport
        } else if flags.is_status_override() {
            CorrectionKind::StatusOverride
        } else if flags.is_collision_push() {
            CorrectionKind::CollisionPush
        } else {
            CorrectionKind::None
        }
    }

    pub fn from_bits(bits: u32) -> Self {
        Self::classify(CorrectionFlags::from_bits(bits))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_bits_classify_as_none() {
        assert_eq!(CorrectionKind::from_bits(0), CorrectionKind::None);
    }

    #[test]
    fn single_bits_classify_by_name() {
        assert_eq!(
            CorrectionKind::from_bits(CorrectionFlags::TELEPORT.bits()),
            CorrectionKind::Teleport
        );
        assert_eq!(
            CorrectionKind::from_bits(CorrectionFlags::COLLISION_PUSH.bits()),
            CorrectionKind::CollisionPush
        );
        assert_eq!(
            CorrectionKind::from_bits(CorrectionFlags::STATUS_OVERRIDE.bits()),
            CorrectionKind::StatusOverride
        );
        assert_eq!(
            CorrectionKind::from_bits(CorrectionFlags::ANTI_CHEAT_REJECT.bits()),
            CorrectionKind::AntiCheatReject
        );
    }

    #[test]
    fn anti_cheat_wins_over_all_others() {
        let bits = CorrectionFlags::ANTI_CHEAT_REJECT.bits()
            | CorrectionFlags::TELEPORT.bits()
            | CorrectionFlags::COLLISION_PUSH.bits()
            | CorrectionFlags::STATUS_OVERRIDE.bits();
        assert_eq!(
            CorrectionKind::from_bits(bits),
            CorrectionKind::AntiCheatReject
        );
    }

    #[test]
    fn teleport_wins_over_status_and_collision() {
        let bits = CorrectionFlags::TELEPORT.bits()
            | CorrectionFlags::STATUS_OVERRIDE.bits()
            | CorrectionFlags::COLLISION_PUSH.bits();
        assert_eq!(CorrectionKind::from_bits(bits), CorrectionKind::Teleport);
    }

    #[test]
    fn status_override_wins_over_collision_push() {
        let bits = CorrectionFlags::STATUS_OVERRIDE.bits() | CorrectionFlags::COLLISION_PUSH.bits();
        assert_eq!(
            CorrectionKind::from_bits(bits),
            CorrectionKind::StatusOverride
        );
    }
}
