//! Environment-backed client runtime configuration.

use bevy::prelude::Resource;
use std::env;

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
            gate_addr: env_or("BEVY_CLIENT_GATE_ADDR", "127.0.0.1:29000"),
            auth_addr: env_or("BEVY_CLIENT_AUTH_ADDR", "http://127.0.0.1:4000"),
            movement_speed: env_parse_or("BEVY_CLIENT_SPEED", 220.0_f32),
            movement_interval_ms: env_parse_or("BEVY_CLIENT_MOVE_INTERVAL_MS", 100_u64),
            heartbeat_interval_ms: env_parse_or("BEVY_CLIENT_HEARTBEAT_MS", 2_000_u64),
            time_sync_interval_ms: env_parse_or("BEVY_CLIENT_TIME_SYNC_MS", 5_000_u64),
        }
    }
}

#[derive(Clone, Debug, Resource)]
/// Credentials returned by the dev auto-login endpoint after the user submits a username.
pub struct SessionCredentials {
    pub username: String,
    pub cid: i64,
    pub token: String,
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
