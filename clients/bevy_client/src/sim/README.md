# Client sim module map

This directory contains the local prediction and reconciliation model.

## Modules

- `types.rs`
  - shared movement simulation data types
- `profile.rs`
  - client-side tuning profile mirroring the server
- `predictor.rs`
  - one-step local movement prediction
- `history.rs`
  - input/predicted-state ring buffers
- `reconcile.rs`
  - authoritative ack reconciliation
- `governance.rs`
  - replay-window thresholds and stats

## Relationship to the runtime

- `world/local_player.rs` owns these structures at runtime
- `net.rs` feeds authoritative acks into reconciliation
