//! Background network thread: TCP connect, UDP fast-lane attach, frame
//! decoding, and translation between [`super::runtime::ClientRuntime`]
//! outcomes and real socket I/O.
//!
//! 阶段4:the thread no longer exits on the first disconnect. [`network_loop`]
//! is an outer reconnect driver around [`run_session`] (one connect → serve
//! attempt); on a drop it re-authenticates (a fresh `auto_login`, rotating the
//! token) and reconnects with capped exponential backoff, giving up only after
//! [`MAX_RECONNECT_ATTEMPTS`] consecutive failures.

use std::{
    io::{self, Read},
    net::{TcpStream, UdpSocket},
    sync::{
        Arc, Mutex,
        mpsc::{self, Receiver, Sender, TryRecvError},
    },
    thread,
    time::{Duration, Instant},
};

use crate::config::ClientConfig;
use crate::observe::ClientObserver;
use crate::protocol::{ClientMessage, decode_server_payload, take_frame};
use crate::session::SessionCredentials;
use crate::session::auth::auto_login_with_timeout;
use crate::session::reconnect::{MAX_RECONNECT_ATTEMPTS, backoff_delay};

/// Per-attempt auth timeout on the reconnect path — shorter than the initial
/// login's 30s so a hung auth server during a reconnect storm doesn't block the
/// thread (and a queued `Shutdown`) for the full login budget each attempt
/// (复审 finding: Shutdown unresponsive during blocking re-auth).
const RECONNECT_AUTH_TIMEOUT: Duration = Duration::from_secs(8);

use super::events::{MessageTransport, NetworkBridge, NetworkCommand, NetworkEvent};
use super::observe::{emit_event, observe_outbound_message};
use super::runtime::{ClientRuntime, OutboundAction, RuntimeOutcome};
use super::transport::{open_udp_socket, resolve_gate_addr, send_tcp_message, send_udp_message};

/// Spawns the background network thread and returns the app-facing bridge.
pub fn spawn_network_thread(
    config: ClientConfig,
    creds: SessionCredentials,
    observer: ClientObserver,
) -> NetworkBridge {
    let (command_tx, command_rx) = mpsc::channel();
    let (event_tx, event_rx) = mpsc::channel();

    thread::spawn(move || network_loop(config, creds, observer, command_rx, event_tx));

    NetworkBridge {
        tx: command_tx,
        rx: Arc::new(Mutex::new(event_rx)),
    }
}

/// Outcome of one [`run_session`] attempt.
struct SessionOutcome {
    /// The app asked the thread to stop (`NetworkCommand::Shutdown`).
    shutdown: bool,
    /// The session reached a confirmed scene entry (`EnteredScene`) before dropping.
    /// Used to reset the reconnect attempt budget on a fresh drop (a genuine session
    /// that finally drops gets the full budget again) while NOT resetting it for a
    /// connect/auth flap that never joined a scene (so a persistently-failing server
    /// escalates to `ReconnectFailed`).
    connected: bool,
    /// Drop reason, when not a clean shutdown.
    reason: Option<String>,
}

/// Drives the connect → serve → drop → backoff-reconnect lifecycle so a dropped
/// connection recovers without the user restarting the client.
fn network_loop(
    config: ClientConfig,
    mut creds: SessionCredentials,
    observer: ClientObserver,
    command_rx: Receiver<NetworkCommand>,
    event_tx: Sender<NetworkEvent>,
) {
    if creds.token.trim().is_empty() {
        emit_event(
            &observer,
            &event_tx,
            NetworkEvent::Disconnected(
                "missing session token: auto_login did not return a token".to_string(),
            ),
        );
        // Unrecoverable: no socket retry rotates a token `auto_login` never
        // returned. Surface the terminal Failed phase rather than a frozen
        // Reconnecting that never advances (复审 finding: empty-token early exit
        // mapped to non-terminal Reconnecting{0}).
        emit_event(&observer, &event_tx, NetworkEvent::ReconnectFailed);
        return;
    }

    // Consecutive failed reconnect attempts. Reset to 0 ONLY when a session that
    // actually joined a scene drops (a genuine session, not a connect/auth flap) —
    // so a server that keeps rejecting auth / closing right after the handshake is
    // counted against the budget and eventually escalates to ReconnectFailed
    // instead of looping forever (复审 finding: budget reset keyed on auth-bytes-
    // sent defeated the give-up guard).
    let mut attempt = 0u32;
    loop {
        let outcome = run_session(&config, &creds, &observer, &command_rx, &event_tx);
        if outcome.shutdown {
            return;
        }
        let reason = outcome
            .reason
            .unwrap_or_else(|| "connection lost".to_string());

        if outcome.connected {
            // A scene-joined session ended → fresh disconnect; reset the budget.
            attempt = 0;
            emit_event(&observer, &event_tx, NetworkEvent::Disconnected(reason));
        } else if attempt == 0 {
            // First failure of a never-joined run → surface the initial disconnect.
            // Subsequent never-joined tries are reported via `Reconnecting` below.
            emit_event(&observer, &event_tx, NetworkEvent::Disconnected(reason));
        }

        attempt += 1;
        if attempt > MAX_RECONNECT_ATTEMPTS {
            emit_event(&observer, &event_tx, NetworkEvent::ReconnectFailed);
            return;
        }

        if sleep_with_shutdown(backoff_delay(attempt), &command_rx) {
            return; // Shutdown requested (or the app dropped the bridge) during backoff.
        }

        // Surface 'now retrying' AFTER the backoff so the 'just dropped'
        // (Disconnected) and the 'reconnecting' phase are distinct observable
        // states rather than coalesced into one frame.
        emit_event(
            &observer,
            &event_tx,
            NetworkEvent::Reconnecting {
                attempt,
                max_attempts: MAX_RECONNECT_ATTEMPTS,
            },
        );

        // Re-authenticate to rotate the (possibly expired) token before the next
        // connect. On failure keep the existing token and let the connect attempt
        // fail → the next backoff cycle re-auths again. Short timeout so a hung
        // auth server doesn't wedge Shutdown responsiveness.
        match auto_login_with_timeout(
            &config.auth_addr,
            &creds.username,
            RECONNECT_AUTH_TIMEOUT,
        ) {
            Ok(fresh) => creds = fresh,
            Err(err) => emit_event(
                &observer,
                &event_tx,
                NetworkEvent::Log(format!(
                    "reconnect re-auth attempt {attempt} failed: {err}; retrying with existing token"
                )),
            ),
        }
    }
}

/// Sleeps for `total`, polling `command_rx` for `Shutdown` every ≤100ms so the
/// thread stays responsive to a quit during backoff. Returns `true` if Shutdown
/// was requested OR the command channel closed (the app dropped the bridge → stop
/// the thread rather than reconnect forever; 复审 finding: closed channel was
/// indistinguishable from empty). Other commands seen during the wait are stale
/// and discarded.
fn sleep_with_shutdown(total: Duration, command_rx: &Receiver<NetworkCommand>) -> bool {
    let deadline = Instant::now() + total;
    loop {
        loop {
            match command_rx.try_recv() {
                Ok(NetworkCommand::Shutdown) => return true,
                Ok(_) => continue,
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => return true,
            }
        }
        let now = Instant::now();
        if now >= deadline {
            return false;
        }
        thread::sleep((deadline - now).min(Duration::from_millis(100)));
    }
}

/// Runs exactly one connect → authenticate → serve session. Returns when the
/// connection drops or the app requests shutdown. NEVER reconnects itself — that
/// is [`network_loop`]'s job.
fn run_session(
    config: &ClientConfig,
    creds: &SessionCredentials,
    observer: &ClientObserver,
    command_rx: &Receiver<NetworkCommand>,
    event_tx: &Sender<NetworkEvent>,
) -> SessionOutcome {
    // Discard any stale commands queued while we were disconnected (movement /
    // voxel edits aimed at the previous, now-dead session) — but honour a
    // Shutdown (or a closed channel = app gone) that arrived in the gap.
    loop {
        match command_rx.try_recv() {
            Ok(NetworkCommand::Shutdown) | Err(TryRecvError::Disconnected) => {
                return SessionOutcome {
                    shutdown: true,
                    connected: false,
                    reason: None,
                };
            }
            Ok(_) => continue,
            Err(TryRecvError::Empty) => break,
        }
    }

    let dropped = |reason: String, connected: bool| SessionOutcome {
        shutdown: false,
        connected,
        reason: Some(reason),
    };

    let gate_tcp_addr = match resolve_gate_addr(&config.gate_addr) {
        Ok(addr) => addr,
        Err(err) => {
            return dropped(
                format!("failed to resolve gate address {}: {err}", config.gate_addr),
                false,
            );
        }
    };

    emit_event(
        observer,
        event_tx,
        NetworkEvent::Status(format!("connecting to {gate_tcp_addr}")),
    );

    let mut stream = match TcpStream::connect(gate_tcp_addr) {
        Ok(stream) => stream,
        Err(err) => return dropped(format!("connect failed: {err}"), false),
    };

    if let Err(err) = stream.set_nonblocking(true) {
        return dropped(format!("nonblocking setup failed: {err}"), false);
    }

    if let Err(err) = stream.set_nodelay(true) {
        emit_event(
            observer,
            event_tx,
            NetworkEvent::Log(format!("warning: failed to enable TCP_NODELAY: {err}")),
        );
    }

    let mut runtime = ClientRuntime::new(gate_tcp_addr);
    emit_event(observer, event_tx, runtime.transport_event());

    let initial_auth = runtime.initial_auth_message(creds);
    observe_outbound_message(observer, "tcp", &initial_auth);

    // Audit A-M2: previously a single auth send failure dropped the
    // connection. Retry with exponential backoff so transient network
    // hiccups (TCP send buffer momentarily full, server briefly busy) do
    // not force the user to restart the client.
    const AUTH_SEND_MAX_ATTEMPTS: u32 = 3;
    let mut auth_attempt = 0u32;
    let mut auth_backoff = Duration::from_millis(50);
    let auth_send_result = loop {
        auth_attempt += 1;
        match send_tcp_message(&mut stream, &initial_auth) {
            Ok(()) => break Ok(()),
            Err(err) if auth_attempt < AUTH_SEND_MAX_ATTEMPTS => {
                emit_event(
                    observer,
                    event_tx,
                    NetworkEvent::Log(format!(
                        "auth send attempt {auth_attempt}/{AUTH_SEND_MAX_ATTEMPTS} failed: {err}; retrying in {}ms",
                        auth_backoff.as_millis()
                    )),
                );
                thread::sleep(auth_backoff);
                auth_backoff *= 2;
            }
            Err(err) => break Err(err),
        }
    };
    if let Err(err) = auth_send_result {
        return dropped(
            format!("auth send failed after {AUTH_SEND_MAX_ATTEMPTS} attempts: {err}"),
            false,
        );
    }

    // Whether the server has confirmed scene entry (`EnteredScene`). The reconnect
    // budget resets ONLY for a drop after this is true — a connect/auth-send that
    // the server rejects or closes before scene entry counts against the budget so
    // a persistently-failing server escalates to ReconnectFailed instead of looping
    // forever (复审 finding: budget reset was keyed on auth-bytes-sent).
    let mut entered_scene = false;

    let mut frame_buffer = Vec::new();
    let mut read_buffer = [0_u8; 4096];
    // Max TCP reads drained per loop tick (256 * 4096 = 1 MiB), so a saturated
    // socket can't starve the rest of the loop, while bursts still arrive fast.
    const MAX_TCP_READS_PER_TICK: usize = 256;
    let mut udp_socket: Option<UdpSocket> = None;
    let mut udp_read_buffer = [0_u8; 4096];
    let mut last_heartbeat = Instant::now();
    let mut last_time_sync = Instant::now();

    loop {
        loop {
            let command = match command_rx.try_recv() {
                Ok(NetworkCommand::Shutdown) | Err(TryRecvError::Disconnected) => {
                    // Shutdown, or the app dropped the bridge (channel closed) →
                    // stop the thread rather than treat it as a reconnectable drop.
                    return SessionOutcome {
                        shutdown: true,
                        connected: entered_scene,
                        reason: None,
                    };
                }
                Ok(command) => command,
                Err(TryRecvError::Empty) => break,
            };

            let outcome = runtime.handle_command(creds, command);
            if let Err(reason) = apply_runtime_outcome(
                &mut runtime,
                &mut stream,
                &mut udp_socket,
                event_tx,
                observer,
                outcome,
            ) {
                return dropped(reason, entered_scene);
            }
        }

        if last_heartbeat.elapsed() >= Duration::from_millis(config.heartbeat_interval_ms) {
            if let Some(message) = runtime.heartbeat_message() {
                observe_outbound_message(observer, "tcp", &message);
                if let Err(err) = send_tcp_message(&mut stream, &message) {
                    return dropped(format!("heartbeat send failed: {err}"), entered_scene);
                }
            }
            last_heartbeat = Instant::now();
        }

        if last_time_sync.elapsed() >= Duration::from_millis(config.time_sync_interval_ms) {
            if let Some(message) = runtime.time_sync_message() {
                observe_outbound_message(observer, "tcp", &message);
                if let Err(err) = send_tcp_message(&mut stream, &message) {
                    return dropped(format!("time-sync send failed: {err}"), entered_scene);
                }
            }

            last_time_sync = Instant::now();
        }

        let retry_outcome = runtime.poll_fast_lane_retry(Instant::now());
        if (!retry_outcome.outbounds.is_empty() || !retry_outcome.events.is_empty())
            && let Err(reason) = apply_runtime_outcome(
                &mut runtime,
                &mut stream,
                &mut udp_socket,
                event_tx,
                observer,
                retry_outcome,
            )
        {
            return dropped(reason, entered_scene);
        }

        // Drain all currently-buffered TCP data this tick (bounded), instead of a
        // single 4096B read. A lone read per 16ms tick capped throughput at
        // ~256KB/s, which paced large bursts like voxel snapshot streams (~78KB
        // each) to ~3 chunks/s; draining lets a burst arrive at line speed.
        for _ in 0..MAX_TCP_READS_PER_TICK {
            match stream.read(&mut read_buffer) {
                Ok(0) => {
                    return dropped("server closed the connection".to_string(), entered_scene);
                }
                Ok(n) => frame_buffer.extend_from_slice(&read_buffer[..n]),
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => break,
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) => {
                    return dropped(format!("socket read failed: {err}"), entered_scene);
                }
            }
        }

        while let Some(frame) = take_frame(&mut frame_buffer) {
            match decode_server_payload(&frame) {
                Ok(message) => {
                    match runtime.handle_server_message(creds, MessageTransport::Tcp, message) {
                        Ok(outcome) => {
                            // Mark the session scene-joined once the server confirms
                            // scene entry — this (not auth-bytes-sent) is what makes
                            // a later drop reset the reconnect budget.
                            if !entered_scene
                                && outcome
                                    .events
                                    .iter()
                                    .any(|event| matches!(event, NetworkEvent::EnteredScene { .. }))
                            {
                                entered_scene = true;
                            }
                            if let Err(reason) = apply_runtime_outcome(
                                &mut runtime,
                                &mut stream,
                                &mut udp_socket,
                                event_tx,
                                observer,
                                outcome,
                            ) {
                                return dropped(reason, entered_scene);
                            }
                        }
                        Err(reason) => {
                            return dropped(reason, entered_scene);
                        }
                    }
                }
                Err(err) => {
                    emit_event(
                        observer,
                        event_tx,
                        NetworkEvent::Log(format!("decode error: {err}")),
                    );
                }
            }
        }

        if udp_socket.is_some() {
            while let Some(socket) = udp_socket.as_ref() {
                let recv_result = socket.recv(&mut udp_read_buffer);

                match recv_result {
                    Ok(n) => match decode_server_payload(&udp_read_buffer[..n]) {
                        Ok(message) => match runtime.handle_server_message(
                            creds,
                            MessageTransport::Udp,
                            message,
                        ) {
                            Ok(outcome) => {
                                if let Err(reason) = apply_runtime_outcome(
                                    &mut runtime,
                                    &mut stream,
                                    &mut udp_socket,
                                    event_tx,
                                    observer,
                                    outcome,
                                ) {
                                    return dropped(reason, entered_scene);
                                }
                            }
                            Err(reason) => {
                                return dropped(reason, entered_scene);
                            }
                        },
                        Err(err) => {
                            emit_event(
                                observer,
                                event_tx,
                                NetworkEvent::Log(format!("udp decode error: {err}")),
                            );
                        }
                    },
                    Err(err) if err.kind() == io::ErrorKind::WouldBlock => break,
                    Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                    Err(err) => {
                        udp_socket = None;
                        let outcome = runtime
                            .mark_fast_lane_failed(format!("udp socket read failed: {err}"), true);
                        let _ = apply_runtime_outcome(
                            &mut runtime,
                            &mut stream,
                            &mut udp_socket,
                            event_tx,
                            observer,
                            outcome,
                        );
                        break;
                    }
                }
            }
        }

        thread::sleep(Duration::from_millis(16));
    }
}

fn apply_runtime_outcome(
    runtime: &mut ClientRuntime,
    stream: &mut TcpStream,
    udp_socket: &mut Option<UdpSocket>,
    event_tx: &Sender<NetworkEvent>,
    observer: &ClientObserver,
    outcome: RuntimeOutcome,
) -> Result<(), String> {
    for outbound in outcome.outbounds {
        match outbound {
            OutboundAction::Tcp(message) => {
                observe_outbound_message(observer, "tcp", &message);
                send_tcp_message(stream, &message)
                    .map_err(|err| format!("tcp send failed: {err}"))?
            }
            OutboundAction::Udp(message) => {
                if let Some(socket) = udp_socket.as_ref() {
                    observe_outbound_message(observer, "udp", &message);
                    if let Err(err) = send_udp_message(socket, &message) {
                        *udp_socket = None;
                        let fallback = runtime.mark_fast_lane_failed(
                            format!("udp send failed, falling back to TCP: {err}"),
                            true,
                        );
                        apply_runtime_outcome(
                            runtime, stream, udp_socket, event_tx, observer, fallback,
                        )?;

                        if let ClientMessage::MovementInput { .. } = &message {
                            observe_outbound_message(observer, "tcp-fallback", &message);
                            send_tcp_message(stream, &message).map_err(|tcp_err| {
                                format!("tcp fallback send failed: {tcp_err}")
                            })?;
                        }
                    }
                } else if let ClientMessage::MovementInput { .. } = &message {
                    observe_outbound_message(observer, "tcp-fallback", &message);
                    send_tcp_message(stream, &message)
                        .map_err(|err| format!("tcp fallback send failed: {err}"))?;
                } else {
                    let fallback = runtime.mark_fast_lane_failed(
                        "udp socket missing during non-movement send".to_string(),
                        true,
                    );
                    apply_runtime_outcome(
                        runtime, stream, udp_socket, event_tx, observer, fallback,
                    )?;
                }
            }
            OutboundAction::OpenUdpAndAttach {
                udp_endpoint,
                request_id,
                ticket,
            } => match open_udp_socket(udp_endpoint) {
                Ok(socket) => {
                    observer.emit(
                        "network",
                        "udp_attach_send",
                        &[
                            ("udp_endpoint", udp_endpoint.to_string()),
                            ("request_id", request_id.to_string()),
                        ],
                    );
                    if let Err(err) = send_udp_message(
                        &socket,
                        &ClientMessage::FastLaneAttach { request_id, ticket },
                    ) {
                        *udp_socket = None;
                        let fallback = runtime
                            .mark_fast_lane_failed(format!("udp attach send failed: {err}"), true);
                        apply_runtime_outcome(
                            runtime, stream, udp_socket, event_tx, observer, fallback,
                        )?;
                    } else {
                        *udp_socket = Some(socket);
                    }
                }
                Err(err) => {
                    *udp_socket = None;
                    let fallback = runtime
                        .mark_fast_lane_failed(format!("udp open/connect failed: {err}"), true);
                    apply_runtime_outcome(
                        runtime, stream, udp_socket, event_tx, observer, fallback,
                    )?;
                }
            },
        }
    }

    for event in outcome.events {
        emit_event(observer, event_tx, event);
    }

    Ok(())
}
