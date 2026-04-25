//! Server-free local voxel runner used by `--voxel-headless`.
//!
//! Mirrors the browser client's offline-local voxel CLI loop: build a fresh
//! `VoxelWorld`, bootstrap the showcase platform, then execute the `;`-
//! separated commands in `script` against it, mirroring each result through
//! `client_stdio` and the observe pipeline.

use crate::observe::ClientObserver;
use crate::stdio::emit_owned as emit_stdio_owned;
use crate::voxel::{VoxelWorld, execute_voxel_cli_command, parse_voxel_cli_command};

use super::state::voxel_save_dir;

/// Runs the offline-local voxel runtime without requiring auth or gate server.
pub fn run_voxel_headless(observer: ClientObserver, script: &str) -> Result<(), String> {
    let mut world = VoxelWorld::new();
    world.bootstrap_showcase(2);

    observer.emit("voxel_headless", "start", &[("script", script.to_string())]);

    for segment in script
        .split(';')
        .map(str::trim)
        .filter(|part| !part.is_empty())
    {
        let command = parse_voxel_cli_command(segment)?
            .ok_or_else(|| format!("unsupported voxel command: {segment}"))?;
        let result = execute_voxel_cli_command(&mut world, command, Some(&voxel_save_dir()));
        emit_stdio_owned(&result.event, result.ok, &result.fields);
        observer.emit(
            "voxel_headless",
            &result.event,
            &[
                ("ok", result.ok.to_string()),
                (
                    "fields",
                    result
                        .fields
                        .iter()
                        .map(|(key, value)| format!("{key}={value}"))
                        .collect::<Vec<_>>()
                        .join(","),
                ),
            ],
        );
        if !result.ok {
            return Err(format!(
                "voxel command failed: {segment}: {}",
                result.field("reason").unwrap_or("unknown")
            ));
        }
    }

    observer.emit(
        "voxel_headless",
        "completed",
        &[("solid_cells", world.total_solid_cells().to_string())],
    );
    Ok(())
}
