//! Client-side network runtime split by responsibility.
//!
//! - `events` — public command/event surface and `NetworkBridge` resource.
//! - `runtime` — testable [`runtime::ClientRuntime`] state machine and tests.
//! - `fastlane` — UDP fast-lane state used by the runtime.
//! - `transport` — pure TCP/UDP I/O helpers.
//! - `observe` — translation of events / outbound messages into observer
//!   emissions.
//! - `thread` — the background network thread that owns sockets and drives
//!   the runtime.

use bevy::prelude::Resource;

pub mod events;
pub mod fastlane;
pub mod observe;
pub mod plugin;
pub mod runtime;
pub mod thread;
pub mod transport;

pub use events::{MessageTransport, NetworkBridge, NetworkCommand, NetworkEvent};
pub use plugin::NetworkPlugin;
pub use thread::spawn_network_thread;

// `NetTelemetry` is defined below and used via `crate::net::NetTelemetry`.

/// Transport / latency telemetry surfaced by the HUD + stdio harness
/// (架构重整阶段2:从 `WorldState` god-resource 收口到 net 域)。Pure diagnostics —
/// the authoritative transport selection lives in the net thread's `FastLane` /
/// `ClientRuntime`; these are the projected values the UI reads. Written only by
/// `poll_network_events` on heartbeat / transport-status / disconnect.
#[derive(Resource)]
pub struct NetTelemetry {
    /// Last round-trip time (ms) from a heartbeat exchange.
    pub last_rtt_ms: Option<f64>,
    /// Last server-clock offset estimate (ms).
    pub last_offset_ms: Option<f64>,
    /// Server timestamp of the last heartbeat.
    pub last_heartbeat_ts: Option<u64>,
    /// Transport the control channel resolved to.
    pub control_transport: MessageTransport,
    /// Transport the movement channel resolved to.
    pub movement_transport: MessageTransport,
    /// Human-readable fast-lane (UDP) status line.
    pub fast_lane_status: String,
    /// Resolved UDP endpoint string, if the fast lane came up.
    pub udp_endpoint: Option<String>,
    /// Transport the most recent local-position update arrived on.
    pub last_local_update_transport: Option<MessageTransport>,
    /// Transport the most recent remote-move broadcast arrived on.
    pub last_remote_move_transport: Option<MessageTransport>,
}

impl Default for NetTelemetry {
    fn default() -> Self {
        Self {
            last_rtt_ms: None,
            last_offset_ms: None,
            last_heartbeat_ts: None,
            control_transport: MessageTransport::Tcp,
            movement_transport: MessageTransport::Tcp,
            fast_lane_status: "tcp fallback".to_string(),
            udp_endpoint: None,
            last_local_update_transport: None,
            last_remote_move_transport: None,
        }
    }
}
