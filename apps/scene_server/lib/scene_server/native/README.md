# Scene native adapter map

This directory contains Elixir-side Rustler adapters for native runtime pieces.

## Current bindings

- `movement_engine.ex`
  - authoritative movement stepping and replay math
- `scene_ops/scene_ops.ex`
  - native scene/physics operations on character data
- `octree/`
  - AOI spatial index backend
- `coordinate_system/`
  - older/native coordinate helpers retained for lower-level operations/tests

## Design rule

These modules should stay thin. Business rules, actor orchestration, and process
state belong in Elixir runtime modules above them.
