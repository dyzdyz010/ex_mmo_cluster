use crate::{
    config::ClientConfig,
    observe::ClientObserver,
    protocol::{
        ClientMessage, NetVec3, ServerMessage, decode_server_payload, encode_client_frame,
        encode_client_payload, take_frame,
    },
    protocol_v2::{WireMoveInputFrame, movement_ack_from_server, remote_move_snapshot_from_server},
    world::local_player::LocalPredictionRuntime,
};
use bevy::prelude::Resource;
use std::{
    collections::HashMap,
    io::{self, Read, Write},
    net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs, UdpSocket},
    sync::{
        Arc, Mutex,
        mpsc::{self, Receiver, Sender},
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageTransport {
    Tcp,
    Udp,
}

impl MessageTransport {
    pub const fn label(self) -> &'static str {
        match self {
            Self::Tcp => "TCP",
            Self::Udp => "UDP",
        }
    }
}

impl Default for MessageTransport {
    fn default() -> Self {
        Self::Tcp
    }
}

#[derive(Debug, Clone)]
pub enum NetworkCommand {
    MoveInputSample {
        input_dir: [f32; 2],
        dt_ms: u16,
        speed_scale: f32,
        movement_flags: u16,
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
        velocity: NetVec3,
        transport: MessageTransport,
    },
    PlayerEnter {
        cid: i64,
        location: NetVec3,
    },
    PlayerMove {
        snapshot: crate::sim::types::RemoteMoveSnapshot,
        transport: MessageTransport,
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
    TransportState {
        control_transport: MessageTransport,
        movement_transport: MessageTransport,
        fast_lane_status: String,
        udp_endpoint: Option<String>,
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

#[derive(Debug, Clone, Default)]
struct FastLaneState {
    bootstrap_request_id: Option<u64>,
    attach_request_id: Option<u64>,
    udp_endpoint: Option<SocketAddr>,
    ticket: Option<String>,
    attached: bool,
    last_error: Option<String>,
    rebootstrap_attempts: u8,
    retry_due_at: Option<Instant>,
    cooldown_until: Option<Instant>,
}

impl FastLaneState {
    fn movement_transport(&self) -> MessageTransport {
        if self.attached {
            MessageTransport::Udp
        } else {
            MessageTransport::Tcp
        }
    }

    fn status_text(&self) -> String {
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

    fn reset_for_bootstrap(&mut self, request_id: u64) {
        self.bootstrap_request_id = Some(request_id);
        self.attach_request_id = None;
        self.udp_endpoint = None;
        self.ticket = None;
        self.attached = false;
        self.last_error = None;
        self.retry_due_at = None;
        self.cooldown_until = None;
    }

    fn prepare_attach(&mut self, request_id: u64, udp_endpoint: SocketAddr, ticket: String) {
        self.bootstrap_request_id = None;
        self.attach_request_id = Some(request_id);
        self.udp_endpoint = Some(udp_endpoint);
        self.ticket = Some(ticket);
        self.attached = false;
        self.last_error = None;
        self.retry_due_at = None;
        self.cooldown_until = None;
    }

    fn mark_attached(&mut self) {
        self.attach_request_id = None;
        self.ticket = None;
        self.attached = true;
        self.last_error = None;
        self.rebootstrap_attempts = 0;
        self.retry_due_at = None;
        self.cooldown_until = None;
    }

    fn mark_failed(&mut self, reason: String) {
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

#[derive(Debug, Clone, PartialEq)]
enum OutboundAction {
    Tcp(ClientMessage),
    Udp(ClientMessage),
    OpenUdpAndAttach {
        udp_endpoint: SocketAddr,
        request_id: u64,
        ticket: String,
    },
}

#[derive(Debug, Default, Clone)]
struct RuntimeOutcome {
    outbounds: Vec<OutboundAction>,
    events: Vec<NetworkEvent>,
}

impl RuntimeOutcome {
    fn with_event(mut self, event: NetworkEvent) -> Self {
        self.events.push(event);
        self
    }

    fn push_outbound(&mut self, outbound: OutboundAction) {
        self.outbounds.push(outbound);
    }

    fn push_event(&mut self, event: NetworkEvent) {
        self.events.push(event);
    }
}

#[derive(Debug)]
struct ClientRuntime {
    gate_tcp_addr: SocketAddr,
    phase: ConnectionPhase,
    next_request_id: u64,
    auth_request_id: u64,
    enter_scene_request_id: Option<u64>,
    pending_time_sync: HashMap<u64, u64>,
    last_applied_movement_ack: u32,
    last_remote_move_ticks: HashMap<i64, u32>,
    fast_lane: FastLaneState,
    local_prediction: LocalPredictionRuntime,
}

const MAX_FAST_LANE_REBOOTSTRAP_ATTEMPTS: u8 = 3;
const FAST_LANE_REBOOTSTRAP_BACKOFF_MS: [u64; 3] = [250, 1_000, 3_000];
const FAST_LANE_REBOOTSTRAP_COOLDOWN_MS: u64 = 15_000;
const MAX_PENDING_TIME_SYNC_REQUESTS: usize = 32;
const TIME_SYNC_REQUEST_TIMEOUT_MS: u64 = 30_000;

impl ClientRuntime {
    fn new(gate_tcp_addr: SocketAddr) -> Self {
        Self {
            gate_tcp_addr,
            phase: ConnectionPhase::AwaitingAuth,
            next_request_id: 2,
            auth_request_id: 1,
            enter_scene_request_id: None,
            pending_time_sync: HashMap::new(),
            last_applied_movement_ack: 0,
            last_remote_move_ticks: HashMap::new(),
            fast_lane: FastLaneState::default(),
            local_prediction: LocalPredictionRuntime::default(),
        }
    }

    fn transport_event(&self) -> NetworkEvent {
        NetworkEvent::TransportState {
            control_transport: MessageTransport::Tcp,
            movement_transport: self.fast_lane.movement_transport(),
            fast_lane_status: self.fast_lane.status_text(),
            udp_endpoint: self
                .fast_lane
                .udp_endpoint
                .map(|endpoint| endpoint.to_string()),
        }
    }

    fn next_request_id(&mut self) -> u64 {
        let request_id = self.next_request_id;
        self.next_request_id += 1;
        request_id
    }

    fn initial_auth_message(&self, config: &ClientConfig) -> ClientMessage {
        ClientMessage::AuthRequest {
            request_id: self.auth_request_id,
            username: config.username.clone(),
            token: config.token.clone(),
        }
    }

    fn handle_command(&mut self, config: &ClientConfig, command: NetworkCommand) -> RuntimeOutcome {
        let mut outcome = RuntimeOutcome::default();

        match command {
            NetworkCommand::Shutdown => {}
            NetworkCommand::MoveInputSample {
                input_dir,
                dt_ms,
                speed_scale,
                movement_flags,
            } if self.phase == ConnectionPhase::InScene => {
                let frame = self.local_prediction.build_input_frame(
                    bevy::prelude::Vec2::new(input_dir[0], input_dir[1]),
                    dt_ms,
                    speed_scale,
                    movement_flags,
                );

                if let Some(predicted) = self.local_prediction.apply_local_input(frame.clone()) {
                    outcome.push_event(NetworkEvent::LocalPosition {
                        cid: config.cid,
                        location: [
                            predicted.position.x as f64,
                            predicted.position.y as f64,
                            predicted.position.z as f64,
                        ],
                        velocity: [
                            predicted.velocity.x as f64,
                            predicted.velocity.y as f64,
                            predicted.velocity.z as f64,
                        ],
                        transport: self.fast_lane.movement_transport(),
                    });
                }

                let outbound = ClientMessage::from(WireMoveInputFrame::from(frame));

                match self.fast_lane.movement_transport() {
                    MessageTransport::Tcp => outcome.push_outbound(OutboundAction::Tcp(outbound)),
                    MessageTransport::Udp => outcome.push_outbound(OutboundAction::Udp(outbound)),
                }
            }
            NetworkCommand::Chat(text) if self.phase == ConnectionPhase::InScene => {
                let request_id = self.next_request_id();
                outcome.push_outbound(OutboundAction::Tcp(ClientMessage::ChatSay {
                    request_id,
                    text,
                }));
            }
            NetworkCommand::CastSkill(skill_id) if self.phase == ConnectionPhase::InScene => {
                let request_id = self.next_request_id();
                outcome.push_outbound(OutboundAction::Tcp(ClientMessage::SkillCast {
                    request_id,
                    skill_id,
                }));
            }
            _ => {}
        }

        outcome
    }

    fn heartbeat_message(&self) -> Option<ClientMessage> {
        (self.phase != ConnectionPhase::AwaitingAuth).then(|| ClientMessage::Heartbeat {
            timestamp: now_millis(),
        })
    }

    fn time_sync_message(&mut self) -> Option<ClientMessage> {
        if self.phase == ConnectionPhase::AwaitingAuth {
            return None;
        }

        let now = now_millis();
        self.prune_pending_time_sync(now);
        let request_id = self.next_request_id();
        let client_send_ts = now;
        self.pending_time_sync.insert(request_id, client_send_ts);

        Some(ClientMessage::TimeSync {
            request_id,
            client_send_ts,
        })
    }

    fn prune_pending_time_sync(&mut self, now: u64) {
        self.pending_time_sync
            .retain(|_, sent_at| now.saturating_sub(*sent_at) <= TIME_SYNC_REQUEST_TIMEOUT_MS);

        if self.pending_time_sync.len() > MAX_PENDING_TIME_SYNC_REQUESTS {
            let mut entries = self
                .pending_time_sync
                .iter()
                .map(|(request_id, sent_at)| (*request_id, *sent_at))
                .collect::<Vec<_>>();
            entries.sort_by_key(|(_, sent_at)| *sent_at);

            let trim_count = entries.len() - MAX_PENDING_TIME_SYNC_REQUESTS;
            for (request_id, _) in entries.into_iter().take(trim_count) {
                self.pending_time_sync.remove(&request_id);
            }
        }
    }

    fn mark_fast_lane_failed(
        &mut self,
        reason: impl Into<String>,
        allow_rebootstrap: bool,
    ) -> RuntimeOutcome {
        self.mark_fast_lane_failed_at(Instant::now(), reason, allow_rebootstrap)
    }

    fn mark_fast_lane_failed_at(
        &mut self,
        now: Instant,
        reason: impl Into<String>,
        allow_rebootstrap: bool,
    ) -> RuntimeOutcome {
        let reason = reason.into();
        let cooldown_until = self.fast_lane.cooldown_until;
        self.fast_lane.mark_failed(reason.clone());

        let mut outcome = RuntimeOutcome::default()
            .with_event(NetworkEvent::Log(format!(
                "fast lane unavailable, continuing on TCP: {reason}"
            )))
            .with_event(self.transport_event());

        if allow_rebootstrap && self.phase == ConnectionPhase::InScene {
            if let Some(cooldown_until) = cooldown_until {
                if cooldown_until > now {
                    self.fast_lane.cooldown_until = Some(cooldown_until);
                    outcome.push_event(NetworkEvent::Log(format!(
                        "udp fast-lane retry suppressed during cooldown ({}ms remaining)",
                        cooldown_until.duration_since(now).as_millis()
                    )));
                    outcome.push_event(self.transport_event());
                    return outcome;
                }
            }

            if self.fast_lane.rebootstrap_attempts < MAX_FAST_LANE_REBOOTSTRAP_ATTEMPTS {
                self.fast_lane.rebootstrap_attempts += 1;
                let attempt = self.fast_lane.rebootstrap_attempts;
                let delay_ms = FAST_LANE_REBOOTSTRAP_BACKOFF_MS[(attempt - 1) as usize];
                self.fast_lane.retry_due_at = Some(now + Duration::from_millis(delay_ms));
                outcome.push_event(NetworkEvent::Log(format!(
                    "scheduled UDP fast-lane re-bootstrap attempt {attempt}/{MAX_FAST_LANE_REBOOTSTRAP_ATTEMPTS} in {delay_ms}ms"
                )));
                outcome.push_event(self.transport_event());
            } else {
                self.fast_lane.cooldown_until =
                    Some(now + Duration::from_millis(FAST_LANE_REBOOTSTRAP_COOLDOWN_MS));
                outcome.push_event(NetworkEvent::Log(format!(
                    "udp fast-lane retries exhausted; entering cooldown for {FAST_LANE_REBOOTSTRAP_COOLDOWN_MS}ms"
                )));
                outcome.push_event(self.transport_event());
            }
        }

        outcome
    }

    fn poll_fast_lane_retry(&mut self, now: Instant) -> RuntimeOutcome {
        let mut outcome = RuntimeOutcome::default();

        if self.phase != ConnectionPhase::InScene
            || self.fast_lane.attached
            || self.fast_lane.bootstrap_request_id.is_some()
            || self.fast_lane.attach_request_id.is_some()
        {
            return outcome;
        }

        if let Some(cooldown_until) = self.fast_lane.cooldown_until {
            if now >= cooldown_until {
                self.fast_lane.cooldown_until = None;
                self.fast_lane.rebootstrap_attempts = 0;
                let delay_ms = FAST_LANE_REBOOTSTRAP_BACKOFF_MS[0];
                self.fast_lane.retry_due_at = Some(now + Duration::from_millis(delay_ms));
                outcome.push_event(NetworkEvent::Log(format!(
                    "udp fast-lane cooldown elapsed; scheduling retry attempt 1/{MAX_FAST_LANE_REBOOTSTRAP_ATTEMPTS} in {delay_ms}ms"
                )));
                outcome.push_event(self.transport_event());
            }

            return outcome;
        }

        if let Some(retry_due_at) = self.fast_lane.retry_due_at {
            if now >= retry_due_at {
                let attempt = self.fast_lane.rebootstrap_attempts.max(1);
                let request_id = self.next_request_id();
                self.fast_lane.reset_for_bootstrap(request_id);
                outcome.push_event(NetworkEvent::Log(format!(
                    "retrying UDP fast-lane bootstrap (attempt {attempt}/{MAX_FAST_LANE_REBOOTSTRAP_ATTEMPTS})"
                )));
                outcome.push_event(self.transport_event());
                outcome.push_outbound(OutboundAction::Tcp(ClientMessage::FastLaneRequest {
                    request_id,
                }));
            }
        }

        outcome
    }

    fn handle_server_message(
        &mut self,
        config: &ClientConfig,
        transport: MessageTransport,
        message: ServerMessage,
    ) -> Result<RuntimeOutcome, String> {
        let mut outcome = RuntimeOutcome::default();

        match message {
            ServerMessage::Result { packet_id, ok } => {
                if transport == MessageTransport::Udp && !ok {
                    return Ok(self.mark_fast_lane_failed(
                        format!("udp movement rejected by gate (packet_id={packet_id})"),
                        true,
                    ));
                }

                if packet_id == self.auth_request_id {
                    if !ok {
                        return Err("auth failed".to_string());
                    }

                    self.phase = ConnectionPhase::AwaitingEnterScene;
                    let request_id = self.next_request_id();
                    self.enter_scene_request_id = Some(request_id);
                    outcome.push_outbound(OutboundAction::Tcp(ClientMessage::EnterScene {
                        request_id,
                        cid: config.cid,
                    }));
                    outcome.push_event(NetworkEvent::Status(
                        "authenticated; requesting enter-scene".to_string(),
                    ));
                    return Ok(outcome);
                }

                outcome.push_event(NetworkEvent::Log(format!(
                    "result packet_id={packet_id} via {} status={}",
                    transport.label(),
                    if ok { "ok" } else { "error" }
                )));
            }
            ServerMessage::EnterSceneResult {
                packet_id,
                ok,
                location,
            } => {
                if Some(packet_id) != self.enter_scene_request_id {
                    outcome.push_event(NetworkEvent::Log(format!(
                        "unexpected enter-scene packet_id={packet_id}"
                    )));
                    return Ok(outcome);
                }

                if !ok {
                    return Err("enter-scene failed".to_string());
                }

                self.phase = ConnectionPhase::InScene;
                self.last_applied_movement_ack = 0;
                self.last_remote_move_ticks.clear();
                let location =
                    location.ok_or_else(|| "enter-scene success missing location".to_string())?;
                self.local_prediction.reset(
                    bevy::prelude::Vec3::new(
                        location[0] as f32,
                        location[1] as f32,
                        location[2] as f32,
                    ),
                    None,
                );
                outcome.push_event(NetworkEvent::Status("in scene".to_string()));
                outcome.push_event(NetworkEvent::EnteredScene {
                    cid: config.cid,
                    location,
                });

                let request_id = self.next_request_id();
                self.fast_lane.reset_for_bootstrap(request_id);
                outcome.push_outbound(OutboundAction::Tcp(ClientMessage::FastLaneRequest {
                    request_id,
                }));
                outcome.push_event(NetworkEvent::Log(
                    "scene joined; requesting UDP fast-lane bootstrap".to_string(),
                ));
                outcome.push_event(self.transport_event());
            }
            message @ ServerMessage::MovementAck { ack_seq, cid, .. } => {
                if ack_seq <= self.last_applied_movement_ack {
                    outcome.push_event(NetworkEvent::Log(format!(
                        "ignoring stale movement ack ack_seq={ack_seq} (latest={})",
                        self.last_applied_movement_ack
                    )));
                    return Ok(outcome);
                }

                self.last_applied_movement_ack = ack_seq;

                let ack = movement_ack_from_server(&message).expect("movement ack");

                let latest_state = self
                    .local_prediction
                    .apply_ack(ack)
                    .map(|result| result.latest_state)
                    .or_else(|| self.local_prediction.current_state().cloned());

                if let Some(state) = latest_state {
                    outcome.push_event(NetworkEvent::LocalPosition {
                        cid,
                        location: [
                            state.position.x as f64,
                            state.position.y as f64,
                            state.position.z as f64,
                        ],
                        velocity: [
                            state.velocity.x as f64,
                            state.velocity.y as f64,
                            state.velocity.z as f64,
                        ],
                        transport,
                    });
                }
            }
            ServerMessage::FastLaneResult {
                packet_id,
                ok,
                udp_port,
                ticket,
            } => {
                if Some(packet_id) != self.fast_lane.bootstrap_request_id {
                    outcome.push_event(NetworkEvent::Log(format!(
                        "unexpected fast-lane bootstrap packet_id={packet_id}"
                    )));
                    return Ok(outcome);
                }

                if !ok {
                    return Ok(self.mark_fast_lane_failed("bootstrap rejected by gate", false));
                }

                let udp_port =
                    udp_port.ok_or_else(|| "fast-lane success missing udp port".to_string())?;
                let ticket =
                    ticket.ok_or_else(|| "fast-lane success missing attach ticket".to_string())?;
                let attach_request_id = self.next_request_id();
                let udp_endpoint = SocketAddr::new(self.gate_tcp_addr.ip(), udp_port);

                self.fast_lane
                    .prepare_attach(attach_request_id, udp_endpoint, ticket.clone());
                outcome.push_event(NetworkEvent::Log(format!(
                    "received UDP fast-lane ticket; attaching to {udp_endpoint}"
                )));
                outcome.push_event(self.transport_event());
                outcome.push_outbound(OutboundAction::OpenUdpAndAttach {
                    udp_endpoint,
                    request_id: attach_request_id,
                    ticket,
                });
            }
            ServerMessage::FastLaneAttached { packet_id, ok } => {
                if Some(packet_id) != self.fast_lane.attach_request_id {
                    outcome.push_event(NetworkEvent::Log(format!(
                        "unexpected fast-lane attach ack packet_id={packet_id}"
                    )));
                    return Ok(outcome);
                }

                if !ok {
                    return Ok(self.mark_fast_lane_failed("udp attach rejected by gate", true));
                }

                self.fast_lane.mark_attached();
                outcome.push_event(NetworkEvent::Log(
                    "udp fast lane attached; movement and AOI updates now use UDP".to_string(),
                ));
                outcome.push_event(self.transport_event());
            }
            ServerMessage::PlayerEnter { cid, location } => {
                outcome.push_event(NetworkEvent::PlayerEnter { cid, location });
            }
            message @ ServerMessage::PlayerMove { cid, .. } => {
                let snapshot =
                    remote_move_snapshot_from_server(&message).expect("remote move snapshot");
                let latest_tick = self.last_remote_move_ticks.get(&cid).copied().unwrap_or(0);
                if snapshot.server_tick <= latest_tick {
                    outcome.push_event(NetworkEvent::Log(format!(
                        "ignoring stale player_move cid={cid} tick={} (latest={latest_tick})",
                        snapshot.server_tick
                    )));
                    return Ok(outcome);
                }

                self.last_remote_move_ticks
                    .insert(cid, snapshot.server_tick);
                outcome.push_event(NetworkEvent::PlayerMove {
                    snapshot,
                    transport,
                });
            }
            ServerMessage::PlayerLeave { cid } => {
                outcome.push_event(NetworkEvent::PlayerLeave { cid });
            }
            ServerMessage::ChatMessage {
                cid,
                username,
                text,
            } => {
                outcome.push_event(NetworkEvent::ChatMessage {
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
                outcome.push_event(NetworkEvent::SkillEvent {
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
                let Some(sent_at) = self.pending_time_sync.remove(&packet_id) else {
                    outcome.push_event(NetworkEvent::Log(format!(
                        "unexpected time-sync reply packet_id={packet_id}"
                    )));
                    return Ok(outcome);
                };

                let now = now_millis() as f64;
                let client_send = sent_at as f64;

                if sent_at != client_send_ts {
                    outcome.push_event(NetworkEvent::Log(format!(
                        "time-sync reply packet_id={packet_id} returned mismatched client timestamp"
                    )));
                }

                let server_mid = (server_recv_ts as f64 + server_send_ts as f64) / 2.0;
                let client_mid = (client_send + now) / 2.0;
                outcome.push_event(NetworkEvent::TimeSync {
                    rtt_ms: now - client_send,
                    offset_ms: server_mid - client_mid,
                });
            }
            ServerMessage::HeartbeatReply { timestamp } => {
                outcome.push_event(NetworkEvent::Heartbeat {
                    server_ts: timestamp,
                });
            }
        }

        Ok(outcome)
    }
}

pub fn spawn_network_thread(config: ClientConfig, observer: ClientObserver) -> NetworkBridge {
    let (command_tx, command_rx) = mpsc::channel();
    let (event_tx, event_rx) = mpsc::channel();

    thread::spawn(move || network_loop(config, observer, command_rx, event_tx));

    NetworkBridge {
        tx: command_tx,
        rx: Arc::new(Mutex::new(event_rx)),
    }
}

fn network_loop(
    config: ClientConfig,
    observer: ClientObserver,
    command_rx: Receiver<NetworkCommand>,
    event_tx: Sender<NetworkEvent>,
) {
    if config.token.trim().is_empty() {
        emit_event(
            &observer,
            &event_tx,
            NetworkEvent::Disconnected(
                "missing token: set BEVY_CLIENT_TOKEN before launching the client".to_string(),
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

    let initial_auth = runtime.initial_auth_message(&config);
    observe_outbound_message(&observer, "tcp", &initial_auth);

    if let Err(err) = send_tcp_message(&mut stream, &initial_auth) {
        emit_event(
            &observer,
            &event_tx,
            NetworkEvent::Disconnected(format!("auth send failed: {err}")),
        );
        return;
    }

    let mut frame_buffer = Vec::new();
    let mut read_buffer = [0_u8; 4096];
    let mut udp_socket: Option<UdpSocket> = None;
    let mut udp_read_buffer = [0_u8; 4096];
    let mut last_heartbeat = Instant::now();
    let mut last_time_sync = Instant::now();

    loop {
        while let Ok(command) = command_rx.try_recv() {
            if matches!(command, NetworkCommand::Shutdown) {
                return;
            }

            let outcome = runtime.handle_command(&config, command);
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
        if !retry_outcome.outbounds.is_empty() || !retry_outcome.events.is_empty() {
            if let Err(reason) = apply_runtime_outcome(
                &mut runtime,
                &mut stream,
                &mut udp_socket,
                &event_tx,
                &observer,
                retry_outcome,
            ) {
                emit_event(&observer, &event_tx, NetworkEvent::Disconnected(reason));
                return;
            }
        }

        match stream.read(&mut read_buffer) {
            Ok(0) => {
                emit_event(
                    &observer,
                    &event_tx,
                    NetworkEvent::Disconnected("server closed the connection".to_string()),
                );
                return;
            }
            Ok(n) => {
                frame_buffer.extend_from_slice(&read_buffer[..n]);
                while let Some(frame) = take_frame(&mut frame_buffer) {
                    match decode_server_payload(&frame) {
                        Ok(message) => match runtime.handle_server_message(
                            &config,
                            MessageTransport::Tcp,
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
                                NetworkEvent::Log(format!("decode error: {err}")),
                            );
                        }
                    }
                }
            }
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {}
            Err(err) if err.kind() == io::ErrorKind::Interrupted => {}
            Err(err) => {
                emit_event(
                    &observer,
                    &event_tx,
                    NetworkEvent::Disconnected(format!("socket read failed: {err}")),
                );
                return;
            }
        }

        if udp_socket.is_some() {
            loop {
                let recv_result = match udp_socket.as_ref() {
                    Some(socket) => socket.recv(&mut udp_read_buffer),
                    None => break,
                };

                match recv_result {
                    Ok(n) => match decode_server_payload(&udp_read_buffer[..n]) {
                        Ok(message) => match runtime.handle_server_message(
                            &config,
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

fn emit_event(observer: &ClientObserver, event_tx: &Sender<NetworkEvent>, event: NetworkEvent) {
    observe_network_event(observer, &event);
    let _ = event_tx.send(event);
}

fn observe_network_event(observer: &ClientObserver, event: &NetworkEvent) {
    if !observer.enabled() {
        return;
    }

    match event {
        NetworkEvent::Status(status) => {
            observer.emit("network", "status", &[("message", status.clone())]);
        }
        NetworkEvent::EnteredScene { cid, location } => {
            observer.emit(
                "network",
                "entered_scene",
                &[("cid", cid.to_string()), ("location", format_vec(location))],
            );
        }
        NetworkEvent::LocalPosition {
            cid,
            location,
            velocity,
            transport,
        } => {
            observer.emit(
                "network",
                "movement_ack",
                &[
                    ("cid", cid.to_string()),
                    ("transport", transport.label().to_string()),
                    ("location", format_vec(location)),
                    ("velocity", format_vec(velocity)),
                ],
            );
        }
        NetworkEvent::PlayerEnter { cid, location } => {
            observer.emit(
                "network",
                "player_enter",
                &[("cid", cid.to_string()), ("location", format_vec(location))],
            );
        }
        NetworkEvent::PlayerMove {
            snapshot,
            transport,
        } => {
            observer.emit(
                "network",
                "player_move",
                &[
                    ("cid", snapshot.cid.to_string()),
                    ("server_tick", snapshot.server_tick.to_string()),
                    ("transport", transport.label().to_string()),
                    (
                        "location",
                        format_vec(&[
                            snapshot.position.x as f64,
                            snapshot.position.y as f64,
                            snapshot.position.z as f64,
                        ]),
                    ),
                ],
            );
        }
        NetworkEvent::PlayerLeave { cid } => {
            observer.emit("network", "player_leave", &[("cid", cid.to_string())]);
        }
        NetworkEvent::ChatMessage {
            cid,
            username,
            text,
        } => {
            observer.emit(
                "network",
                "chat_message",
                &[
                    ("cid", cid.to_string()),
                    ("username", username.clone()),
                    ("text", text.clone()),
                ],
            );
        }
        NetworkEvent::SkillEvent {
            cid,
            skill_id,
            location,
        } => {
            observer.emit(
                "network",
                "skill_event",
                &[
                    ("cid", cid.to_string()),
                    ("skill_id", skill_id.to_string()),
                    ("location", format_vec(location)),
                ],
            );
        }
        NetworkEvent::TimeSync { rtt_ms, offset_ms } => {
            observer.emit(
                "network",
                "time_sync",
                &[
                    ("rtt_ms", format!("{rtt_ms:.1}")),
                    ("offset_ms", format!("{offset_ms:.1}")),
                ],
            );
        }
        NetworkEvent::Heartbeat { server_ts } => {
            observer.emit(
                "network",
                "heartbeat_reply",
                &[("server_ts", server_ts.to_string())],
            );
        }
        NetworkEvent::TransportState {
            control_transport,
            movement_transport,
            fast_lane_status,
            udp_endpoint,
        } => {
            observer.emit(
                "network",
                "transport_state",
                &[
                    ("control_transport", control_transport.label().to_string()),
                    ("movement_transport", movement_transport.label().to_string()),
                    ("fast_lane_status", fast_lane_status.clone()),
                    (
                        "udp_endpoint",
                        udp_endpoint.clone().unwrap_or_else(|| "n/a".to_string()),
                    ),
                ],
            );
        }
        NetworkEvent::Log(line) => observer.emit("network", "log", &[("message", line.clone())]),
        NetworkEvent::Disconnected(reason) => {
            observer.emit("network", "disconnected", &[("reason", reason.clone())]);
        }
    }
}

fn observe_outbound_message(observer: &ClientObserver, transport: &str, message: &ClientMessage) {
    if !observer.enabled() {
        return;
    }

    match message {
        ClientMessage::AuthRequest {
            request_id,
            username,
            ..
        } => observer.emit(
            "network",
            "send_auth_request",
            &[
                ("transport", transport.to_string()),
                ("request_id", request_id.to_string()),
                ("username", username.clone()),
            ],
        ),
        ClientMessage::FastLaneRequest { request_id } => observer.emit(
            "network",
            "send_fast_lane_request",
            &[
                ("transport", transport.to_string()),
                ("request_id", request_id.to_string()),
            ],
        ),
        ClientMessage::FastLaneAttach { request_id, .. } => observer.emit(
            "network",
            "send_fast_lane_attach",
            &[
                ("transport", transport.to_string()),
                ("request_id", request_id.to_string()),
            ],
        ),
        ClientMessage::EnterScene { request_id, cid } => observer.emit(
            "network",
            "send_enter_scene",
            &[
                ("transport", transport.to_string()),
                ("request_id", request_id.to_string()),
                ("cid", cid.to_string()),
            ],
        ),
        ClientMessage::MovementInput {
            seq,
            client_tick,
            input_dir,
            speed_scale,
            movement_flags,
            ..
        } => observer.emit(
            "network",
            "send_movement_input",
            &[
                ("transport", transport.to_string()),
                ("seq", seq.to_string()),
                ("client_tick", client_tick.to_string()),
                (
                    "input_dir",
                    format!("{:.2},{:.2}", input_dir[0], input_dir[1]),
                ),
                ("speed_scale", format!("{speed_scale:.2}")),
                ("movement_flags", movement_flags.to_string()),
            ],
        ),
        ClientMessage::TimeSync {
            request_id,
            client_send_ts,
        } => observer.emit(
            "network",
            "send_time_sync",
            &[
                ("transport", transport.to_string()),
                ("request_id", request_id.to_string()),
                ("client_send_ts", client_send_ts.to_string()),
            ],
        ),
        ClientMessage::Heartbeat { timestamp } => observer.emit(
            "network",
            "send_heartbeat",
            &[
                ("transport", transport.to_string()),
                ("timestamp", timestamp.to_string()),
            ],
        ),
        ClientMessage::ChatSay { request_id, text } => observer.emit(
            "network",
            "send_chat",
            &[
                ("transport", transport.to_string()),
                ("request_id", request_id.to_string()),
                ("text", text.clone()),
            ],
        ),
        ClientMessage::SkillCast {
            request_id,
            skill_id,
        } => observer.emit(
            "network",
            "send_skill",
            &[
                ("transport", transport.to_string()),
                ("request_id", request_id.to_string()),
                ("skill_id", skill_id.to_string()),
            ],
        ),
    }
}

fn format_vec(value: &[f64; 3]) -> String {
    format!("{:.1},{:.1},{:.1}", value[0], value[1], value[2])
}

fn resolve_gate_addr(gate_addr: &str) -> io::Result<SocketAddr> {
    gate_addr
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::AddrNotAvailable, "no socket addresses"))
}

fn open_udp_socket(endpoint: SocketAddr) -> io::Result<UdpSocket> {
    let bind_addr = match endpoint.ip() {
        IpAddr::V4(_) => "0.0.0.0:0",
        IpAddr::V6(_) => "[::]:0",
    };

    let socket = UdpSocket::bind(bind_addr)?;
    socket.connect(endpoint)?;
    socket.set_nonblocking(true)?;
    Ok(socket)
}

fn send_tcp_message(stream: &mut TcpStream, message: &ClientMessage) -> io::Result<()> {
    let frame = encode_client_frame(message);
    send_tcp_bytes(stream, &frame)
}

fn send_udp_message(socket: &UdpSocket, message: &ClientMessage) -> io::Result<()> {
    let payload = encode_client_payload(message);
    socket.send(&payload).map(|_| ())
}

fn send_tcp_bytes(stream: &mut TcpStream, bytes: &[u8]) -> io::Result<()> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, SocketAddrV4};

    fn test_config() -> ClientConfig {
        ClientConfig {
            gate_addr: "127.0.0.1:29000".into(),
            username: "tester".into(),
            token: "token".into(),
            cid: 42,
            movement_speed: 220.0,
            movement_interval_ms: 100,
            heartbeat_interval_ms: 2_000,
            time_sync_interval_ms: 5_000,
        }
    }

    fn test_gate_addr() -> SocketAddr {
        SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 29_000))
    }

    fn movement_command() -> NetworkCommand {
        NetworkCommand::MoveInputSample {
            input_dir: [1.0, 0.0],
            dt_ms: 100,
            speed_scale: 1.0,
            movement_flags: 0,
        }
    }

    fn expect_transport_state(event: &NetworkEvent) -> (&str, MessageTransport) {
        match event {
            NetworkEvent::TransportState {
                fast_lane_status,
                movement_transport,
                ..
            } => (fast_lane_status.as_str(), *movement_transport),
            other => panic!("expected transport state, got {other:?}"),
        }
    }

    #[test]
    fn requests_fast_lane_bootstrap_after_scene_join() {
        let config = test_config();
        let mut runtime = ClientRuntime::new(test_gate_addr());

        let auth = runtime
            .handle_server_message(
                &config,
                MessageTransport::Tcp,
                ServerMessage::Result {
                    packet_id: runtime.auth_request_id,
                    ok: true,
                },
            )
            .unwrap();

        assert_eq!(
            auth.outbounds,
            vec![OutboundAction::Tcp(ClientMessage::EnterScene {
                request_id: 2,
                cid: 42,
            })]
        );

        let enter = runtime
            .handle_server_message(
                &config,
                MessageTransport::Tcp,
                ServerMessage::EnterSceneResult {
                    packet_id: 2,
                    ok: true,
                    location: Some([10.0, 20.0, 0.0]),
                },
            )
            .unwrap();

        assert!(
            enter
                .outbounds
                .contains(&OutboundAction::Tcp(ClientMessage::FastLaneRequest {
                    request_id: 3
                }))
        );
        assert!(enter.events.iter().any(|event| matches!(
            event,
            NetworkEvent::EnteredScene {
                cid: 42,
                location: [10.0, 20.0, 0.0]
            }
        )));

        let transport = enter
            .events
            .iter()
            .find(|event| matches!(event, NetworkEvent::TransportState { .. }))
            .expect("transport state event");
        let (status, movement_transport) = expect_transport_state(transport);
        assert_eq!(status, "requesting udp ticket");
        assert_eq!(movement_transport, MessageTransport::Tcp);
    }

    #[test]
    fn movement_uses_udp_only_after_attach_ack_and_tracks_udp_downlink() {
        let config = test_config();
        let mut runtime = ClientRuntime::new(test_gate_addr());
        runtime.phase = ConnectionPhase::InScene;
        runtime.fast_lane.reset_for_bootstrap(3);
        runtime
            .local_prediction
            .reset(bevy::prelude::Vec3::ZERO, None);

        let bootstrap = runtime
            .handle_server_message(
                &config,
                MessageTransport::Tcp,
                ServerMessage::FastLaneResult {
                    packet_id: 3,
                    ok: true,
                    udp_port: Some(29_001),
                    ticket: Some("ticket-123".into()),
                },
            )
            .unwrap();

        assert_eq!(
            bootstrap.outbounds,
            vec![OutboundAction::OpenUdpAndAttach {
                udp_endpoint: SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 29_001)),
                request_id: 2,
                ticket: "ticket-123".into(),
            }]
        );

        let before_attach = runtime.handle_command(&config, movement_command());
        assert!(matches!(
            before_attach.outbounds.as_slice(),
            [OutboundAction::Tcp(ClientMessage::MovementInput { .. })]
        ));

        let attach = runtime
            .handle_server_message(
                &config,
                MessageTransport::Udp,
                ServerMessage::FastLaneAttached {
                    packet_id: 2,
                    ok: true,
                },
            )
            .unwrap();

        let transport = attach
            .events
            .iter()
            .find(|event| matches!(event, NetworkEvent::TransportState { .. }))
            .expect("transport state event");
        let (status, movement_transport) = expect_transport_state(transport);
        assert!(status.starts_with("udp attached"));
        assert_eq!(movement_transport, MessageTransport::Udp);

        let after_attach = runtime.handle_command(&config, movement_command());
        assert!(matches!(
            after_attach.outbounds.as_slice(),
            [OutboundAction::Udp(ClientMessage::MovementInput { .. })]
        ));

        let move_ack = runtime
            .handle_server_message(
                &config,
                MessageTransport::Udp,
                ServerMessage::MovementAck {
                    ack_seq: 1,
                    auth_tick: 1,
                    cid: 42,
                    location: [7.0, 8.0, 9.0],
                    velocity: [4.0, 0.0, 0.0],
                    acceleration: [0.0, 0.0, 0.0],
                    movement_mode: 0,
                    correction_flags: 0,
                },
            )
            .unwrap();
        assert!(move_ack.events.iter().any(|event| matches!(
            event,
            NetworkEvent::LocalPosition {
                cid: 42,
                transport: MessageTransport::Udp,
                ..
            }
        )));

        let player_move = runtime
            .handle_server_message(
                &config,
                MessageTransport::Udp,
                ServerMessage::PlayerMove {
                    cid: 77,
                    server_tick: 1,
                    location: [11.0, 12.0, 13.0],
                    velocity: [1.0, 0.0, 0.0],
                    acceleration: [0.0, 0.0, 0.0],
                    movement_mode: 0,
                },
            )
            .unwrap();
        assert!(player_move.events.iter().any(|event| matches!(
            event,
            NetworkEvent::PlayerMove {
                snapshot,
                transport: MessageTransport::Udp,
            } if snapshot.cid == 77
                && snapshot.server_tick == 1
                && snapshot.position.x == 11.0
        )));
    }

    #[test]
    fn falls_back_to_tcp_when_fast_lane_bootstrap_fails() {
        let config = test_config();
        let mut runtime = ClientRuntime::new(test_gate_addr());
        runtime.phase = ConnectionPhase::InScene;
        runtime.fast_lane.reset_for_bootstrap(5);

        let fallback = runtime
            .handle_server_message(
                &config,
                MessageTransport::Tcp,
                ServerMessage::FastLaneResult {
                    packet_id: 5,
                    ok: false,
                    udp_port: None,
                    ticket: None,
                },
            )
            .unwrap();

        let transport = fallback
            .events
            .iter()
            .find(|event| matches!(event, NetworkEvent::TransportState { .. }))
            .expect("transport state event");
        let (status, movement_transport) = expect_transport_state(transport);
        assert!(status.starts_with("tcp fallback"));
        assert_eq!(movement_transport, MessageTransport::Tcp);
        assert!(fallback.outbounds.is_empty());

        let movement = runtime.handle_command(&config, movement_command());
        assert!(matches!(
            movement.outbounds.as_slice(),
            [OutboundAction::Tcp(ClientMessage::MovementInput { .. })]
        ));
    }

    #[test]
    fn udp_error_downgrades_to_tcp_and_schedules_rebootstrap() {
        let mut runtime = ClientRuntime::new(test_gate_addr());
        runtime.phase = ConnectionPhase::InScene;
        runtime.fast_lane.attached = true;
        runtime.fast_lane.udp_endpoint = Some(SocketAddr::V4(SocketAddrV4::new(
            Ipv4Addr::LOCALHOST,
            29_001,
        )));
        let now = Instant::now();

        let fallback = runtime.mark_fast_lane_failed_at(
            now,
            "udp movement rejected by gate (packet_id=27)",
            true,
        );

        assert!(fallback.outbounds.is_empty());
        assert!(fallback.events.iter().any(|event| matches!(
            event,
            NetworkEvent::Log(message)
                if message.contains("udp movement rejected by gate (packet_id=27)")
        )));
        assert!(fallback.events.iter().any(|event| matches!(
            event,
            NetworkEvent::Log(message)
                if message.contains("scheduled UDP fast-lane re-bootstrap attempt 1/3 in 250ms")
        )));

        let transport_states = fallback
            .events
            .iter()
            .filter_map(|event| match event {
                NetworkEvent::TransportState {
                    fast_lane_status,
                    movement_transport,
                    ..
                } => Some((fast_lane_status.as_str(), *movement_transport)),
                _ => None,
            })
            .collect::<Vec<_>>();

        assert_eq!(
            transport_states,
            vec![
                (
                    "tcp fallback (udp movement rejected by gate (packet_id=27))",
                    MessageTransport::Tcp,
                ),
                (
                    "tcp fallback (udp retry scheduled: udp movement rejected by gate (packet_id=27))",
                    MessageTransport::Tcp,
                ),
            ]
        );

        let due = runtime.poll_fast_lane_retry(now + Duration::from_millis(250));
        assert_eq!(
            due.outbounds,
            vec![OutboundAction::Tcp(ClientMessage::FastLaneRequest {
                request_id: 2,
            })]
        );
        assert!(due.events.iter().any(|event| matches!(
            event,
            NetworkEvent::Log(message)
                if message.contains("retrying UDP fast-lane bootstrap (attempt 1/3)")
        )));
    }

    #[test]
    fn rebootstrap_uses_backoff_and_enters_cooldown_after_repeated_failures() {
        let mut runtime = ClientRuntime::new(test_gate_addr());
        runtime.phase = ConnectionPhase::InScene;
        let start = Instant::now();

        runtime.fast_lane.attached = true;
        let first = runtime.mark_fast_lane_failed_at(start, "udp send failed", true);
        assert!(first.outbounds.is_empty());
        assert_eq!(
            runtime.fast_lane.retry_due_at,
            Some(start + Duration::from_millis(FAST_LANE_REBOOTSTRAP_BACKOFF_MS[0]))
        );

        let attempt_one = runtime.poll_fast_lane_retry(start + Duration::from_millis(250));
        assert_eq!(
            attempt_one.outbounds,
            vec![OutboundAction::Tcp(ClientMessage::FastLaneRequest {
                request_id: 2,
            })]
        );

        runtime.fast_lane.attached = true;
        let second = runtime.mark_fast_lane_failed_at(
            start + Duration::from_millis(251),
            "udp send failed again",
            true,
        );
        assert!(second.outbounds.is_empty());
        assert_eq!(
            runtime.fast_lane.retry_due_at,
            Some(start + Duration::from_millis(251 + FAST_LANE_REBOOTSTRAP_BACKOFF_MS[1]))
        );

        let attempt_two = runtime.poll_fast_lane_retry(start + Duration::from_millis(1_251));
        assert_eq!(
            attempt_two.outbounds,
            vec![OutboundAction::Tcp(ClientMessage::FastLaneRequest {
                request_id: 3,
            })]
        );

        runtime.fast_lane.attached = true;
        let third = runtime.mark_fast_lane_failed_at(
            start + Duration::from_millis(1_252),
            "udp send failed third time",
            true,
        );
        assert!(third.outbounds.is_empty());
        assert_eq!(
            runtime.fast_lane.retry_due_at,
            Some(start + Duration::from_millis(1_252 + FAST_LANE_REBOOTSTRAP_BACKOFF_MS[2]))
        );

        let attempt_three = runtime.poll_fast_lane_retry(start + Duration::from_millis(4_252));
        assert_eq!(
            attempt_three.outbounds,
            vec![OutboundAction::Tcp(ClientMessage::FastLaneRequest {
                request_id: 4,
            })]
        );

        runtime.fast_lane.attached = true;
        let exhausted = runtime.mark_fast_lane_failed_at(
            start + Duration::from_millis(4_253),
            "udp send failed fourth time",
            true,
        );
        assert!(exhausted.outbounds.is_empty());
        assert!(exhausted.events.iter().any(|event| matches!(
            event,
            NetworkEvent::Log(message)
                if message.contains("udp fast-lane retries exhausted; entering cooldown for 15000ms")
        )));

        let cooldown_elapsed = runtime.poll_fast_lane_retry(
            start + Duration::from_millis(4_253 + FAST_LANE_REBOOTSTRAP_COOLDOWN_MS),
        );
        assert!(cooldown_elapsed.outbounds.is_empty());
        assert!(cooldown_elapsed.events.iter().any(|event| matches!(
            event,
            NetworkEvent::Log(message)
                if message.contains("udp fast-lane cooldown elapsed; scheduling retry attempt 1/3 in 250ms")
        )));

        let retried_after_cooldown = runtime.poll_fast_lane_retry(
            start
                + Duration::from_millis(
                    4_253 + FAST_LANE_REBOOTSTRAP_COOLDOWN_MS + FAST_LANE_REBOOTSTRAP_BACKOFF_MS[0],
                ),
        );
        assert_eq!(
            retried_after_cooldown.outbounds,
            vec![OutboundAction::Tcp(ClientMessage::FastLaneRequest {
                request_id: 5,
            })]
        );
    }

    #[test]
    fn ignores_stale_movement_ack_packets() {
        let config = test_config();
        let mut runtime = ClientRuntime::new(test_gate_addr());
        runtime.phase = ConnectionPhase::InScene;
        runtime
            .local_prediction
            .reset(bevy::prelude::Vec3::ZERO, None);

        let latest = runtime
            .handle_server_message(
                &config,
                MessageTransport::Udp,
                ServerMessage::MovementAck {
                    ack_seq: 10,
                    auth_tick: 1,
                    cid: 42,
                    location: [4.0, 5.0, 6.0],
                    velocity: [0.0, 0.0, 0.0],
                    acceleration: [0.0, 0.0, 0.0],
                    movement_mode: 0,
                    correction_flags: 0,
                },
            )
            .unwrap();

        assert!(latest.events.iter().any(|event| matches!(
            event,
            NetworkEvent::LocalPosition {
                cid: 42,
                location: [4.0, 5.0, 6.0],
                transport: MessageTransport::Udp,
                ..
            }
        )));

        let stale = runtime
            .handle_server_message(
                &config,
                MessageTransport::Tcp,
                ServerMessage::MovementAck {
                    ack_seq: 9,
                    auth_tick: 1,
                    cid: 42,
                    location: [1.0, 2.0, 3.0],
                    velocity: [0.0, 0.0, 0.0],
                    acceleration: [0.0, 0.0, 0.0],
                    movement_mode: 0,
                    correction_flags: 0,
                },
            )
            .unwrap();

        assert!(
            !stale
                .events
                .iter()
                .any(|event| matches!(event, NetworkEvent::LocalPosition { .. }))
        );
        assert!(stale.events.iter().any(|event| matches!(
            event,
            NetworkEvent::Log(message)
                if message.contains("ignoring stale movement ack ack_seq=9")
        )));
    }

    #[test]
    fn ignores_stale_remote_player_moves_by_tick() {
        let config = test_config();
        let mut runtime = ClientRuntime::new(test_gate_addr());
        runtime.phase = ConnectionPhase::InScene;

        let latest = runtime
            .handle_server_message(
                &config,
                MessageTransport::Udp,
                ServerMessage::PlayerMove {
                    cid: 77,
                    server_tick: 3,
                    location: [7.0, 8.0, 9.0],
                    velocity: [1.0, 0.0, 0.0],
                    acceleration: [0.0, 0.0, 0.0],
                    movement_mode: 0,
                },
            )
            .unwrap();

        assert!(latest.events.iter().any(|event| matches!(
            event,
            NetworkEvent::PlayerMove {
                snapshot,
                transport: MessageTransport::Udp,
            } if snapshot.cid == 77
                && snapshot.server_tick == 3
                && snapshot.position.y == 8.0
        )));

        let stale = runtime
            .handle_server_message(
                &config,
                MessageTransport::Tcp,
                ServerMessage::PlayerMove {
                    cid: 77,
                    server_tick: 2,
                    location: [1.0, 2.0, 3.0],
                    velocity: [0.0, 0.0, 0.0],
                    acceleration: [0.0, 0.0, 0.0],
                    movement_mode: 0,
                },
            )
            .unwrap();

        assert!(
            !stale
                .events
                .iter()
                .any(|event| matches!(event, NetworkEvent::PlayerMove { .. }))
        );
        assert!(stale.events.iter().any(|event| matches!(
            event,
            NetworkEvent::Log(message)
                if message.contains("ignoring stale player_move cid=77 tick=2")
        )));
    }
}
