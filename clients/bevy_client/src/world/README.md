# Client world module map

This directory contains runtime actor state tracked by the client.

## Modules

- `local_player.rs`
  - local prediction runtime and reconciliation ownership
- `remote_player.rs`
  - remote motion buffering/interpolation
- `remote_actor.rs`
  - remote actor identity metadata (player vs NPC)

Keeping remote identity separate from remote motion is intentional: gameplay type
classification should not depend on CID heuristics or interpolation buffers.
