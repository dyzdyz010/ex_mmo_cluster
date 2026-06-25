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

/// Connection / scene-membership liveness — the single owner of "are we
/// connected and in the world" (架构重整阶段1b:从 `WorldState` god-resource 收口
/// 到 session 域)。后续阶段 4 把 `status` String 演进成显式的 `ConnectionPhase` 枚举
/// + 退避重连/重认证;此处先做纯所有权迁移(字段不变,行为不变)。
#[derive(Resource)]
pub struct ConnectionState {
    /// Human-readable status line surfaced by the HUD / stdio harness.
    pub status: String,
    /// True once the server confirmed scene entry; gates all in-world systems
    /// (camera follow, movement upload, voxel subscribe/render, skill cast …).
    pub scene_joined: bool,
}

impl Default for ConnectionState {
    fn default() -> Self {
        Self {
            status: String::new(),
            scene_joined: false,
        }
    }
}

#[derive(Clone, Resource)]
/// Credentials returned by the dev auto-login endpoint after the user submits a username.
pub struct SessionCredentials {
    pub username: String,
    pub cid: i64,
    pub token: String,
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
        };
        let dumped = format!("{creds:?}");
        assert!(!dumped.contains("super-secret-token-do-not-leak"));
        assert!(dumped.contains("<redacted>"));
        assert!(dumped.contains("alice"));
        assert!(dumped.contains("cid: 7"));
    }
}
