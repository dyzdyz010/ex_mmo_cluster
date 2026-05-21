# Scene native adapter map

This directory contains Elixir-side Rustler adapters for native runtime pieces.

## Current bindings

- `movement_engine.ex`
  - authoritative movement stepping and replay math
- `field_kernel.ex`
  - thin Rustler binding for deterministic, chunk-local field math such as
    conduction path search, sparse temperature diffusion, and material-aware
    electric potential propagation; Field-side backend selection and DTO
    encoding belong under `SceneServer.Voxel.Field.NativeBackend`
- `scene_ops/scene_ops.ex`
  - native scene/physics operations on character data
- `octree/`
  - AOI spatial index backend
- `coordinate_system/`
  - older/native coordinate helpers retained for lower-level operations/tests

## Design rule

These modules should stay thin. Business rules, actor orchestration, and process
state belong in Elixir runtime modules above them.

For the `field_kernel` crate specifically, keep `src/lib.rs` as the Rustler
entrypoint only. Solver implementations belong in separate modules
(`conduction_path`, `temperature_diffusion`, `electric_potential`) and shared
AABB/index helpers belong in `grid`.
