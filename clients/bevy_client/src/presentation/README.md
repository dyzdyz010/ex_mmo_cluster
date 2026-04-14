# Client presentation module map

This directory contains visual helpers that sit *after* gameplay simulation.

## Modules

- `smoothing.rs`
  - generic interpolation helpers
- `camera.rs`
  - local camera targeting/follow behavior
- `animation.rs`
  - lightweight animation-facing state derived from runtime velocity

These modules should not own authoritative state or protocol logic.
