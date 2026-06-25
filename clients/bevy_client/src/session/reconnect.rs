//! Reconnect / re-auth policy — pure, Bevy-free logic owned by the session
//! domain (架构重整阶段4)。The background network thread executes this policy;
//! keeping it here (not buried in `net::thread`) means the session domain owns
//! *when and how hard we try to recover a dropped connection*, and the policy is
//! unit-testable without sockets.

use std::time::Duration;

/// How many reconnect attempts the network thread makes after a drop before it
/// gives up and surfaces `ReconnectFailed` (→ `ConnectionPhase::Failed`). Sized
/// generously: a dropped connection during a dev-server restart can take tens of
/// seconds to recover, and each attempt re-auths (a fresh token) + reconnects.
pub const MAX_RECONNECT_ATTEMPTS: u32 = 30;

/// First backoff delay; the schedule ramps from here toward [`MAX_BACKOFF`].
const BASE_BACKOFF: Duration = Duration::from_millis(500);
/// Backoff ceiling — never wait longer than this between attempts.
const MAX_BACKOFF: Duration = Duration::from_secs(5);

/// Backoff before reconnect `attempt` (1-based): exponential (×1.6 per attempt)
/// capped at [`MAX_BACKOFF`]. `attempt == 0` (the drop itself, no retry yet)
/// returns `BASE_BACKOFF` so callers can use it uniformly.
///
/// Exponential-with-cap avoids both hammering the server on a flapping link and
/// waiting absurdly long on a slow-to-recover one.
pub fn backoff_delay(attempt: u32) -> Duration {
    if attempt <= 1 {
        return BASE_BACKOFF;
    }
    // 0.5s, 0.8s, 1.28s, 2.05s, 3.28s, 5s (cap), 5s, …
    let factor = 1.6_f64.powi((attempt - 1) as i32);
    let millis = (BASE_BACKOFF.as_millis() as f64 * factor) as u64;
    Duration::from_millis(millis).min(MAX_BACKOFF)
}

/// Whether a still-connected session should proactively reconnect to refresh its
/// auth token before it hard-expires.
///
/// The dev auth server issues a `Phoenix.Token` with a fixed `max_age` but does
/// not (yet) expose a refresh endpoint, so the only way to rotate the token is a
/// fresh `auto_login`. Rather than let a long-lived session die mid-action when
/// the token finally expires server-side, we proactively cycle the connection at
/// `REFRESH_FRACTION` of the advertised TTL — a brief reconnect blip instead of a
/// hard failure.
///
/// Returns `false` when `expires_in_secs` is `None` (the server didn't advertise
/// a TTL), so behaviour is unchanged until the auth response carries `expires_in`
/// — the reactive reconnect path still refreshes the token on any real drop.
pub fn proactive_refresh_due(session_age_secs: f64, expires_in_secs: Option<u64>) -> bool {
    /// Reconnect once the session has used this fraction of the token's TTL.
    const REFRESH_FRACTION: f64 = 0.9;
    match expires_in_secs {
        Some(ttl) if ttl > 0 => session_age_secs >= ttl as f64 * REFRESH_FRACTION,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_ramps_and_caps() {
        assert_eq!(backoff_delay(0), BASE_BACKOFF);
        assert_eq!(backoff_delay(1), BASE_BACKOFF);
        // Monotonic non-decreasing.
        let mut prev = Duration::ZERO;
        for attempt in 1..=MAX_RECONNECT_ATTEMPTS {
            let d = backoff_delay(attempt);
            assert!(d >= prev, "attempt {attempt}: {d:?} < {prev:?}");
            assert!(d <= MAX_BACKOFF, "attempt {attempt}: {d:?} exceeds cap");
            prev = d;
        }
        // Eventually pinned at the cap.
        assert_eq!(backoff_delay(MAX_RECONNECT_ATTEMPTS), MAX_BACKOFF);
    }

    #[test]
    fn proactive_refresh_only_when_ttl_known_and_mostly_elapsed() {
        // No TTL advertised → never proactively refresh (reactive path covers it).
        assert!(!proactive_refresh_due(1_000_000.0, None));
        assert!(!proactive_refresh_due(1_000_000.0, Some(0)));
        // 24h TTL: not due early, due past 90%.
        let ttl = 86_400;
        assert!(!proactive_refresh_due(0.0, Some(ttl)));
        assert!(!proactive_refresh_due(ttl as f64 * 0.5, Some(ttl)));
        assert!(proactive_refresh_due(ttl as f64 * 0.9, Some(ttl)));
        assert!(proactive_refresh_due(ttl as f64 * 0.99, Some(ttl)));
    }
}
