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

Burning also reduces structural integrity. When a voxel crosses its material
failure threshold, combustion emits a `voxel_structural_collapse_candidate`
observe event. The event is only a bridge for later object/collapse systems;
the phenomenon rule still leaves truth writes to `ChunkProcess`.

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
