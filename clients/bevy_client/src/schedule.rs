//! Client-wide system ordering for the Update schedule.
//!
//! Phase 0 of the bevy_client restructure introduces this enum so subsequent
//! phases can move systems into Plugins and tag them with `.in_set(...)`. The
//! ordering is the same one the legacy monolithic `app::run` produced through
//! tuple `.chain()` calls; it is just expressed declaratively here so each
//! Plugin can opt into a set without knowing about its peers.
//!
//! Currently no system is tagged with these sets. They become load-bearing in
//! Phase 4 when systems migrate into their owning Plugins.

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
/// Plugins call this through `BevyClientPlugins`; `app::run` only needs to
/// invoke it once. It is idempotent — calling it twice in the same `App` is a
/// no-op because Bevy deduplicates set ordering edges.
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
