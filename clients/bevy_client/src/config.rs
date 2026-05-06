//! Environment-backed client runtime configuration.

use bevy::prelude::Resource;
use std::env;
use std::fmt;

#[derive(Clone, Debug, Resource)]
/// Resolved transport/observe configuration for one client launch.
pub struct ClientConfig {
    pub gate_addr: String,
    pub auth_addr: String,
    pub movement_speed: f32,
    pub movement_interval_ms: u64,
    pub heartbeat_interval_ms: u64,
    pub time_sync_interval_ms: u64,
}

impl ClientConfig {
    /// Builds the client configuration from environment variables.
    pub fn from_env() -> Self {
        Self {
            gate_addr: env_or("BEVY_CLIENT_GATE_ADDR", "127.0.0.1:20002"),
            auth_addr: env_or("BEVY_CLIENT_AUTH_ADDR", "http://127.0.0.1:20000"),
            movement_speed: env_parse_or("BEVY_CLIENT_SPEED", 220.0_f32),
            movement_interval_ms: env_parse_or("BEVY_CLIENT_MOVE_INTERVAL_MS", 100_u64),
            heartbeat_interval_ms: env_parse_or("BEVY_CLIENT_HEARTBEAT_MS", 2_000_u64),
            time_sync_interval_ms: env_parse_or("BEVY_CLIENT_TIME_SYNC_MS", 5_000_u64),
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

fn env_or(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_string())
}

fn env_parse_or<T>(key: &str, default: T) -> T
where
    T: std::str::FromStr,
{
    env::var(key)
        .ok()
        .and_then(|value| value.parse::<T>().ok())
        .unwrap_or(default)
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
