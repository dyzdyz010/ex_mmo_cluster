//! Session domain — identity (credentials) + connection lifecycle.
//!
//! Single home for *who the player is* and (in later phases) *whether we're
//! connected*. Authentication — the dev auto-login HTTP handshake — lives in
//! [`session::auth`](crate::session::auth). `SessionCredentials` moved here from
//! `config` so other layers reach for identity through one domain rather than a
//! grab-bag config module (架构重整阶段1:认证收口).
//!
//! Later phases add `ConnectionPhase` (the connect → handshake → in-scene →
//! reconnect state machine) and a `SessionPlugin` driving the net thread's
//! start / stop / reconnect, so identity + connection liveness have a single
//! authoritative owner instead of being scattered across `net` + `WorldState`.

use bevy::prelude::Resource;
use std::fmt;

pub mod auth;
pub mod plugin;
pub mod reconnect;

pub use plugin::SessionPlugin;

/// Where the client is in the connect → in-scene → reconnect lifecycle
/// (架构重整阶段4:`status` String 之外引入显式相位枚举,驱动退避重连 UI/逻辑)。
///
/// `scene_joined`(旧 bool)派生自 `phase == InScene`,所以断线时所有 in-world 系统
/// 自动停摆——旧实现断线后 `scene_joined` 仍为 true 是个潜在 bug,相位化顺带修掉。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionPhase {
    /// Connecting / authenticating; not in a scene yet.
    Connecting,
    /// Fully in a scene (the server confirmed scene entry).
    InScene,
    /// Connection dropped; backing off before reconnect attempt `attempt`
    /// (`attempt == 0` = just dropped, not yet retried).
    Reconnecting { attempt: u32 },
    /// Gave up after exhausting the reconnect budget (terminal until the user
    /// restarts). Surfaced so the HUD can show a definitive "please restart".
    Failed,
}

impl ConnectionPhase {
    /// Whether the client is fully in a scene — gates every in-world system
    /// (camera follow, movement upload, voxel subscribe/render, skill cast …).
    pub fn is_in_scene(&self) -> bool {
        matches!(self, ConnectionPhase::InScene)
    }
}

/// Connection / scene-membership liveness — the single owner of "where are we in
/// the connection lifecycle" (架构重整阶段1b 从 `WorldState` 收口到 session;阶段4
/// 把 scene_joined bool 演进为 `ConnectionPhase` 相位机)。
#[derive(Resource)]
pub struct ConnectionState {
    /// Lifecycle phase — the single source of truth for connection liveness.
    pub phase: ConnectionPhase,
    /// Latest human-readable status detail surfaced by the HUD / stdio harness
    /// (net `Status` events, phase-transition messages).
    pub status: String,
}

impl Default for ConnectionState {
    fn default() -> Self {
        Self {
            phase: ConnectionPhase::Connecting,
            status: String::new(),
        }
    }
}

impl ConnectionState {
    /// True once the server confirmed scene entry (derives from `phase`).
    pub fn scene_joined(&self) -> bool {
        self.phase.is_in_scene()
    }
}

#[derive(Clone, Resource)]
/// Credentials returned by the dev auto-login endpoint after the user submits a username.
pub struct SessionCredentials {
    pub username: String,
    pub cid: i64,
    pub token: String,
    /// Advertised token lifetime in seconds, if the auth response carried an
    /// `expires_in` field (架构重整阶段4 令牌过期接缝)。`None` when the server did
    /// not advertise a TTL — proactive refresh is then disabled and the reactive
    /// reconnect path refreshes the token on any real drop. See
    /// [`reconnect::proactive_refresh_due`].
    pub expires_in_secs: Option<u64>,
}

// Audit E-M2: hand-written Debug that redacts the token. The auto-derived
// Debug printed the token verbatim, leaking it into any panic/log/observer
// dump. Keep username and cid visible (they are not secret) so the field is
// still useful in diagnostics.
impl fmt::Debug for SessionCredentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SessionCredentials")
            .field("username", &self.username)
            .field("cid", &self.cid)
            .field("token", &"<redacted>")
            .field("expires_in_secs", &self.expires_in_secs)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_credentials_debug_redacts_token() {
        let creds = SessionCredentials {
            username: "alice".into(),
            cid: 7,
            token: "super-secret-token-do-not-leak".into(),
            expires_in_secs: None,
        };
        let dumped = format!("{creds:?}");
        assert!(!dumped.contains("super-secret-token-do-not-leak"));
        assert!(dumped.contains("<redacted>"));
        assert!(dumped.contains("alice"));
        assert!(dumped.contains("cid: 7"));
    }
}
