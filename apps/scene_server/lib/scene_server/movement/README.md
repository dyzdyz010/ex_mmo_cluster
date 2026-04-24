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

## Jump / airborne contract

- `InputFrame.movement_flags` uses `0x0004` as a one-shot jump request.
- Only `:grounded` actors can consume that request and enter `:airborne`.
- `State.ground_z` is owned by the movement state so an airborne arc can land
  back on the ground height it launched from, independent of current Z.
- `Profile` owns airborne tuning: `jump_impulse`, `gravity`, `air_control`,
  `air_accel`, and `max_fall_speed`.

## Relationship to actors

- `SceneServer.PlayerCharacter` consumes network input and steps movement here
- `SceneServer.Npc.Actor` builds its own input via `Npc.Navigation` and steps
  movement here

This shared layer is what keeps player and NPC motion on the same authority
rules.
