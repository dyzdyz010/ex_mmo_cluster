# Voxel server authority — 会话间衔接备忘

**Last updated**: 2026-05-08,Phase 3-bis 全程落地后。

下个会话开始时,先读这份(landing pad),再按需读 phase-X-*.md / 设计文档。

## 已落地阶段(2026-05-08 收盘)

| 阶段 | 状态 | 关键 commit |
| --- | --- | --- |
| 1a Refined cell domain (read-only wire) | 已完成 | `872e439` |
| 1b typed VoxelEditIntent (decode-only) + VoxelImpactIntent deprecation | 已完成 | `872e439` |
| 1c Scene refined mutation API + CellRefined delta + 客户端解锁 | 已完成 | `c99d6fd` (1c-1/2/3) → `508ce1e` (1c-4) → `a02817a` (1c-5) → `07bee6b` (1c-6) |
| 1d DataService canonical 持久化 + chunk_hash 全字段覆盖回归 | 已完成 | `36b8ad7` |
| 2 refined micro edit 端到端贯通 | 已完成(被 1c 吸收) | `314ad8a` (stub + README) |
| 3 prefab v2 事务化(World/Scene transaction coordinator) | 已完成 | `a053c82` (决策稿) → `3fc9966` (3-1) → `6973843` (3-2) → `bd74e01` (3-3a) → `e91c38f` (3-3b) → `b93a10d` (3-4) → `86d9186` (3-5) |
| 3-bis fence persistence + auto-resume commit(crash safety 闭环) | 已完成 | `5e3b1e7` (决策稿) → `5cadbdf` (3-bis-1) → `f6602b0` (3-bis-2) → `d767c29` (3-bis-3) → `9db8c1d` (3-bis-4) → `d01b3d6` (3-bis-5) → 本会话 (3-bis-6) |

测试规模(2026-05-08 末态,Phase 3-bis 收尾):

- data_service: 53 tests (+12 ChunkPendingTransactionStore)
- scene_server: 277 tests (+9 chunk_process_persistence_test)
- gate_server: 181 tests (Phase 3 后未变)
- world_server: 60 tests (+5 intents_by_participant / fast-path / resume)
- web_client: 210 vitest, tsc clean(Phase 3 后未变)

预存失败:`apps/world_server/test/world_server/voxel/authority_observe_test.exs:35`
Windows path 大小写,不动(memory 已记)。

未 push(用户没说 push 就别 push)。本地 master 领先 origin 23 commits。

## 已知预存失败(本环境)

- `apps/world_server/test/world_server/voxel/authority_observe_test.exs:35` Windows path 大小写比对。**不要尝试修**(本会话也没碰过 world_server)。

## 下一步候选(按 README 顺序)

按 `docs/voxel-server-authority/README.md` 阶段表:

| 阶段 | 状态 | 范围 |
| --- | --- | --- |
| 4 | 未开始 | object provenance 与局部破坏 |
| 5 | 未开始 | 属性目录 + 温湿度基础模拟 |

**Phase 3-bis 后剩余的 backlog**(若用户优先继续巩固 3 系):

- 跨 region 多 participant 事务(D6 推到 Phase 3-bis 后续):BuildTransaction 已支持 multi-participant,Gate 的 prefab dispatch 还只构造 single-participant。需要先有跨 region prefab 的语义设计文档。
- Per-region coordinator(D5 留 Phase 6):当前单全局 coordinator 是潜在 SPOF。
- 紧凑 ChunkDelta(取代 commit 时的 snapshot fan-out):commit 时把 batch 内每个 intent 编成 ChunkDelta op 推送,不必走整 chunk snapshot。
- 跨进程 e2e harness(Phase 2 决策稿 park 的 backlog):gate ↔ scene ↔ data_service ↔ web_client 全链路 e2e 自动化。
- fence 超时 sweeper:`fenced_at_ms` 字段已写入,但目前没自动清理"卡死"fence(coordinator 持续不可达 + Scene 持续不重启的极端场景)。

**Phase 4 object provenance 与局部破坏**(README 顺序下一阶段):

- 还没建决策稿。需要先和用户对齐:从 prefab/part 反查 owner、prefab 内"挖一个 micro slot"的局部破坏语义、`voxel_scene_objects` 表的形态(协议设计文档 §11 已留 placeholder)。
- 新决策稿位置:`docs/voxel-server-authority/phase-4-object-provenance.md`(待建)。

## 工作流约定(跨会话)

参考 memory:`feedback_decision_stub_workflow.md` + `feedback_no_backcompat_unreleased.md`。简版:

1. **决策稿先行**:每 phase 在 `docs/voxel-server-authority/phase-<id>-<slug>.md` 写决策稿,列决策项(每项给推荐值)、不在范围、风险、step 列表。决策稿入仓后才动代码。
2. **逐 step commit**:每 step 单独 commit。Elixir 文件改前 `mix format`;web 端 `npx tsc --noEmit && npx vitest run`。
3. **进度日志**:每 step 完成后在决策稿 `## 进度日志` 追加一行。同步 `README.md` 阶段表。
4. **不 push**:用户没说 push 就只 commit。
5. **全新系统不留兼容**:架构重写默认按"未上线第一版"姿势,不留 wrapper / 双路径 / deprecated alias。

## 关键运行时约定(避免下次重新发现)

### Postgres / Repo

- `apps/data_service/test/test_helper.exs` 启动 `DataService.Repo` + 跑 `priv/repo/migrations`。
- **Phase 1d 后**:`apps/scene_server/test/test_helper.exs` 与 `apps/gate_server/test/test_helper.exs` 也启动 Repo + migrations(因为 ChunkSnapshotStore 走 Repo)。
- **assert_receive_timeout 调到 1000ms**(scene/gate test_helper),容忍 Postgres INSERT 延迟。
- 持久化测试要 `async: false` + `setup do Repo.delete_all(VoxelChunkSnapshot); WriteTokenStore.reset(WriteTokenStore); :ok end`。

### Windows 测试

- `mix` 用 `cmd //c "mix ..."`(via Bash 工具)或 `mix ...`(via PowerShell 工具)。
- vitest 必须 `cd clients/web_client/`,从 umbrella 根跑会丢 globals。
- `cmd /c` 在 PowerShell 工具里 cwd 跨调用持久;Bash 工具不持久。
- `mix` 报 dependency 问题就从 umbrella 根跑,不从 `apps/<app>/` 跑。

### 体素架构现状

- ChunkSnapshotStore 是 stateless module,直走 `DataService.Repo`(Phase 1d)。
- ChunkPendingTransactionStore 也是 stateless module,直走 `DataService.Repo`(Phase 3-bis-1):新表 `voxel_chunk_pending_transactions`,复合 PK `(logical_scene_id, coord_x, coord_y, coord_z)`,fence_payload 用 term_to_binary 编码 normalized intent batch。
- WriteTokenStore 仍是 GenServer(in-memory);Phase 1d 加了 `reset/1` test hatch。
- ChunkProcess 是每个 chunk 一个 GenServer,持有 hot truth + lease;`pending_fence.intents` 是 list(Phase 3-3a 升级,支持单 chunk 多 macro 的 batch fence);**fence 同步持久化进 voxel_chunk_pending_transactions**(Phase 3-bis-2),init 时按 lease 一致性校验 reload,不匹配丢弃孤儿。
- ChunkDirectory 注册 chunk 到 ChunkProcess pid,负责 apply_intent 路由 + handoff prewarm + transaction prepare/commit/abort 路由(Phase 3-bis-2 起 attrs 透传 `:decision_version`)。
- TransactionCoordinator 持久化走 Postgres(`voxel_transaction_coordinator_snapshots` 单行 snapshot,Phase 3-1);**`BuildTransaction.intents_by_participant` 字段随之持久化**(Phase 3-bis-3)。
- TransactionExecutor 加 `:prepared` fast-path(Phase 3-bis-4):跳过 prepare phase 直接 dispatch commit,`prepare_results` 由 `derive_prepare_results_from_prepared_state/1` 推导。
- TransactionRecoveryWatcher 对 `:preparing`/`:aborting` 自动 abort(Phase 3-2);**对 `:prepared` 通过 `:scene_opts_resolver` 自动重发 commit dispatch**(Phase 3-bis-5):WorldSup 注入 BeaconServer-backed resolver,scene_node 不可达时退化为 :pending_commit + emit unavailable。
- 0x67 PrefabPlaceIntent dispatch 切到 World 事务路径(Phase 3-3b):rasterize → 按 chunk 分组 → 单 lease 事务 → executor 三相 → atomic commit/abort。
- 客户端在线模式:storage.refinedCells 仍然是 `FRefinedCellData[]`(lossy 自 wire);Phase 1c-5 决策 5 RFC 备注了"未来改 wire-form-as-truth"。

### 前端策略冻结(2026-04-26)

- 唯一在迭代的客户端是 `clients/bevy_client`(Rust + Bevy)。
- `clients/web_client` 已冻结:本会话改了 web_client 是因为 Phase 1c/1d 之前的工作流尚未明文冻结;后续 Phase 2+ 优先看是否要改 bevy_client 而不是 web_client。
- **下个会话注意**:涉及客户端改动时先确认对哪个客户端落地。

## 关键文件锚点

| 用途 | 路径 |
| --- | --- |
| 阶段总表 | `docs/voxel-server-authority/README.md` |
| 协议设计参考(权威) | `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md` |
| 线协议规范 | `docs/2026-04-10-线协议规范.md` |
| 体素 chunk 进程 | `apps/scene_server/lib/scene_server/voxel/chunk_process.ex` |
| 体素 chunk 目录 | `apps/scene_server/lib/scene_server/voxel/chunk_directory.ex` |
| Codec / chunk_hash | `apps/scene_server/lib/scene_server/voxel/codec.ex` |
| Storage(canonical truth) | `apps/scene_server/lib/scene_server/voxel/storage.ex` |
| Postgres 持久化(1d 后) | `apps/data_service/lib/data_service/voxel/chunk_snapshot_store.ex` |
| Postgres schema | `apps/data_service/lib/data_service/schema/voxel_chunk_snapshot.ex` |
| Postgres migration | `apps/data_service/priv/repo/migrations/20260507000001_create_voxel_chunks.exs` |
| Gate 协议 codec | `apps/gate_server/lib/gate_server/codec.ex` |
| Gate ws/tcp dispatch | `apps/gate_server/lib/gate_server/worker/{ws,tcp}_connection.ex` |
| World map ledger | `apps/world_server/lib/world_server/voxel/map_ledger.ex` |
| Web client 在线 adapter | `clients/web_client/src/voxel/onlineVoxelWorldAdapter.ts` |
| Web client wire decoder | `clients/web_client/src/infrastructure/net/refinedCellWire.ts`,`voxelEditIntent.ts`,`voxelProtocol.ts` |

## 这次会话产出(2026-05-08,Phase 3-bis)

7 个 commit,本地 master 未 push:

```
本会话 docs(voxel): finalize Phase 3-bis (apps READMEs + plan progress log + handoff)
d01b3d6 voxel: TransactionRecoveryWatcher auto-resumes :prepared via executor (Phase 3-bis-5)
9db8c1d voxel: TransactionExecutor :prepared fast-path (Phase 3-bis-4)
d767c29 voxel: BuildTransaction.intents_by_participant + coordinator persistence (Phase 3-bis-3)
f6602b0 voxel: ChunkProcess persists pending_fence to Postgres (Phase 3-bis-2)
5cadbdf voxel: ChunkPendingTransactionStore + voxel_chunk_pending_transactions table (Phase 3-bis-1)
5e3b1e7 docs(voxel): land Phase 3-bis plan (fence persistence + auto-resume commit)
```

加上上一会话已经在 master 上的 Phase 3 收尾(从 Phase 1a 一路到 Phase 3 全部 commit):

```
86d9186 docs(voxel): finalize Phase 3 (READMEs + plan progress log + handoff)
b93a10d voxel: lock down :transaction_not_prepared contract for released fences (Phase 3-4)
e91c38f voxel: route 0x67 PrefabPlaceIntent through World transaction (Phase 3-3b)
bd74e01 voxel: ChunkProcess fence holds intent batch instead of single intent (Phase 3-3a)
6973843 voxel: TransactionRecoveryWatcher sweeps in-flight tx on startup (Phase 3-2)
3fc9966 voxel: TransactionCoordinator persists through Postgres only (Phase 3-1)
a053c82 docs(voxel): land Phase 3 plan (prefab v2 transactionalization)
314ad8a docs(voxel): mark Phase 2 as absorbed by Phase 1c (refined micro edit roundtrip)
f24cb6c docs(voxel): add session handoff landing pad for cross-conversation continuity
36b8ad7 voxel: canonical Postgres persistence + chunk_hash regression matrix (Phase 1d)
204c285 docs(voxel): mark Phase 1c as completed in tracking index
07bee6b voxel: harden VoxelEditIntent dispatch + surface specific solid-macro reason (Phase 1c-6)
a02817a voxel: web client unlocks micro edits + consumes CellRefined deltas (Phase 1c-5)
508ce1e voxel: route typed VoxelEditIntent end-to-end (Phase 1c-4)
c99d6fd voxel: server-side micro mutation slice (Phase 1c-1 / 1c-2 / 1c-3)
872e439 voxel: lay down server-authoritative wire foundation (Phase 1a + 1b)
```
