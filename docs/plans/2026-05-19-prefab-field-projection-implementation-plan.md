# Prefab Field Projection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use inline execution in this session. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first runnable slice of prefab-as-field-participant by making electric conduction read a generic participant projection instead of treating refined prefab cells as whole-macro conductors.

**Architecture:** Add a focused `Field.ParticipantProjection` domain module that derives electric face connectivity from solid/refined voxel truth. `ConductionPathKernel` consumes that projection through a small adapter boundary; it still remains an electric kernel and does not query prefab or object registries directly.

**Tech Stack:** Elixir, ExUnit, existing `SceneServer.Voxel.Storage`, refined micro cells, `ConductionPathKernel`.

---

### Task 1: Lock Broken Refined Conductor Behavior

**Files:**
- Modify: `apps/scene_server/test/scene_server/voxel/field/conduction_path_kernel_test.exs`

- [x] **Step 1: Write the failing test**

Add a test where the middle macro is a refined prefab/object-backed conductor with one iron micro slot touching `x-` and one iron micro slot touching `x+`, but no contiguous conductive slots between them. The expected field result is no channel.

- [x] **Step 2: Run the focused test**

Run:

```powershell
mix test apps/scene_server/test/scene_server/voxel/field/conduction_path_kernel_test.exs --seed 0
```

Observed before implementation: the new test failed because the current kernel treated the refined macro as conductive by material, ignoring internal micro connectivity.

### Task 2: Add Electric Participant Projection

**Files:**
- Create: `apps/scene_server/lib/scene_server/voxel/field/participant_projection.ex`
- Test: `apps/scene_server/test/scene_server/voxel/field/participant_projection_test.exs`

- [x] **Step 1: Add projection unit tests**

Cover solid conductors, broken refined conductors, and connected refined conductors. The tests should assert face-level conductivity and face-to-face connectivity.

- [x] **Step 2: Implement minimal projection**

Implement a read-only projection that:

- treats solid conductive macro cells as all six faces connected;
- derives refined conductive micro components from material defaults;
- marks which macro faces each conductive component touches;
- records face-to-face connectivity only when one component touches both faces;
- exposes electric conductivity and dielectric strength for kernel cost calculations.

### Task 3: Route Conduction Through Projection

**Files:**
- Modify: `apps/scene_server/lib/scene_server/voxel/field/kernels/conduction_path_kernel.ex`
- Modify: `apps/scene_server/test/scene_server/voxel/field/conduction_path_kernel_test.exs`

- [x] **Step 1: Build projection once per search**

`find_path/6` should build or accept a `participant_projection` option and pass it through Dijkstra state.

- [x] **Step 2: Make Dijkstra entry-face aware**

Search state becomes `{macro_index, entry_face}`. A step from one macro to a neighbor is valid only if:

- the current macro can conduct from its entry face to the outgoing shared face;
- the neighbor has a conductive incoming shared face.

For the source macro, `:source` entry can exit through any conductive face.

- [x] **Step 3: Keep public output unchanged**

The kernel still writes active macro cells to `:electric_potential` and `:ionization`, and still emits Joule heat effects over macro paths.

### Task 4: Verify and Document

**Files:**
- Modify: `docs/plans/2026-05-19-prefab-field-participant-projection.md`

- [x] **Step 1: Run focused tests**

Run:

```powershell
mix test apps/scene_server/test/scene_server/voxel/field/participant_projection_test.exs apps/scene_server/test/scene_server/voxel/field/conduction_path_kernel_test.exs --seed 0
```

- [x] **Step 2: Run compile check**

Run:

```powershell
mix compile --warnings-as-errors
```

- [x] **Step 3: Update design document progress**

Record that the first electric verification slice has started with projection-backed refined connectivity.

### Task 5: Preserve Object/Part Targets In Electric Heat Effects

**Files:**
- Modify: `apps/scene_server/lib/scene_server/voxel/field/participant_projection.ex`
- Modify: `apps/scene_server/lib/scene_server/voxel/field/kernels/conduction_path_kernel.ex`
- Modify: `apps/scene_server/test/scene_server/voxel/field/participant_projection_test.exs`
- Modify: `apps/scene_server/test/scene_server/voxel/field/conduction_path_kernel_test.exs`

- [x] **Step 1: Write failing tests**

Add projection and kernel tests proving prefab-backed refined conductors expose
`%{owner_object_id, owner_part_id}` and Joule heat effects carry that metadata as
`object_part_targets`.

- [x] **Step 2: Implement projection API**

Expose `ParticipantProjection.electric_object_refs/2` as a JSON-friendly list of
maps, while keeping the projection itself read-only and derived from micro layer
provenance.

- [x] **Step 3: Attach targets to effects**

`ConductionPathKernel` keeps emitting `:write_voxel_attribute` effects, but adds
`object_part_targets` only when the projected macro has object-backed conductor
parts.

- [x] **Step 4: Run focused tests**

Run:

```powershell
mix test apps/scene_server/test/scene_server/voxel/field/participant_projection_test.exs apps/scene_server/test/scene_server/voxel/field/conduction_path_kernel_test.exs --seed 0
```

Observed after implementation: 16 tests, 0 failures.

### Task 6: Add Micro-Aligned Shared-Face Contact

**Files:**
- Modify: `apps/scene_server/lib/scene_server/voxel/field/participant_projection.ex`
- Modify: `apps/scene_server/lib/scene_server/voxel/field/kernels/conduction_path_kernel.ex`
- Modify: `apps/scene_server/test/scene_server/voxel/field/participant_projection_test.exs`
- Modify: `apps/scene_server/test/scene_server/voxel/field/conduction_path_kernel_test.exs`
- Modify: `docs/plans/2026-05-19-prefab-field-participant-projection.md`

- [x] **Step 1: Write failing cross-macro contact tests**

Add tests for two refined x-axis conductor segments in adjacent macro cells:

- misaligned shared-face contacts, such as `{y, z} = {1, 1}` touching
  `{y, z} = {6, 6}`, must not conduct;
- aligned shared-face contacts at the same `{y, z}` must conduct.

Observed before implementation: the misaligned test failed because the kernel
treated any conductive contact on the same macro face as enough for conduction.

- [x] **Step 2: Add face-contact projection**

Extend electric projection with per-face micro contact sets:

- x faces use `{y, z}`;
- y faces use `{x, z}`;
- z faces use `{x, y}`.

Solid conductive macro cells expose all 64 contacts on every face. Refined macro
cells expose only the contacts occupied by conductive micro slots.

- [x] **Step 3: Carry entry contacts through path search**

Change conduction search state from `{macro_index, entry_face}` to
`{macro_index, entry_face, entry_contacts}`. A neighbor step is valid only when:

- the current macro can reach exit-face contacts from the actual entry contacts;
- the neighbor exposes overlapping contacts on the opposite shared face.

This preserves component identity inside one macro cell: entering through a
contact that belongs to an unconnected component cannot exit through a different
component on the same face.

- [x] **Step 4: Run focused tests**

Run:

```powershell
cmd /c mix.bat test apps/scene_server/test/scene_server/voxel/field/participant_projection_test.exs apps/scene_server/test/scene_server/voxel/field/conduction_path_kernel_test.exs --seed 0
```

Observed after implementation: 19 tests, 0 failures.
