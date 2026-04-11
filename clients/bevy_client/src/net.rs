use crate::{
    config::ClientConfig,
    protocol::{
        ClientMessage, NetVec3, ServerMessage, decode_server_payload, encode_client_frame,
        take_frame,
    },
};
use bevy::prelude::Resource;
use std::{
    collections::HashMap,
    io::{self, Read, Write},
    net::TcpStream,
    sync::{
        Arc, Mutex,
        mpsc::{self, Receiver, Sender},
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

#[derive(Debug, Clone)]
pub enum NetworkCommand {
    Movement {
        location: NetVec3,
        velocity: NetVec3,
        acceleration: NetVec3,
    },
    Chat(String),
    CastSkill(u16),
    Shutdown,
}

#[derive(Debug, Clone)]
pub enum NetworkEvent {
    Status(String),
    EnteredScene {
        cid: i64,
        location: NetVec3,
    },
    LocalPosition {
        cid: i64,
        location: NetVec3,
    },
    PlayerEnter {
        cid: i64,
        location: NetVec3,
    },
    PlayerMove {
        cid: i64,
        location: NetVec3,
    },
    PlayerLeave {
        cid: i64,
    },
    ChatMessage {
        cid: i64,
        username: String,
        text: String,
    },
    SkillEvent {
        cid: i64,
        skill_id: u16,
        location: NetVec3,
    },
    TimeSync {
        rtt_ms: f64,
        offset_ms: f64,
    },
    Heartbeat {
        server_ts: u64,
    },
    Log(String),
    Disconnected(String),
}

#[derive(Clone, Resource)]
pub struct NetworkBridge {
    pub tx: Sender<NetworkCommand>,
    pub rx: Arc<Mutex<Receiver<NetworkEvent>>>,
}

impl NetworkBridge {
    pub fn send(&self, command: NetworkCommand) {
        let _ = self.tx.send(command);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ConnectionPhase {
    AwaitingAuth,
    AwaitingEnterScene,
    InScene,
}

pub fn spawn_network_thread(config: ClientConfig) -> NetworkBridge {
    let (command_tx, command_rx) = mpsc::channel();
    let (event_tx, event_rx) = mpsc::channel();

    thread::spawn(move || network_loop(config, command_rx, event_tx));

    NetworkBridge {
        tx: command_tx,
        rx: Arc::new(Mutex::new(event_rx)),
    }
}

fn network_loop(
    config: ClientConfig,
    command_rx: Receiver<NetworkCommand>,
    event_tx: Sender<NetworkEvent>,
) {
    if config.token.trim().is_empty() {
        let _ = event_tx.send(NetworkEvent::Disconnected(
            "missing token: set BEVY_CLIENT_TOKEN before launching the client".to_string(),
        ));
        return;
    }

    let _ = event_tx.send(NetworkEvent::Status(format!(
        "connecting to {}",
        config.gate_addr
    )));

    let mut stream = match TcpStream::connect(&config.gate_addr) {
        Ok(stream) => stream,
        Err(err) => {
            let _ = event_tx.send(NetworkEvent::Disconnected(format!("connect failed: {err}")));
            return;
        }
    };

    if let Err(err) = stream.set_nonblocking(true) {
        let _ = event_tx.send(NetworkEvent::Disconnected(format!(
            "nonblocking setup failed: {err}"
        )));
        return;
    }

    if let Err(err) = stream.set_nodelay(true) {
        let _ = event_tx.send(NetworkEvent::Log(format!(
            "warning: failed to enable TCP_NODELAY: {err}"
        )));
    }

    let mut next_request_id = 1_u64;
    let auth_request_id = next_request_id;
    next_request_id += 1;

    if let Err(err) = send_message(
        &mut stream,
        &ClientMessage::AuthRequest {
            request_id: auth_request_id,
            username: config.username.clone(),
            token: config.token.clone(),
        },
    ) {
        let _ = event_tx.send(NetworkEvent::Disconnected(format!(
            "auth send failed: {err}"
        )));
        return;
    }

    let mut phase = ConnectionPhase::AwaitingAuth;
    let mut frame_buffer = Vec::new();
    let mut read_buffer = [0_u8; 4096];
    let mut pending_time_sync = HashMap::new();
    let mut enter_scene_request_id = None;
    let mut last_heartbeat = Instant::now();
    let mut last_time_sync = Instant::now();

    loop {
        while let Ok(command) = command_rx.try_recv() {
            match command {
                NetworkCommand::Shutdown => return,
                NetworkCommand::Movement {
                    location,
                    velocity,
                    acceleration,
                } if phase == ConnectionPhase::InScene => {
                    let request_id = next_request_id;
                    next_request_id += 1;
                    if let Err(err) = send_message(
                        &mut stream,
                        &ClientMessage::Movement {
                            request_id,
                            cid: config.cid,
                            timestamp: now_millis(),
                            location,
                            velocity,
                            acceleration,
                        },
                    ) {
                        let _ = event_tx.send(NetworkEvent::Disconnected(format!(
                            "movement send failed: {err}"
                        )));
                        return;
                    }
                }
                NetworkCommand::Chat(text) if phase == ConnectionPhase::InScene => {
                    let request_id = next_request_id;
                    next_request_id += 1;
                    if let Err(err) =
                        send_message(&mut stream, &ClientMessage::ChatSay { request_id, text })
                    {
                        let _ = event_tx.send(NetworkEvent::Disconnected(format!(
                            "chat send failed: {err}"
                        )));
                        return;
                    }
                }
                NetworkCommand::CastSkill(skill_id) if phase == ConnectionPhase::InScene => {
                    let request_id = next_request_id;
                    next_request_id += 1;
                    if let Err(err) = send_message(
                        &mut stream,
                        &ClientMessage::SkillCast {
                            request_id,
                            skill_id,
                        },
                    ) {
                        let _ = event_tx.send(NetworkEvent::Disconnected(format!(
                            "skill send failed: {err}"
                        )));
                        return;
                    }
                }
                _ => {}
            }
        }

        if phase != ConnectionPhase::AwaitingAuth
            && last_heartbeat.elapsed() >= Duration::from_millis(config.heartbeat_interval_ms)
        {
            if let Err(err) = send_message(
                &mut stream,
                &ClientMessage::Heartbeat {
                    timestamp: now_millis(),
                },
            ) {
                let _ = event_tx.send(NetworkEvent::Disconnected(format!(
                    "heartbeat send failed: {err}"
                )));
                return;
            }
            last_heartbeat = Instant::now();
        }

        if phase != ConnectionPhase::AwaitingAuth
            && last_time_sync.elapsed() >= Duration::from_millis(config.time_sync_interval_ms)
        {
            let request_id = next_request_id;
            next_request_id += 1;
            let client_send_ts = now_millis();
            pending_time_sync.insert(request_id, client_send_ts);

            if let Err(err) = send_message(
                &mut stream,
                &ClientMessage::TimeSync {
                    request_id,
                    client_send_ts,
                },
            ) {
                let _ = event_tx.send(NetworkEvent::Disconnected(format!(
                    "time-sync send failed: {err}"
                )));
                return;
            }

            last_time_sync = Instant::now();
        }

        match stream.read(&mut read_buffer) {
            Ok(0) => {
                let _ = event_tx.send(NetworkEvent::Disconnected(
                    "server closed the connection".to_string(),
                ));
                return;
            }
            Ok(n) => {
                frame_buffer.extend_from_slice(&read_buffer[..n]);
                while let Some(frame) = take_frame(&mut frame_buffer) {
                    match decode_server_payload(&frame) {
                        Ok(message) => {
                            if let Err(err) = handle_server_message(
                                &config,
                                &mut stream,
                                &event_tx,
                                &mut next_request_id,
                                auth_request_id,
                                &mut enter_scene_request_id,
                                &mut pending_time_sync,
                                &mut phase,
                                message,
                            ) {
                                let _ = event_tx.send(NetworkEvent::Disconnected(err));
                                return;
                            }
                        }
                        Err(err) => {
                            let _ =
                                event_tx.send(NetworkEvent::Log(format!("decode error: {err}")));
                        }
                    }
                }
            }
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {}
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => {
                let _ = event_tx.send(NetworkEvent::Disconnected(format!(
                    "socket read failed: {err}"
                )));
                return;
            }
        }

        thread::sleep(Duration::from_millis(16));
    }
}

fn handle_server_message(
    config: &ClientConfig,
    stream: &mut TcpStream,
    event_tx: &Sender<NetworkEvent>,
    next_request_id: &mut u64,
    auth_request_id: u64,
    enter_scene_request_id: &mut Option<u64>,
    pending_time_sync: &mut HashMap<u64, u64>,
    phase: &mut ConnectionPhase,
    message: ServerMessage,
) -> Result<(), String> {
    match message {
        ServerMessage::Result {
            packet_id,
            ok,
            movement,
        } => {
            if packet_id == auth_request_id {
                if !ok {
                    return Err("auth failed".to_string());
                }

                *phase = ConnectionPhase::AwaitingEnterScene;
                let request_id = *next_request_id;
                *next_request_id += 1;
                *enter_scene_request_id = Some(request_id);
                send_message(
                    stream,
                    &ClientMessage::EnterScene {
                        request_id,
                        cid: config.cid,
                    },
                )
                .map_err(|err| format!("enter-scene send failed: {err}"))?;
                let _ = event_tx.send(NetworkEvent::Status(
                    "authenticated; requesting enter-scene".to_string(),
                ));
            } else {
                if let Some((cid, location)) = movement {
                    let _ = event_tx.send(NetworkEvent::LocalPosition { cid, location });
                }

                let _ = event_tx.send(NetworkEvent::Log(format!(
                    "result packet_id={packet_id} status={}",
                    if ok { "ok" } else { "error" }
                )));
            }
        }
        ServerMessage::EnterSceneResult {
            packet_id,
            ok,
            location,
        } => {
            if Some(packet_id) != *enter_scene_request_id {
                let _ = event_tx.send(NetworkEvent::Log(format!(
                    "unexpected enter-scene packet_id={packet_id}"
                )));
                return Ok(());
            }

            if !ok {
                return Err("enter-scene failed".to_string());
            }

            *phase = ConnectionPhase::InScene;
            let location =
                location.ok_or_else(|| "enter-scene success missing location".to_string())?;
            let _ = event_tx.send(NetworkEvent::Status("in scene".to_string()));
            let _ = event_tx.send(NetworkEvent::EnteredScene {
                cid: config.cid,
                location,
            });
        }
        ServerMessage::PlayerEnter { cid, location } => {
            let _ = event_tx.send(NetworkEvent::PlayerEnter { cid, location });
        }
        ServerMessage::PlayerMove { cid, location } => {
            let _ = event_tx.send(NetworkEvent::PlayerMove { cid, location });
        }
        ServerMessage::PlayerLeave { cid } => {
            let _ = event_tx.send(NetworkEvent::PlayerLeave { cid });
        }
        ServerMessage::ChatMessage {
            cid,
            username,
            text,
        } => {
            let _ = event_tx.send(NetworkEvent::ChatMessage {
                cid,
                username,
                text,
            });
        }
        ServerMessage::SkillEvent {
            cid,
            skill_id,
            location,
        } => {
            let _ = event_tx.send(NetworkEvent::SkillEvent {
                cid,
                skill_id,
                location,
            });
        }
        ServerMessage::TimeSyncReply {
            packet_id,
            client_send_ts,
            server_recv_ts,
            server_send_ts,
        } => {
            pending_time_sync.remove(&packet_id);
            let now = now_millis() as f64;
            let client_send = client_send_ts as f64;
            let server_mid = (server_recv_ts as f64 + server_send_ts as f64) / 2.0;
            let client_mid = (client_send + now) / 2.0;
            let _ = event_tx.send(NetworkEvent::TimeSync {
                rtt_ms: now - client_send,
                offset_ms: server_mid - client_mid,
            });
        }
        ServerMessage::HeartbeatReply { timestamp } => {
            let _ = event_tx.send(NetworkEvent::Heartbeat {
                server_ts: timestamp,
            });
        }
    }

    Ok(())
}

fn send_message(stream: &mut TcpStream, message: &ClientMessage) -> io::Result<()> {
    let frame = encode_client_frame(message);
    send_bytes(stream, &frame)
}

fn send_bytes(stream: &mut TcpStream, bytes: &[u8]) -> io::Result<()> {
    let mut written = 0;
    while written < bytes.len() {
        match stream.write(&bytes[written..]) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "socket closed while writing",
                ));
            }
            Ok(n) => written += n,
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(5))
            }
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        }
    }
    Ok(())
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
