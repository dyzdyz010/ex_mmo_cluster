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

### AOI index ownership (S1 去单点 / 句柄所有权分离)

- `SceneServer.Aoi.IndexStore` is the authoritative owner of two named public ETS
  tables: `:scene_aoi_octree`(单条 `:octree` 记录,持有整个 Scene 节点共享的唯一
  `OctreeArc` 八叉树句柄)和 `:scene_aoi_entries`(`cid => entry`,CID 索引的唯一真相源)。
  它是一个极简、近乎不会崩的存储进程,不跑任何热路径逻辑。
- `SceneServer.Aoi.IndexHeir` is the ETS heir of those two tables. 当 `IndexStore`
  崩溃,ETS 自动把表所有权转交 heir;`IndexStore` 重启后向 heir 认领回**同一句柄 + 同一份
  entries**(hydrate 不变式)。因此句柄所有权与执行 facade 分离,**管理者崩溃不会让存活
  `AoiItem` 的八叉树引用悬空、AOI 视图不脑裂**。冷启动才造新空树;绝不用空默认覆盖已有
  权威 entries(失败时发 `aoi_index_store_degraded` observe,而非静默兜底)。
- `SceneServer.Aoi.Index` is a **stateless functional facade** over those tables:
  `octree/0`、`put_entry/1`、`delete_entry/1`、`update_location/2`、`fetch_entries/1`、
  `actor_pid/1`、`nearby_actor_pids/3`。所有操作直接落 ETS / 八叉树 NIF,**没有任何到单点
  进程的同步 GenServer.call**——`self_move` 热路径写位置走 `:ets` 原子并发写,邻居查询走
  共享八叉树句柄(进程无关、可并发)。
- `SceneServer.AoiManager` 现在是无状态 facade 模块(不再是进程),对外保留原 API,内部全部
  委托给 `SceneServer.Aoi.Index`。Player 与 NPC actor 仍通过它注册;combat targeting 仍
  actor-agnostic。它**不再**持有任何与八叉树平行的 CID map,双真相源已删除。
- `SceneServer.Aoi.AoiItem` owns each actor's subscription list and movement /
  combat / skill fan-out. It does not own MMO chat delivery. 八叉树句柄在 `init` 时从
  `SceneServer.Aoi.Index.octree/0` 取(所有 item 共享同一权威句柄),而不是被传入一个可能
  随管理者重启而孤儿化的旧句柄。
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
