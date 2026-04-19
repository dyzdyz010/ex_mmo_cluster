//! Binary entrypoint that chooses between interactive and headless client modes.

use bevy_client::{
    app,
    auth_client,
    config::ClientConfig,
    headless::{HeadlessOptions, run as run_headless, run_stdio as run_headless_stdio},
    observe::ClientObserver,
    stdio::ClientStdioInterface,
};
use std::{env, process};

fn main() {
    let launch = match LaunchOptions::from_env_and_args() {
        Ok(options) => options,
        Err(error) => {
            eprintln!("{error}");
            process::exit(2);
        }
    };

    let config = ClientConfig::from_env();
    let observer = ClientObserver::new(launch.observe_log.clone(), launch.observe_stdout);
    let stdio_enabled = launch.stdio || env_flag("BEVY_CLIENT_STDIO");

    if launch.headless {
        let Some(username) = launch.username.as_deref() else {
            eprintln!("headless mode requires --username <name>");
            process::exit(2);
        };

        let creds = match auth_client::auto_login(&config.auth_addr, username) {
            Ok(creds) => creds,
            Err(error) => {
                eprintln!("auto_login failed: {error}");
                process::exit(1);
            }
        };

        let result = if stdio_enabled {
            run_headless_stdio(
                config,
                creds,
                observer,
                ClientStdioInterface::enabled(),
                launch.wait_for_scene_ms,
            )
        } else {
            run_headless(
                config,
                creds,
                observer,
                HeadlessOptions {
                    script: launch.headless_script,
                    wait_for_scene_ms: launch.wait_for_scene_ms,
                    drain_after_script_ms: launch.drain_after_script_ms,
                },
            )
        };

        if let Err(error) = result {
            eprintln!("{error}");
            process::exit(1);
        }
    } else {
        let stdio = if stdio_enabled {
            ClientStdioInterface::enabled()
        } else {
            ClientStdioInterface::disabled()
        };

        let initial_credentials = match launch.username.as_deref() {
            Some(username) => match auth_client::auto_login(&config.auth_addr, username) {
                Ok(creds) => Some(creds),
                Err(error) => {
                    eprintln!("auto_login failed: {error}");
                    process::exit(1);
                }
            },
            None => None,
        };

        app::run(config, observer, stdio, initial_credentials);
    }
}

#[derive(Debug)]
struct LaunchOptions {
    headless: bool,
    headless_script: String,
    wait_for_scene_ms: u64,
    drain_after_script_ms: u64,
    observe_log: Option<String>,
    observe_stdout: bool,
    stdio: bool,
    username: Option<String>,
}

impl LaunchOptions {
    /// Parses launch options from CLI flags plus environment variables.
    fn from_env_and_args() -> Result<Self, String> {
        let defaults = HeadlessOptions::default();
        let mut options = Self {
            headless: env_flag("BEVY_CLIENT_HEADLESS"),
            headless_script: env::var("BEVY_CLIENT_HEADLESS_SCRIPT")
                .unwrap_or_else(|_| defaults.script.clone()),
            wait_for_scene_ms: env_parse_u64("BEVY_CLIENT_WAIT_FOR_SCENE_MS")
                .unwrap_or(defaults.wait_for_scene_ms),
            drain_after_script_ms: env_parse_u64("BEVY_CLIENT_DRAIN_AFTER_MS")
                .unwrap_or(defaults.drain_after_script_ms),
            observe_log: env::var("BEVY_CLIENT_OBSERVE_LOG").ok(),
            observe_stdout: env_flag("BEVY_CLIENT_OBSERVE_STDOUT"),
            stdio: env_flag("BEVY_CLIENT_STDIO"),
            username: None,
        };

        let mut args = env::args().skip(1);
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--headless" => options.headless = true,
                "--observe-stdout" => options.observe_stdout = true,
                "--stdio" => options.stdio = true,
                "--script" => {
                    options.headless_script = args
                        .next()
                        .ok_or_else(|| "missing value for --script".to_string())?;
                }
                "--observe-log" => {
                    options.observe_log = Some(
                        args.next()
                            .ok_or_else(|| "missing value for --observe-log".to_string())?,
                    );
                }
                "--username" => {
                    options.username = Some(
                        args.next()
                            .ok_or_else(|| "missing value for --username".to_string())?,
                    );
                }
                "--wait-for-scene-ms" => {
                    options.wait_for_scene_ms = args
                        .next()
                        .ok_or_else(|| "missing value for --wait-for-scene-ms".to_string())?
                        .parse::<u64>()
                        .map_err(|error| format!("invalid --wait-for-scene-ms: {error}"))?;
                }
                "--drain-after-ms" => {
                    options.drain_after_script_ms = args
                        .next()
                        .ok_or_else(|| "missing value for --drain-after-ms".to_string())?
                        .parse::<u64>()
                        .map_err(|error| format!("invalid --drain-after-ms: {error}"))?;
                }
                "--help" | "-h" => {
                    return Err(help_text());
                }
                other => {
                    return Err(format!("unsupported option: {other}\n\n{}", help_text()));
                }
            }
        }

        Ok(options)
    }
}

fn env_flag(key: &str) -> bool {
    matches!(
        env::var(key)
            .ok()
            .as_deref()
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("1" | "true" | "yes" | "on")
    )
}

fn env_parse_u64(key: &str) -> Option<u64> {
    env::var(key).ok()?.parse::<u64>().ok()
}

fn help_text() -> String {
    [
        "Usage: cargo run -- [--username <name>] [--headless] [--script <steps>]",
        "                     [--observe-log <path>] [--observe-stdout] [--stdio]",
        "",
        "--username <name>   Skip the login panel and auto-login as <name>. Required for --headless.",
        "",
        "Environment:",
        "  BEVY_CLIENT_GATE_ADDR   gate host:port (default 127.0.0.1:29000)",
        "  BEVY_CLIENT_AUTH_ADDR   auth base URL (default http://127.0.0.1:4000)",
        "",
        "Headless script steps:",
        "  wait:<ms>",
        "  move:<w|a|s|d|up|down|left|right>:<ms>",
        "  chat:<text>",
        "  skill:<id>",
        "  snapshot",
    ]
    .join("\n")
}
