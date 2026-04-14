# Scene supervisor subtrees

This directory contains the small supervisor wrappers that shape the scene
runtime tree.

## Current subtrees

- `InterfaceSup`
  - `SceneServer.Interface`
- `PhysicsSup`
  - `SceneServer.PhysicsManager`
- `AoiSup`
  - `SceneServer.AoiManager`
  - `SceneServer.AoiItemSup`
- `PlayerSup`
  - `SceneServer.PlayerCharacterSup`
  - `SceneServer.PlayerManager`
- `NpcSup`
  - `SceneServer.NpcActorSup`
  - `SceneServer.NpcManager`

## Why keep these wrappers small

The wrappers make the application tree legible and give each subsystem a stable
home without pushing domain logic into supervisors.
