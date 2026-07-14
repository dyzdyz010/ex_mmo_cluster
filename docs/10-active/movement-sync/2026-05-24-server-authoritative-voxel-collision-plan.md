# 2026-05-24 server-authoritative voxel collision plan

## Current state

- `SceneServer.PlayerCharacter` already owns the authoritative player movement
  state and emits movement acks / AOI snapshots from that state.
- `Movement.Engine` delegates fixed-step movement math to the Rust NIF and can
  carry explicit correction flags into `Ack.correction_flags`.
- Voxel truth is owned by `SceneServer.Voxel.ChunkProcess`. `ChunkDirectory`
  only routes to chunk processes and starts hot chunks when needed.
- `scene_ops` currently updates player transform state, but voxel terrain is
  not registered as static physics colliders there. It cannot be the terrain
  collision source yet.

## Decision

Add terrain collision as a read-only query from movement into voxel authority:

- `Storage` exposes a public micro-slot occupancy read.
- `ChunkProcess` exposes a structured collision query over local macro /
  micro-slot samples.
- `ChunkDirectory` routes collision queries to the owning chunk process.
- `PlayerCharacter` keeps owning actor movement state, calls a movement-layer
  resolver after each fixed-step integration, and passes explicit
  `COLLISION_PUSH` flags into movement acks when terrain blocks the move.

No movement actor stores voxel state. No voxel process stores actor state.

## Coordinate contract

Movement state uses centimeters as `{x, y, z}`, with server `z` as vertical.
Voxel storage uses world micro coordinates as `{x, y, z}`, with voxel `y` as
vertical and 8 micro slots per 100 cm macro cell.

Movement-to-voxel conversion:

```text
movement_cm {x, y, z} -> voxel_micro {floor(x * 8 / 100), floor(z * 8 / 100), floor(y * 8 / 100)}
```

The server resolver treats movement position as the avatar center. The default
avatar shape is an AABB around that center:

- radius: 30 cm
- height: 170 cm

This is a historical server/browser fixture anchor: `{750, 750, 185}` stands on
the DevSeed platform whose top is at movement `z = 100` for a 170 cm avatar. It
is not yet a Voxia prediction/render acceptance target; Voxia must establish its
own verified scene coordinate through its current baseline and CLI flow.

## Runtime observability

Every movement tick can emit `player_movement_collision` with:

- `cid`, `logical_scene_id`, `tick`
- previous/proposed/resolved positions
- queried chunks, sample count, occupied count
- blocked axes and correction flags
- unavailable/error reasons when voxel authority cannot be queried

The event is structured CLI observe output, so Voxia screenshots are not the
only verification surface.

## Next slices

1. Server collision MVP: block horizontal penetration into solid/refined voxel
   occupancy and snap falling actors to terrain tops.
2. Voxia prediction collision: run the same center-anchor AABB check against
   the client voxel cache before sending predicted poses.
3. Reconciliation tuning: expose collision counters and hard/soft correction
   rates in the Voxia stdio CLI / structured debug surface.
4. Physics convergence: only after voxel colliders are chunk-streamed into the
   physics scene, decide whether Rapier replaces or supplements the read-only
   resolver.
