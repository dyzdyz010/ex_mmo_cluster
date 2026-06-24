//! Attached stdio automation interface for the normal client runtime.
//!
//! - The types/parser/emit helpers live here in `mod.rs`.
//! - `plugin` registers the system that drains queued commands once per
//!   frame in the Bevy app.

pub mod plugin;

pub use plugin::StdioPlugin;

use crate::voxel::{VoxelCliCommand, parse_voxel_cli_command};
use bevy::prelude::{Resource, Vec2, Vec3};
use std::{
    io::{self, BufRead},
    sync::{
        Arc, Mutex,
        mpsc::{self, Receiver},
    },
    thread,
};

#[derive(Debug, Clone, PartialEq)]
/// Commands accepted by the attached stdio interface.
pub enum ClientStdioCommand {
    Snapshot,
    Position,
    Transport,
    Players,
    Npcs,
    Target(i64),
    ClearTarget,
    TargetPoint(Vec3),
    ClearTargetPoint,
    Chat(String),
    Skill {
        skill_id: u16,
        target_cid: Option<i64>,
    },
    Move {
        direction: Vec2,
        direction_label: String,
        duration_ms: u64,
    },
    Jump,
    Stop,
    Quit,
    ReconcileStats,
    DiagRender,
    Voxel(VoxelCliCommand),
    /// Server-authoritative voxel store status (chunk count + renderable quads).
    VoxelAuthorityStatus,
    /// Subscribe to server voxel chunks around a center (drives the stream).
    VoxelSubscribe {
        logical_scene_id: u64,
        center: [i32; 3],
        radius: u8,
    },
    /// Per-chunk authority inspection (cell breakdown + mesh quad count).
    VoxelChunkInfo {
        coord: [i32; 3],
    },
    /// Unsubscribe a chunk (0x61 ChunkUnsubscribe) + evict it locally — the
    /// scriptable equivalent of the AOI-move eviction, so the unsubscribe path can
    /// be self-verified (chunk gone from `va-status`/`va-chunk` after).
    VoxelUnsubscribe {
        logical_scene_id: u64,
        coord: [i32; 3],
    },
    /// Construction C5: place a catalog blueprint as a prefab (0x67) over the live
    /// connection — headless/scriptable equivalent of the GUI prefab hotbar, so
    /// the prefab round-trip (→ refined-cell ChunkDelta) can be self-verified.
    VoxelPrefabPlace {
        logical_scene_id: u64,
        blueprint_id: u64,
        anchor_macro: [i32; 3],
        rotation: u8,
    },
    /// Construction C5.2: place/clear a surface element (torch/lever) on a face of
    /// a GLOBAL host macro (0x66) over the live connection — headless/scriptable
    /// equivalent of the GUI surface hotbar, so the decal round-trip (→ snapshot
    /// section 0x08 → `surface_decal` render) can be self-verified. `action` is 0
    /// (place) / 1 (clear); `face` is the 0..5 ordinal; `surface_type_id` is a
    /// `SurfaceCatalog` id (torch=4, lever=5).
    VoxelSurfacePlace {
        logical_scene_id: u64,
        action: u8,
        host_macro: [i32; 3],
        face: u8,
        surface_type_id: u16,
    },
    /// Sends a server-authoritative voxel edit (0x70 VoxelEditIntent) over the
    /// live connection — the headless/scriptable equivalent of the GUI F/RMB
    /// build, so the build round-trip + the 0x68 ACK can be self-verified without
    /// a human at the keyboard. `target_macro` is in voxel (render-axis) macro
    /// space; for `break` it's the cell to clear, for `place` the cell to fill.
    VoxelEditLive {
        logical_scene_id: u64,
        action: u8,
        target_macro: [i32; 3],
        material_id: u16,
    },
    /// AOI follow: subscribe around the player's CURRENT position's chunk,
    /// computed via the real `voxel_chunk_of` (sim→voxel axis map). Lets the
    /// terrain-streams-as-you-move path be self-verified after a `move`.
    VoxelFollow {
        logical_scene_id: u64,
        radius: u8,
    },
    /// Inspect a single GLOBAL macro cell in the authority store (present / state
    /// / material) — verifies an edit landed at the EXACT cell, not just an
    /// aggregate count.
    VoxelMacroInfo {
        global_macro: [i32; 3],
    },
    /// List the retained field regions (heat/electric/light/...) — verifies the
    /// emergence field stream reaches the client.
    VoxelFields,
    /// C5.3: list a chunk's semiconductor cells (resistor/comparator) + their
    /// classified LOGIC state (idle/active, low/high) derived from the electric
    /// field — the headless-only verification path for the digital-circuit overlay.
    VoxelSemiconductors {
        chunk_coord: [i32; 3],
    },
    /// C5.2: list a chunk's surface elements (torch/lever/decals) with their exact
    /// macro/face/type/owner — verifies decal placement landed at the right cell.
    VoxelSurfaceList {
        chunk_coord: [i32; 3],
    },
    /// Recent server-message history queries (bounded ring buffers). Let the harness
    /// ASSERT a chat/skill/combat/effect message was received + decoded, rather than
    /// only catching the real-time emit. `count` = how many most-recent to print.
    ChatLog {
        count: usize,
    },
    SkillLog {
        count: usize,
    },
    CombatLog {
        count: usize,
    },
    EffectLog {
        count: usize,
    },
    /// Scripting marker: echo a tag back as `client_stdio event="echo"` so a test
    /// can correlate a command with the observer events it triggered in a big log.
    Echo {
        text: String,
    },
    /// Scripting delay (headless: blocks the run loop `ms`; GUI: non-blocking note).
    /// Lets a script order operations (send A, wait, send B) without a shell sleep.
    Wait {
        ms: u64,
    },
}

#[derive(Clone, Default, Resource)]
/// Receiver side of the attached stdio automation channel.
pub struct ClientStdioInterface {
    rx: Option<Arc<Mutex<Receiver<ClientStdioCommand>>>>,
}

impl ClientStdioInterface {
    /// Returns a disabled stdio interface.
    pub fn disabled() -> Self {
        Self { rx: None }
    }

    /// Spawns the stdin reader thread and returns an enabled stdio interface.
    pub fn enabled() -> Self {
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            emit(
                "ready",
                &[(
                    "commands",
                    "help|snapshot|position|transport|players|npcs|target <cid>|clear_target|target_point <x> <y> [z]|clear_target_point|chat <text>|skill <id> [target_cid]|move <dir> <ms>|stop|voxel_snapshot|place|break|micro_cell|prefab_place|prefab_place_snap|world_export|world_import|world_save|world_load|quit"
                        .to_string(),
                )],
            );

            for line in io::stdin().lock().lines() {
                match line {
                    Ok(line) => {
                        let trimmed = sanitize_line(&line);
                        if trimmed.is_empty() {
                            continue;
                        }

                        if trimmed == "help" {
                            emit(
                                "help",
                                &[(
                                    "commands",
                                    "help|snapshot|position|transport|players|npcs|target <cid>|clear_target|target_point <x> <y> [z]|clear_target_point|chat <text>|skill <id> [target_cid]|move <dir> <ms>|stop|reconcile_stats|diag_render|voxel_snapshot|place|break|hotbar|hotbar_select|micro_cell|prefabs|prefab_place|prefab_snap_preview|prefab_place_snap|world_export|world_import|world_save|world_load|quit"
                                        .to_string(),
                                )],
                            );
                            continue;
                        }

                        match parse_command(trimmed) {
                            Ok(command) => {
                                if tx.send(command).is_err() {
                                    break;
                                }
                            }
                            Err(error) => emit("error", &[("reason", error)]),
                        }
                    }
                    Err(error) => {
                        // Audit E-S1: surface stdin failures explicitly. The
                        // reader thread cannot recover from an Io error on
                        // stdin (terminal closed, pipe broken), so we emit a
                        // structured `stdin_closed` event before exiting.
                        // The Quit synthesised below also reaches the Bevy
                        // side via the command channel so the app shuts down
                        // cleanly. Together these mean the operator can tell
                        // *why* the stdio interface went silent rather than
                        // wondering whether the binary hung.
                        emit(
                            "error",
                            &[("reason", format!("stdin read failed: {error}"))],
                        );
                        emit("stdin_closed", &[("cause", "io_error".to_string())]);
                        break;
                    }
                }
            }

            // Reached when stdin EOF or the loop above broke. If we did not
            // already announce closure (the io-error branch did), say so now
            // so log scrapers see a definitive end-of-stdio marker.
            emit(
                "stdin_closed",
                &[("cause", "eof_or_broken_pipe".to_string())],
            );
            let _ = tx.send(ClientStdioCommand::Quit);
        });

        Self {
            rx: Some(Arc::new(Mutex::new(rx))),
        }
    }

    /// Returns whether the attached stdio command channel is active.
    pub fn is_enabled(&self) -> bool {
        self.rx.is_some()
    }

    /// Attempts to read the next parsed stdio command without blocking.
    pub fn try_recv(&self) -> Option<ClientStdioCommand> {
        let rx = self.rx.as_ref()?;
        let Ok(receiver) = rx.lock() else {
            return None;
        };

        receiver.try_recv().ok()
    }
}

/// Emits one structured stdio response line for automation.
pub fn emit(event: &str, fields: &[(&str, String)]) {
    let mut line = format!("client_stdio event={event:?}");
    for (key, value) in fields {
        line.push(' ');
        line.push_str(key);
        line.push('=');
        line.push_str(&format!("{value:?}"));
    }
    println!("{line}");
}

/// Emits one structured stdio response line from owned key/value fields.
pub fn emit_owned(event: &str, ok: bool, fields: &[(String, String)]) {
    let mut line = format!("client_stdio event={event:?} ok={ok:?}");
    for (key, value) in fields {
        line.push(' ');
        line.push_str(key);
        line.push('=');
        line.push_str(&format!("{value:?}"));
    }
    println!("{line}");
}

/// Emits one GLOBAL macro cell's authority state (present / state / material).
/// Shared by the headless and GUI stdio `va-macro` probes so an edit can be
/// verified to land at the EXACT cell with the EXACT material. The global macro
/// → chunk map mirrors `authority_macro_occupied` (chunk axis 1 = vertical).
pub fn emit_voxel_macro_info(store: &crate::voxel::authority::VoxelAuthorityStore, g: [i32; 3]) {
    use crate::voxel::authority::CellState;
    let coord = format!("{},{},{}", g[0], g[1], g[2]);
    let chunk = [g[0].div_euclid(16), g[1].div_euclid(16), g[2].div_euclid(16)];
    let chunk_label = format!("{},{},{}", chunk[0], chunk[1], chunk[2]);
    let idx = (g[0].rem_euclid(16) + g[1].rem_euclid(16) * 16 + g[2].rem_euclid(16) * 256) as usize;
    let (present, state, material) = match store.chunk(chunk).and_then(|c| c.cell(idx)) {
        Some(CellState::Solid(b)) => ("true", "solid", b.material_id.to_string()),
        Some(CellState::Refined(_)) => ("true", "refined", "n/a".to_string()),
        Some(CellState::Empty) => ("true", "empty", "n/a".to_string()),
        None => ("false", "chunk_absent", "n/a".to_string()),
    };
    emit(
        "va_macro",
        &[
            ("coord", coord),
            ("chunk", chunk_label),
            ("present", present.to_string()),
            ("state", state.to_string()),
            ("material", material),
        ],
    );
}

/// Emits one chunk's authority summary (version + cell breakdown + mesh quads +
/// C5.2 surface elements / decal quads). Shared by the headless + GUI stdio
/// executors so `va-chunk` reports the SAME field set in both modes (the GUI used
/// to emit 7 fields, headless 9 — a parity gap that broke C5.2 decal assertions).
pub fn emit_voxel_chunk_info(store: &crate::voxel::authority::VoxelAuthorityStore, coord: [i32; 3]) {
    use crate::voxel::authority::CellState;
    let label = format!("{},{},{}", coord[0], coord[1], coord[2]);
    match store.chunk(coord) {
        Some(chunk) => {
            let (mut solid, mut refined, mut empty) = (0usize, 0usize, 0usize);
            for cell in &chunk.cells {
                match cell {
                    CellState::Solid(_) => solid += 1,
                    CellState::Refined(_) => refined += 1,
                    CellState::Empty => empty += 1,
                }
            }
            let quads = crate::voxel::mesher::greedy_mesh_chunk(chunk, 1.0).quad_count();
            let surface_elements = chunk.surface_elements.len();
            let decal_quads =
                crate::voxel::surface_decal::surface_decal_mesh(chunk, 1.0).quad_count();
            emit(
                "va_chunk",
                &[
                    ("coord", label),
                    ("present", "true".to_string()),
                    ("version", chunk.chunk_version.to_string()),
                    ("solid", solid.to_string()),
                    ("refined", refined.to_string()),
                    ("empty", empty.to_string()),
                    ("quads", quads.to_string()),
                    ("surface_elements", surface_elements.to_string()),
                    ("decal_quads", decal_quads.to_string()),
                ],
            );
        }
        None => emit(
            "va_chunk",
            &[("coord", label), ("present", "false".to_string())],
        ),
    }
}

/// Emits the retained field regions (id:chunk:mask:cells) — verifies the
/// emergence field stream (heat / electric / light / ...) reaches the client.
pub fn emit_voxel_fields(field_store: &crate::voxel::field_view::VoxelFieldStore) {
    let mut regions: Vec<String> = field_store
        .regions()
        .map(|r| {
            format!(
                "{}:{},{},{}:0x{:02x}:{}",
                r.region_id,
                r.chunk_coord[0],
                r.chunk_coord[1],
                r.chunk_coord[2],
                r.field_mask,
                r.macro_indices.len()
            )
        })
        .collect();
    regions.sort();
    emit(
        "va_fields",
        &[
            ("count", field_store.region_count().to_string()),
            ("regions", format!("[{}]", regions.join(";"))),
        ],
    );
}

/// C5.3 headless verification: emits a chunk's semiconductor cells (resistor /
/// comparator) with their classified LOGIC state, derived from chunk material +
/// the electric field — the only headless probe for the digital-circuit overlay.
/// Each cell is `mx,my,mz:kind:state:i=<current>:v=<potential>`.
pub fn emit_voxel_semiconductors(
    store: &crate::voxel::authority::VoxelAuthorityStore,
    field_store: &crate::voxel::field_view::VoxelFieldStore,
    chunk_coord: [i32; 3],
) {
    use crate::voxel::authority::CellState;
    use crate::voxel::semiconductor_overlay::{
        COMPARATOR_MATERIAL_ID, RESISTOR_MATERIAL_ID, SemiconductorState,
    };

    let label = format!("{},{},{}", chunk_coord[0], chunk_coord[1], chunk_coord[2]);
    let Some(chunk) = store.chunk(chunk_coord) else {
        emit(
            "va_semi",
            &[("chunk", label), ("present", "false".to_string())],
        );
        return;
    };

    let grids = field_store.electric_grids(chunk_coord);
    let mut entries: Vec<String> = Vec::new();
    for (idx, cell) in chunk.cells.iter().enumerate() {
        let CellState::Solid(block) = cell else {
            continue;
        };
        if block.material_id != RESISTOR_MATERIAL_ID && block.material_id != COMPARATOR_MATERIAL_ID
        {
            continue;
        }
        let (current, potential) = grids
            .as_ref()
            .map(|(c, p)| {
                (
                    c.get(idx).copied().unwrap_or(0.0),
                    p.get(idx).copied().unwrap_or(0.0),
                )
            })
            .unwrap_or((0.0, 0.0));
        let kind = if block.material_id == RESISTOR_MATERIAL_ID {
            "resistor"
        } else {
            "comparator"
        };
        let state = SemiconductorState::classify(block.material_id, current, potential)
            .map(|s| format!("{s:?}"))
            .unwrap_or_else(|| "none".to_string());
        let (mx, my, mz) = (idx % 16, (idx / 16) % 16, idx / 256);
        entries.push(format!(
            "{mx},{my},{mz}:{kind}:{state}:i={current:.3}:v={potential:.3}"
        ));
    }
    entries.sort();
    emit(
        "va_semi",
        &[
            ("chunk", label),
            ("present", "true".to_string()),
            ("count", entries.len().to_string()),
            ("cells", format!("[{}]", entries.join(";"))),
        ],
    );
}

/// C5.2 headless verification: emits a chunk's surface elements (torch / lever /
/// decals) with exact `mx,my,mz:face:type:owner` — verifies a placed decal landed
/// at the right cell/face/type (va-chunk only reports the aggregate count).
pub fn emit_voxel_surface_list(
    store: &crate::voxel::authority::VoxelAuthorityStore,
    chunk_coord: [i32; 3],
) {
    let label = format!("{},{},{}", chunk_coord[0], chunk_coord[1], chunk_coord[2]);
    let Some(chunk) = store.chunk(chunk_coord) else {
        emit(
            "va_surface_list",
            &[("chunk", label), ("present", "false".to_string())],
        );
        return;
    };

    let mut entries: Vec<String> = chunk
        .surface_elements
        .iter()
        .map(|e| {
            let (mx, my, mz) = (
                (e.macro_index % 16) as i32,
                ((e.macro_index / 16) % 16) as i32,
                (e.macro_index / 256) as i32,
            );
            format!(
                "{mx},{my},{mz}:face={}:type={}:owner={}",
                e.face, e.surface_type_id, e.owner_actor_id
            )
        })
        .collect();
    entries.sort();
    emit(
        "va_surface_list",
        &[
            ("chunk", label),
            ("present", "true".to_string()),
            ("count", entries.len().to_string()),
            ("elements", format!("[{}]", entries.join(";"))),
        ],
    );
}

/// Emits the most-recent `count` entries of a bounded server-message ring buffer
/// (chat / skill / combat / effect), oldest-first. Shared by the headless + GUI
/// stdio executors so a scripted test can ASSERT a message was received/decoded.
pub fn emit_event_log(event: &str, buffer: &std::collections::VecDeque<String>, count: usize) {
    let total = buffer.len();
    let take = count.min(total);
    let recent: Vec<String> = buffer.iter().skip(total - take).cloned().collect();
    emit(
        event,
        &[
            ("total", total.to_string()),
            ("shown", recent.len().to_string()),
            ("entries", format!("[{}]", recent.join(";"))),
        ],
    );
}

/// Standard snapshot data shared by interactive and headless stdio output.
#[derive(Debug, Clone, Copy)]
pub struct SnapshotFields<'a> {
    pub status: &'a str,
    pub scene_joined: bool,
    pub local_cid: i64,
    pub local_position: Option<Vec3>,
    pub local_hp: u16,
    pub local_max_hp: u16,
    pub local_alive: bool,
    pub movement_transport: &'a str,
    pub fast_lane_status: &'a str,
    pub remote_player_count: usize,
    pub remote_npc_count: usize,
}

/// Builds the standard snapshot key/value fields used by interactive and headless modes.
pub fn snapshot_fields(snapshot: SnapshotFields<'_>) -> Vec<(&'static str, String)> {
    vec![
        ("status", snapshot.status.to_string()),
        ("scene_joined", snapshot.scene_joined.to_string()),
        ("local_cid", snapshot.local_cid.to_string()),
        (
            "local_position",
            snapshot
                .local_position
                .map(|value| format!("{:.1},{:.1},{:.1}", value.x, value.y, value.z))
                .unwrap_or_else(|| "n/a".to_string()),
        ),
        ("local_hp", snapshot.local_hp.to_string()),
        ("local_max_hp", snapshot.local_max_hp.to_string()),
        ("local_alive", snapshot.local_alive.to_string()),
        (
            "movement_transport",
            snapshot.movement_transport.to_string(),
        ),
        ("fast_lane_status", snapshot.fast_lane_status.to_string()),
        (
            "remote_player_count",
            snapshot.remote_player_count.to_string(),
        ),
        ("remote_npc_count", snapshot.remote_npc_count.to_string()),
    ]
}

/// Trims surrounding whitespace and a UTF-8 BOM (U+FEFF) from a stdin line.
///
/// Windows tooling that pipes commands in — notably PowerShell's
/// `Process.StandardInput` — prepends a UTF-8 BOM to the first line written.
/// `str::trim` does not strip a BOM, so without this the very first piped
/// command would fail to match its prefix and report `unknown command`. Trimming
/// the BOM here keeps the attached stdio interface robust to that.
fn sanitize_line(line: &str) -> &str {
    line.trim_matches(|c: char| c.is_whitespace() || c == '\u{feff}')
}

fn parse_command(line: &str) -> Result<ClientStdioCommand, String> {
    if line == "snapshot" || line == "status" {
        return Ok(ClientStdioCommand::Snapshot);
    }

    if line == "position" {
        return Ok(ClientStdioCommand::Position);
    }

    if line == "transport" {
        return Ok(ClientStdioCommand::Transport);
    }

    if line == "players" {
        return Ok(ClientStdioCommand::Players);
    }

    if line == "npcs" {
        return Ok(ClientStdioCommand::Npcs);
    }

    if line == "stop" {
        return Ok(ClientStdioCommand::Stop);
    }

    if line == "jump" {
        return Ok(ClientStdioCommand::Jump);
    }

    if line == "clear_target" {
        return Ok(ClientStdioCommand::ClearTarget);
    }

    if line == "clear_target_point" {
        return Ok(ClientStdioCommand::ClearTargetPoint);
    }

    if line == "quit" || line == "exit" {
        return Ok(ClientStdioCommand::Quit);
    }

    if line == "reconcile_stats" {
        return Ok(ClientStdioCommand::ReconcileStats);
    }

    if line == "diag_render" {
        return Ok(ClientStdioCommand::DiagRender);
    }

    if let Some(cid) = line.strip_prefix("target ") {
        let parsed = cid
            .parse::<i64>()
            .map_err(|error| format!("invalid target cid: {error}"))?;
        return Ok(ClientStdioCommand::Target(parsed));
    }

    if let Some(rest) = line.strip_prefix("target_point ") {
        let parts = rest.split_whitespace().collect::<Vec<_>>();
        if parts.len() < 2 || parts.len() > 3 {
            return Err("target_point expects: target_point <x> <y> [z]".to_string());
        }

        let x = parts[0]
            .parse::<f32>()
            .map_err(|error| format!("invalid target x: {error}"))?;
        let y = parts[1]
            .parse::<f32>()
            .map_err(|error| format!("invalid target y: {error}"))?;
        let z = if parts.len() == 3 {
            parts[2]
                .parse::<f32>()
                .map_err(|error| format!("invalid target z: {error}"))?
        } else {
            90.0
        };
        return Ok(ClientStdioCommand::TargetPoint(Vec3::new(x, y, z)));
    }

    if let Some(text) = line.strip_prefix("chat ") {
        return Ok(ClientStdioCommand::Chat(text.to_string()));
    }

    if let Some(skill) = line.strip_prefix("skill ") {
        let parts = skill.split_whitespace().collect::<Vec<_>>();
        if parts.is_empty() || parts.len() > 2 {
            return Err("skill command expects: skill <id> [target_cid]".to_string());
        }

        let skill_id = parts[0]
            .parse::<u16>()
            .map_err(|error| format!("invalid skill id: {error}"))?;
        let target_cid = if parts.len() == 2 {
            Some(
                parts[1]
                    .parse::<i64>()
                    .map_err(|error| format!("invalid target cid: {error}"))?,
            )
        } else {
            None
        };
        return Ok(ClientStdioCommand::Skill {
            skill_id,
            target_cid,
        });
    }

    if let Some(rest) = line.strip_prefix("move ") {
        let parts = rest.split_whitespace().collect::<Vec<_>>();
        if parts.len() != 2 {
            return Err("move command expects: move <dir> <ms>".to_string());
        }

        let direction = parse_direction(parts[0])?;
        let duration_ms = parts[1]
            .parse::<u64>()
            .map_err(|error| format!("invalid move duration: {error}"))?;

        return Ok(ClientStdioCommand::Move {
            direction,
            direction_label: parts[0].to_string(),
            duration_ms,
        });
    }

    if line == "va-status" {
        return Ok(ClientStdioCommand::VoxelAuthorityStatus);
    }

    if let Some(rest) = line.strip_prefix("va-subscribe ") {
        let parts = rest.split_whitespace().collect::<Vec<_>>();
        if parts.len() != 5 {
            return Err("va-subscribe <scene_id> <cx> <cy> <cz> <radius>".to_string());
        }
        let logical_scene_id = parse_field(parts[0], "scene_id")?;
        let center = [
            parse_field(parts[1], "cx")?,
            parse_field(parts[2], "cy")?,
            parse_field(parts[3], "cz")?,
        ];
        let radius = parse_field(parts[4], "radius")?;
        return Ok(ClientStdioCommand::VoxelSubscribe {
            logical_scene_id,
            center,
            radius,
        });
    }

    if let Some(rest) = line.strip_prefix("va-chunk ") {
        let parts = rest.split_whitespace().collect::<Vec<_>>();
        if parts.len() != 3 {
            return Err("va-chunk <cx> <cy> <cz>".to_string());
        }
        let coord = [
            parse_field(parts[0], "cx")?,
            parse_field(parts[1], "cy")?,
            parse_field(parts[2], "cz")?,
        ];
        return Ok(ClientStdioCommand::VoxelChunkInfo { coord });
    }

    if let Some(rest) = line.strip_prefix("va-edit ") {
        let parts = rest.split_whitespace().collect::<Vec<_>>();
        if parts.len() < 5 || parts.len() > 6 {
            return Err("va-edit <place|break> <scene_id> <mx> <my> <mz> [material_id]".to_string());
        }
        let action = match parts[0].to_ascii_lowercase().as_str() {
            "place" => 0u8,
            "break" => 1u8,
            other => return Err(format!("va-edit action must be place|break, got '{other}'")),
        };
        let logical_scene_id = parse_field(parts[1], "scene_id")?;
        let target_macro = [
            parse_field(parts[2], "mx")?,
            parse_field(parts[3], "my")?,
            parse_field(parts[4], "mz")?,
        ];
        let material_id = if parts.len() == 6 {
            parse_field(parts[5], "material_id")?
        } else {
            0u16
        };
        return Ok(ClientStdioCommand::VoxelEditLive {
            logical_scene_id,
            action,
            target_macro,
            material_id,
        });
    }

    if line == "va-fields" {
        return Ok(ClientStdioCommand::VoxelFields);
    }

    if let Some(rest) = line.strip_prefix("va-semi ") {
        let parts = rest.split_whitespace().collect::<Vec<_>>();
        if parts.len() != 3 {
            return Err("va-semi <chunk_cx> <chunk_cy> <chunk_cz>".to_string());
        }
        return Ok(ClientStdioCommand::VoxelSemiconductors {
            chunk_coord: [
                parse_field(parts[0], "cx")?,
                parse_field(parts[1], "cy")?,
                parse_field(parts[2], "cz")?,
            ],
        });
    }

    if let Some(rest) = line.strip_prefix("va-surface-list ") {
        let parts = rest.split_whitespace().collect::<Vec<_>>();
        if parts.len() != 3 {
            return Err("va-surface-list <chunk_cx> <chunk_cy> <chunk_cz>".to_string());
        }
        return Ok(ClientStdioCommand::VoxelSurfaceList {
            chunk_coord: [
                parse_field(parts[0], "cx")?,
                parse_field(parts[1], "cy")?,
                parse_field(parts[2], "cz")?,
            ],
        });
    }

    // Server-message history queries: `<name>` (default 10) or `<name> <count>`.
    if let Some(count) = parse_log_count(line, "chat-log") {
        return Ok(ClientStdioCommand::ChatLog { count: count? });
    }
    if let Some(count) = parse_log_count(line, "skill-log") {
        return Ok(ClientStdioCommand::SkillLog { count: count? });
    }
    if let Some(count) = parse_log_count(line, "combat-log") {
        return Ok(ClientStdioCommand::CombatLog { count: count? });
    }
    if let Some(count) = parse_log_count(line, "effect-log") {
        return Ok(ClientStdioCommand::EffectLog { count: count? });
    }

    if let Some(text) = line.strip_prefix("echo ") {
        return Ok(ClientStdioCommand::Echo {
            text: text.trim().to_string(),
        });
    }

    if let Some(rest) = line.strip_prefix("wait ") {
        return Ok(ClientStdioCommand::Wait {
            ms: parse_field(rest.trim(), "ms")?,
        });
    }

    if let Some(rest) = line.strip_prefix("va-prefab ") {
        let parts = rest.split_whitespace().collect::<Vec<_>>();
        if parts.len() != 6 {
            return Err(
                "va-prefab <scene_id> <blueprint_id> <mx> <my> <mz> <rotation>".to_string(),
            );
        }
        let logical_scene_id = parse_field(parts[0], "scene_id")?;
        let blueprint_id = parse_field(parts[1], "blueprint_id")?;
        let anchor_macro = [
            parse_field(parts[2], "mx")?,
            parse_field(parts[3], "my")?,
            parse_field(parts[4], "mz")?,
        ];
        let rotation = parse_field(parts[5], "rotation")?;
        return Ok(ClientStdioCommand::VoxelPrefabPlace {
            logical_scene_id,
            blueprint_id,
            anchor_macro,
            rotation,
        });
    }

    if let Some(rest) = line.strip_prefix("va-surface ") {
        let parts = rest.split_whitespace().collect::<Vec<_>>();
        if parts.len() != 7 {
            return Err(
                "va-surface <scene_id> <action 0place|1clear> <mx> <my> <mz> <face 0..5> <surface_type_id>"
                    .to_string(),
            );
        }
        let logical_scene_id = parse_field(parts[0], "scene_id")?;
        let action: u8 = parse_field(parts[1], "action")?;
        let host_macro = [
            parse_field(parts[2], "mx")?,
            parse_field(parts[3], "my")?,
            parse_field(parts[4], "mz")?,
        ];
        let face: u8 = parse_field(parts[5], "face")?;
        let surface_type_id = parse_field(parts[6], "surface_type_id")?;
        // Bounds: fail fast on a mistyped face/action instead of sending a doomed
        // intent the server silently rejects (audit: face=99 was accepted before).
        if action > 1 {
            return Err(format!("action must be 0 (place) or 1 (clear), got {action}"));
        }
        if face > 5 {
            return Err(format!("face must be 0..5 (x_neg..z_pos), got {face}"));
        }
        return Ok(ClientStdioCommand::VoxelSurfacePlace {
            logical_scene_id,
            action,
            host_macro,
            face,
            surface_type_id,
        });
    }

    if let Some(rest) = line.strip_prefix("va-unsubscribe ") {
        let parts = rest.split_whitespace().collect::<Vec<_>>();
        if parts.len() != 4 {
            return Err("va-unsubscribe <scene_id> <cx> <cy> <cz>".to_string());
        }
        let logical_scene_id = parse_field(parts[0], "scene_id")?;
        let coord = [
            parse_field(parts[1], "cx")?,
            parse_field(parts[2], "cy")?,
            parse_field(parts[3], "cz")?,
        ];
        return Ok(ClientStdioCommand::VoxelUnsubscribe {
            logical_scene_id,
            coord,
        });
    }

    if let Some(rest) = line.strip_prefix("va-follow") {
        let parts = rest.split_whitespace().collect::<Vec<_>>();
        // va-follow [scene_id] [radius]
        let logical_scene_id = if parts.is_empty() {
            1
        } else {
            parse_field(parts[0], "scene_id")?
        };
        let radius = if parts.len() >= 2 {
            parse_field(parts[1], "radius")?
        } else {
            2u8
        };
        return Ok(ClientStdioCommand::VoxelFollow {
            logical_scene_id,
            radius,
        });
    }

    if let Some(rest) = line.strip_prefix("va-macro ") {
        let parts = rest.split_whitespace().collect::<Vec<_>>();
        if parts.len() != 3 {
            return Err("va-macro <gx> <gy> <gz>".to_string());
        }
        let global_macro = [
            parse_field(parts[0], "gx")?,
            parse_field(parts[1], "gy")?,
            parse_field(parts[2], "gz")?,
        ];
        return Ok(ClientStdioCommand::VoxelMacroInfo { global_macro });
    }

    match parse_voxel_cli_command(line)? {
        Some(command) => Ok(ClientStdioCommand::Voxel(command)),
        None => Err("unknown command".to_string()),
    }
}

fn parse_field<T: std::str::FromStr>(value: &str, name: &str) -> Result<T, String>
where
    T::Err: std::fmt::Display,
{
    value
        .parse::<T>()
        .map_err(|error| format!("invalid {name}: {error}"))
}

/// Matches a `<name>` (→ `Some(Ok(default))`) or `<name> <count>` event-log query;
/// returns `None` when `line` is a different command (so the parser falls through).
/// Guards against false matches like `chat-logx` (only a following space counts).
fn parse_log_count(line: &str, name: &str) -> Option<Result<usize, String>> {
    const DEFAULT: usize = 10;
    if line == name {
        return Some(Ok(DEFAULT));
    }
    let rest = line.strip_prefix(name)?.strip_prefix(' ')?.trim();
    if rest.is_empty() {
        return Some(Ok(DEFAULT));
    }
    Some(
        rest.parse::<usize>()
            .map_err(|_| format!("invalid count for {name}: {rest:?}")),
    )
}

fn parse_direction(value: &str) -> Result<Vec2, String> {
    match value.to_ascii_lowercase().as_str() {
        "w" | "up" => Ok(Vec2::new(0.0, 1.0)),
        "s" | "down" => Ok(Vec2::new(0.0, -1.0)),
        "a" | "left" => Ok(Vec2::new(-1.0, 0.0)),
        "d" | "right" => Ok(Vec2::new(1.0, 0.0)),
        other => Err(format!("unsupported move direction: {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_strips_leading_bom_and_whitespace() {
        // PowerShell's piped first line arrives BOM-prefixed.
        assert_eq!(
            sanitize_line("\u{feff}va-subscribe 1 0 0 0 0"),
            "va-subscribe 1 0 0 0 0"
        );
        assert_eq!(sanitize_line("  snapshot  "), "snapshot");
        assert_eq!(sanitize_line("\u{feff}"), "");
        assert_eq!(sanitize_line("plain"), "plain");
    }

    #[test]
    fn parses_bom_prefixed_first_command() {
        // The exact failure seen via PowerShell automation: a BOM on the first
        // piped command must still parse once sanitized.
        assert_eq!(
            parse_command(sanitize_line("\u{feff}va-subscribe 1 0 0 0 0")).unwrap(),
            ClientStdioCommand::VoxelSubscribe {
                logical_scene_id: 1,
                center: [0, 0, 0],
                radius: 0,
            }
        );
    }

    #[test]
    fn parses_voxel_authority_commands() {
        assert_eq!(
            parse_command("va-status").unwrap(),
            ClientStdioCommand::VoxelAuthorityStatus
        );
        assert_eq!(
            parse_command("va-subscribe 7 0 1 -2 2").unwrap(),
            ClientStdioCommand::VoxelSubscribe {
                logical_scene_id: 7,
                center: [0, 1, -2],
                radius: 2,
            }
        );
        assert_eq!(
            parse_command("va-chunk 3 0 -1").unwrap(),
            ClientStdioCommand::VoxelChunkInfo { coord: [3, 0, -1] }
        );
        assert!(parse_command("va-subscribe 7 0 1").is_err());
        assert!(parse_command("va-chunk 1 2").is_err());
    }

    #[test]
    fn parses_voxel_edit_follow_macro_fields_commands() {
        assert_eq!(
            parse_command("va-edit place 1 7 4 7 5").unwrap(),
            ClientStdioCommand::VoxelEditLive {
                logical_scene_id: 1,
                action: 0,
                target_macro: [7, 4, 7],
                material_id: 5,
            }
        );
        // break omits material → defaults to 0.
        assert_eq!(
            parse_command("va-edit break 1 7 0 7").unwrap(),
            ClientStdioCommand::VoxelEditLive {
                logical_scene_id: 1,
                action: 1,
                target_macro: [7, 0, 7],
                material_id: 0,
            }
        );
        assert!(parse_command("va-edit nuke 1 7 0 7").is_err());
        assert!(parse_command("va-edit place 1 7 0").is_err());

        // va-follow with/without args (defaults scene 1, radius 2).
        assert_eq!(
            parse_command("va-follow").unwrap(),
            ClientStdioCommand::VoxelFollow {
                logical_scene_id: 1,
                radius: 2,
            }
        );
        assert_eq!(
            parse_command("va-follow 1 3").unwrap(),
            ClientStdioCommand::VoxelFollow {
                logical_scene_id: 1,
                radius: 3,
            }
        );

        assert_eq!(
            parse_command("va-macro 7 0 7").unwrap(),
            ClientStdioCommand::VoxelMacroInfo {
                global_macro: [7, 0, 7],
            }
        );
        assert!(parse_command("va-macro 7 0").is_err());

        assert_eq!(parse_command("va-fields").unwrap(), ClientStdioCommand::VoxelFields);

        assert_eq!(
            parse_command("va-semi 0 0 0").unwrap(),
            ClientStdioCommand::VoxelSemiconductors { chunk_coord: [0, 0, 0] }
        );
        assert_eq!(
            parse_command("va-semi -1 2 -3").unwrap(),
            ClientStdioCommand::VoxelSemiconductors { chunk_coord: [-1, 2, -3] }
        );
        assert!(parse_command("va-semi 0 0").is_err());

        assert_eq!(
            parse_command("va-surface-list 0 0 0").unwrap(),
            ClientStdioCommand::VoxelSurfaceList { chunk_coord: [0, 0, 0] }
        );
        // va-surface-list must NOT be mis-parsed as va-surface (different '-' vs ' ').
        assert!(matches!(
            parse_command("va-surface-list 1 2 3"),
            Ok(ClientStdioCommand::VoxelSurfaceList { .. })
        ));
        assert!(parse_command("va-surface-list 0 0").is_err());

        // Event-log queries: default count 10, explicit count, bad count errors.
        assert_eq!(parse_command("chat-log").unwrap(), ClientStdioCommand::ChatLog { count: 10 });
        assert_eq!(parse_command("chat-log 3").unwrap(), ClientStdioCommand::ChatLog { count: 3 });
        assert_eq!(
            parse_command("combat-log").unwrap(),
            ClientStdioCommand::CombatLog { count: 10 }
        );
        assert_eq!(
            parse_command("effect-log 5").unwrap(),
            ClientStdioCommand::EffectLog { count: 5 }
        );
        assert_eq!(parse_command("skill-log 2").unwrap(), ClientStdioCommand::SkillLog { count: 2 });
        assert!(parse_command("chat-log abc").is_err());
        // The `chat <text>` SEND command must NOT be swallowed by the chat-log query.
        assert!(!matches!(
            parse_command("chat hello"),
            Ok(ClientStdioCommand::ChatLog { .. })
        ));
        // `chat-logx` is not a valid command (guard against loose prefix match).
        assert!(parse_command("chat-logx").is_err());

        // echo + wait scripting utilities.
        assert_eq!(
            parse_command("echo marker_1").unwrap(),
            ClientStdioCommand::Echo { text: "marker_1".to_string() }
        );
        assert_eq!(parse_command("wait 250").unwrap(), ClientStdioCommand::Wait { ms: 250 });
        assert!(parse_command("wait abc").is_err());

        assert_eq!(
            parse_command("va-unsubscribe 1 0 1 -2").unwrap(),
            ClientStdioCommand::VoxelUnsubscribe {
                logical_scene_id: 1,
                coord: [0, 1, -2],
            }
        );
        assert!(parse_command("va-unsubscribe 1 0 1").is_err());

        assert_eq!(
            parse_command("va-prefab 1 4 10 6 10 1").unwrap(),
            ClientStdioCommand::VoxelPrefabPlace {
                logical_scene_id: 1,
                blueprint_id: 4,
                anchor_macro: [10, 6, 10],
                rotation: 1,
            }
        );
        assert!(parse_command("va-prefab 1 4 10 6 10").is_err());

        // va-surface: torch (type 4) on +X face (ordinal 1) of host macro (5,4,5).
        assert_eq!(
            parse_command("va-surface 1 0 5 4 5 1 4").unwrap(),
            ClientStdioCommand::VoxelSurfacePlace {
                logical_scene_id: 1,
                action: 0,
                host_macro: [5, 4, 5],
                face: 1,
                surface_type_id: 4,
            }
        );
        // clear action + negative coord.
        assert_eq!(
            parse_command("va-surface 2 1 -3 0 7 5 5").unwrap(),
            ClientStdioCommand::VoxelSurfacePlace {
                logical_scene_id: 2,
                action: 1,
                host_macro: [-3, 0, 7],
                face: 5,
                surface_type_id: 5,
            }
        );
        assert!(parse_command("va-surface 1 0 5 4 5 1").is_err());
        // Bounds: face > 5 and action > 1 are rejected at parse time (fail fast).
        assert!(parse_command("va-surface 1 0 5 4 5 9 4").is_err()); // face 9
        assert!(parse_command("va-surface 1 2 5 4 5 1 4").is_err()); // action 2
    }

    #[test]
    fn parses_snapshot_and_stop_commands() {
        assert_eq!(
            parse_command("snapshot").unwrap(),
            ClientStdioCommand::Snapshot
        );
        assert_eq!(
            parse_command("position").unwrap(),
            ClientStdioCommand::Position
        );
        assert_eq!(
            parse_command("transport").unwrap(),
            ClientStdioCommand::Transport
        );
        assert_eq!(
            parse_command("players").unwrap(),
            ClientStdioCommand::Players
        );
        assert_eq!(parse_command("npcs").unwrap(), ClientStdioCommand::Npcs);
        assert_eq!(
            parse_command("target 90001").unwrap(),
            ClientStdioCommand::Target(90_001)
        );
        assert_eq!(
            parse_command("clear_target").unwrap(),
            ClientStdioCommand::ClearTarget
        );
        assert_eq!(
            parse_command("target_point 1080 1000 90").unwrap(),
            ClientStdioCommand::TargetPoint(Vec3::new(1080.0, 1000.0, 90.0))
        );
        assert_eq!(
            parse_command("clear_target_point").unwrap(),
            ClientStdioCommand::ClearTargetPoint
        );
        assert_eq!(parse_command("stop").unwrap(), ClientStdioCommand::Stop);
        assert_eq!(parse_command("jump").unwrap(), ClientStdioCommand::Jump);
        assert_eq!(parse_command("quit").unwrap(), ClientStdioCommand::Quit);
        assert_eq!(
            parse_command("reconcile_stats").unwrap(),
            ClientStdioCommand::ReconcileStats
        );
        assert_eq!(
            parse_command("diag_render").unwrap(),
            ClientStdioCommand::DiagRender
        );
        assert!(matches!(
            parse_command("place 1 2 3 wood").unwrap(),
            ClientStdioCommand::Voxel(_)
        ));
    }

    #[test]
    fn parses_move_chat_and_skill_commands() {
        assert_eq!(
            parse_command("move w 600").unwrap(),
            ClientStdioCommand::Move {
                direction: Vec2::new(0.0, 1.0),
                direction_label: "w".to_string(),
                duration_ms: 600,
            }
        );
        assert_eq!(
            parse_command("chat hello").unwrap(),
            ClientStdioCommand::Chat("hello".to_string())
        );
        assert_eq!(
            parse_command("skill 2").unwrap(),
            ClientStdioCommand::Skill {
                skill_id: 2,
                target_cid: None,
            }
        );
        assert_eq!(
            parse_command("skill 3 90001").unwrap(),
            ClientStdioCommand::Skill {
                skill_id: 3,
                target_cid: Some(90_001),
            }
        );
    }
}
