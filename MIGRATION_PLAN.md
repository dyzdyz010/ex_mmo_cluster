# Ex MMO Cluster — Incremental Migration Plan

**Date**: 2026-04-07
**Updated**: 2026-04-07
**Scope**: P0 (Critical) and P1 (Important) issues. P2 listed as future work.
**Constraint**: System must compile and pass tests after every single commit. No big-bang changes.

## Completion Status

| Phase | Description | Status | Commits |
|-------|-------------|--------|---------|
| 1 | TCP Framing + Custom Binary Protocol | **DONE** | 5 |
| 2 | Mnesia → PostgreSQL (core path) | **DONE** | 4 |
| 3 | Beacon HA (libcluster + Horde) | **DONE** | 3 |
| 4 | Scene Spatial Partitioning | Pending | — |
| 5 | Player State Persistence & Crash Recovery | Pending | — |
| 6 | Future Work (P2) | Deferred | — |

---

## Architecture Constraints (Must Preserve Throughout)

1. **Interface pattern**: Every app has `worker/interface.ex` that handles beacon registration, resource declaration, and requirement resolution
2. **Layer separation**: Connection → Game Logic → Data → Infrastructure
3. **Supervision trees**: `:one_for_one` strategy, DynamicSupervisor for dynamic processes
4. **Inter-app boundary**: Cross-app calls go through Interface modules or well-defined public APIs
5. **NIF safety**: Rust NIF calls must never block the BEAM scheduler for extended periods

---

## Dependency Graph

```
Phase 1 (TCP + Custom Protocol) --> independent, do first
  1.1 TCP framing fix (packet:4)
  1.2-1.4 Custom binary codec (hot path → all messages)
  1.5 Remove protobuf
  1.6 Document protocol
Phase 2 (PostgreSQL)  ------------> independent, can parallel with Phase 1
Phase 3 (Beacon HA)   ------------> independent of 1/2, but Phase 2 simplifies it
Phase 4 (Zone Partitioning) ------> independent
Phase 5 (Crash Recovery) ---------> depends on Phase 2 (needs PostgreSQL)
                                 --> benefits from Phase 4 (zone_id in checkpoints)
```

**Recommended execution order**:
1. Phase 1 step 1.1 (TCP framing — smallest, safest, critical correctness fix)
2. Phase 1 steps 1.2–1.3 (custom codec for hot path, dual-protocol period)
3. Phase 2 steps 2.1–2.4 (Ecto infrastructure setup, no behavior change)
4. Phase 1 steps 1.4–1.6 (finish protocol migration, remove protobuf)
5. Phase 2 steps 2.5–2.7 (dual-write, then switch reads)
6. Phase 5 steps 5.1–5.2 (checkpoint schema, leveraging Ecto infra)
7. Phase 3 (beacon HA)
8. Phase 2 steps 2.8–2.10 (Mnesia removal, after PostgreSQL proven stable)
9. Phase 4 (zone partitioning, largest scope)
10. Phase 5 steps 5.3–5.6 (player recovery, after zones in place)

---

## Phase 1: TCP Framing + Custom Binary Protocol (P0)

**Problem**: (1) `tcp_acceptor.ex` opens socket with `packet: 0` (raw mode), causing protobuf decode failures on segment merging/splitting. (2) protox (pure Elixir protobuf) is too slow for high-frequency game messages. Position sync at 10-30Hz per player requires minimal serialization overhead.

**Goal**: Fix TCP framing, then incrementally replace protobuf with a custom binary protocol. Erlang binary pattern matching is zero-allocation and the fastest path on the BEAM.

**Design Decision**: All messages will eventually use custom binary format. No protobuf long-term. The custom protocol uses a fixed header + message-type-specific binary layout:

```
Wire format: <<length::32-big, msg_type::8, payload::binary>>
  - length: auto-handled by Erlang {packet, 4}
  - msg_type: 1 byte message type ID
  - payload: message-type-specific binary layout (fixed size where possible)
```

### Step 1.1: Add `packet: 4` to listening socket

- **Files**: `apps/gate_server/lib/gate_server/worker/tcp_acceptor.ex`
- **Change**: `packet: 0` → `packet: 4` in `:gen_tcp.listen/2` options
- **Validate**: `mix compile && mix test apps/gate_server/`
- **Invariants**: `:binary` and `active: true` preserved. Accepted sockets inherit listen socket options. `:gen_tcp.send/2` auto-prepends length header when `packet: 4` is set.

### Step 1.2: Define custom binary codec module

- **Files**: `apps/gate_server/lib/gate_server/codec.ex` (new)
- **Change**: Define message type constants and encode/decode functions using binary pattern matching. Start with the hot-path messages only:

```elixir
# Message types
@msg_movement     0x01
@msg_enter_scene  0x02
@msg_time_sync    0x03
@msg_result       0x80
@msg_player_enter 0x81
@msg_player_leave 0x82
@msg_player_move  0x83

# Decode: binary → tuple (zero allocation for fixed-size messages)
def decode(<<@msg_movement, cid::64, timestamp::64,
             lx::float-64, ly::float-64, lz::float-64,
             vx::float-64, vy::float-64, vz::float-64,
             ax::float-64, ay::float-64, az::float-64>>) do
  {:movement, cid, timestamp, {lx, ly, lz}, {vx, vy, vz}, {ax, ay, az}}
end

# Encode: tuple → iodata
def encode({:player_move, cid, {x, y, z}}) do
  <<@msg_player_move, cid::64, x::float-64, y::float-64, z::float-64>>
end
```

- **Validate**: Unit tests for each message type: encode → decode roundtrip, verify field values.
- **Invariants**: Old protobuf path still exists. Codec is a standalone module, not wired in yet.

### Step 1.3: Wire hot-path messages through custom codec

- **Files**: `apps/gate_server/lib/gate_server/worker/tcp_connection.ex`, `apps/gate_server/lib/gate_server/message.ex`
- **Change**: In `handle_info({:tcp, _, data}, state)`, dispatch based on first byte: if it matches a known custom message type, route to `GateServer.Codec.decode/1`; otherwise fall back to `GateServer.Message.decode/1` (protobuf). Similarly, `send_data/3` uses `GateServer.Codec.encode/1` for hot-path messages.
- **Validate**: Integration test: send a custom-encoded movement message, verify server processes it and replies with custom-encoded response.
- **Invariants**: Protobuf path still works for all other message types. **Dual-protocol period** — both old and new clients supported.

### Step 1.4: Migrate remaining message types to custom codec

- **Files**: `apps/gate_server/lib/gate_server/codec.ex`, `apps/gate_server/lib/gate_server/message.ex`
- **Change**: Add encode/decode for all remaining message types (enter_scene, time_sync, heartbeat, broadcast actions, result replies). One message type per commit if preferred.
- **Validate**: Each message type has roundtrip test. Integration test for each dispatch path.
- **Invariants**: All message types covered by custom codec.

### Step 1.5: Remove protobuf dependency

- **Files**:
  - `apps/gate_server/lib/gate_server/message.ex` — remove `Protox.decode/2` and `Protox.encode/1` calls
  - `apps/gate_server/lib/gate_server/proto/` — delete proto definition modules
  - `apps/gate_server/mix.exs` — remove `{:protox, ...}` dependency
  - `.gitmodules` — evaluate if `mmo_protos` submodule still needed
- **Change**: All encode/decode goes through `GateServer.Codec`. Remove protox.
- **Validate**: `mix deps.get && mix compile && mix test`. No protox references remain.
- **Invariants**: `GateServer.Message.dispatch/3` still handles routing logic; it now receives decoded tuples from `Codec` instead of protobuf structs.

### Step 1.6: Document wire protocol

- **Files**: `PROTOCOL.md` (new)
- **Change**: Document the complete custom binary protocol:
  - Wire framing: `<<length::32-big, body::binary>>`
  - Message format: `<<msg_type::8, fields::binary>>`
  - Table of all message types with their binary layouts
  - Byte-level field definitions for each message
- **Validate**: N/A (documentation only).

---

## Phase 2: Mnesia → PostgreSQL Migration (P0)

**Problem**: Mnesia DETS has 2GB per-table limit, painful schema migrations, weak netsplit handling.

**Goal**: PostgreSQL (via Ecto) for persistent data. Keep existing `DataService.Dispatcher → poolboy → Worker` architecture.

### Step 2.1: Add Ecto and Postgrex dependencies

- **Files**: `apps/data_service/mix.exs`, `config/config.exs`
- **Change**: Add `{:ecto_sql, "~> 3.11"}` and `{:postgrex, ">= 0.0.0"}`. Configure `DataService.Repo` but don't start it yet.
- **Validate**: `mix deps.get && mix compile`. All existing tests pass.
- **Invariants**: Mnesia still works. Zero runtime change.

### Step 2.2: Create Ecto Repo and schema modules

- **Files**:
  - `apps/data_service/lib/data_service/repo.ex` (new)
  - `apps/data_service/lib/data_service/schema/account.ex` (new)
  - `apps/data_service/lib/data_service/schema/character.ex` (new)
- **Change**: Ecto schemas mirroring Mnesia `User.Account` and `User.Character` fields exactly.
- **Validate**: `mix compile`. Schemas instantiable in `iex`.
- **Invariants**: No runtime behavior change.

### Step 2.3: Add Ecto migrations

- **Files**: `apps/data_service/priv/repo/migrations/` (two new migration files)
- **Change**: Create `accounts` and `characters` tables matching Mnesia attributes. Unique indexes on `username`, `email`.
- **Validate**: `mix ecto.create && mix ecto.migrate` succeeds. `mix ecto.rollback` works.
- **Invariants**: Production still uses Mnesia.

### Step 2.4: Start Ecto Repo in supervision tree

- **Files**: `apps/data_service/lib/data_service/application.ex`, `config/config.exs`
- **Change**: Add `DataService.Repo` to children list. Both Mnesia and Ecto running.
- **Validate**: `DataService.Repo.query("SELECT 1")` returns `{:ok, ...}` in iex.
- **Invariants**: All Mnesia code paths unchanged.

### Step 2.5: Dual-write adapter for UserAccount

- **Files**: `apps/data_service/lib/data_service/db_ops/user_account.ex`, `apps/data_service/lib/data_service/worker/worker.ex`
- **Change**: After each Mnesia write, also insert into Ecto. Ecto failures logged but non-fatal (try/catch).
- **Validate**: Register account → verify exists in both Mnesia and PostgreSQL.
- **Invariants**: Mnesia still source of truth for reads. PostgreSQL failures non-fatal.

### Step 2.6: Backfill script — Mnesia → PostgreSQL

- **Files**: `apps/data_init/lib/mix/tasks/migrate_to_pg.ex` (new)
- **Change**: Mix task reads all Mnesia records, bulk-inserts into PostgreSQL with `ON CONFLICT DO NOTHING`.
- **Validate**: Compare record counts. Spot-check records.
- **Invariants**: Mnesia data unchanged.

### Step 2.7: Switch reads to PostgreSQL (feature flag)

- **Files**: `apps/data_service/lib/data_service/db_ops/user_account.ex`, `apps/data_service/lib/data_service/worker/worker.ex`, `config/config.exs`
- **Change**: Add `config :data_service, :use_ecto, false`. When true, reads from Ecto. Default off.
- **Validate**: Toggle flag, run account operations, verify identical results.
- **Invariants**: Flag off = zero behavior change.

### Step 2.8: Enable PostgreSQL, remove Mnesia writes

- **Files**: `config/config.exs`, `apps/data_service/lib/data_service/worker/worker.ex`, `apps/data_service/lib/data_service/db_ops/user_account.ex`
- **Change**: Set `:use_ecto` to `true`. Remove Mnesia write path.
- **Validate**: Full integration test. Mnesia tables can be empty.
- **Invariants**: No Mnesia dependency for account/character data.

### Step 2.9: Remove Mnesia infrastructure for migrated tables

- **Files**: `apps/data_init/lib/table_def.ex`, `apps/data_init/lib/data_init.ex`, various `mix.exs`
- **Change**: Remove `User.Account`/`User.Character` from Mnesia tables. Evaluate `data_store`/`data_contact` necessity.
- **Validate**: `mix compile` no warnings. All tests pass.
- **Invariants**: No data loss. PostgreSQL sole source of truth.

### Step 2.10: Simplify data layer topology

- **Files**: All `interface.ex` files — remove `@requirement [:data_contact]` where no longer needed.
- **Change**: Interface modules no longer need `data_contact` for Mnesia cluster joining.
- **Validate**: Cluster starts with simplified topology.
- **Invariants**: Interface pattern preserved. Beacon registration still works.

---

## Phase 3: Beacon HA — libcluster + Horde (P1)

**Problem**: `@beacon :"beacon1@127.0.0.1"` hardcoded everywhere. Single point of failure.

**Goal**: Distributed service discovery. No single node required.

### Step 3.1: Add libcluster dependency

- **Files**: Each app's `mix.exs`, `config/config.exs`
- **Change**: Add `{:libcluster, "~> 3.3"}`. Configure gossip topology. Don't change Interface modules.
- **Validate**: `mix deps.get && mix compile`.
- **Invariants**: Existing beacon still works.

### Step 3.2: Start libcluster in beacon_server

- **Files**: `apps/beacon_server/lib/beacon_server/application.ex`
- **Change**: Add `Cluster.Supervisor` to children. Both old and new discovery coexist.
- **Validate**: Start two nodes, verify they find each other via libcluster.
- **Invariants**: Existing `BeaconServer.Beacon` GenServer unchanged.

### Step 3.3: Add Horde distributed registry

- **Files**:
  - `apps/beacon_server/mix.exs`
  - `apps/beacon_server/lib/beacon_server/distributed_registry.ex` (new)
  - `apps/beacon_server/lib/beacon_server/distributed_supervisor.ex` (new)
  - `apps/beacon_server/lib/beacon_server/application.ex`
- **Change**: Horde registry + supervisor. Register `BeaconServer.Beacon` in Horde.
- **Validate**: Start two beacons. Kill one. Process restarts on survivor.
- **Invariants**: Old direct GenServer calls still work.

### Step 3.4: Create beacon client abstraction

- **Files**: `apps/beacon_server/lib/beacon_server/client.ex` (new)
- **Change**: `BeaconServer.Client.register/1` and `.get_requirements/1` — tries Horde first, falls back to hardcoded node.
- **Validate**: Unit test both paths.
- **Invariants**: No Interface modules changed yet.

### Step 3.5: Migrate Interface modules (one per commit)

- **Files**: Each app's `worker/interface.ex` (9 apps, 9 commits)
- **Change**: Replace `GenServer.call({BeaconServer.Beacon, @beacon}, ...)` with `BeaconServer.Client` calls. Order: `data_contact` → `data_store` → `data_service` → `auth_server` → `agent_server` → `agent_manager` → `world_server` → `scene_server` → `gate_server`
- **Validate**: After each commit, start full cluster. Verify registration works.
- **Invariants**: Interface lifecycle (join → register → get_requirements) preserved.

### Step 3.6: Remove hardcoded beacon fallback

- **Files**: `apps/beacon_server/lib/beacon_server/client.ex`, all `interface.ex`
- **Change**: Remove `@beacon` attribute and fallback path.
- **Validate**: Start cluster without `:"beacon1@127.0.0.1"`. Everything works.
- **Invariants**: No single point of failure.

### Step 3.7: Add libcluster to all app nodes

- **Files**: Each app's `application.ex`
- **Change**: All nodes use libcluster for peer discovery.
- **Validate**: Start 3+ nodes, kill one, others remain connected.
- **Invariants**: Cluster formation fully automatic.

---

## Phase 4: Scene Spatial Partitioning (P1)

**Problem**: Single AoiManager queries entire world. O(N²) broadcasts.

**Goal**: Zone-based partitioning. Each zone owns its own AOI, players, and physics.

### Step 4.1: Define Zone configuration

- **Files**: `apps/scene_server/lib/scene_server/zone/zone_config.ex` (new)
- **Change**: Zone boundaries, IDs, neighbor map. World 5000³ → 2×2 grid of 2500² zones.
- **Validate**: Unit test: boundaries non-overlapping, cover full world.
- **Invariants**: No runtime change.

### Step 4.2: Create ZoneServer GenServer

- **Files**:
  - `apps/scene_server/lib/scene_server/zone/zone_server.ex` (new)
  - `apps/scene_server/lib/scene_server/sup/zone_sup.ex` (new)
- **Change**: Each ZoneServer owns its AOI and player management. Start with ONE zone covering whole world = identical behavior.
- **Validate**: Players enter and move as before.
- **Invariants**: External API (`SceneServer.PlayerManager` calls from gate_server) still works.

### Step 4.3: Zone-aware PlayerManager

- **Files**: `apps/scene_server/lib/scene_server/worker/player_manager.ex`
- **Change**: Accept `zone_id` in init. Add `ZoneRouter` to determine zone by spawn position.
- **Validate**: Single zone, behavior unchanged.
- **Invariants**: `gate_server` dispatch path still resolves.

### Step 4.4: Zone-scoped AoiManager

- **Files**: `apps/scene_server/lib/scene_server/worker/aoi/aoi_manager.ex`
- **Change**: Octree covers only zone's coordinate space. Fix the `{1_000_000, 1_000_000, 1_000_000}` query to use actual `interest_radius`.
- **Validate**: Single zone, identical behavior.
- **Invariants**: AoiItem API unchanged.

### Step 4.5: Enable multi-zone

- **Files**: `zone_config.ex`, `zone_server.ex`, `zone_router.ex`
- **Change**: Switch from 1 zone to 2×2 grid. Route players by spawn location.
- **Validate**: Spawn players at different coordinates → correct zones. AOI scoped to zone.
- **Invariants**: Intra-zone behavior correct. Cross-zone visibility deferred.

### Step 4.6: Zone handoff for moving players

- **Files**:
  - `apps/scene_server/lib/scene_server/zone/zone_handoff.ex` (new)
  - `apps/scene_server/lib/scene_server/worker/player_character.ex`
- **Change**: When position crosses zone boundary, transfer player. Two-phase: remove-from-old → add-to-new.
- **Validate**: Move player across boundary, verify no duplication.
- **Invariants**: Player state preserved. Connection unchanged.

### Step 4.7: Cross-zone AOI for border regions

- **Files**:
  - `apps/scene_server/lib/scene_server/zone/zone_border.ex` (new)
  - `apps/scene_server/lib/scene_server/worker/aoi/aoi_item.ex`
- **Change**: Players near zone border query neighboring zone's AoiManager too.
- **Validate**: Two players on opposite sides of border, within AOI range, see each other.
- **Invariants**: Players far from borders unaffected.

---

## Phase 5: Player State Persistence & Crash Recovery (P1)

**Problem**: `restart: :temporary`, all state lost on crash.

**Goal**: Periodic checkpoint to PostgreSQL (Phase 2 infra). Automatic recovery on crash.

### Step 5.1: Checkpoint schema

- **Files**: `apps/data_service/lib/data_service/schema/player_checkpoint.ex` (new), migration file
- **Change**: Ecto schema: `cid`, `position_{x,y,z}`, `zone_id`, `last_checkpoint_at`, `status`. Upsert on `cid`.
- **Validate**: Migration runs.
- **Invariants**: No runtime change.

### Step 5.2: Checkpoint read/write functions

- **Files**: `apps/data_service/lib/data_service/db_ops/player_checkpoint.ex` (new)
- **Change**: `save_checkpoint/1` (upsert) and `load_checkpoint/1` (get_by cid).
- **Validate**: Unit test: save → load → verify equality.
- **Invariants**: Not integrated with PlayerCharacter yet.

### Step 5.3: Periodic checkpoint in PlayerCharacter

- **Files**: `apps/scene_server/lib/scene_server/worker/player_character.ex`
- **Change**: Add `:checkpoint_tick` timer (30s). Async write via `Task.start/1`. Includes cid, position, zone_id.
- **Validate**: Start player, wait 30s+, query PostgreSQL.
- **Invariants**: Checkpoint failure does not crash player (try/catch). Game loop unaffected.

### Step 5.4: Change restart strategy to `:transient`

- **Files**: `apps/scene_server/lib/scene_server/worker/player_character.ex`
- **Change**: `restart: :temporary` → `restart: :transient`. Restarts on abnormal exit only.
- **Validate**: `Process.exit(pid, :kill)` → supervisor restarts. Normal exit → no restart.
- **Invariants**: Disconnect flow (`{:stop, :normal, ...}`) not affected.

### Step 5.5: Recovery logic in PlayerCharacter init

- **Files**: `apps/scene_server/lib/scene_server/worker/player_character.ex`, `player_manager.ex`
- **Change**: On init, check for existing checkpoint. Use checkpointed position instead of random.
- **Validate**: Move player → wait for checkpoint → kill → verify respawn at checkpoint position.
- **Invariants**: First-time players still get random spawn.

### Step 5.6: Connection reassociation on recovery

- **Files**: `apps/scene_server/lib/scene_server/worker/player_character.ex`, `apps/gate_server/lib/gate_server/worker/tcp_connection.ex`
- **Change**: New PlayerCharacter notifies TcpConnection to update `scene_ref`. Buffer messages in TcpConnection when `scene_ref` is nil.
- **Validate**: Kill PlayerCharacter → TcpConnection gets new `scene_ref` → client movement reaches new process.
- **Invariants**: Client sees no disconnection, just brief pause.

---

## Phase 6: Future Work (P2)

### 6.1: Mix Release Profiles
Per-node-type releases (`:gate_node`, `:scene_node`, `:data_node`). Enables independent deployment/scaling.

### 6.2: UDP Channel for Position Sync
KCP or raw UDP for high-frequency movement. TCP for reliable messages (login, chat, combat).

### 6.3: Physics Engine Evaluation
Evaluate NavMesh (Recast/Detour) vs Rapier3D for MMO movement/pathfinding. NIF interface preserved.

---

## Risk Assessment

| Step | Risk | Mitigation |
|------|------|------------|
| 1.1 (packet:4) | Client must update framing | Document protocol change; gate can detect old clients by failed decode |
| 1.3 (dual protocol) | Two code paths to maintain | Keep protobuf fallback short-lived; migrate all types in 1.4 promptly |
| 1.5 (remove protobuf) | Breaking change for old clients | Only after all message types migrated and client updated |
| 2.5 (dual-write) | Ecto write fails silently | Add telemetry on Ecto failures; alert if rate > 0 |
| 2.8 (remove Mnesia) | Data loss if migration incomplete | Run backfill twice; verify row counts before cutover |
| 3.5 (Interface migration) | Horde registry not populated | Fallback in `BeaconServer.Client` ensures degradation |
| 4.6 (zone handoff) | Player duplication | Two-phase protocol: remove-from-old then add-to-new |
| 5.6 (connection reassoc.) | Race condition during recovery | Buffer messages when `scene_ref` is nil; replay after |
