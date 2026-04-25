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
