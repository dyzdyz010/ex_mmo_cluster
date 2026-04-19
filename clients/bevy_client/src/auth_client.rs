//! Synchronous HTTP client for the dev-only auto-login endpoint.
//!
//! Calls `POST {auth_addr}/ingame/auto_login` with a `{"username": ...}` body and
//! returns a parsed [`SessionCredentials`] on success.

use crate::config::SessionCredentials;
use serde::Deserialize;

#[derive(Deserialize)]
struct AutoLoginResponse {
    token: String,
    cid: i64,
    username: String,
}

/// Issues a blocking POST to `{auth_addr}/ingame/auto_login` and returns credentials.
pub fn auto_login(auth_addr: &str, username: &str) -> Result<SessionCredentials, String> {
    let url = format!("{}/ingame/auto_login", auth_addr.trim_end_matches('/'));
    let response = match ureq::post(&url).send_json(ureq::json!({ "username": username })) {
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
