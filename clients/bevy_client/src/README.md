# Bevy client module map

This directory is intentionally split by runtime responsibility instead of
keeping all networking/gameplay glue inside `app.rs`.

## Key areas

- `net.rs`
  - transport thread, protocol handling, client runtime state machine
- `protocol.rs`
  - wire format between client and gate
- `protocol_v2.rs`
  - movement-specific DTO adapters
- `input/`
  - input frame shapes
- `sim/`
  - prediction, reconciliation, replay governance
- `presentation/`
  - smoothing, camera, animation-facing helpers
- `world/`
  - local vs remote actor runtime state
- `voxel/`
  - offline-local voxel world, refined microgrid, prefab/hotbar, CLI snapshot truth
- `app.rs`
  - Bevy runtime composition; owns the 3D camera, PBR voxel/actor meshes,
    center-ray voxel picking, face highlight, prefab preview gizmos, and the
    GUI-to-voxel input adapter
- `stdio.rs`
  - attached stdio automation interface
- `login.rs`
  - egui login UI; systems that construct egui widgets must run in
    `EguiPrimaryContextPass`, not the normal Bevy `Update` schedule
- `headless.rs`
  - non-visual automation/QA entrypoint

## Relationship to the server

- local player movement follows server-authoritative prediction/reconciliation
- remote actors consume server snapshots plus actor identity metadata
- NPCs are represented as remote actors with explicit `RemoteActorKind::Npc`,
  not by inferring from CID ranges
