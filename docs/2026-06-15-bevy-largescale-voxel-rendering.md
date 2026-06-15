# 大规模体素渲染 推进计划（2026-06-15）

/ goal：「客户端与服务端功能完全对齐 + 客户端架构合理 + **能够大规模渲染体素**」。单 chunk
（266 块 → 29 面）已 live + GUI 目视验证（见 `2026-06-15-bevy-live-integration-findings.md` §6）。
本文记录把它推到「大规模」所需的 grounded 改动，源自三面并行盘点（server seeding /
server streaming / client scaling）。

## 1. 盘点结论（grounded，已核实到 file:line）

### 1.1 服务器种子（无地形生成器）
- `WorldServer.Voxel.DevSeed.ensure_default_region/1` 目前只在 chunk (0,0,0) 写 16×16 平台
  （`seed_starter_platform/2`, dev_seed.ex:289）。仓库**无任何地形生成器**（无 perlin/noise/
  heightmap/程序化）。
- 多-chunk 必须**每 chunk 一次 `apply_intents`**：`ChunkDirectory.apply_intents` 硬约束单
  chunk，跨 chunk 返回 `:batch_cross_chunk_unsupported`（chunk_directory.ex:868）。
- 默认 region bounds `{-2,-2,-2}..{3,3,3}` 半开 = 5×5×5 = 125 chunk 容量。**5×5 水平平台
  （25 chunk）落在默认 region 内，无需改 region。** 所有 chunk 同 region 共享同一 lease，
  循环复用 `route.lease` 即可。

### 1.2 服务器流式订阅（能力够，被出口预算限速）
- 0x60 ChunkSubscribe → gate 连接进程同步把 L∞ radius 内 (2r+1)³ 个 chunk 逐个 subscribe，
  每个 ChunkProcess 立即回推一份 **~78KB 定长稠密 ChunkSnapshot**（恒编码 4096 macro 头，
  空 chunk 也推 version 0）。**radius 硬上限 = 4**（ws_connection.ex:23，最多 9³=729 chunk）。
- 真正限速 = gate Egress bulk token bucket：`@egress_capacity_bytes` 262144 B / `@egress_window_ms`
  100ms（~2.5MB/s），ChunkSnapshot 归最低优先 `:bulk_stream`，每 100ms 窗仅放行 ~3 个 78KB
  快照。radius1=27→~0.9s，radius2=125→~4.2s。
- **关键：`egress_capacity_bytes`/`egress_window_ms` 可经 app env 覆盖**（ws_connection.ex:90-91
  `Application.get_env(:gate_server, ...)`）→ 零代码放宽。

### 1.3 客户端渲染规模化（架构对，两处短板）
- 架构 OK：贪婪网格化 + per-chunk 单 `Mesh3d`（Bevy 自动算 AABB → 视锥剔除生效）+ 跨 chunk
  边界剔除 + dirty-set 增量。空 chunk despawn。
- **短板 1（首要）**：`render_dirty_chunks`（chunk_render.rs:73）在主线程**同步**重网格化，且
  take_dirty 把每个脏 chunk 的 6 个已加载邻居一并拉进重网格集（最多 7× 放大）。一批 snapshot
  同帧到达会卡帧。
- **短板 2**：`SUBSCRIBE_RADIUS` 硬编码 1（net/plugin.rs:104）；玩家移动无 AOI 跟随重订阅
  （标注 M3）；ChunkSubscribe.known 恒空 → 每次全量 snapshot。
- 离线 showcase（bootstrap_showcase + sync_voxel_visuals per-voxel cube）始终开。但它只 5×5
  **macro**（500 单位）= 相对 5×5 **chunk** 平台（8000 单位）是个小点，且拾取/相机避障仍只读
  `VoxelWorld`——故**本轮不动 showcase**，留作后续（拾取迁移到 authority 后再关）。

## 2. 本轮执行（LS-1..LS-4，逐 step commit）

- **LS-1（server）**：`DevSeed` 多-chunk 平台。加 `@platform_chunk_min/max`，`seed_starter_platform`
  改为循环每个平台 chunk 各一次 `apply_intents`（demo 电路仍只在中心 (0,0,0)）。默认 5×5 水平
  （chunk x,z ∈ -2..2，y=0）= 25 chunk × 256 cell。汇总 written/skipped/errors/max_chunk_version
  + chunk_count，保持 emit_terrain 形状。
- **LS-2（client）**：`render_dirty_chunks` 加**每帧重网格化预算**——dirty 入一个 pending 队列，
  每帧最多处理 N 个（默认如 8），其余顺延下帧。消除 burst 单帧卡顿（比全异步 threadpool 简单、
  低风险；真异步留作后续优化项）。
- **LS-3（client）**：`SUBSCRIBE_RADIUS` 1 → 2（覆盖 5×5 平台），并补**玩家跨 chunk 边界时
  按新 center 重订阅**（AOI 跟随，= M3），让大世界可随移动加载。
- **LS-4（撤销 — 不适用 TCP）**：原据流式盘点拟调大 `egress_capacity_bytes`。**核实后撤销**：
  egress token bucket 是 **WS(浏览器)专属**（ws_connection.ex），`tcp_connection.ex` 的
  `{:voxel_chunk_snapshot_payload}` handler（:290-301）**直接 send 到 socket、无任何限速**。bevy
  走 TCP，故 egress 配置对 bevy 无效。**bevy 的真实流式瓶颈 = `subscribe_voxel_chunks`
  （tcp_connection.ex:2494）的同步逐 chunk 循环**：(2r+1)³ 个 coord 在一个阻塞 handler 里逐个
  route + ChunkDirectory.subscribe（懒启 ChunkProcess + 编码 78KB 快照），快照经 send/2 进连接
  mailbox，**只能在 subscribe handler 返回后**才批量写 socket → radius 2（125 chunk，含 100 空）
  会先 stall ~数~十几秒再 burst。empty chunk 也照启 ChunkProcess + 编码（主要浪费）。
  → 改服务器订阅路径（异步/并行 subscribe、空 chunk 轻量化/跳过初始空快照）是 grounded 的服务器
  侧 follow-up，不在本轮（避免动 voxel authority 热路径）。本轮先实测 radius 2 实际耗时再定。

## 3. 验收

重启 server（重编译）→ reseed（多-chunk）→ 关 GUI 重建客户端 → headless probe：
`va-subscribe 1 0 0 0 2` → `va-status chunks` 增长到 25+（renderable≈25，total_quads 反映多 chunk
greedy 效率）→ GUI 目视一大片 5×5 chunk 地板。注意 PowerShell stdin 首行 BOM（已在 stdio reader
硬化，但驱动仍建议先发弃用首行）。

## 4. 留作后续（不阻塞本轮）

- 真异步 remesh（AsyncComputeTaskPool）+ inbox/store 背压与按距离 evict（r≥4 大订阅时需要）。
- 快照稀疏/压缩（治本降 78KB/chunk；协议变更，需 bevy decoder + golden fixture 同步）。
- 关离线 showcase + 拾取/相机避障迁移到 authority store。
- Resync 自动重订阅（authority_plugin 目前只 debug 日志）。
- region bounds 扩大 + 9×9 floor（radius 4 满订阅）作更大规模压测。
