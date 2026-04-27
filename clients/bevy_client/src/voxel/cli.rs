//! Browser-compatible voxel CLI parsing and execution.
//!
//! This module is the "command surface" for both the integrated stdio
//! interface and the headless voxel runner. It maps text commands onto
//! [`VoxelWorld`] mutations and renders structured `client_stdio` field lists
//! that the observe pipeline consumes.

use std::{fs, path::Path};

use crate::voxel::core::{
    MacroCoord, MicroCoord, Rotation, VoxelMaterialId, format_macro_coord, format_micro_coord,
    parse_macro_coord, parse_micro_coord,
};
use crate::voxel::prefab::{BoundarySnapPreview, BoundarySnapRequest};
use crate::voxel::world::{EditStats, NormalBlockData, VoxelWorld, WorldSnapshot};

/// Browser-compatible voxel CLI commands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VoxelCliCommand {
    Snapshot,
    Chunks {
        limit: usize,
    },
    Cell {
        coord: MacroCoord,
    },
    MicroCell {
        macro_coord: MacroCoord,
        micro: MicroCoord,
    },
    Place {
        coord: MacroCoord,
        material: Option<VoxelMaterialId>,
    },
    Break {
        coord: MacroCoord,
    },
    Hotbar,
    HotbarSelect {
        index_one_based: usize,
    },
    SelectMaterial {
        material: VoxelMaterialId,
    },
    SelectPrefab {
        name: String,
    },
    Prefabs,
    PrefabBoundary {
        name: String,
    },
    PrefabCapture {
        name: String,
        min: MacroCoord,
        max: MacroCoord,
    },
    PrefabPlace {
        name: String,
        origin: MacroCoord,
        rotation: Rotation,
    },
    PrefabSnapPreview(BoundarySnapRequest),
    PrefabPlaceSnap(BoundarySnapRequest),
    WorldExport,
    WorldImport {
        json: String,
    },
    WorldSave {
        slot: String,
    },
    WorldLoad {
        slot: String,
    },
    EditStats,
}

/// Structured voxel CLI result emitted through stdio and observe logs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoxelCliResult {
    pub ok: bool,
    pub event: String,
    pub fields: Vec<(String, String)>,
}

impl VoxelCliResult {
    /// Returns a field value by key.
    pub fn field(&self, key: &str) -> Option<&str> {
        self.fields
            .iter()
            .find_map(|(field_key, value)| (field_key == key).then_some(value.as_str()))
    }

    fn ok(event: &str, fields: Vec<(String, String)>) -> Self {
        Self {
            ok: true,
            event: event.to_string(),
            fields,
        }
    }

    fn error(event: &str, reason: impl Into<String>) -> Self {
        Self {
            ok: false,
            event: event.to_string(),
            fields: vec![("reason".to_string(), reason.into())],
        }
    }
}

/// Parses a browser-style voxel CLI command. Returns `Ok(None)` for non-voxel
/// commands so the existing movement/chat stdio parser can continue handling
/// them.
pub fn parse_voxel_cli_command(line: &str) -> Result<Option<VoxelCliCommand>, String> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }

    if let Some(json) = trimmed.strip_prefix("world_import ") {
        return Ok(Some(VoxelCliCommand::WorldImport {
            json: json.to_string(),
        }));
    }

    let parts = trimmed.split_whitespace().collect::<Vec<_>>();
    let Some(command) = parts.first().copied() else {
        return Ok(None);
    };

    match command {
        "snapshot" | "voxel_snapshot" => Ok(Some(VoxelCliCommand::Snapshot)),
        "chunks" => {
            let limit = parts
                .get(1)
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(12);
            Ok(Some(VoxelCliCommand::Chunks { limit }))
        }
        "cell" => Ok(Some(VoxelCliCommand::Cell {
            coord: parse_macro_coord(parts.get(1..4).unwrap_or(&[]))
                .ok_or_else(|| "usage: cell <x> <y> <z>".to_string())?,
        })),
        "micro_cell" => Ok(Some(VoxelCliCommand::MicroCell {
            macro_coord: parse_macro_coord(parts.get(1..4).unwrap_or(&[]))
                .ok_or_else(|| "usage: micro_cell <x> <y> <z> <mx> <my> <mz>".to_string())?,
            micro: parse_micro_coord(parts.get(4..7).unwrap_or(&[]))
                .ok_or_else(|| "usage: micro_cell <x> <y> <z> <mx> <my> <mz>".to_string())?,
        })),
        "place" => Ok(Some(VoxelCliCommand::Place {
            coord: parse_macro_coord(parts.get(1..4).unwrap_or(&[]))
                .ok_or_else(|| "usage: place <x> <y> <z> [material]".to_string())?,
            material: parts
                .get(4)
                .map(|value| {
                    VoxelMaterialId::parse(value)
                        .ok_or_else(|| format!("unknown material: {value}"))
                })
                .transpose()?,
        })),
        "break" => Ok(Some(VoxelCliCommand::Break {
            coord: parse_macro_coord(parts.get(1..4).unwrap_or(&[]))
                .ok_or_else(|| "usage: break <x> <y> <z>".to_string())?,
        })),
        "hotbar" => Ok(Some(VoxelCliCommand::Hotbar)),
        "hotbar_select" => Ok(Some(VoxelCliCommand::HotbarSelect {
            index_one_based: parts
                .get(1)
                .ok_or_else(|| "usage: hotbar_select <index>".to_string())?
                .parse::<usize>()
                .map_err(|error| format!("invalid hotbar index: {error}"))?,
        })),
        "select_material" => Ok(Some(VoxelCliCommand::SelectMaterial {
            material: VoxelMaterialId::parse(
                parts
                    .get(1)
                    .ok_or_else(|| "usage: select_material <id|name>".to_string())?,
            )
            .ok_or_else(|| format!("unknown material: {}", parts[1]))?,
        })),
        "select_prefab" => Ok(Some(VoxelCliCommand::SelectPrefab {
            name: parts
                .get(1)
                .ok_or_else(|| "usage: select_prefab <name>".to_string())?
                .to_string(),
        })),
        "prefabs" => Ok(Some(VoxelCliCommand::Prefabs)),
        "prefab_boundary" | "prefab_sockets" => Ok(Some(VoxelCliCommand::PrefabBoundary {
            name: parts
                .get(1)
                .ok_or_else(|| "usage: prefab_boundary <name>".to_string())?
                .to_string(),
        })),
        "prefab_capture" => Ok(Some(VoxelCliCommand::PrefabCapture {
            name: parts
                .get(1)
                .ok_or_else(|| {
                    "usage: prefab_capture <name> <minx> <miny> <minz> <maxx> <maxy> <maxz>"
                        .to_string()
                })?
                .to_string(),
            min: parse_macro_coord(parts.get(2..5).unwrap_or(&[])).ok_or_else(|| {
                "usage: prefab_capture <name> <minx> <miny> <minz> <maxx> <maxy> <maxz>".to_string()
            })?,
            max: parse_macro_coord(parts.get(5..8).unwrap_or(&[])).ok_or_else(|| {
                "usage: prefab_capture <name> <minx> <miny> <minz> <maxx> <maxy> <maxz>".to_string()
            })?,
        })),
        "prefab_place" => Ok(Some(VoxelCliCommand::PrefabPlace {
            name: parts
                .get(1)
                .ok_or_else(|| {
                    "usage: prefab_place <name> <x> <y> <z> [rot0|rot90|rot180|rot270]".to_string()
                })?
                .to_string(),
            origin: parse_macro_coord(parts.get(2..5).unwrap_or(&[])).ok_or_else(|| {
                "usage: prefab_place <name> <x> <y> <z> [rot0|rot90|rot180|rot270]".to_string()
            })?,
            rotation: Rotation::parse(parts.get(5).copied()).ok_or_else(|| {
                format!("invalid rotation: {}", parts.get(5).copied().unwrap_or(""))
            })?,
        })),
        "prefab_snap_preview" => Ok(Some(VoxelCliCommand::PrefabSnapPreview(
            parse_boundary_snap_request(&parts[1..])?,
        ))),
        "prefab_place_snap" => Ok(Some(VoxelCliCommand::PrefabPlaceSnap(
            parse_boundary_snap_request(&parts[1..])?,
        ))),
        "world_export" => Ok(Some(VoxelCliCommand::WorldExport)),
        "world_save" => Ok(Some(VoxelCliCommand::WorldSave {
            slot: parts.get(1).copied().unwrap_or("default").to_string(),
        })),
        "world_load" => Ok(Some(VoxelCliCommand::WorldLoad {
            slot: parts.get(1).copied().unwrap_or("default").to_string(),
        })),
        "edit_stats" => Ok(Some(VoxelCliCommand::EditStats)),
        _ => Ok(None),
    }
}

/// Executes one voxel CLI command against local world truth.
pub fn execute_voxel_cli_command(
    world: &mut VoxelWorld,
    command: VoxelCliCommand,
    save_dir: Option<&Path>,
) -> VoxelCliResult {
    match command {
        VoxelCliCommand::Snapshot => VoxelCliResult::ok(
            "voxel_snapshot",
            vec![
                ("voxel_sync".to_string(), "offline-local".to_string()),
                (
                    "solid_cells".to_string(),
                    world.total_solid_cells().to_string(),
                ),
                (
                    "selected_hotbar".to_string(),
                    (world.hotbar().selected_index + 1).to_string(),
                ),
                (
                    "selected".to_string(),
                    world.hotbar().selected.label.to_string(),
                ),
                (
                    "edit_stats".to_string(),
                    format_edit_stats(world.edit_stats()),
                ),
            ],
        ),
        VoxelCliCommand::Chunks { limit } => {
            let chunks = world
                .cell_summaries()
                .into_iter()
                .take(limit)
                .map(|(coord, mode, slots)| {
                    format!("{}:{}:{}", format_macro_coord(coord), mode, slots)
                })
                .collect::<Vec<_>>()
                .join(";");
            VoxelCliResult::ok(
                "chunks",
                vec![("chunks".to_string(), format!("[{chunks}]"))],
            )
        }
        VoxelCliCommand::Cell { coord } => {
            if let Some(block) = world.normal_block(coord) {
                VoxelCliResult::ok(
                    "cell",
                    vec![
                        ("coord".to_string(), format_macro_coord(coord)),
                        ("mode".to_string(), "normal".to_string()),
                        (
                            "material".to_string(),
                            block.material_id.label().to_string(),
                        ),
                    ],
                )
            } else if let Some(refined) = world.refined_cell(coord) {
                VoxelCliResult::ok(
                    "cell",
                    vec![
                        ("coord".to_string(), format_macro_coord(coord)),
                        ("mode".to_string(), "refined".to_string()),
                        (
                            "occupied_slots".to_string(),
                            refined.occupied_slot_count().to_string(),
                        ),
                    ],
                )
            } else {
                VoxelCliResult::ok(
                    "cell",
                    vec![
                        ("coord".to_string(), format_macro_coord(coord)),
                        ("mode".to_string(), "empty".to_string()),
                    ],
                )
            }
        }
        VoxelCliCommand::MicroCell { macro_coord, micro } => {
            let block = world.micro_block(macro_coord, micro);
            VoxelCliResult::ok(
                "micro_cell",
                vec![
                    ("macro".to_string(), format_macro_coord(macro_coord)),
                    ("micro".to_string(), format_micro_coord(micro)),
                    ("occupied".to_string(), block.is_some().to_string()),
                    (
                        "material".to_string(),
                        block
                            .map(|block| block.material_id.label().to_string())
                            .unwrap_or_else(|| "none".to_string()),
                    ),
                ],
            )
        }
        VoxelCliCommand::Place { coord, material } => {
            let material = material.unwrap_or_else(|| selected_material(world));
            let ok = world.place_block(coord, NormalBlockData::new(material));
            VoxelCliResult {
                ok,
                event: "place".to_string(),
                fields: vec![
                    ("coord".to_string(), format_macro_coord(coord)),
                    ("material".to_string(), material.label().to_string()),
                    ("ok".to_string(), ok.to_string()),
                ],
            }
        }
        VoxelCliCommand::Break { coord } => {
            let ok = world.break_block(coord);
            VoxelCliResult {
                ok,
                event: "break".to_string(),
                fields: vec![
                    ("coord".to_string(), format_macro_coord(coord)),
                    ("ok".to_string(), ok.to_string()),
                ],
            }
        }
        VoxelCliCommand::Hotbar => {
            let hotbar = world.hotbar();
            VoxelCliResult::ok(
                "hotbar",
                vec![
                    (
                        "selected_index".to_string(),
                        (hotbar.selected_index + 1).to_string(),
                    ),
                    ("selected".to_string(), hotbar.selected.label),
                    (
                        "entries".to_string(),
                        hotbar
                            .entries
                            .iter()
                            .enumerate()
                            .map(|(index, entry)| format!("{}:{}", index + 1, entry.label))
                            .collect::<Vec<_>>()
                            .join(","),
                    ),
                ],
            )
        }
        VoxelCliCommand::HotbarSelect { index_one_based } => {
            let result = index_one_based
                .checked_sub(1)
                .ok_or_else(|| "hotbar index must be one-based".to_string())
                .and_then(|index| world.select_hotbar_index(index));
            match result {
                Ok(()) => VoxelCliResult::ok(
                    "hotbar_select",
                    vec![
                        ("selected_index".to_string(), index_one_based.to_string()),
                        ("selected".to_string(), world.hotbar().selected.label),
                    ],
                ),
                Err(error) => VoxelCliResult::error("hotbar_select", error),
            }
        }
        VoxelCliCommand::SelectMaterial { material } => {
            world.select_material(material);
            VoxelCliResult::ok(
                "select_material",
                vec![("material".to_string(), material.label().to_string())],
            )
        }
        VoxelCliCommand::SelectPrefab { name } => match world.select_prefab(&name) {
            Ok(()) => VoxelCliResult::ok("select_prefab", vec![("prefab".to_string(), name)]),
            Err(error) => VoxelCliResult::error("select_prefab", error),
        },
        VoxelCliCommand::Prefabs => {
            let prefabs = world
                .list_prefabs()
                .iter()
                .map(|prefab| {
                    format!(
                        "{}:{}:{}",
                        prefab.name,
                        prefab.definition.micro_resolution,
                        prefab.total_occupied_slots()
                    )
                })
                .collect::<Vec<_>>()
                .join(";");
            VoxelCliResult::ok(
                "prefabs",
                vec![("prefabs".to_string(), format!("[{prefabs}]"))],
            )
        }
        VoxelCliCommand::PrefabBoundary { name } => match world.prefab(&name) {
            Some(prefab) => VoxelCliResult::ok(
                "prefab_boundary",
                vec![
                    ("prefab".to_string(), name),
                    (
                        "occupied_slots".to_string(),
                        prefab.total_occupied_slots().to_string(),
                    ),
                    (
                        "micro_resolution".to_string(),
                        prefab.definition.micro_resolution.to_string(),
                    ),
                ],
            ),
            None => VoxelCliResult::error("prefab_boundary", format!("unknown prefab: {name}")),
        },
        VoxelCliCommand::PrefabCapture { name, min, max } => {
            let prefab = world.capture_prefab(&name, min, max);
            VoxelCliResult::ok(
                "prefab_capture",
                vec![
                    ("prefab".to_string(), name),
                    (
                        "cells".to_string(),
                        prefab.definition.cells.len().to_string(),
                    ),
                    (
                        "occupied_slots".to_string(),
                        prefab.total_occupied_slots().to_string(),
                    ),
                ],
            )
        }
        VoxelCliCommand::PrefabPlace {
            name,
            origin,
            rotation,
        } => {
            let result = world.place_prefab(&name, origin, rotation);
            VoxelCliResult {
                ok: result.ok,
                event: "prefab_place".to_string(),
                fields: vec![
                    ("prefab".to_string(), name),
                    ("origin".to_string(), format_macro_coord(origin)),
                    ("ok".to_string(), result.ok.to_string()),
                    ("placed".to_string(), result.placed.to_string()),
                    (
                        "instance_id".to_string(),
                        result
                            .instance_id
                            .map(|value| value.to_string())
                            .unwrap_or_else(|| "none".to_string()),
                    ),
                    ("conflict".to_string(), result.conflict.to_string()),
                ],
            }
        }
        VoxelCliCommand::PrefabSnapPreview(request) => {
            let preview = world.preview_prefab_boundary_snap(&request);
            boundary_preview_result("prefab_snap_preview", preview)
        }
        VoxelCliCommand::PrefabPlaceSnap(request) => {
            let result = world.place_prefab_boundary_snap(&request);
            let mut out = boundary_preview_result(
                "prefab_place_snap",
                result.preview.clone().unwrap_or_else(|| {
                    BoundarySnapPreview::rejected(&request, "preview_unavailable")
                }),
            );
            out.ok = result.ok;
            out.fields.push((
                "instance_id".to_string(),
                result.instance_id.unwrap_or(0).to_string(),
            ));
            out.fields
                .push(("conflict".to_string(), result.conflict.to_string()));
            out
        }
        VoxelCliCommand::WorldExport => match serde_json::to_string(&world.export_snapshot()) {
            Ok(json) => VoxelCliResult::ok(
                "world_export",
                vec![
                    ("bytes".to_string(), json.len().to_string()),
                    ("json".to_string(), json),
                ],
            ),
            Err(error) => VoxelCliResult::error("world_export", error.to_string()),
        },
        VoxelCliCommand::WorldImport { json } => {
            match serde_json::from_str::<WorldSnapshot>(&json)
                .map_err(|error| error.to_string())
                .and_then(|snapshot| world.import_snapshot(snapshot))
            {
                Ok(()) => VoxelCliResult::ok(
                    "world_import",
                    vec![(
                        "solid_cells".to_string(),
                        world.total_solid_cells().to_string(),
                    )],
                ),
                Err(error) => VoxelCliResult::error("world_import", error),
            }
        }
        VoxelCliCommand::WorldSave { slot } => {
            let Some(save_dir) = save_dir else {
                return VoxelCliResult::error("world_save", "world save directory unavailable");
            };
            match serde_json::to_string(&world.export_snapshot())
                .map_err(|error| error.to_string())
                .and_then(|json| {
                    fs::create_dir_all(save_dir).map_err(|error| error.to_string())?;
                    let path = save_dir.join(world_save_file_name(&slot));
                    fs::write(&path, &json).map_err(|error| error.to_string())?;
                    Ok((json.len(), path))
                }) {
                Ok((bytes, path)) => VoxelCliResult::ok(
                    "world_save",
                    vec![
                        ("slot".to_string(), slot),
                        ("bytes".to_string(), bytes.to_string()),
                        ("path".to_string(), path.display().to_string()),
                    ],
                ),
                Err(error) => VoxelCliResult::error("world_save", error),
            }
        }
        VoxelCliCommand::WorldLoad { slot } => {
            let Some(save_dir) = save_dir else {
                return VoxelCliResult::error("world_load", "world save directory unavailable");
            };
            let path = save_dir.join(world_save_file_name(&slot));
            match fs::read_to_string(&path)
                .map_err(|error| error.to_string())
                .and_then(|json| {
                    serde_json::from_str::<WorldSnapshot>(&json).map_err(|error| error.to_string())
                })
                .and_then(|snapshot| world.import_snapshot(snapshot))
            {
                Ok(()) => VoxelCliResult::ok(
                    "world_load",
                    vec![
                        ("slot".to_string(), slot),
                        (
                            "solid_cells".to_string(),
                            world.total_solid_cells().to_string(),
                        ),
                        ("path".to_string(), path.display().to_string()),
                    ],
                ),
                Err(error) => VoxelCliResult::error("world_load", error),
            }
        }
        VoxelCliCommand::EditStats => VoxelCliResult::ok(
            "edit_stats",
            vec![(
                "edit_stats".to_string(),
                format_edit_stats(world.edit_stats()),
            )],
        ),
    }
}

fn parse_boundary_snap_request(parts: &[&str]) -> Result<BoundarySnapRequest, String> {
    Ok(BoundarySnapRequest {
        prefab_name: parts
            .first()
            .ok_or_else(|| {
                "usage: prefab_snap_preview <name> <x> <y> <z> <nx> <ny> <nz> [rotation]"
                    .to_string()
            })?
            .to_string(),
        hit_macro: parse_macro_coord(parts.get(1..4).unwrap_or(&[])).ok_or_else(|| {
            "usage: prefab_snap_preview <name> <x> <y> <z> <nx> <ny> <nz> [rotation]".to_string()
        })?,
        face_normal: parse_macro_coord(parts.get(4..7).unwrap_or(&[])).ok_or_else(|| {
            "usage: prefab_snap_preview <name> <x> <y> <z> <nx> <ny> <nz> [rotation]".to_string()
        })?,
        rotation: Rotation::parse(parts.get(7).copied())
            .ok_or_else(|| format!("invalid rotation: {}", parts.get(7).copied().unwrap_or("")))?,
        anchor_micro: None,
    })
}

fn selected_material(world: &VoxelWorld) -> VoxelMaterialId {
    world
        .hotbar()
        .selected
        .material_id
        .unwrap_or(VoxelMaterialId::Dirt)
}

fn boundary_preview_result(event: &str, preview: BoundarySnapPreview) -> VoxelCliResult {
    VoxelCliResult {
        ok: preview.ok,
        event: event.to_string(),
        fields: vec![
            ("prefab".to_string(), preview.prefab_id),
            (
                "hit_macro".to_string(),
                format_macro_coord(preview.hit_macro),
            ),
            (
                "face_normal".to_string(),
                format_macro_coord(preview.face_normal),
            ),
            ("ok".to_string(), preview.ok.to_string()),
            (
                "affected_macro_count".to_string(),
                preview.affected_macro_count.to_string(),
            ),
            (
                "incoming_occupied_slots".to_string(),
                preview.incoming_occupied_slots.to_string(),
            ),
            (
                "overlap_slots".to_string(),
                preview.overlap_slots.to_string(),
            ),
            (
                "contact_slots".to_string(),
                preview.contact_slots.to_string(),
            ),
            (
                "reject_reason".to_string(),
                preview.reject_reason.unwrap_or_default(),
            ),
        ],
    }
}

fn format_edit_stats(stats: EditStats) -> String {
    format!(
        "placed={},broken={},rejected={},conflicts={},prefab_placed={}",
        stats.placed, stats.broken, stats.rejected, stats.conflicts, stats.prefab_placed
    )
}

fn world_save_file_name(slot: &str) -> String {
    let sanitized = slot
        .chars()
        .map(|chr| {
            if chr.is_ascii_alphanumeric() || chr == '-' || chr == '_' {
                chr
            } else {
                '_'
            }
        })
        .collect::<String>();
    format!("bevy-world-{sanitized}.json")
}
