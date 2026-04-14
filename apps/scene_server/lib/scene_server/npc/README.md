# NPC runtime structure

## Why one active NPC = one process

Active NPCs are modeled as one `SceneServer.Npc.Actor` process each because an
NPC needs a stable authority boundary for:

- AI intent
- movement state
- combat state
- respawn lifecycle
- AOI presence

This keeps NPC behavior local and testable instead of scattering it across
global managers.

## Internal layering

- `Profile` — static spawn/config data
- `Facts` — read-only situational snapshot gathered by the actor
- `Brain` — pure decision function (`idle/chase/attack/return_home/dead`)
- `Navigation` — turns intent into shared movement input frames
- `Attack` — turns NPC config into a combat skill struct
- `State` — NPC intent/target metadata only
- `Actor` — orchestrates fixed ticks, combat, AOI, and respawn
- `Manager` — external spawn/index API

## Supervision

`SceneServer.NpcSup`

- `SceneServer.NpcActorSup`
  - many `SceneServer.Npc.Actor`
- `SceneServer.NpcManager`

## Relationships with the rest of the runtime

- `Npc.Actor` uses `SceneServer.Movement.Engine` for authoritative motion
- `Npc.Actor` uses `SceneServer.Combat.State` for HP/death/respawn state
- `Npc.Actor` registers through `SceneServer.AoiManager`
- `SceneServer.Combat.Targeting` sees NPCs the same way it sees players: as
  combat-capable actors that answer `:get_state_summary`
