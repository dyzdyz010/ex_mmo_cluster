//! Background network thread: TCP connect, UDP fast-lane attach, frame
//! decoding, and translation between [`super::runtime::ClientRuntime`]
//! outcomes and real socket I/O.

use std::{
    io::{self, Read},
    net::{TcpStream, UdpSocket},
    sync::{
        Arc, Mutex,
        mpsc::{self, Receiver, Sender},
    },
    thread,
    time::{Duration, Instant},
};

use crate::config::ClientConfig;
use crate::session::SessionCredentials;
use crate::observe::ClientObserver;
use crate::protocol::{ClientMessage, decode_server_payload, take_frame};

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

fn network_loop(
    config: ClientConfig,
    creds: SessionCredentials,
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
        return;
    }

    let gate_tcp_addr = match resolve_gate_addr(&config.gate_addr) {
        Ok(addr) => addr,
        Err(err) => {
            emit_event(
                &observer,
                &event_tx,
                NetworkEvent::Disconnected(format!(
                    "failed to resolve gate address {}: {err}",
                    config.gate_addr
                )),
            );
            return;
        }
    };

    emit_event(
        &observer,
        &event_tx,
        NetworkEvent::Status(format!("connecting to {gate_tcp_addr}")),
    );

    let mut stream = match TcpStream::connect(gate_tcp_addr) {
        Ok(stream) => stream,
        Err(err) => {
            emit_event(
                &observer,
                &event_tx,
                NetworkEvent::Disconnected(format!("connect failed: {err}")),
            );
            return;
        }
    };

    if let Err(err) = stream.set_nonblocking(true) {
        emit_event(
            &observer,
            &event_tx,
            NetworkEvent::Disconnected(format!("nonblocking setup failed: {err}")),
        );
        return;
    }

    if let Err(err) = stream.set_nodelay(true) {
        emit_event(
            &observer,
            &event_tx,
            NetworkEvent::Log(format!("warning: failed to enable TCP_NODELAY: {err}")),
        );
    }

    let mut runtime = ClientRuntime::new(gate_tcp_addr);
    emit_event(&observer, &event_tx, runtime.transport_event());

    let initial_auth = runtime.initial_auth_message(&creds);
    observe_outbound_message(&observer, "tcp", &initial_auth);

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
                    &observer,
                    &event_tx,
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
        emit_event(
            &observer,
            &event_tx,
            NetworkEvent::Disconnected(format!(
                "auth send failed after {AUTH_SEND_MAX_ATTEMPTS} attempts: {err}"
            )),
        );
        return;
    }

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
        while let Ok(command) = command_rx.try_recv() {
            if matches!(command, NetworkCommand::Shutdown) {
                return;
            }

            let outcome = runtime.handle_command(&creds, command);
            if let Err(reason) = apply_runtime_outcome(
                &mut runtime,
                &mut stream,
                &mut udp_socket,
                &event_tx,
                &observer,
                outcome,
            ) {
                emit_event(&observer, &event_tx, NetworkEvent::Disconnected(reason));
                return;
            }
        }

        if last_heartbeat.elapsed() >= Duration::from_millis(config.heartbeat_interval_ms) {
            if let Some(message) = runtime.heartbeat_message() {
                observe_outbound_message(&observer, "tcp", &message);
                if let Err(err) = send_tcp_message(&mut stream, &message) {
                    emit_event(
                        &observer,
                        &event_tx,
                        NetworkEvent::Disconnected(format!("heartbeat send failed: {err}")),
                    );
                    return;
                }
            }
            last_heartbeat = Instant::now();
        }

        if last_time_sync.elapsed() >= Duration::from_millis(config.time_sync_interval_ms) {
            if let Some(message) = runtime.time_sync_message() {
                observe_outbound_message(&observer, "tcp", &message);
                if let Err(err) = send_tcp_message(&mut stream, &message) {
                    emit_event(
                        &observer,
                        &event_tx,
                        NetworkEvent::Disconnected(format!("time-sync send failed: {err}")),
                    );
                    return;
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
                &event_tx,
                &observer,
                retry_outcome,
            )
        {
            emit_event(&observer, &event_tx, NetworkEvent::Disconnected(reason));
            return;
        }

        // Drain all currently-buffered TCP data this tick (bounded), instead of a
        // single 4096B read. A lone read per 16ms tick capped throughput at
        // ~256KB/s, which paced large bursts like voxel snapshot streams (~78KB
        // each) to ~3 chunks/s; draining lets a burst arrive at line speed.
        for _ in 0..MAX_TCP_READS_PER_TICK {
            match stream.read(&mut read_buffer) {
                Ok(0) => {
                    emit_event(
                        &observer,
                        &event_tx,
                        NetworkEvent::Disconnected("server closed the connection".to_string()),
                    );
                    return;
                }
                Ok(n) => frame_buffer.extend_from_slice(&read_buffer[..n]),
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => break,
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) => {
                    emit_event(
                        &observer,
                        &event_tx,
                        NetworkEvent::Disconnected(format!("socket read failed: {err}")),
                    );
                    return;
                }
            }
        }

        while let Some(frame) = take_frame(&mut frame_buffer) {
            match decode_server_payload(&frame) {
                Ok(message) => {
                    match runtime.handle_server_message(&creds, MessageTransport::Tcp, message) {
                        Ok(outcome) => {
                            if let Err(reason) = apply_runtime_outcome(
                                &mut runtime,
                                &mut stream,
                                &mut udp_socket,
                                &event_tx,
                                &observer,
                                outcome,
                            ) {
                                emit_event(
                                    &observer,
                                    &event_tx,
                                    NetworkEvent::Disconnected(reason),
                                );
                                return;
                            }
                        }
                        Err(reason) => {
                            emit_event(&observer, &event_tx, NetworkEvent::Disconnected(reason));
                            return;
                        }
                    }
                }
                Err(err) => {
                    emit_event(
                        &observer,
                        &event_tx,
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
                            &creds,
                            MessageTransport::Udp,
                            message,
                        ) {
                            Ok(outcome) => {
                                if let Err(reason) = apply_runtime_outcome(
                                    &mut runtime,
                                    &mut stream,
                                    &mut udp_socket,
                                    &event_tx,
                                    &observer,
                                    outcome,
                                ) {
                                    emit_event(
                                        &observer,
                                        &event_tx,
                                        NetworkEvent::Disconnected(reason),
                                    );
                                    return;
                                }
                            }
                            Err(reason) => {
                                emit_event(
                                    &observer,
                                    &event_tx,
                                    NetworkEvent::Disconnected(reason),
                                );
                                return;
                            }
                        },
                        Err(err) => {
                            emit_event(
                                &observer,
                                &event_tx,
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
                            &event_tx,
                            &observer,
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
