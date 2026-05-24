# Scene worker runtime map

This directory contains the long-lived runtime processes that own authoritative
state.

## Key workers

- `interface.ex`
  - registers the scene service for discovery
- `physics_manager.ex`
  - owns the shared native physics reference
- `player_manager.ex`
  - spawn/index façade for player actors
- `player_character.ex`
  - authoritative player aggregate root; owns movement/combat state and
    monitors/rebuilds its per-player AOI adapter if that adapter exits while
    the player is still active
- `aoi/aoi_manager.ex`
  - shared spatial index and CID → actor lookup
- `aoi/aoi_item.ex`
  - per-actor AOI broadcast adapter and priority fan-out executor
- `../aoi/priority.ex`
  - pure AOI priority/cadence policy used by `aoi_item.ex`

## Design rule

Workers in this directory own runtime state. Reusable value objects and pure
logic should live in sibling directories such as `movement/`, `combat/`, and
`npc/`. `PlayerCharacter` is the player authority; `Aoi.AoiItem` is an adapter
for subscription/fan-out only. If an AOI item dies, the player authority must
recreate it and re-register the current authoritative movement snapshot rather
than letting remote observers freeze on stale AOI data. AOI priority decisions
live in `../aoi/`; AOI workers only apply those decisions to their owned
subscription state.

`PlayerManager` owns CID session replacement. A reconnect for the same CID
stops the old `PlayerCharacter` before publishing the new PID, and stale
terminate cleanup is ignored unless the PID still matches the current index.
