# Auto Circuit and Surface Prefab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Conductive voxel/prefab networks should automatically produce visible current when a valid source-load circuit exists, and the architecture should reserve a face-only prefab layer for future wire decals that do not occupy voxel volume.

**Architecture:** Keep authority and lifecycle in Elixir/OTP, pure bounded graph solving behind field kernels/native backend seams, and rendering in the web client. The first circuit slice is chunk-local and source/load based, but it is a real closed-loop circuit: conductive connectivity is projected into a segment graph, graph 2-core pruning identifies closed-loop cores, and current is written only when a physical power source and a load/sink participant both sit on the same closed-loop core. Surface prefabs are introduced as a separate participant concept, not as fake `microOccupancyMask`.

**Tech Stack:** Elixir/OTP field runtime, Rustler-native boundary for later pure graph acceleration, TypeScript web field protocol/overlay, Vitest and ExUnit focused tests.

---

## Scope

This plan intentionally does not implement full SPICE-like resistance solving, AC phase, multi-chunk global circuit search, damage/fuse gameplay, or a full face-decal editor. It creates the automatic circuit foundation and the surface-prefab boundary so later work can extend both without rewriting field/runtime ownership.

## Task 1: Add Electric Current Field Layer

**Files:**
- Modify: `apps/scene_server/lib/scene_server/voxel/field/field_region.ex`
- Modify: `apps/scene_server/lib/scene_server/voxel/field/field_codec.ex`
- Test: `apps/scene_server/test/scene_server/voxel/field/field_codec_test.exs`
- Modify: `clients/web_client/src/voxel/field/fieldProtocol.ts`
- Modify: `clients/web_client/src/voxel/field/fieldDebugOverlay.ts`
- Test: `clients/web_client/src/voxel/field/fieldDebugOverlay.test.ts`

- [x] Add `:electric_current` as a known field layer with wire mask bit `0x08`.
- [x] Encode/decode electric current as `f32[cell_count]`, parallel to existing macro indices.
- [x] Show current in the debug snapshot and overlay separately from electric potential.
- [x] RED tests first: codec must fail because the layer is unknown; client protocol/overlay must fail because current values are ignored.

## Task 2: Add Chunk-Local Automatic Circuit Detection

**Files:**
- Create: `apps/scene_server/lib/scene_server/voxel/field/circuit_component_analysis.ex`
- Create: `apps/scene_server/lib/scene_server/voxel/field/kernels/circuit_current_kernel.ex`
- Modify: `apps/scene_server/lib/scene_server/voxel/field/participant_projection.ex`
- Modify: `apps/scene_server/lib/scene_server/voxel/material_catalog.ex`
- Test: `apps/scene_server/test/scene_server/voxel/field/circuit_current_kernel_test.exs`

- [x] Add a load/sink material id with conductive material defaults.
- [x] Project each conductive macro entry with role facts: `:source` for power blocks, `:load` for load blocks, `:conductor` otherwise.
- [x] Implement a pure chunk-local graph pass that finds conductive connected components, extracts the closed-loop core, and marks current only when that loop core contains at least one source and one load.
- [x] Write `CircuitCurrentKernel` so a field region can tick without an explicit target and refresh `:electric_current`, `:electric_potential`, and `:ionization`.
- [x] RED tests first: an open wire with a source produces no current; an open source-to-load path also produces no current; adding a source/load closed loop produces current on the loop core, and breaking one loop conductor clears current.

## Task 3: Add Runtime and CLI Trigger for the First Auto Circuit Slice

**Files:**
- Modify: `apps/scene_server/lib/scene_server/voxel/field/field_runtime.ex`
- Modify: `apps/scene_server/lib/scene_server/voxel/field/dev_field_create.ex`
- Modify: `apps/auth_server/lib/auth_server_web/controllers/ingame_controller.ex`
- Modify: `apps/auth_server/lib/auth_server_web/router.ex`
- Modify: `clients/web_client/src/voxel/onlineVoxelWorldAdapter.ts`
- Modify: `clients/web_client/src/presentation/devtools/devToolsCli.ts`
- Test: `apps/scene_server/test/scene_server/voxel/field/field_runtime_test.exs`
- Test: `clients/web_client/src/presentation/devtools/devToolsCli.test.ts`
- Test: `clients/web_client/src/voxel/onlineVoxelWorldAdapter.test.ts`

- [x] Add `ensure_auto_circuit/1` for one chunk-local scan anchored around a source or selected cell.
- [x] Expose a web debug endpoint, client adapter refresh path, browser CLI command, and visible panel trigger for server-authoritative edits.
- [x] Keep it source/load automatic: the user supplies an anchor, not a target.
- [x] Emit structured accepted/rejected reasons through the field-runtime summary and HTTP error surface.

## Task 4: Reserve Surface Prefab Boundary

**Files:**
- Modify: `apps/scene_server/lib/scene_server/voxel/field/participant_projection.ex`
- Create or modify: `clients/web_client/src/voxel/surfaceAttachment.ts`
- Test: `apps/scene_server/test/scene_server/voxel/field/participant_projection_test.exs`
- Test: `clients/web_client/src/voxel/surfaceAttachment.test.ts`

- [x] Define the client-side data shape for face-only attachments: anchor macro/micro, face, face mask, material, owner object/part, visibility policy.
- [x] Keep attachments out of `microOccupancyMask`.
- [x] Define adjacency hiding rule: an attachment is visually hidden when the neighboring solid/refined cell occupies the covered face, but remains in truth unless explicitly destroyed.
- [x] Keep the projection boundary component-based so future surface participants can enter without each kernel knowing prefab internals.

## Task 5: Review, Verification, and Documentation

**Files:**
- Modify: `apps/scene_server/lib/scene_server/voxel/field/README.md` if present or nearby field README
- Modify: `clients/web_client/src/voxel/field/README.md`
- Modify: `docs/plans/2026-05-16-phase7-local-field-runtime-roadmap.md`

- [x] Run focused ExUnit tests for field codec, circuit kernel, runtime, participant projection.
- [x] Run focused Vitest tests for field protocol/overlay/CLI/surface attachment.
- [x] Run `npm run typecheck`.
- [x] Run browser smoke once the CLI path exists: place source/wire/load, run auto circuit scan, confirm current appears in overlay and CLI snapshot.
- [x] Ask separate reviewer subagents for spec compliance and code quality before final claims.
