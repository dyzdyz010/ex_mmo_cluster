# SceneServer runtime map

This directory holds the authoritative simulation/runtime side of the project.

## Top-level supervision tree

`SceneServer.Application` starts:

- `SceneServer.InterfaceSup`
  - node registration / service discovery entrypoint
- `SceneServer.PhysicsSup`
  - native scene/physics integration
- `SceneServer.AoiSup`
  - `SceneServer.AoiManager`
  - `SceneServer.AoiItemSup`
- `SceneServer.PlayerSup`
  - `SceneServer.PlayerCharacterSup`
  - `SceneServer.PlayerManager`
- `SceneServer.NpcSup`
  - `SceneServer.NpcActorSup`
  - `SceneServer.NpcManager`

## Authority split

### `movement/`

Shared authoritative movement model:

- `Profile` — shared movement tuning
- `InputFrame` — fixed-step control sample
- `State` — authoritative movement state
- `Ack` — controlling-client reconciliation payload
- `RemoteSnapshot` — AOI broadcast payload
- `Engine` — façade over Rustler movement math
- `Integrator` — reference Elixir implementation used by tests/docs

### `combat/`

Shared combat primitives for both players and NPCs:

- `Profile` — HP / respawn defaults
- `State` — HP/death state machine
- `Skill` — player-oriented skill definitions
- `Targeting` — actor-agnostic AOI targeting

### `worker/`

Long-lived authoritative actors and infrastructure:

- `PlayerCharacter` — one active player aggregate root
- `PlayerManager` — player spawn/index façade
- `AoiManager` — shared octree/index
- `Aoi.AoiItem` — per-actor AOI subscription/broadcast adapter

### `npc/`

NPC-specific actor model built on top of shared movement/combat:

- `Profile` — static NPC template/config
- `Facts` — read-only perception snapshot
- `Brain` — pure intent selection
- `Navigation` — intent → movement input translation
- `Attack` — NPC profile → combat skill translation
- `State` — NPC intent state only
- `Actor` — one active NPC aggregate root
- `Manager` — NPC spawn/index façade

See `npc/README.md` for the NPC-specific flow.
