# Voxel Phenomenon

This directory owns condition-triggered physical phenomena such as combustion.

Boundary:

- Field kernels evolve continuous fields such as temperature.
- Phenomenon rules read field values, voxel truth, and material profiles.
- Phenomenon rules return structured effects only.
- `ChunkProcess` remains the authority that accepts or rejects truth writes.

Combustion is the first implementation slice. It uses material ignition
thresholds plus dynamic voxel attributes for moisture, fuel, oxygen, stage,
smoke, carbonization, and structural integrity. Wet combustible materials do
not ignite immediately: high heat first emits a moisture writeback, and later
ticks may ignite only after chunk authority exposes the dried voxel truth.
Stage changes are observable: preheat, ignition, burning, smoldering, and
extinguish transitions have distinct state writebacks, and smoldering uses a
lower persistent heat source cap than active flame.
Burn residue is expressed as either a material transition, such as wood to
charcoal, or a cell clear effect for materials that burn away completely. The
initial material set intentionally covers three outcomes: wood becomes
charcoal, cloth becomes ash, and dry grass burns away.

Combustion profiles are material-bound. A runtime `profile` option may tune an
existing combustible material for a specific field region, but it does not make
stone, dirt, or other inert materials combustible. Tests and scripted dev
regions that need different fast-forward settings per material should pass
`profile_overrides` keyed by material id; the base `MaterialCatalog` profile
continues to supply ignition thresholds, fuel policy, and residue behavior
unless that material-specific override explicitly changes them.

Structural integrity changes now go through the shared `StructuralIntegrity`
effect boundary. Combustion and freezing both use this boundary to write the
authoritative `structural_integrity` attribute, to emit a single
`voxel_structural_collapse_candidate` observe event when a voxel crosses its
failure threshold, and to produce an `:apply_structural_damage` effect. The
effect is still routed through `ChunkProcess`: the chunk authority resolves
owner refs in the failed macro and applies damage to prefab/object parts
through the existing `ObjectRegistry` boundary. Phenomenon rules still do not
mutate object truth directly.

Oxygen-limited high heat can carbonize combustible material without starting a
self-sustaining flame. Wood uses this path to turn into charcoal when its
carbonization crosses the material residue threshold; no combustion heat source
is emitted for this carbonization path.

Combustion heat is fed back into the existing temperature field as a persistent
heat source. The source temperature is derived from the fuel mass burned during
the current tick, the material `combustion_heat_j_per_kg`, release efficiency,
and the voxel heat capacity, then capped by the material heat-source limit for
the current stage. Heat propagation remains owned by the field runtime;
combustion only decides whether a heated material changes state and which
structured effects should be sent back to chunk authority.

Combustion smoke now follows the same boundary. Burning still writes the local
voxel `smoke_density` attribute for probes and later material reactions, but it
also emits a `:smoke_density` field source. `SmokeDiffusionKernel` consumes that
source and evolves the browser-visible smoke plume through the regular
`FieldRegionSnapshot` pipeline instead of hiding smoke inside per-voxel
attributes.

Combustion oxygen is also field-aware. Burning still writes per-voxel oxygen
truth, but it now emits an `:oxygen` field source for the consumed air. If the
owning `FieldRegion` has an active oxygen deficit at the target cell, the
combustion decision reads that field value before falling back to storage, so
oxygen-poor heat drives carbonization instead of a normal flame.

Combustion moisture is field-aware as well. Wet materials still dry through
authoritative voxel `moisture` writebacks, but the removed water becomes a
`:moisture` field source. If the owning `FieldRegion` has active moisture at
the target cell, the combustion decision reads that value before falling back
to storage, so a humid or recently dried hot zone delays ignition through the
same phenomenon boundary.

Corrosion follows the same authority boundary for the Phase 8.E chemical
surface-state slice. `Corrosion` reads voxel `moisture`,
`chemical_concentration`, material `corrosion_resistance`, and a material
corrosion profile, then returns effects for `surface_state`, `corrosion`,
`structural_integrity`, and degraded `electric_conductivity`. Chemical exposure
without enough moisture only marks the surface as exposed; active corrosion
requires both moisture and chemical concentration to exceed the material
thresholds. `chemical_concentration` is intentionally a dynamic voxel attribute
in this first slice, not a transported chemical field or cross-chunk acid-cloud
runtime.

Once a material enters burning or smoldering, the combustion kernel refreshes a
stable `{:combustion_instance, logical_scene_id, chunk_coord, macro_index}`
field source on the owning chunk. This gives the fire its own FieldRegion
lifecycle after the trigger heat impulse expires while still reusing source-key
dedupe, worker supervision, and `ChunkProcess` authority for every truth write.
The same tick also emits `upsert_phenomenon_instance` or
`complete_phenomenon_instance` effects. `ChunkProcess` owns the chunk-local
instance ledger, so tools can distinguish an active fire from a voxel that only
has historical combustion attributes. The ledger is intentionally in-memory for
this slice; durable/cross-node instance recovery remains a later Phase 8 concern.

When a combustion heat source reaches a chunk face, the combustion kernel emits
an `ensure_field_region` handoff instead of directly mutating the neighbor. The
source `ChunkProcess` queues that handoff through `ChunkDirectory`; the target
chunk accepts or rejects it as its own authority, starts a local temperature
region, and then runs the same material-driven combustion rules. This keeps
cross-chunk fire spread in the field/source lifecycle rather than adding
neighbor writes to the material state machine. Remote handoff requests do not
inherit the source chunk lease; the target chunk stamps its own current lease
onto the FieldRegion it owns.

`CombustionProbe` is the read-only debug boundary for this subsystem. It reads
the target chunk's authoritative storage and reports material id/name,
combustible profile, stage, fuel, oxygen, smoke, carbonization, structural
integrity, residue policy, and the active chunk-local phenomenon instance when
one exists. The probe never evaluates new combustion effects and never creates
field regions; browser and HTTP dev tools use it to observe the state machine
instead of duplicating combustion rules outside this directory.

`PhaseChangeProbe` follows the same boundary for contained-moisture phase
state. It reports material id/name, `phase_state` (`stable`, `frozen`,
`boiling`, or `vapor`), temperature, moisture, structural integrity, the
contained-water thresholds used by the rule, and any active chunk-local
`phase_change` instance. Vaporized cells can therefore remain observable even
after the active instance has completed, while the probe still performs no
state transition and creates no field region.

`ObjectPhysicalProbe` is the read-only object-side check for phenomenon-driven
structural damage. World routing still selects a scene node by route
coordinate, but the probe itself reads only `ObjectRegistry` and serializes the
current object version, covered chunks, object flags, and part health/damaged/
destroyed state. It is deliberately outside phenomenon rule evaluation:
combustion, carbonization, and phase change may emit structured damage
effects, but only chunk/object authority changes object truth.
