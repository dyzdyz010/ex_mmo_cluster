//! UDP fast-lane bootstrap / attach state machine internal state.
//!
//! Tracks the in-flight bootstrap and attach request ids, the resolved UDP
//! endpoint, retry/backoff timing, and the user-visible status string. The
//! `ClientRuntime` in `runtime.rs` owns the policy decisions; this struct
//! owns the bookkeeping.

use std::{net::SocketAddr, time::Instant};

use super::events::MessageTransport;

/// Maximum number of bootstrap retries before entering a long cooldown.
pub(super) const MAX_FAST_LANE_REBOOTSTRAP_ATTEMPTS: u8 = 3;
/// Backoff schedule (ms) for successive bootstrap retries before cooldown.
pub(super) const FAST_LANE_REBOOTSTRAP_BACKOFF_MS: [u64; 3] = [250, 1_000, 3_000];
/// Cooldown duration (ms) after exhausting bootstrap retries.
pub(super) const FAST_LANE_REBOOTSTRAP_COOLDOWN_MS: u64 = 15_000;

#[derive(Debug, Clone, Default)]
pub(super) struct FastLaneState {
    pub bootstrap_request_id: Option<u64>,
    pub attach_request_id: Option<u64>,
    pub udp_endpoint: Option<SocketAddr>,
    pub ticket: Option<String>,
    pub attached: bool,
    pub last_error: Option<String>,
    pub rebootstrap_attempts: u8,
    pub retry_due_at: Option<Instant>,
    pub cooldown_until: Option<Instant>,
}

impl FastLaneState {
    pub(super) fn movement_transport(&self) -> MessageTransport {
        if self.attached {
            MessageTransport::Udp
        } else {
            MessageTransport::Tcp
        }
    }

    pub(super) fn status_text(&self) -> String {
        if self.attached {
            match self.udp_endpoint {
                Some(endpoint) => format!("udp attached ({endpoint})"),
                None => "udp attached".to_string(),
            }
        } else if let Some(endpoint) = self.udp_endpoint {
            format!("attaching udp ({endpoint})")
        } else if self.bootstrap_request_id.is_some() {
            "requesting udp ticket".to_string()
        } else if self.cooldown_until.is_some() {
            match &self.last_error {
                Some(error) => format!("tcp fallback (udp cooldown: {error})"),
                None => "tcp fallback (udp cooldown)".to_string(),
            }
        } else if self.retry_due_at.is_some() {
            match &self.last_error {
                Some(error) => format!("tcp fallback (udp retry scheduled: {error})"),
                None => "tcp fallback (udp retry scheduled)".to_string(),
            }
        } else if let Some(error) = &self.last_error {
            format!("tcp fallback ({error})")
        } else {
            "tcp fallback".to_string()
        }
    }

    pub(super) fn reset_for_bootstrap(&mut self, request_id: u64) {
        self.bootstrap_request_id = Some(request_id);
        self.attach_request_id = None;
        self.udp_endpoint = None;
        self.ticket = None;
        self.attached = false;
        self.last_error = None;
        self.retry_due_at = None;
        self.cooldown_until = None;
    }

    pub(super) fn prepare_attach(
        &mut self,
        request_id: u64,
        udp_endpoint: SocketAddr,
        ticket: String,
    ) {
        self.bootstrap_request_id = None;
        self.attach_request_id = Some(request_id);
        self.udp_endpoint = Some(udp_endpoint);
        self.ticket = Some(ticket);
        self.attached = false;
        self.last_error = None;
        self.retry_due_at = None;
        self.cooldown_until = None;
    }

    pub(super) fn mark_attached(&mut self) {
        self.attach_request_id = None;
        self.ticket = None;
        self.attached = true;
        self.last_error = None;
        self.rebootstrap_attempts = 0;
        self.retry_due_at = None;
        self.cooldown_until = None;
    }

    pub(super) fn mark_failed(&mut self, reason: String) {
        self.bootstrap_request_id = None;
        self.attach_request_id = None;
        self.ticket = None;
        self.udp_endpoint = None;
        self.attached = false;
        self.last_error = Some(reason);
        self.retry_due_at = None;
        self.cooldown_until = None;
    }
}
