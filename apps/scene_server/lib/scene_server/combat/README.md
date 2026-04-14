# Combat module map

This directory contains the shared combat primitives used by both player and NPC
actors.

## Responsibilities

- `Profile` — HP / respawn defaults
- `State` — HP/death state machine
- `Skill` — player-facing skill definitions
- `Targeting` — AOI-backed actor targeting

## Relationship to actors

- `SceneServer.PlayerCharacter` uses these modules directly
- `SceneServer.Npc.Actor` reuses `Combat.State` and `Combat.Targeting`
- `SceneServer.Npc.Attack` adapts NPC profile data into the shared `Skill` shape

The goal is to keep damage/HP/targeting rules shared while still allowing
player- and NPC-specific orchestration above this layer.
