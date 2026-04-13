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
    pub fn is_npc(&self) -> bool {
        matches!(self.kind, RemoteActorKind::Npc)
    }
}
