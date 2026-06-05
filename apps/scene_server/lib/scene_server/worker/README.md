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
- `aoi/remote_mirror_runner.ex`
  - one-pass remote halo ghost/prewarm worker; consumes ledger groups and emits
    summaries without inserting remote actors into live AOI fan-out
- `../aoi/priority.ex`
  - pure AOI priority/cadence policy used by `aoi_item.ex`

## Design rule

Workers in this directory own runtime state. Reusable value objects and pure
logic should live in sibling directories such as `movement/`, `combat/`, and
`npc/`. `PlayerCharacter` is the player authority; `Aoi.AoiItem` is an adapter
for subscription/fan-out only. If an AOI item dies, the player authority must
recreate it and re-register the current authoritative movement snapshot rather
than letting remote observers freeze on stale AOI data. The same recovery path
also replays the latest server-authoritative partition window so the rebuilt
AOI adapter does not fall back to radius-only visibility for one or more ticks.
AOI priority, partition-interest decisions, and the remote-demand ledger live
in `../aoi/`; AOI workers only apply those decisions to owned runtime state or
consume the ledger through bounded worker passes. `RemoteMirrorRunner` is
deliberately one-pass and owns no long-lived truth: it asks an injected fetch or
prewarm adapter for ghost/prewarm summaries, emits observe events, and reports
`live_fanout_count: 0` so remote halo data cannot silently become local
subscription truth.

Chat delivery is not a worker/AOI responsibility. `PlayerCharacter` rejects the
legacy `{:chat_say, ...}` call with `:chat_runtime_required` and emits
`player_chat_legacy_rejected`; `Aoi.AoiItem` rejects legacy chat casts with
`aoi_chat_legacy_rejected`. Gate-owned chat intents must go through
`ChatServer.Runtime` so world/region/local delivery follows the same partition
context as voxel subscriptions.

`PlayerManager` owns CID session replacement. A reconnect for the same CID
stops the old `PlayerCharacter` before publishing the new PID, and stale
terminate cleanup is ignored unless the PID still matches the current index.

`PlayerCharacter` may receive a dedicated `movement_ack_pid` from Gate on
session start. It still owns authoritative movement simulation and AOI snapshot
publication; the extra pid only selects where local-player movement ACKs are
cast so the browser can receive reconciliation data without waiting behind
Gate's voxel/bulk downlink queue.

Network-origin movement input must enter `PlayerCharacter` through
`SceneServer.PlayerCharacter.submit_movement_input/2`, which writes to the
shared movement input buffer. `PlayerCharacter` drains that buffer from
`:movement_tick` and then runs the existing authoritative replay, collision,
AOI snapshot, and ACK flow. Gate workers must not use per-frame `GenServer.call`
or `GenServer.cast` into the player actor for normal movement input because that
puts input traffic in the same FIFO mailbox as the fixed tick and can delay
local authority ACKs under continuous 60Hz input.
