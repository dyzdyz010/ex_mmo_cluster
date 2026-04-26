//! Synchronous HTTP client for the dev-only auto-login endpoint.
//!
//! Calls `POST {auth_addr}/ingame/auto_login` with a `{"username": ...}` body and
//! returns a parsed [`SessionCredentials`] on success.

use crate::config::SessionCredentials;
use serde::Deserialize;
use std::time::Duration;

/// Audit E-M4: bound the synchronous auth roundtrip so the login-thread
/// (and the spinner UI behind it) cannot wedge indefinitely if the auth
/// server hangs. 30 seconds is generous enough for a cold dev container
/// boot, short enough that the user gets actionable feedback.
const AUTO_LOGIN_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Deserialize)]
struct AutoLoginResponse {
    token: String,
    cid: i64,
    username: String,
}

/// Issues a blocking POST to `{auth_addr}/ingame/auto_login` and returns credentials.
pub fn auto_login(auth_addr: &str, username: &str) -> Result<SessionCredentials, String> {
    let url = format!("{}/ingame/auto_login", auth_addr.trim_end_matches('/'));
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(AUTO_LOGIN_TIMEOUT)
        .timeout_read(AUTO_LOGIN_TIMEOUT)
        .timeout_write(AUTO_LOGIN_TIMEOUT)
        .build();
    let response = match agent
        .post(&url)
        .send_json(ureq::json!({ "username": username }))
    {
        Ok(response) => response,
        Err(ureq::Error::Status(code, response)) => {
            let body = response
                .into_string()
                .unwrap_or_else(|_| "<failed to read body>".to_string());
            return Err(format!("auto_login failed ({code}): {body}"));
        }
        Err(err) => return Err(format!("auto_login network error: {err}")),
    };

    let parsed: AutoLoginResponse = response
        .into_json()
        .map_err(|err| format!("auto_login response parse error: {err}"))?;

    Ok(SessionCredentials {
        token: parsed.token,
        cid: parsed.cid,
        username: parsed.username,
    })
}
