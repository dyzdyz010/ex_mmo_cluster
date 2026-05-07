# Voxel server authority — 会话间衔接备忘

**Last updated**: 2026-05-07,Phase 1d commit `36b8ad7` 落地后。

下个会话开始时,先读这份(landing pad),再按需读 phase-X-*.md / 设计文档。

## 已落地阶段(2026-05-07 收盘)

| 阶段 | 状态 | 关键 commit |
| --- | --- | --- |
| 1a Refined cell domain (read-only wire) | 已完成 | `872e439` |
| 1b typed VoxelEditIntent (decode-only) + VoxelImpactIntent deprecation | 已完成 | `872e439` |
| 1c Scene refined mutation API + CellRefined delta + 客户端解锁 | 已完成 | `c99d6fd` (1c-1/2/3) → `508ce1e` (1c-4) → `a02817a` (1c-5) → `07bee6b` (1c-6) |
| 1d DataService canonical 持久化 + chunk_hash 全字段覆盖回归 | 已完成 | `36b8ad7` |

测试规模(2026-05-07 末态):

- data_service: 41 tests (+1 chunk_hash 8-byte CHECK)
- scene_server: 265 tests (+18 chunk_hash 全字段覆盖矩阵)
- gate_server: 181 tests (+5 hardening + 9 typed VoxelEditIntent routing)
- web_client: 210 vitest, tsc clean

未 push(用户没说 push 就别 push)。本地 master 领先 origin。

## 已知预存失败(本环境)

- `apps/world_server/test/world_server/voxel/authority_observe_test.exs:35` Windows path 大小写比对。**不要尝试修**(本会话也没碰过 world_server)。

## 下一步候选(按 README 顺序)

按 `docs/voxel-server-authority/README.md` 阶段表:

| 阶段 | 状态 | 范围 |
| --- | --- | --- |
| 2 | 未开始 | (原文档 Phase 2)refined micro edit 端到端贯通 |
| 3 | 未开始 | prefab v2 事务化(World/Scene transaction coordinator) |
| 4 | 未开始 | object provenance 与局部破坏 |
| 5 | 未开始 | 属性目录 + 温湿度基础模拟 |

**关于 Phase 2**:1c-5 已经把 micro edit 客户端→服务端→ delta 回推 → 客户端应用全程贯通了一次。所以 Phase 2 可能是:

- (a) 实质上已被 1c 吸收,只剩"标记完成"这种动作,
- (b) 还有遗留 scope(例如决策 5 RFC 留下的"在线模式 truth 改用 RefinedCellWireData[] 而不是 lossy adapter 到 FRefinedCellData"),
- (c) 端到端 e2e 自动化测试(目前是 ExUnit + vitest 各自覆盖,没有真正跨进程的 e2e)。

下个会话第一件事应该是和用户对齐 Phase 2 实际范围,**不要直接动手**。如果用户说"接着做",问"Phase 2 落地哪个 scope"。如果用户跳过 Phase 2 直接说"做 Phase 3",按 prefab v2 事务化推进。

**Phase 3 prefab v2 事务化**(如果选这个):

- 当前实现:`apps/scene_server/lib/scene_server/voxel/build_transaction_applier.ex` 已经存在 prepare/commit/abort 三相骨架。
- 当前 `0x67 PrefabPlaceIntent` Gate dispatch 走 cell-major 循环 + 单 chunk apply_intent,无跨 chunk atomicity(prefab 部分写不会回滚)。
- Phase 3 目标:World 协调跨 Scene/跨 chunk 的 prepare/commit/abort,事务可恢复(ProcessRestart 后能继续 commit 或 abort,不产生半提交)。
- 新决策稿位置:`docs/voxel-server-authority/phase-3-prefab-v2-transactions.md`(待建)。

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
- WriteTokenStore 仍是 GenServer(in-memory);Phase 1d 加了 `reset/1` test hatch。
- ChunkProcess 是每个 chunk 一个 GenServer,持有 hot truth + lease。
- ChunkDirectory 注册 chunk 到 ChunkProcess pid,负责 apply_intent 路由 + handoff prewarm。
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

## 这次会话产出(2026-05-07)

5 个 commit,本地 master 未 push:

```
36b8ad7 voxel: canonical Postgres persistence + chunk_hash regression matrix (Phase 1d)
204c285 docs(voxel): mark Phase 1c as completed in tracking index
07bee6b voxel: harden VoxelEditIntent dispatch + surface specific solid-macro reason (Phase 1c-6)
a02817a voxel: web client unlocks micro edits + consumes CellRefined deltas (Phase 1c-5)
508ce1e voxel: route typed VoxelEditIntent end-to-end (Phase 1c-4)
```

加上更早会话已经在 master 上的 1c-1/2/3:

```
c99d6fd voxel: server-side micro mutation slice (Phase 1c-1 / 1c-2 / 1c-3)
872e439 voxel: lay down server-authoritative wire foundation (Phase 1a + 1b)
```
