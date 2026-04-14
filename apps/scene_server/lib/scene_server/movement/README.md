# Movement module map

This directory holds the shared movement model used by both player and NPC
actors.

## Responsibilities

- `Profile` — shared movement tuning parameters
- `InputFrame` — one sanitized fixed-step input sample
- `State` — authoritative movement state at a tick
- `Ack` — controlling-client reconciliation payload
- `RemoteSnapshot` — AOI broadcast payload for remote observers
- `Engine` — stable Elixir API over the Rustler movement math
- `Integrator` — readable Elixir reference implementation for tests/docs

## Relationship to actors

- `SceneServer.PlayerCharacter` consumes network input and steps movement here
- `SceneServer.Npc.Actor` builds its own input via `Npc.Navigation` and steps
  movement here

This shared layer is what keeps player and NPC motion on the same authority
rules.
