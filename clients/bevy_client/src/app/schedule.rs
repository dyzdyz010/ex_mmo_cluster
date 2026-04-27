//! Client-wide system ordering for the Update schedule.
//!
//! The ordering is expressed declaratively so each Plugin can opt into a set
//! without knowing about its peers. The movement-sync path relies on this
//! sequence: drain network/stdin first, sample input, advance local sync, then
//! render camera/HUD/presentation state.

use bevy::prelude::*;

#[derive(SystemSet, Debug, Hash, PartialEq, Eq, Clone, Copy)]
pub enum ClientSet {
    /// Drain inbound `NetworkEvent`s and queue outbound commands.
    Network,
    /// Drain queued stdio commands so the rest of the frame sees them as input.
    Stdio,
    /// Sample keyboard / mouse / chat input and emit domain events.
    Input,
    /// Apply input events: voxel edits, skill casts, chat sends.
    Logic,
    /// Movement uplink and local render prediction integration.
    Sync,
    /// Camera, HUD, presentation, gizmos.
    Render,
}

/// Configure the canonical ordering of [`ClientSet`] inside `Update`.
///
/// `app::run` invokes this once after adding `BevyClientPlugins`. It is
/// idempotent — calling it twice in the same `App` is a no-op because Bevy
/// deduplicates set ordering edges.
pub fn configure_client_sets(app: &mut App) {
    app.configure_sets(
        Update,
        (
            ClientSet::Network,
            ClientSet::Stdio,
            ClientSet::Input,
            ClientSet::Logic,
            ClientSet::Sync,
            ClientSet::Render,
        )
            .chain(),
    );
}
