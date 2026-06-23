//! Network thread state machine: connection phase, fast-lane bootstrap, and
//! all command/server-message handling.
//!
//! `ClientRuntime` is the testable core of the network layer. It produces
//! [`RuntimeOutcome`]s that the I/O glue in [`super::thread`] then translates
//! into TCP / UDP socket activity. Keeping the runtime free of socket
//! ownership lets the unit tests below drive the same logic without sockets.

use std::{
    collections::HashMap,
    net::SocketAddr,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use crate::config::SessionCredentials;
use crate::movement_codec::{
    WireMoveInputFrame, movement_ack_from_server, remote_move_snapshot_from_server,
};
use crate::protocol::{ActorKind, ClientMessage, ServerMessage};
use crate::world::local_player::LocalPredictionRuntime;
use crate::world::remote_actor::RemoteActorKind;

use super::events::{MessageTransport, NetworkCommand, NetworkEvent};
use super::fastlane::{
    FAST_LANE_REBOOTSTRAP_BACKOFF_MS, FAST_LANE_REBOOTSTRAP_COOLDOWN_MS, FastLaneState,
    MAX_FAST_LANE_REBOOTSTRAP_ATTEMPTS,
};

const MAX_PENDING_TIME_SYNC_REQUESTS: usize = 32;
const TIME_SYNC_REQUEST_TIMEOUT_MS: u64 = 30_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ConnectionPhase {
    AwaitingAuth,
    AwaitingEnterScene,
    InScene,
}

#[derive(Debug, Clone, PartialEq)]
pub(super) enum OutboundAction {
    Tcp(ClientMessage),
    Udp(ClientMessage),
    OpenUdpAndAttach {
        udp_endpoint: SocketAddr,
        request_id: u64,
        ticket: String,
    },
}

#[derive(Debug, Default, Clone)]
pub(super) struct RuntimeOutcome {
    pub outbounds: Vec<OutboundAction>,
    pub events: Vec<NetworkEvent>,
}

impl RuntimeOutcome {
    pub(super) fn with_event(mut self, event: NetworkEvent) -> Self {
        self.events.push(event);
        self
    }

    pub(super) fn push_outbound(&mut self, outbound: OutboundAction) {
        self.outbounds.push(outbound);
    }

    pub(super) fn push_event(&mut self, event: NetworkEvent) {
        self.events.push(event);
    }
}

#[derive(Debug)]
pub(super) struct ClientRuntime {
    pub(super) gate_tcp_addr: SocketAddr,
    pub(super) phase: ConnectionPhase,
    pub(super) next_request_id: u64,
    pub(super) auth_request_id: u64,
    pub(super) enter_scene_request_id: Option<u64>,
    pub(super) pending_time_sync: HashMap<u64, u64>,
    pub(super) last_applied_movement_ack: u32,
    pub(super) last_applied_auth_tick: u32,
    pub(super) last_remote_move_ticks: HashMap<i64, u32>,
    pub(super) fast_lane: FastLaneState,
    pub(super) local_prediction: LocalPredictionRuntime,
    /// Audit B-M2: last server-reported fixed_dt_ms we already logged as
    /// a mismatch — used to throttle the per-ack warning to once per
    /// distinct mismatch value.
    pub(super) last_logged_fixed_dt_mismatch: Option<u16>,
    /// Monotonic per-edit sequence for `VoxelEditIntent` replay dedup (server
    /// derives command_id from `client_intent_seq`). Construction system.
    pub(super) voxel_edit_seq: u32,
}

impl ClientRuntime {
    pub(super) fn new(gate_tcp_addr: SocketAddr) -> Self {
        Self {
            gate_tcp_addr,
            phase: ConnectionPhase::AwaitingAuth,
            next_request_id: 2,
            auth_request_id: 1,
            enter_scene_request_id: None,
            pending_time_sync: HashMap::new(),
            last_applied_movement_ack: 0,
            last_applied_auth_tick: 0,
            last_remote_move_ticks: HashMap::new(),
            fast_lane: FastLaneState::default(),
            local_prediction: LocalPredictionRuntime::default(),
            last_logged_fixed_dt_mismatch: None,
            voxel_edit_seq: 0,
        }
    }

    pub(super) fn transport_event(&self) -> NetworkEvent {
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

    pub(super) fn initial_auth_message(&self, creds: &SessionCredentials) -> ClientMessage {
        ClientMessage::AuthRequest {
            request_id: self.auth_request_id,
            username: creds.username.clone(),
            token: creds.token.clone(),
        }
    }

    pub(super) fn handle_command(
        &mut self,
        creds: &SessionCredentials,
        command: NetworkCommand,
    ) -> RuntimeOutcome {
        let mut outcome = RuntimeOutcome::default();

        match command {
            NetworkCommand::Shutdown => {}
            NetworkCommand::MoveInputSample {
                input_dir,
                dt_ms,
                speed_scale,
                movement_flags,
            } if self.phase == ConnectionPhase::InScene => {
                let current_before = self.local_prediction.current_state().cloned().map(|state| {
                    (
                        format_vec(&[
                            state.position.x as f64,
                            state.position.y as f64,
                            state.position.z as f64,
                        ]),
                        format_vec(&[
                            state.velocity.x as f64,
                            state.velocity.y as f64,
                            state.velocity.z as f64,
                        ]),
                    )
                });
                let frame = self.local_prediction.build_input_frame(
                    bevy::prelude::Vec2::new(input_dir[0], input_dir[1]),
                    dt_ms,
                    speed_scale,
                    movement_flags,
                );

                if let Some(predicted) = self.local_prediction.apply_local_input(frame.clone()) {
                    outcome.push_event(NetworkEvent::Log(format!(
                        "movement_sample seq={} tick={} dt_ms={} dir={:.2},{:.2} speed_scale={:.2} flags={} previous_pos={} previous_vel={} predicted_pos={:.1},{:.1},{:.1} predicted_vel={:.1},{:.1},{:.1}",
                        frame.seq,
                        frame.client_tick,
                        frame.dt_ms,
                        input_dir[0],
                        input_dir[1],
                        speed_scale,
                        movement_flags,
                        current_before
                            .as_ref()
                            .map(|(position, _)| position.as_str())
                            .unwrap_or("n/a"),
                        current_before
                            .as_ref()
                            .map(|(_, velocity)| velocity.as_str())
                            .unwrap_or("n/a"),
                        predicted.position.x,
                        predicted.position.y,
                        predicted.position.z,
                        predicted.velocity.x,
                        predicted.velocity.y,
                        predicted.velocity.z
                    )));
                    outcome.push_event(NetworkEvent::LocalPosition {
                        cid: creds.cid,
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
                        acceleration: [
                            predicted.acceleration.x as f64,
                            predicted.acceleration.y as f64,
                            predicted.acceleration.z as f64,
                        ],
                        movement_mode: predicted.movement_mode,
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
                    target_kind: crate::protocol::SkillTargetKind::Auto,
                    target_cid: -1,
                    target_position: [0.0, 0.0, 0.0],
                }));
            }
            NetworkCommand::CastSkillTargeted {
                skill_id,
                target_cid,
                target_position,
            } if self.phase == ConnectionPhase::InScene => {
                let request_id = self.next_request_id();
                let (target_kind, cid, position) = match (target_cid, target_position) {
                    (Some(cid), _) => (
                        crate::protocol::SkillTargetKind::Actor,
                        cid,
                        [0.0, 0.0, 0.0],
                    ),
                    (None, Some(position)) => {
                        (crate::protocol::SkillTargetKind::Point, -1, position)
                    }
                    _ => (crate::protocol::SkillTargetKind::Auto, -1, [0.0, 0.0, 0.0]),
                };
                outcome.push_outbound(OutboundAction::Tcp(ClientMessage::SkillCast {
                    request_id,
                    skill_id,
                    target_kind,
                    target_cid: cid,
                    target_position: position,
                }));
            }
            NetworkCommand::RequestReconcileStats => {
                let stats = self.local_prediction.governance_stats().clone();
                outcome.push_event(NetworkEvent::ReconcileStats {
                    total_corrections: stats.total_corrections,
                    total_replays: stats.total_replays,
                    total_hard_snaps: stats.total_hard_snaps,
                    total_window_trims: stats.total_window_trims,
                    last_replayed_frames: stats.last_replayed_frames,
                    last_pending_inputs: stats.last_pending_inputs,
                    last_correction_distance: stats.last_correction_distance,
                });
            }
            NetworkCommand::SubscribeChunks {
                logical_scene_id,
                center_chunk,
                radius,
            } if self.phase == ConnectionPhase::InScene => {
                let request_id = self.next_request_id();
                let subscribe = crate::voxel::wire::ChunkSubscribe {
                    request_id,
                    logical_scene_id,
                    center_chunk,
                    radius_l_inf: radius,
                    want_snapshot: true,
                    known: Vec::new(),
                };
                outcome.push_outbound(OutboundAction::Tcp(ClientMessage::Voxel(
                    crate::voxel::wire::VoxelClientMessage::ChunkSubscribe(subscribe),
                )));
            }
            NetworkCommand::UnsubscribeChunks {
                logical_scene_id,
                chunks,
            } if self.phase == ConnectionPhase::InScene && !chunks.is_empty() => {
                let request_id = self.next_request_id();
                let unsubscribe = crate::voxel::wire::ChunkUnsubscribe {
                    request_id,
                    logical_scene_id,
                    chunks,
                };
                outcome.push_outbound(OutboundAction::Tcp(ClientMessage::Voxel(
                    crate::voxel::wire::VoxelClientMessage::ChunkUnsubscribe(unsubscribe),
                )));
            }
            NetworkCommand::EditVoxel {
                logical_scene_id,
                action,
                target_macro,
                material_id,
            } if self.phase == ConnectionPhase::InScene => {
                let request_id = self.next_request_id();
                self.voxel_edit_seq += 1;
                let intent = crate::voxel::wire::VoxelEditIntent::macro_edit(
                    request_id,
                    self.voxel_edit_seq,
                    logical_scene_id,
                    action,
                    target_macro,
                    material_id,
                );
                outcome.push_outbound(OutboundAction::Tcp(ClientMessage::Voxel(
                    crate::voxel::wire::VoxelClientMessage::EditIntent(intent),
                )));
            }
            _ => {}
        }

        outcome
    }

    pub(super) fn heartbeat_message(&self) -> Option<ClientMessage> {
        (self.phase != ConnectionPhase::AwaitingAuth).then(|| ClientMessage::Heartbeat {
            timestamp: now_millis(),
        })
    }

    pub(super) fn time_sync_message(&mut self) -> Option<ClientMessage> {
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

    pub(super) fn mark_fast_lane_failed(
        &mut self,
        reason: impl Into<String>,
        allow_rebootstrap: bool,
    ) -> RuntimeOutcome {
        self.mark_fast_lane_failed_at(Instant::now(), reason, allow_rebootstrap)
    }

    pub(super) fn mark_fast_lane_failed_at(
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
            if let Some(cooldown_until) = cooldown_until
                && cooldown_until > now
            {
                self.fast_lane.cooldown_until = Some(cooldown_until);
                outcome.push_event(NetworkEvent::Log(format!(
                    "udp fast-lane retry suppressed during cooldown ({}ms remaining)",
                    cooldown_until.duration_since(now).as_millis()
                )));
                outcome.push_event(self.transport_event());
                return outcome;
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

    pub(super) fn poll_fast_lane_retry(&mut self, now: Instant) -> RuntimeOutcome {
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

        if let Some(retry_due_at) = self.fast_lane.retry_due_at
            && now >= retry_due_at
        {
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

        outcome
    }

    pub(super) fn handle_server_message(
        &mut self,
        creds: &SessionCredentials,
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
                        cid: creds.cid,
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
                expected_seq,
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
                self.last_applied_auth_tick = 0;
                self.last_remote_move_ticks.clear();
                let location =
                    location.ok_or_else(|| "enter-scene success missing location".to_string())?;
                let expected_seq = expected_seq
                    .ok_or_else(|| "enter-scene success missing expected_seq".to_string())?;
                outcome.push_event(NetworkEvent::Log(format!(
                    "enter-scene handshake: expected_seq={expected_seq}"
                )));
                // Audit B-S1 / B-SRV1: align client input counter with the
                // value the server is going to validate against.
                self.local_prediction.reset_with_seq(
                    bevy::prelude::Vec3::new(
                        location[0] as f32,
                        location[1] as f32,
                        location[2] as f32,
                    ),
                    None,
                    expected_seq,
                );
                outcome.push_event(NetworkEvent::Status("in scene".to_string()));
                outcome.push_event(NetworkEvent::EnteredScene {
                    cid: creds.cid,
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
            message @ ServerMessage::MovementAck {
                ack_seq,
                auth_tick,
                cid,
                location,
                velocity,
                acceleration,
                server_fixed_dt_ms,
                ..
            } => {
                if ack_seq < self.last_applied_movement_ack
                    || (ack_seq == self.last_applied_movement_ack
                        && auth_tick <= self.last_applied_auth_tick)
                {
                    outcome.push_event(NetworkEvent::Log(format!(
                        "ignoring stale movement ack ack_seq={ack_seq} auth_tick={auth_tick} (latest={}:{})",
                        self.last_applied_movement_ack,
                        self.last_applied_auth_tick
                    )));
                    return Ok(outcome);
                }

                self.last_applied_movement_ack = ack_seq;
                self.last_applied_auth_tick = auth_tick;

                // Audit B-M2: detect fixed_dt_ms drift. If the value the
                // server is using diverges from the client's
                // MovementProfile.fixed_dt_ms, hundreds of frames of replay
                // would silently accumulate drift. Surface it via observer
                // log so an operator can react. Throttling is left to the
                // observer side (sample is per-ack but jitter logs already
                // dwarf this volume).
                let client_fixed_dt_ms = self.local_prediction.movement_profile_fixed_dt_ms();
                if server_fixed_dt_ms != 0
                    && client_fixed_dt_ms != 0
                    && server_fixed_dt_ms != client_fixed_dt_ms
                    && self.last_logged_fixed_dt_mismatch != Some(server_fixed_dt_ms)
                {
                    outcome.push_event(NetworkEvent::Log(format!(
                        "movement profile fixed_dt_ms drift: server={server_fixed_dt_ms} client={client_fixed_dt_ms}; replay accuracy may degrade until profiles realign"
                    )));
                    self.last_logged_fixed_dt_mismatch = Some(server_fixed_dt_ms);
                }

                let predicted_before = self.local_prediction.current_state().cloned();
                // Audit A-M1: replace `expect()` with explicit error reporting
                // so a non-MovementAck server message routed here cannot panic
                // the network thread. The match arm above already gates on
                // ServerMessage::MovementAck so this should be unreachable in
                // practice, but defending against future routing changes is
                // cheap.
                let ack = match movement_ack_from_server(&message) {
                    Some(ack) => ack,
                    None => {
                        outcome.push_event(NetworkEvent::Log(
                            "internal: non-MovementAck routed to MovementAck handler".to_string(),
                        ));
                        return Ok(outcome);
                    }
                };
                let reconcile = self.local_prediction.apply_ack(ack);

                if let Some(result) = &reconcile {
                    let before_position = predicted_before
                        .as_ref()
                        .map(|state| {
                            format_vec(&[
                                state.position.x as f64,
                                state.position.y as f64,
                                state.position.z as f64,
                            ])
                        })
                        .unwrap_or_else(|| "n/a".to_string());
                    let before_velocity = predicted_before
                        .as_ref()
                        .map(|state| {
                            format_vec(&[
                                state.velocity.x as f64,
                                state.velocity.y as f64,
                                state.velocity.z as f64,
                            ])
                        })
                        .unwrap_or_else(|| "n/a".to_string());
                    let after_position = format_vec(&[
                        result.latest_state.position.x as f64,
                        result.latest_state.position.y as f64,
                        result.latest_state.position.z as f64,
                    ]);
                    let after_velocity = format_vec(&[
                        result.latest_state.velocity.x as f64,
                        result.latest_state.velocity.y as f64,
                        result.latest_state.velocity.z as f64,
                    ]);
                    outcome.push_event(NetworkEvent::Log(format!(
                        "movement_reconcile transport={} cid={} ack_seq={} auth_tick={} authoritative_pos={} authoritative_vel={} authoritative_accel={} predicted_before_pos={} predicted_before_vel={} latest_after_pos={} latest_after_vel={} action={:?} correction_distance={:.2} replayed_frames={} pending_inputs={}",
                        transport.label(),
                        cid,
                        ack_seq,
                        auth_tick,
                        format_vec(&location),
                        format_vec(&velocity),
                        format_vec(&acceleration),
                        before_position,
                        before_velocity,
                        after_position,
                        after_velocity,
                        result.action,
                        result.correction_distance,
                        result.replayed_frames,
                        result.pending_inputs
                    )));
                    if !matches!(
                        result.action,
                        crate::sim::governance::ReplayAction::Accepted
                    ) {
                        outcome.push_event(NetworkEvent::Log(format!(
                            "reconcile action={:?} correction_distance={:.2} replayed_frames={} pending_inputs={}",
                            result.action,
                            result.correction_distance,
                            result.replayed_frames,
                            result.pending_inputs
                        )));
                    }
                }

                let latest_state = reconcile
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
                        acceleration: [
                            state.acceleration.x as f64,
                            state.acceleration.y as f64,
                            state.acceleration.z as f64,
                        ],
                        movement_mode: state.movement_mode,
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
                // Treat each (re-)enter as a fresh per-cid tick epoch. A remote
                // PlayerCharacter process is `restart: :temporary`, so a
                // reconnect/respawn spawns a NEW process whose movement tick
                // restarts near 0. Without clearing the stale high watermark, the
                // re-entered actor's low-tick PlayerMoves would all be dropped as
                // "stale" and it would appear frozen at its spawn position.
                self.last_remote_move_ticks.remove(&cid);
                outcome.push_event(NetworkEvent::PlayerEnter { cid, location });
            }
            message @ ServerMessage::PlayerMove { cid, .. } => {
                let snapshot = match remote_move_snapshot_from_server(&message) {
                    Some(snapshot) => snapshot,
                    None => {
                        // Audit A-M1 sibling: defensive check against future
                        // routing changes. The arm gate already requires PlayerMove.
                        outcome.push_event(NetworkEvent::Log(
                            "internal: non-PlayerMove routed to PlayerMove handler".to_string(),
                        ));
                        return Ok(outcome);
                    }
                };
                let latest_tick = self.last_remote_move_ticks.get(&cid).copied().unwrap_or(0);
                if snapshot.server_tick <= latest_tick {
                    outcome.push_event(NetworkEvent::Log(format!(
                        "ignoring stale player_move cid={cid} tick={} (latest={latest_tick})",
                        snapshot.server_tick
                    )));
                    return Ok(outcome);
                }

                // Audit A-L2: log when remote-move snapshot ticks jump by more
                // than 1 — useful for diagnosing late/dropped UDP packets.
                // `latest_tick == 0` means "first ever", not a real jump.
                if latest_tick != 0 && snapshot.server_tick > latest_tick + 1 {
                    let gap = snapshot.server_tick - latest_tick - 1;
                    outcome.push_event(NetworkEvent::Log(format!(
                        "player_move tick jump cid={cid} from={latest_tick} to={} (skipped {gap})",
                        snapshot.server_tick
                    )));
                }

                self.last_remote_move_ticks
                    .insert(cid, snapshot.server_tick);
                outcome.push_event(NetworkEvent::PlayerMove {
                    snapshot,
                    transport,
                });
            }
            ServerMessage::PlayerLeave { cid } => {
                // Bound the per-cid tick map and clear the stale epoch so a future
                // re-enter of this cid starts fresh (see PlayerEnter).
                self.last_remote_move_ticks.remove(&cid);
                outcome.push_event(NetworkEvent::PlayerLeave { cid });
            }
            ServerMessage::ActorIdentity { cid, kind, name } => {
                outcome.push_event(NetworkEvent::ActorIdentity {
                    cid,
                    kind: remote_actor_kind(kind),
                    name,
                });
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
            ServerMessage::PlayerState {
                cid,
                hp,
                max_hp,
                alive,
            } => {
                outcome.push_event(NetworkEvent::PlayerState {
                    cid,
                    hp,
                    max_hp,
                    alive,
                });
            }
            ServerMessage::CombatHit {
                source_cid,
                target_cid,
                skill_id,
                damage,
                hp_after,
                location,
            } => {
                outcome.push_event(NetworkEvent::CombatHit {
                    source_cid,
                    target_cid,
                    skill_id,
                    damage,
                    hp_after,
                    location,
                });
            }
            ServerMessage::EffectEvent {
                source_cid,
                skill_id,
                cue_kind,
                target_cid,
                origin,
                target_position,
                radius,
                duration_ms,
            } => {
                outcome.push_event(NetworkEvent::EffectEvent {
                    source_cid,
                    skill_id,
                    cue_kind,
                    target_cid,
                    origin,
                    target_position,
                    radius,
                    duration_ms,
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
                let rtt_ms = now - client_send;
                self.local_prediction.observe_rtt(rtt_ms as f32);
                outcome.push_event(NetworkEvent::TimeSync {
                    rtt_ms,
                    offset_ms: server_mid - client_mid,
                });
            }
            ServerMessage::HeartbeatReply { timestamp } => {
                outcome.push_event(NetworkEvent::Heartbeat {
                    server_ts: timestamp,
                });
            }
            ServerMessage::Voxel(voxel) => {
                outcome.push_event(NetworkEvent::Voxel(voxel));
            }
        }

        Ok(outcome)
    }
}

fn format_vec(value: &[f64; 3]) -> String {
    format!("{:.1},{:.1},{:.1}", value[0], value[1], value[2])
}

fn remote_actor_kind(kind: ActorKind) -> RemoteActorKind {
    match kind {
        ActorKind::Player => RemoteActorKind::Player,
        ActorKind::Npc => RemoteActorKind::Npc,
        ActorKind::Unknown(value) => RemoteActorKind::Unknown(value),
    }
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
    use crate::config::SessionCredentials;
    use crate::protocol::{ClientMessage, ServerMessage};
    use std::net::{Ipv4Addr, SocketAddrV4};

    fn test_creds() -> SessionCredentials {
        SessionCredentials {
            username: "tester".into(),
            token: "token".into(),
            cid: 42,
        }
    }

    fn test_gate_addr() -> SocketAddr {
        SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 20_002))
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
        let creds = test_creds();
        let mut runtime = ClientRuntime::new(test_gate_addr());

        let auth = runtime
            .handle_server_message(
                &creds,
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
                &creds,
                MessageTransport::Tcp,
                ServerMessage::EnterSceneResult {
                    packet_id: 2,
                    ok: true,
                    location: Some([10.0, 20.0, 0.0]),
                    expected_seq: Some(1),
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
        let creds = test_creds();
        let mut runtime = ClientRuntime::new(test_gate_addr());
        runtime.phase = ConnectionPhase::InScene;
        runtime.fast_lane.reset_for_bootstrap(3);
        runtime
            .local_prediction
            .reset(bevy::prelude::Vec3::ZERO, None);

        let bootstrap = runtime
            .handle_server_message(
                &creds,
                MessageTransport::Tcp,
                ServerMessage::FastLaneResult {
                    packet_id: 3,
                    ok: true,
                    udp_port: Some(20_003),
                    ticket: Some("ticket-123".into()),
                },
            )
            .unwrap();

        assert_eq!(
            bootstrap.outbounds,
            vec![OutboundAction::OpenUdpAndAttach {
                udp_endpoint: SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 20_003)),
                request_id: 2,
                ticket: "ticket-123".into(),
            }]
        );

        let before_attach = runtime.handle_command(&creds, movement_command());
        assert!(matches!(
            before_attach.outbounds.as_slice(),
            [OutboundAction::Tcp(ClientMessage::MovementInput { .. })]
        ));

        let attach = runtime
            .handle_server_message(
                &creds,
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

        let after_attach = runtime.handle_command(&creds, movement_command());
        assert!(matches!(
            after_attach.outbounds.as_slice(),
            [OutboundAction::Udp(ClientMessage::MovementInput { .. })]
        ));

        let move_ack = runtime
            .handle_server_message(
                &creds,
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
                    server_fixed_dt_ms: 100,
                    ground_z: 0.0,
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
                &creds,
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
        let creds = test_creds();
        let mut runtime = ClientRuntime::new(test_gate_addr());
        runtime.phase = ConnectionPhase::InScene;
        runtime.fast_lane.reset_for_bootstrap(5);

        let fallback = runtime
            .handle_server_message(
                &creds,
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

        let movement = runtime.handle_command(&creds, movement_command());
        assert!(matches!(
            movement.outbounds.as_slice(),
            [OutboundAction::Tcp(ClientMessage::MovementInput { .. })]
        ));
    }

    #[test]
    fn edit_voxel_in_scene_emits_edit_intent_with_monotonic_seq() {
        use crate::voxel::wire::{ACTION_BREAK, ACTION_PLACE, VoxelClientMessage};

        let creds = test_creds();
        let mut runtime = ClientRuntime::new(test_gate_addr());
        runtime.phase = ConnectionPhase::InScene;

        let place = runtime.handle_command(
            &creds,
            NetworkCommand::EditVoxel {
                logical_scene_id: 1,
                action: ACTION_PLACE,
                target_macro: [4, 0, 7],
                material_id: 2,
            },
        );
        match place.outbounds.as_slice() {
            [OutboundAction::Tcp(ClientMessage::Voxel(VoxelClientMessage::EditIntent(intent)))] => {
                assert_eq!(intent.action, ACTION_PLACE);
                assert_eq!(intent.material_id, 2);
                assert_eq!(intent.target_world_micro, [32, 0, 56]); // macro * 8
                assert_eq!(intent.target_granularity, 0);
                assert_eq!(intent.client_intent_seq, 1);
            }
            other => panic!("expected one EditIntent outbound, got {other:?}"),
        }

        // Second edit bumps client_intent_seq (server replay dedup keys on it).
        let brk = runtime.handle_command(
            &creds,
            NetworkCommand::EditVoxel {
                logical_scene_id: 1,
                action: ACTION_BREAK,
                target_macro: [4, 0, 7],
                material_id: 0,
            },
        );
        match brk.outbounds.as_slice() {
            [OutboundAction::Tcp(ClientMessage::Voxel(VoxelClientMessage::EditIntent(intent)))] => {
                assert_eq!(intent.action, ACTION_BREAK);
                assert_eq!(intent.client_intent_seq, 2);
            }
            other => panic!("expected one EditIntent outbound, got {other:?}"),
        }
    }

    #[test]
    fn edit_voxel_gated_outside_scene() {
        let creds = test_creds();
        let mut runtime = ClientRuntime::new(test_gate_addr()); // AwaitingAuth
        let outcome = runtime.handle_command(
            &creds,
            NetworkCommand::EditVoxel {
                logical_scene_id: 1,
                action: crate::voxel::wire::ACTION_PLACE,
                target_macro: [0, 0, 0],
                material_id: 2,
            },
        );
        assert!(outcome.outbounds.is_empty());
    }

    #[test]
    fn udp_error_downgrades_to_tcp_and_schedules_rebootstrap() {
        let mut runtime = ClientRuntime::new(test_gate_addr());
        runtime.phase = ConnectionPhase::InScene;
        runtime.fast_lane.attached = true;
        runtime.fast_lane.udp_endpoint = Some(SocketAddr::V4(SocketAddrV4::new(
            Ipv4Addr::LOCALHOST,
            20_003,
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
        let creds = test_creds();
        let mut runtime = ClientRuntime::new(test_gate_addr());
        runtime.phase = ConnectionPhase::InScene;
        runtime
            .local_prediction
            .reset(bevy::prelude::Vec3::ZERO, None);

        let latest = runtime
            .handle_server_message(
                &creds,
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
                    server_fixed_dt_ms: 100,
                    ground_z: 0.0,
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
                &creds,
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
                    server_fixed_dt_ms: 100,
                    ground_z: 0.0,
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
    fn accepts_newer_auth_tick_for_same_ack_seq() {
        let creds = test_creds();
        let mut runtime = ClientRuntime::new(test_gate_addr());
        runtime.phase = ConnectionPhase::InScene;
        runtime
            .local_prediction
            .reset(bevy::prelude::Vec3::ZERO, None);

        let first = runtime
            .handle_server_message(
                &creds,
                MessageTransport::Udp,
                ServerMessage::MovementAck {
                    ack_seq: 10,
                    auth_tick: 1,
                    cid: 42,
                    location: [4.0, 5.0, 6.0],
                    velocity: [1.0, 0.0, 0.0],
                    acceleration: [0.0, 0.0, 0.0],
                    movement_mode: 0,
                    correction_flags: 0,
                    server_fixed_dt_ms: 100,
                    ground_z: 0.0,
                },
            )
            .unwrap();

        assert!(
            first
                .events
                .iter()
                .any(|event| matches!(event, NetworkEvent::LocalPosition { .. }))
        );

        let newer_tick = runtime
            .handle_server_message(
                &creds,
                MessageTransport::Udp,
                ServerMessage::MovementAck {
                    ack_seq: 10,
                    auth_tick: 2,
                    cid: 42,
                    location: [4.5, 5.0, 6.0],
                    velocity: [0.5, 0.0, 0.0],
                    acceleration: [0.0, 0.0, 0.0],
                    movement_mode: 1,
                    correction_flags: 0,
                    server_fixed_dt_ms: 100,
                    ground_z: 0.0,
                },
            )
            .unwrap();

        assert!(newer_tick.events.iter().any(|event| matches!(
            event,
            NetworkEvent::LocalPosition {
                location: [4.5, 5.0, 6.0],
                movement_mode: crate::sim::types::MovementMode::Airborne,
                ..
            }
        )));
    }

    #[test]
    fn ignores_stale_remote_player_moves_by_tick() {
        let creds = test_creds();
        let mut runtime = ClientRuntime::new(test_gate_addr());
        runtime.phase = ConnectionPhase::InScene;

        let latest = runtime
            .handle_server_message(
                &creds,
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
                &creds,
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
