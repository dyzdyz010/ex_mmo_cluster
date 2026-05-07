# Phase 1d — DataService canonical 持久化 + chunk_hash 全字段覆盖回归

## 目标

把 `DataService.Voxel.ChunkSnapshotStore` 从进程内 in-memory map 升级为 PostgreSQL 真持久化(canonical schema),并在两端补齐 `chunk_hash` 全字段覆盖回归测试。

完成后:

- `DataService.Repo` 多一张 `voxel_chunks` 表(按协议设计 §11),Scene 写入 / 读取经 Ecto。
- 在线模式下重启 ChunkSnapshotStore(无状态模块,概念上"重启 = 丢缓存")也不丢真相,客户端 reload 行为一致。
- `chunk_hash` 任一规范字段(macro_headers truth / normal_blocks / refined_cells / environment_summaries / object_refs / 大小字段)发生变化都会改变 `chunk_hash`;`chunk_version` / dirty flags / lease 等非真相字段变化不改变 `chunk_hash`。

## 不在范围内

- `voxel_attribute_sets` / `voxel_tag_sets` 表(留 Phase 5 属性目录)。
- `voxel_chunk_journal` 表(留 Phase 3 事务化)。
- `voxel_scene_objects` 表(留 Phase 4 object provenance)。
- `WriteTokenStore` / `MapLedgerStore` 持久化重写(本阶段不动,token 仍 in-memory)。
- 跨节点同步 / 多 Repo / 分库分表(留运维 / Phase 6)。

## 决策项(已定稿,未上线无需向后兼容)

> 用户确认"全新系统,不留兼容,直接改第一版";以下决策已落定。后续偏离需在进度日志显式记录 RFC 与替代方案。

### 决策 1:**`ChunkSnapshotStore` 改为无 GenServer 的 stateless module,直走 Repo**

不再 `use GenServer`、不再 `start_link`、不再有 `name:` 注册。`put_snapshot/1` / `get_snapshot/2` 直接调用 `DataService.Repo`。

理由:全新系统,不需要保留 GenServer 入口的兼容包装。Repo 行级锁 + 事务足够保证并发正确性,不需要单进程串行化瓶颈。Scene 调用点全量改造(`apps/scene_server/lib/scene_server/voxel/chunk_process.ex` 调 `persist_snapshot` 处)。测试 setup 改用 `Repo.delete_all(VoxelChunkSnapshot)`,与 `schema_test.exs` 对齐。

`ChunkSnapshotStore.snapshot/1`(全表 dump)CLI/debug 用途保留,改成 `Repo.all(VoxelChunkSnapshot) |> Map.new(...)`。

### 决策 2:**`voxel_chunks` 表 schema 与协议设计 §11 一一对齐**

```sql
voxel_chunks
  logical_scene_id        bigint
  coord_x, coord_y, coord_z  int
  schema_version          smallint
  chunk_size_in_macro     smallint
  micro_resolution        smallint
  region_id               bigint
  lease_id                bigint
  owner_scene_instance_ref bigint
  owner_epoch             bigint
  chunk_version           bigint
  chunk_hash              bytea
  data                    bytea
  inserted_at             timestamptz
  updated_at              timestamptz
  primary key (logical_scene_id, coord_x, coord_y, coord_z)
```

约束:

- `chunk_hash` 长度通过 Ecto changeset `validate_length` 强制 8 字节。
- 所有 `bigint` 字段加 `CHECK (field >= 0)`(协议设计强调 v1 限制 u63)。
- `schema_version`/`chunk_size_in_macro`/`micro_resolution` 用 `smallint` + `>= 0` CHECK。
- `coord_x/y/z` 用 `int`(签名 i32,与线格式 chunk_coord 对齐)。
- `region_id` 在 §11 不强制,但保留以便按 region 检索/迁移列出(无独立索引)。

主键设为 `(logical_scene_id, coord_x, coord_y, coord_z)` 复合主键,免去额外 unique 索引。

### 决策 3:**`chunk_hash` 字段类型用 `bytea`**

而不是 `bigint`。理由:协议设计 §11 已明确"哈希是原始 64 位摘要,不适合落 bigint";现有 Scene `Hash.encode64/1` 也输出 8 字节 binary。Ecto 用 `:binary` 类型映射 `bytea`。changeset 校验长度 == 8。

### 决策 4:**chunk_version 单调递增 fence 落到数据库,用单条事务 SELECT FOR UPDATE + INSERT/UPDATE**

不再在 GenServer 内做 cmp;改用 `Repo.transaction(fn -> ... end)`:

```
SELECT chunk_version, chunk_hash, data
FROM voxel_chunks
WHERE logical_scene_id = $1 AND coord_x = $2 AND coord_y = $3 AND coord_z = $4
FOR UPDATE;
```

- 行不存在 → `INSERT` → 返回 `:inserted`
- 行存在 且 `next.chunk_version > current.chunk_version` → `UPDATE` → 返回 `:updated`
- 行存在 且 `next.chunk_version < current.chunk_version` → 回滚事务 → 返回 `{:error, :stale_chunk_version}`
- 行存在 且 `next.chunk_version == current.chunk_version` 且 `(chunk_hash, data)` 完全相同 → 回滚 → 返回 `:unchanged`
- 行存在 且 `next.chunk_version == current.chunk_version` 且 内容不同 → 回滚 → 返回 `{:error, :chunk_version_conflict}`

事务隔离 + 行锁保证多写并发下 invariant 不被破坏。

### 决策 5:**测试用 `async: false` + setup `Repo.delete_all(VoxelChunkSnapshot)`,与 `schema_test.exs` 对齐**

不引入 `Ecto.Adapters.SQL.Sandbox` 共享/子进程模式(增量复杂度,1d v1 不需要)。

`apps/data_service/test/test_helper.exs` 的 Postgres + migration 启动机制保持不动(本环境已验证 40 tests 全绿)。

### 决策 6:**`chunk_hash` 全字段覆盖回归测试矩阵放在 `apps/scene_server/test/scene_server/voxel/codec_test.exs`**

既然 `Codec.chunk_hash/1` 是真相计算入口,回归测试与之同模块。用一个 baseline storage,逐字段做"敏感性矩阵":

| 字段 | 类型 | 期望 | 实现 |
| --- | --- | --- | --- |
| schema_version / logical_scene_id / chunk_coord | 真相 | hash 改变 | 修改 storage 字段后比对 |
| chunk_size_in_macro / micro_resolution | 真相 | hash 改变 | 同上 |
| macro_headers (mode / canonical_flags / payload_index / environment_index) | 真相 | hash 改变 | 同上 |
| normal_blocks (任一 NormalBlockData 字段) | 真相 | hash 改变 | 同上 |
| refined_cells (occupancyWords / 任一 layer 字段 / object_refs) | 真相 | hash 改变 | 同上 |
| environment_summaries (任一字段) | 真相 | hash 改变 | 同上 |
| object_refs | 真相 | hash 改变 | 同上 |
| chunk_version | 派生 | hash 不变 | 改 chunk_version 后比对 |
| dirty_macro_min/max / dirty_flags | 派生 | hash 不变 | 同上 |
| macro_header.cell_version / cell_hash(线格式字段非真相) | 派生 | hash 不变 | 同上 |

理由:1d 的"全字段覆盖回归"——把"真相 ↔ 派生"边界变成可测试断言,以后任何 schema 演进改动 `chunk_hash` 输入字段都会被该测试矩阵抓出来。

## 高层步骤

| Step | 范围 | 验收信号 |
| --- | --- | --- |
| 1d-1 | 写迁移 + Ecto Schema(`DataService.Schema.VoxelChunkSnapshot`) | `mix ecto.migrate` 通过;schema 字段类型与 §11 一致 |
| 1d-2 | `ChunkSnapshotStore` 从 GenServer 改为 Repo 直读直写 + 事务 CAS;Scene 调用点全量更新 | data_service ChunkSnapshotStore 测试改写,Scene `chunk_process.persist_snapshot` 调用更新,gate_server / scene_server 全套测试不破回归 |
| 1d-3 | `chunk_hash` 全字段覆盖回归测试矩阵(决策 6) | 真相字段任一变化 hash 改变;派生字段任一变化 hash 不变 |
| 1d-4 | 加固:CLI / debug observe 字段对齐;`mix migrate_to_pg` 不破回归 | CLI / observe 字段对齐 |

## 验收

- mix test 全 umbrella 全绿(scene_server / gate_server / data_service)
- 数据库存在 `voxel_chunks` 表与对应主键
- `put_snapshot` 写一次 → 同个 logical_scene_id/chunk_coord 再 `get_snapshot` 一致
- `put_snapshot` 在 chunk_version 单调递增/相等同内容/相等不同内容/旧版本四态返回正确 reply
- chunk_hash 全字段覆盖回归矩阵全绿
- 不破当前 1c 路径(Scene `apply_intent` → ChunkProcess persist → ChunkSnapshotStore.put_snapshot 这条线全程兼容)

## 风险

- **风险:Postgres 事务行锁可能撞上 advisory 锁/连接池上限**。1d v1 写 QPS 不高,但极端场景下 SELECT FOR UPDATE 会拖慢同 chunk 写。Phase 6 视实测改 advisory lock 或 conditional UPDATE 单语句版本。
- **风险:`mix migrate_to_pg` 旧任务可能仍假设旧 in-memory 路径**。需要排查并按需更新或留 RFC 在 1d 之外。
- **风险:`chunk_hash` 全字段覆盖矩阵把当前 chunk_hash 行为冻结**。如果 Phase 5/6 想给 chunk_hash 增加新字段(例如 attribute_set),会强制更新该测试。视为期望行为(测试是契约,改契约要走显式路径)。
- **风险:Windows 测试环境 Postgres 连接超时**。已在本会话验证 data_service 40 tests 通,假设环境稳定。

## 进度日志

- 2026-05-07: **1d 全程落地**(canonical 持久化 + chunk_hash 全字段覆盖回归)。data_service 40 → 41 tests, scene_server 247 → 265 tests, gate_server 181 tests, web_client 不动 210 tests, 全绿。
  - **1d-1 schema + 迁移**:`priv/repo/migrations/20260507000001_create_voxel_chunks.exs` 按协议设计 §11 落地;主键 `(logical_scene_id, coord_x, coord_y, coord_z)`;`schema_version`/`chunk_size_in_macro`/`micro_resolution` 用 `smallint`,`coord_x/y/z` 用 `int`,其余整型字段用 `bigint` + `>= 0` CHECK,`chunk_hash` 用 `bytea` + `octet_length = 8` CHECK。`DataService.Schema.VoxelChunkSnapshot` Ecto schema 与之对齐;changeset 校验 chunk_hash 字节长度 + 非负字段。
  - **1d-2 ChunkSnapshotStore 改 Repo 直写**:删 GenServer (start_link/init/handle_call),改为 stateless 模块。`put_snapshot/2` 在 `Repo.transaction(fn -> SELECT FOR UPDATE → INSERT/UPDATE/比较内容 end)` 内执行五态 CAS:inserted / updated / unchanged / stale_chunk_version / chunk_version_conflict。`get_snapshot/3` 改 `Repo.get_by`。`snapshot/1` CLI dump 改 `Repo.all`。
  - **Scene 调用点**:`ChunkProcess` 删 `:snapshot_store` opt,`persist_snapshot` 直接调 `DataService.Voxel.ChunkSnapshotStore.put_snapshot/1`。新加 `schema_version`/`chunk_size_in_macro`/`micro_resolution` 透传给 attrs。`ChunkDirectory` 同样删 `:snapshot_store` opt。`gate_server/stdio_interface.ex`/`voxel_smoke.ex` 把 `safe_snapshot(ChunkSnapshotStore)` 与 `apply(snapshot_store, :start_link, ...)` 改为 stateless module 路径。`DataService.Application` 从 supervision tree 删除 ChunkSnapshotStore 子进程。
  - **WriteTokenStore 测试 hatch**:加 `reset/1` 公共 API,test-only 注释。setup 块清 voxel_chunks + 重置 token store,使 async: false 测试可重复跑同 key。
  - **测试基础设施**:scene_server / gate_server 的 `test_helper.exs` 启动 `DataService.Repo` + 跑 `priv/repo/migrations`,assert_receive_timeout 调到 1000 ms 以容忍真实 Postgres INSERT 延迟。所有用 `start_supervised!({ChunkSnapshotStore, ...})` 的测试改为 setup `Repo.delete_all(VoxelChunkSnapshot)` + `WriteTokenStore.reset(WriteTokenStore)`,持久化测试切 async: false。
  - **1d-3 chunk_hash 全字段覆盖回归矩阵**:`scene_server/test/scene_server/voxel/codec_test.exs` 加 `chunk_hash 全字段覆盖回归 (Phase 1d)` describe。+18 用例:真相字段(logical_scene_id, chunk_coord 三轴, macro_header 的 mode/canonical_flags/payload_index/environment_index, normal_blocks 七字段, refined_cells.occupancy_words/boundary_cache, layers 七字段, object_refs 三字段, environment_summaries 六字段)→ hash 改;派生字段(chunk_version, dirty_bounds.min_macro/max_macro/reason_flags, chunk-level flags, macro_header 的 cell_version/cell_hash/transient flag bits)→ hash 不变。schema_version / chunk_size_in_macro / micro_resolution 因 `Storage.normalize!` 强制固定值,本矩阵不展开测试。
- 2026-05-07: 用户确认"全新系统不留兼容";决策 1-6 按"直接改第一版"路径定稿。计划稿入仓。
