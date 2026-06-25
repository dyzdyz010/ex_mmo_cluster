//! Public command and event surface between the network thread and the
//! Bevy app / headless shell.

use std::sync::{
    Arc, Mutex,
    mpsc::{Receiver, Sender},
};

use bevy::prelude::Resource;

use crate::protocol::{EffectCueKind, NetVec3};
use crate::sim::types::{MovementMode, RemoteMoveSnapshot};
use crate::world::remote_actor::RemoteActorKind;

/// Transport used for a particular message family.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MessageTransport {
    #[default]
    Tcp,
    Udp,
}

impl MessageTransport {
    /// Human-readable label used in logs and stdio output.
    pub const fn label(self) -> &'static str {
        match self {
            Self::Tcp => "TCP",
            Self::Udp => "UDP",
        }
    }
}

/// Commands sent from the Bevy app/headless shell into the network thread.
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
    CastSkillTargeted {
        skill_id: u16,
        target_cid: Option<i64>,
        target_position: Option<NetVec3>,
    },
    RequestReconcileStats,
    /// Subscribe to voxel chunks around a center (L∞ radius). `known` advertises
    /// `(chunk_coord, chunk_version)` the client already holds (from the on-disk
    /// map cache) so the server sends a snapshot ONLY for chunks whose version
    /// differs — a startup diff instead of re-streaming the whole box.
    SubscribeChunks {
        logical_scene_id: u64,
        center_chunk: [i32; 3],
        radius: u8,
        known: Vec<([i32; 3], u64)>,
    },
    /// Unsubscribe from voxel chunks that fell out of the AOI box as the player
    /// moved, so the server stops fanning out deltas/field snapshots for chunks
    /// behind the player (bounds per-session bandwidth + the client chunk store).
    UnsubscribeChunks {
        logical_scene_id: u64,
        chunks: Vec<[i32; 3]>,
    },
    /// Construction system: a single macro-cell place/break edit at a GLOBAL macro
    /// coord. The runtime resolves it to a `VoxelEditIntent` (0x70). Server-
    /// authoritative — the resulting `ChunkDelta` is what the client renders.
    EditVoxel {
        logical_scene_id: u64,
        /// `voxel::wire::ACTION_PLACE` (0) or `ACTION_BREAK` (1).
        action: u8,
        /// Global macro coord: the adjacent cell for place, the clicked cell for break.
        target_macro: [i32; 3],
        /// Material to place (ignored for break).
        material_id: u16,
    },
    /// Construction system (C5): place a server-catalog blueprint as a refined
    /// prefab (0x67). `anchor_macro` is the GLOBAL macro anchor; the runtime
    /// resolves it to world-micro. `blueprint_id` is a `BlueprintCatalog` id (1..7).
    PlacePrefab {
        logical_scene_id: u64,
        blueprint_id: u64,
        anchor_macro: [i32; 3],
        rotation: u8,
    },
    /// Construction system (C5.2): place/clear a surface element (torch/lever) on
    /// a face of a GLOBAL host macro (0x66). The runtime resolves `host_macro` to
    /// world-micro. `action` is `surface_element_intent::ACTION_PLACE`/`ACTION_CLEAR`,
    /// `face` is the 0..5 ordinal, `surface_type_id` a `SurfaceCatalog` id (torch=4,
    /// lever=5). Server-authoritative — the resulting snapshot is what renders.
    PlaceSurfaceElement {
        logical_scene_id: u64,
        action: u8,
        host_macro: [i32; 3],
        face: u8,
        surface_type_id: u16,
    },
    Shutdown,
}

/// Events emitted by the network thread back to the game/app layer.
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
        acceleration: NetVec3,
        movement_mode: MovementMode,
        transport: MessageTransport,
    },
    PlayerEnter {
        cid: i64,
        location: NetVec3,
    },
    PlayerMove {
        snapshot: RemoteMoveSnapshot,
        transport: MessageTransport,
    },
    PlayerLeave {
        cid: i64,
    },
    ActorIdentity {
        cid: i64,
        kind: RemoteActorKind,
        name: String,
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
    PlayerState {
        cid: i64,
        hp: u16,
        max_hp: u16,
        alive: bool,
    },
    CombatHit {
        source_cid: i64,
        target_cid: i64,
        skill_id: u16,
        damage: u16,
        hp_after: u16,
        location: NetVec3,
    },
    EffectEvent {
        source_cid: i64,
        skill_id: u16,
        cue_kind: EffectCueKind,
        target_cid: Option<i64>,
        origin: NetVec3,
        target_position: NetVec3,
        radius: f64,
        duration_ms: u32,
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
    ReconcileStats {
        total_corrections: u32,
        total_replays: u32,
        total_hard_snaps: u32,
        total_window_trims: u32,
        last_replayed_frames: usize,
        last_pending_inputs: usize,
        last_correction_distance: f32,
    },
    /// A decoded server→client voxel message (chunk snapshot/delta/invalidate/
    /// object-state/catalog/field). Drained into the voxel authority store.
    Voxel(crate::voxel::wire::VoxelServerMessage),
    Log(String),
    Disconnected(String),
    /// The network thread dropped and is backing off before reconnect `attempt`
    /// of `max_attempts` (阶段4 退避重连)。Surfaced so the HUD shows live recovery
    /// progress instead of a frozen "disconnected".
    Reconnecting {
        attempt: u32,
        max_attempts: u32,
    },
    /// The network thread exhausted its reconnect budget and gave up (terminal
    /// until the user restarts) — drives `ConnectionPhase::Failed`.
    ReconnectFailed,
}

/// App-side handle for sending commands to and receiving events from the
/// network thread.
#[derive(Clone, Resource)]
pub struct NetworkBridge {
    pub tx: Sender<NetworkCommand>,
    pub rx: Arc<Mutex<Receiver<NetworkEvent>>>,
}

impl NetworkBridge {
    /// Sends one command to the network thread, ignoring disconnects.
    pub fn send(&self, command: NetworkCommand) {
        let _ = self.tx.send(command);
    }
}
