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
- `stdio.rs`
  - attached stdio automation interface
- `headless.rs`
  - non-visual automation/QA entrypoint

## Relationship to the server

- local player movement follows server-authoritative prediction/reconciliation
- remote actors consume server snapshots plus actor identity metadata
- NPCs are represented as remote actors with explicit `RemoteActorKind::Npc`,
  not by inferring from CID ranges
