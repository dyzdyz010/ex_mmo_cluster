# Bevy Client Web-Parity Voxel Migration (2026-04-25)

## Scope

This migration ports the browser client's currently implemented local features
back into `clients/bevy_client`:

1. movement jump input: Space / `jump` produce movement flag `0x04`.
2. offline-local voxel truth: macro placement/breaking, refined microgrid, prefab placement, boundary snap, snapshot import/export.
3. user-operable entrypoints: 3D GUI controls, stdio CLI, and server-free voxel headless smoke.
4. structured verification: `client_stdio ...` lines plus observe logs under `.demo/observe/`.

Voxel remains **offline-local** for the Bevy parity slice. The browser client
now defaults to server-authoritative voxel S1, so this document is historical
for Bevy migration scope rather than the current browser runtime contract.

## Web-Parity Checklist

- Perspective 3D camera with orbit follow and `Ctrl + wheel` zoom.
- Full 3D macro/refined voxel rendering; refined cells expose every occupied
  micro slot, not only the top surface.
- Screen-center voxel raycast against macro and micro AABBs.
- Single hit-face highlight plus adjacent macro/micro target derivation.
- Left/G break and right/F place through the center selection.
- Material hotbar placement to the hit face's adjacent macro cell.
- Prefab hotbar placement through boundary snap first, with the browser
  fallback reasons `no_target_boundary`, `no_contact`, and `empty_prefab`.
- Prefab preview through micro-wire boundary-snap gizmos, with macro fallback
  preview for browser-compatible fallback cases.
- Actor, selected target point, and effect cues rendered in the 3D world
  coordinate mapping used by voxels.
- Existing stdio, headless, observe logs, movement sync, jump, and voxel CLI
  remain available for non-GUI verification.

## Implementation Map

| Area | Bevy files |
| --- | --- |
| Voxel truth / prefab / hotbar | `clients/bevy_client/src/voxel/mod.rs` |
| Voxel module boundary doc | `clients/bevy_client/src/voxel/README.md` |
| CLI parser / stdio dispatch | `clients/bevy_client/src/stdio.rs`, `clients/bevy_client/src/app.rs`, `clients/bevy_client/src/headless.rs` |
| GUI controls / 3D render / center-ray picking | `clients/bevy_client/src/app.rs` |
| Launch mode | `clients/bevy_client/src/main.rs` |
| Regression tests | `clients/bevy_client/tests/voxel_parity.rs`, `clients/bevy_client/tests/voxel_cli_parity.rs` |

## Behavior Contract

- `MICRO_PER_MACRO = 8`, `MICRO_GRID_SLOT_COUNT = 512`.
- Built-ins:
  - `builtin_sphere`: 280 occupied slots.
  - `builtin_cylinder`: 416 occupied slots.
  - `builtin_stairs`: refined occupancy, count is intentionally not a protocol number.
- Public player edits are macro block place/break and prefab place/snap.
- `micro_cell` is read-only inspection. Direct public `micro_place` / `micro_break` is still not exposed.
- Boundary snap uses geometry:
  - reject if incoming occupied slots overlap existing slots.
  - accept when overlap is zero and contact slots are positive.
  - tags remain future gameplay metadata, not placement legality.

## GUI Controls

- `W/A/S/D` or arrows: movement.
- `Space`: jump.
- Left/middle drag: orbit the 3D camera around the local actor.
- `Ctrl + mouse wheel`: camera zoom.
- Center ray + left mouse / `G`: break the hit voxel macro cell.
- Center ray + right mouse / `F`: place current hotbar item on the adjacent face.
- Mouse wheel / `1..7`: hotbar selection; `Ctrl` reserves the wheel for camera zoom.
- `Shift + 1..4`: skill hotkeys.
- `Shift + right mouse`: skill target point.

The Bevy client now uses a perspective 3D view for voxel parity with the
browser client: macro blocks render as full cubes, refined prefab cells render
all occupied micro slots, the selected hit face is highlighted, and prefab
hotbar entries draw a boundary-snap micro-wire preview when a valid refined
target is available. CLI/log output remains the authoritative validation
surface for automated debugging.

## CLI / Headless

Integrated stdio commands include:

```text
voxel_snapshot
place <x> <y> <z> [material]
break <x> <y> <z>
hotbar
hotbar_select <1..7>
select_material <id|name>
select_prefab <name>
micro_cell <x> <y> <z> <mx> <my> <mz>
prefabs
prefab_boundary <name>
prefab_capture <name> <minx> <miny> <minz> <maxx> <maxy> <maxz>
prefab_place <name> <x> <y> <z> [rot0|rot90|rot180|rot270]
prefab_snap_preview <name> <x> <y> <z> <nx> <ny> <nz> [rotation]
prefab_place_snap <name> <x> <y> <z> <nx> <ny> <nz> [rotation]
world_export
world_import <json>
world_save [slot]
world_load [slot]
jump
```

Server-free voxel smoke:

```powershell
cd clients/bevy_client
cargo run -- --voxel-headless --observe-log ..\..\.demo\observe\bevy-voxel-headless-smoke.log --script "voxel_snapshot; hotbar_select 5; prefab_place builtin_sphere 8 5 8; micro_cell 8 5 8 4 4 4; prefab_snap_preview builtin_cylinder 8 5 8 1 0 0; world_export"
```

Save/load smoke:

```powershell
cargo run -- --voxel-headless --observe-log ..\..\.demo\observe\bevy-voxel-save-load-smoke.log --script "place 9 1 9 ice; world_save smoke; break 9 1 9; world_load smoke; micro_cell 9 1 9 0 0 0"
```

## Verification

Validated locally:

```powershell
cargo test --test voxel_parity
cargo test --test voxel_cli_parity
cargo test pressing_space_sets_one_shot_jump_intent_and_flag
cargo test voxel_3d_ray_selects_hit_face_and_adjacent_macro
cargo test voxel_3d_render_cells_include_all_refined_micro_slots
cargo fmt -- --check
cargo test
cargo clippy --all-targets -- -D warnings
cargo run -- --voxel-headless --observe-log ..\..\.demo\observe\bevy-voxel-headless-smoke.log --script "voxel_snapshot; hotbar_select 5; prefab_place builtin_sphere 8 5 8; micro_cell 8 5 8 4 4 4; prefab_snap_preview builtin_cylinder 8 5 8 1 0 0; world_export"
cargo run -- --voxel-headless --observe-log ..\..\.demo\observe\bevy-voxel-save-load-smoke.log --script "place 9 1 9 ice; world_save smoke; break 9 1 9; world_load smoke; micro_cell 9 1 9 0 0 0"
target\debug\bevy_client.exe --observe-log ..\..\.demo\observe\bevy-gui-3d-startup-smoke.log
```

Generated observe artifacts:

- `.demo/observe/bevy-voxel-headless-smoke.log`
- `.demo/observe/bevy-voxel-save-load-smoke.log`
- `.demo/observe/bevy-voxel-3d-parity-smoke.log`
- `.demo/observe/bevy-voxel-3d-save-load-smoke.log`
- `.demo/observe/bevy-gui-3d-startup-smoke.log`
- `.demo/observe/bevy-world-smoke.json`
