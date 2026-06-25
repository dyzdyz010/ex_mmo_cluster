//! Runtime world-state helpers for local and remote actors.

use std::collections::HashMap;

use bevy::prelude::Resource;

use crate::world::remote_actor::RemoteActorIdentity;
use crate::world::remote_player::RemotePlayerState;

pub mod local_player;
pub mod remote_actor;
pub mod remote_player;

/// Registry of every remote actor currently in the AOI — their motion buffers,
/// identity metadata, and health (架构重整阶段2:从 `WorldState` god-resource 收口
/// 到 world 域)。Keyed by cid; the three maps are kept parallel (an entry in one
/// has, or will shortly have, a matching entry in the others) and cleared together
/// on scene entry / disconnect. Written by `net::poll_network_events` as
/// PlayerEnter / PlayerSnapshot / ActorIdentity / HealthUpdate / PlayerLeave
/// events arrive; read by HUD, presentation, skill targeting, and stdio queries.
#[derive(Resource, Default)]
pub struct RemotePlayers {
    /// Per-cid motion sample buffer (interpolation / extrapolation source).
    pub players: HashMap<i64, RemotePlayerState>,
    /// Per-cid identity metadata (player vs NPC, display name).
    pub identity: HashMap<i64, RemoteActorIdentity>,
    /// Per-cid `(hp, max_hp, alive)` health triple.
    pub health: HashMap<i64, (u16, u16, bool)>,
}
