# AOI policy layer

This directory holds pure AOI synchronization policy.

## Responsibilities

- `Priority` classifies nearby observers into high/medium/low priority bands.
- `Priority` decides snapshot delivery cadence for each observer.
- `Priority` decorates `Movement.RemoteSnapshot` with per-observer metadata.

## Runtime boundary

- `SceneServer.AoiManager` owns the CID index and cached AOI locations.
- `SceneServer.Aoi.AoiItem` owns each actor's subscription list and fan-out.
- `SceneServer.PlayerCharacter` remains the player authority and monitors its
  `AoiItem`. If the fan-out adapter exits, the player recreates it from the
  current authoritative position/movement state.
- Modules here own no process state; they are deterministic policy helpers used
  by AOI workers.

Combat lag compensation is intentionally not implemented here. The boundary is
ready for historical AOI queries later, but current policy covers movement
snapshot priority only.
