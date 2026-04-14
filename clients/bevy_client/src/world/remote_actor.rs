//! Remote actor identity metadata tracked alongside motion state.
//!
//! Motion snapshots and actor identity are kept separate on purpose:
//!
//! - motion buffers solve interpolation/extrapolation
//! - identity metadata answers what kind of thing an actor is
//!
//! This avoids encoding gameplay type assumptions into CID ranges or snapshot
//! heuristics.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteActorKind {
    Player,
    Npc,
    Unknown(u8),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteActorIdentity {
    pub cid: i64,
    pub kind: RemoteActorKind,
    pub name: String,
}

impl RemoteActorIdentity {
    /// Returns whether this remote actor should be treated as an NPC in
    /// presentation/UI logic.
    pub fn is_npc(&self) -> bool {
        matches!(self.kind, RemoteActorKind::Npc)
    }
}
