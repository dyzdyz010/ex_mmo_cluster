# AOI policy layer

This directory holds pure AOI synchronization policy.

## Responsibilities

- `Priority` classifies nearby observers into high/medium/low priority bands.
- `Priority` decides snapshot delivery cadence for each observer.
- `Priority` decorates `Movement.RemoteSnapshot` with per-observer metadata.
- `PartitionInterest` converts a World partition-window shaped value into an
  AOI near/halo query plan. Near assigned chunks become authoritative AOI
  queries; halo assigned chunks become boundary ghost/prewarm queries; missing
  or unleased chunks are skipped with explicit reasons.
- `RemoteMirrorLedger` aggregates planned remote halo mirror/prewarm demand by
  AOI item and `{logical_scene_id, request_mode, {owner_scene_node, lease_id,
  chunk_coord}}` group for cross-node mirror/prewarm workers.

## Runtime boundary

- `SceneServer.AoiManager` owns the CID index and cached AOI locations.
- `SceneServer.Aoi.AoiItem` owns each actor's subscription list and movement /
  combat / skill fan-out. It does not own MMO chat delivery.
- `SceneServer.PlayerCharacter` remains the player authority and monitors its
  `AoiItem`. If the fan-out adapter exits, the player recreates it from the
  current authoritative position/movement state and replays the latest
  server-authoritative partition window before the next AOI refresh.
- Modules here own no process state; they are deterministic policy helpers used
  by AOI workers.
- `PartitionInterest` does not call World, Gate, DataService, or chunk
  processes. World remains the partition/lease authority; this module only
  consumes the already-authoritative window shape so AOI can converge on the
  same near/halo boundary as voxel subscription and chat presence.
- Live AOI applies partition windows through `AoiItem.update_partition_window/2`.
  The AOI item derives and caches the query plan locally, filters octree
  candidates by chunk route, and lets the partition tier override delivery
  cadence while distance remains a within-tier score.
- Routes assigned to another Scene node are not satisfied from the local octree;
  they need an explicit mirrored ghost/prewarm channel before they can enter
  live fan-out. A `nil` partition-window update is treated as a failed refresh
  and preserves the last authoritative plan. Applying a new window immediately
  prunes existing subscribers that no longer pass the owner/route fence, so
  movement fan-out cannot leak through a stale subscription list until the next
  AOI timer.
- Remote halo routes are now surfaced as `remote_mirror_requests` on
  `PartitionInterest`, cached separately on `AoiItem`, and published into
  `RemoteMirrorLedger`. These requests are a control-plane contract only:
  `request_mode: :ghost` means the local Scene node needs remote actor/field
  summary data; `request_mode: :prewarm` means it needs bulk halo warm-up data.
  Neither means a remote actor has entered `subscribees` or live fan-out. The
  ledger exposes both a `by_cid` reconciliation view and `request_groups` so
  `SceneServer.Worker.Aoi.RemoteMirrorRunner` can fan in many local AOI item
  demands for the same remote halo chunk while keeping ghost and prewarm lanes
  separate. When a later
  authoritative partition window removes the remote halo route or makes it
  local again, the request list is reconciled and withdrawn immediately.

Combat lag compensation is intentionally not implemented here. The boundary is
ready for historical AOI queries later, but current policy covers movement
snapshot priority only.

Chat is intentionally outside AOI. `world` / `region` / `local` chat is routed
through `ChatServer.Runtime` from Gate's server-authoritative partition context.
Legacy `{:chat_say, ...}` and `{:chat_message, ...}` casts to AOI items are
rejected with `aoi_chat_legacy_rejected` observe events so older call sites are
visible without creating a second chat truth.

## CLI Smoke

```bat
cmd /c mix.bat scene_server.aoi_partition_observe --logical-scene-id 1 --cid 42 --center 0,0,0
cmd /c mix.bat scene_server.remote_mirror_observe --logical-scene-id 1 --cid 42 --center 0,0,0
```

The partition task writes `scene_aoi_partition_interest_planned` and prints
near/halo/skipped plus `remote_mirror_requests` counts. The remote-mirror task
publishes two sample local AOI demands for the same remote halo route into a
private temporary `RemoteMirrorLedger` and writes
`scene_remote_mirror_ledger_snapshot` plus `scene_remote_mirror_runner_*` events
with request-group and mirror/prewarm counts, so the smoke does not wipe live
runtime demand. Together they prove the planner, runtime request ledger, and
one-pass worker can consume the server-authoritative partition-window contract
without trusting a client region hint. Runtime `AoiItem` tests cover the live
fan-out fence that prevents remote-owned actors from being invented from the
local octree.
