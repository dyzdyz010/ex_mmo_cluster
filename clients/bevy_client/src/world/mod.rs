//! Runtime world-state helpers for local and remote actors.

use std::collections::HashMap;

use bevy::prelude::{Resource, Vec3};

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
/// The local (own) player's authoritative runtime state — cid, position,
/// velocity, and health (架构重整阶段2:从 `WorldState` god-resource 收口到 world
/// 域,WorldState 至此清空并删除)。Server-authoritative: written only by
/// `net::poll_network_events` (EnteredScene / LocalPosition / HealthUpdate /
/// disconnect) and the post-login cid seed; the prediction/visual layers read it
/// (camera follow, movement stop-sync, presentation, HUD).
#[derive(Resource)]
pub struct LocalPlayerState {
    /// The local actor's character id (0 before scene entry).
    pub cid: i64,
    /// Last authoritative sim-space position (`None` after disconnect).
    pub position: Option<Vec3>,
    /// Last authoritative sim-space velocity.
    pub velocity: Vec3,
    /// Current hit points.
    pub hp: u16,
    /// Maximum hit points.
    pub max_hp: u16,
    /// Whether the local actor is alive.
    pub alive: bool,
}

impl Default for LocalPlayerState {
    fn default() -> Self {
        Self {
            cid: 0,
            position: Some(Vec3::ZERO),
            velocity: Vec3::ZERO,
            hp: 100,
            max_hp: 100,
            alive: true,
        }
    }
}

#[derive(Resource, Default)]
pub struct RemotePlayers {
    /// Per-cid motion sample buffer (interpolation / extrapolation source).
    pub players: HashMap<i64, RemotePlayerState>,
    /// Per-cid identity metadata (player vs NPC, display name).
    pub identity: HashMap<i64, RemoteActorIdentity>,
    /// Per-cid `(hp, max_hp, alive)` health triple.
    pub health: HashMap<i64, (u16, u16, bool)>,
}
