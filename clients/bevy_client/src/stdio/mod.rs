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
