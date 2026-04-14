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
  - authoritative player aggregate root
- `aoi/aoi_manager.ex`
  - shared spatial index and CID → actor lookup
- `aoi/aoi_item.ex`
  - per-actor AOI broadcast adapter

## Design rule

Workers in this directory own runtime state. Reusable value objects and pure
logic should live in sibling directories such as `movement/`, `combat/`, and
`npc/`.
