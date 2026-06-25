//! `SessionPlugin` — Bevy-side owner of the connection lifecycle surface.
//!
//! 阶段4:the background network thread self-recovers (connect → drop → backoff
//! re-auth + reconnect, see [`crate::net::thread`]); `net::poll_network_events`
//! projects its events onto [`ConnectionState::phase`]. This plugin is the single
//! Bevy-side home that *surfaces* that lifecycle — an edge-triggered structured
//! observer event on every phase change — so automation / logs (and a future
//! reconnect-overlay UI) see the connect → reconnect → in-scene / failed
//! transitions without scraping the HUD status string.
//!
//! The reconnect *policy* (attempt budget, backoff schedule, proactive refresh)
//! lives in [`crate::session::reconnect`] — pure, unit-tested logic the network
//! thread executes — so the session domain owns *when and how hard we recover*
//! even though the thread owns the socket mechanics.

use bevy::prelude::*;

use crate::login::AppState;
use crate::observe::ClientObserver;

use super::{ConnectionPhase, ConnectionState};

pub struct SessionPlugin;

impl Plugin for SessionPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(
            Update,
            surface_connection_phase.run_if(in_state(AppState::Game)),
        );
    }
}

/// Returns a stable label for one connection phase (structured-event friendly).
fn phase_label(phase: &ConnectionPhase) -> String {
    match phase {
        ConnectionPhase::Connecting => "connecting".to_string(),
        ConnectionPhase::InScene => "in_scene".to_string(),
        ConnectionPhase::Reconnecting { attempt } => format!("reconnecting:{attempt}"),
        ConnectionPhase::Failed => "failed".to_string(),
    }
}

/// Edge-triggered: emit a structured observer event whenever the connection phase
/// changes, so the connect → reconnect → in-scene / failed lifecycle is observable
/// without polling. Uses Bevy change-detection plus a `Local` snapshot so it fires
/// exactly once per distinct phase (the same phase touched repeatedly — e.g. each
/// `Reconnecting { attempt }` increment IS a distinct phase — fires once each).
fn surface_connection_phase(
    connection: Res<ConnectionState>,
    observer: Res<ClientObserver>,
    mut last_phase: Local<Option<ConnectionPhase>>,
) {
    if !connection.is_changed() {
        return;
    }
    if last_phase.as_ref() == Some(&connection.phase) {
        return;
    }
    *last_phase = Some(connection.phase.clone());

    observer.emit(
        "session",
        "phase_changed",
        &[
            ("phase", phase_label(&connection.phase)),
            ("status", connection.status.clone()),
        ],
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phase_label_is_stable_and_carries_attempt() {
        assert_eq!(phase_label(&ConnectionPhase::Connecting), "connecting");
        assert_eq!(phase_label(&ConnectionPhase::InScene), "in_scene");
        assert_eq!(
            phase_label(&ConnectionPhase::Reconnecting { attempt: 3 }),
            "reconnecting:3"
        );
        assert_eq!(phase_label(&ConnectionPhase::Failed), "failed");
    }
}
