# 体素真值、基线与运行时 Diff 当前事实

> 当前唯一事实文档。它覆盖“世界是什么”的事实源、客户端基线校验、启动器/入场/运行时三阶段边界。

## 当前最高层原则

**权威体素数据是服务器生命周期里的唯一事实源。**

- WorldGen 噪声只应作为一次性 world-seed migration，开发期用于灌入权威 store。
- 真实地图导入未来应作为同层 migration，灌入同一个权威 store。
- chunk 服务、远景 LOD、raycast、碰撞、远程交互都应只读或派生自权威体素。
- 派生物必须显式维护一致性，例如编辑后 dirty LOD mip，而不是依赖“源不会变”的隐式假设。
- **客户端是 snapshot-only 消费者（2026-07-06 投影路线终态）**：配方（`base ⊕ overlay`）只在服务端内部使用，跨 wire 的一律是投影（近窗 1m `0x62/0x63` + 远区 7m source pages）；客户端 WorldGen 永久定位 dev preview / fixture 源。术语口径见 [`glossary.md`](../../../voxel-server-authority/glossary.md)，裁决见 [`2026-07-06-projection-route-final-decision.md`](../../../voxel-server-authority/2026-07-06-projection-route-final-decision.md)。

## 当前世界事实模型

当前世界不应把“运行时可读布局”本身当成唯一不可恢复事实。长期权威恢复模型为：

```text
world(seq=N) = world_snapshot(seq=K) + committed_voxel_events(K+1..N)
```

其中：

- `world_snapshot` 是可校验的世界快照。最初版本可以来自 immutable world pack / baseline pack；后续应由定期 compact 生成新的 checkpoint snapshot。
- `committed_voxel_events` 是服务端裁决后已经提交的体素事实事件，而不是客户端原始 intent。它必须能按序 replay，或者已经被后续 checkpoint 覆盖。
- 运行时可读布局、近场 hot chunk、LOD projection、客户端本地窗口缓存都是 `snapshot + events` 的物化结果或派生索引。它们可以为运行时读写优化，但不能成为唯一不可恢复事实。
- 服务端向客户端 ACK 成功前，必须保证对应 voxel event、事务结果或等价 checkpoint/snapshot 已 durable；否则崩溃后会丢失已经确认给玩家的世界变化。

```mermaid
flowchart LR
  Pack["immutable baseline pack<br/>content_version / hash / index"]
  Checkpoint["periodic world checkpoint<br/>snapshot seq=K"]
  Events["committed voxel events<br/>K+1..N"]
  Runtime["runtime read layout<br/>hot chunks / region index"]
  Derived["derived stores<br/>LOD projection / client window cache"]

  Pack --> Checkpoint
  Checkpoint --> Runtime
  Events --> Runtime
  Runtime --> Derived
  Runtime --> Scene["Scene / ChunkProcess authority runtime"]
  Scene --> Events
```

恢复和修复规则：

- 如果损坏的是运行时布局、hot cache、LOD projection 或本地 active-window cache，可以删除后从最近 checkpoint 加后续 events 重建。
- 如果损坏的是 checkpoint / baseline pack / committed event log，则属于权威数据损坏，不能用运行时 snapshot 或客户端缓存静默修复。
- 定期 compact 的目标是把 `old snapshot + many events` 压成新的 checkpoint，并记录 event high-watermark；旧 events 可以归档，但不能在 checkpoint 验证完成前丢弃。
- 初始 world pack 与后续 checkpoint 在逻辑上都是 `world_snapshot`，差别只是初始包面向分发安装，checkpoint 面向减少恢复 replay 成本。

## 三阶段边界

```mermaid
flowchart LR
  Launcher["启动器 / 更新阶段<br/>world pack / 大体素补丁"]
  Lobby["入场前阶段<br/>账号 / 角色 / manifest 校验"]
  Scene["场景运行时<br/>runtime diff / semantic diff"]
  Reject["拒绝进入<br/>诊断错误"]

  Launcher --> Lobby
  Lobby -- baseline 校验通过 --> Scene
  Lobby -- 缺包/hash 不匹配/diff chain 断裂 --> Reject
```

当前设计要求：

- 大体素包、广域重写、全量 tile 更新不进入 scene runtime 热路径。
- 本地 `world pack / region manifest / chunk baseline / diff chain` 必须在进入场景前校验。
- 校验失败视为客户端数据不可被信任，必须拒绝进入场景。
- 禁止用运行时 `ChunkSnapshot`、resync、自愈逻辑或静默兜底绕过基线校验。
- 进入场景后只流送已验证基线之上的 runtime diff、语义 diff、prefab/object/event diff。

## Tile 预算口径

生产流式预算已经冻结如下：

| 单位 | 定义 |
| --- | --- |
| chunk | `16×16×16` macro cell，边长 `16m`，共 `4096` cells |
| tile | `7×7×7` chunks，边长 `112m`，共 `1,404,928` cells |
| 近场窗口 | `27 tiles = 3×3×3 tiles = 9,261 chunks = 37,933,056 cells` |
| 跨 tile 边界新增 | 若旧窗口保留，只新增一片 `3×3 = 9 tiles` |
| 穿过一个 tile 时间 | 按 `6m/s`，约 `18.67s` |

该口径已拍板冻结：“同步数据量可能很大”不作为当前缺陷的默认解释，不能提前当作可操作区域不刷新或编辑无效的主因；只登记为后续风险。实际碰到吞吐瓶颈时，必须先用 observe/CLI 统计 `tiles_changed`、`chunks_changed`、`ops`、`bytes`、`encode_ms`、`send_queue_bytes` 再针对性设计。

该口径的独立决策记录见
[`docs/plans/2026-06-28-voxel-tile-budget-runtime-diff-decision.md`](../../../plans/2026-06-28-voxel-tile-budget-runtime-diff-decision.md)。

## 当前实现与目标的差异

| 主题 | 当前实现/状态 | 目标事实 |
| --- | --- | --- |
| 近场 chunk truth | Scene / ChunkProcess 持热 truth，server snapshot/delta authoritative | 保持 |
| 远景 LOD 数据源 | `0x6A` 默认读取 `LodHeightmapStore` 持久化 projection；chunk snapshot 写入同事务 upsert projection；已有显式 `LodProjection.Rebuilder`；开发/demo bootstrapper 可触发 projection rebuild；`WorldPackBootstrapper` 可按显式 chunk bounds 生成真实 WorldGen pack；缺 cell 显式失败 | 补齐 launcher 包管理、material/top surface 和完整 dirty/rebuild 调度 |
| WorldGen 噪声 | 默认关闭，仅保留显式 dev opt-in / migration helper；Voxia 新增 `-VoxiaWorldGenPreview` 仅作本地可见预览，不进入生产 H gate/authority 验收 | **服务端单实现**确定性生成器（NIF），承担服务端懒物化与未来 pages writer 未修改区直采；**跨端 bit-exact 目标已关闭**（2026-07-06 投影路线终态：客户端不再重算 baseline）；客户端 C++ 副本永久定位 preview/fixture 源 |
| chunk runtime materialization | `ChunkProcess` 生产默认只接受持久化 snapshot / provided storage；缺失、损坏或 store 不可用会启动失败并 emit `voxel_chunk_materialization_failed`；`DefaultRegionBootstrapper` 开发/demo 默认通过 `DevSeed` 写 starter chunk snapshots 并 rebuild LOD projection；`WorldPackBootstrapper` 可在启动/部署阶段写真实 WorldGen snapshots；测试/dev 可显式 `missing_chunk_policy: :empty` 或 `worldgen: [enabled?: true]` | 懒物化 + 确定性重算；未修改 chunk 不落 snapshot，靠 WorldGen+H 恢复；见 baseline 边界决策 |
| 客户端 baseline | 入场前强校验 + 服务端 ready manifest + UE 本地随机访问 pack 加载已接入；`-VoxiaWorldGenPreview` 可跳过 pack 只生成本地预览世界 | **客户端 snapshot-only（2026-07-06 终态）**：launcher/update 传已验证投影包（近窗 world pack + 远区 source pages）+ H 凭证，运行时增量走 0x62/0x63（近窗）与 pages HTTP 拉取（远区）；"seed+maps+D+H 本地重算"目标已关闭，同构路线仅存为定向优化选项（五条件 + 负载画像） |
| **baseline 形态与流送边界** | **当前处于全量物化过渡**（WorldPackBootstrapper/shard 装 chunk payload）；新边界决策已定待迁移 | **确定性 WorldGen + 设计师 delta D + hash 凭证 H**；storage ∝ 修改量；见 [2026-06-29 baseline 边界决策](../../../voxel-server-authority/2026-06-29-voxel-baseline-streaming-boundary.md) |
| runtime snapshot | 当前订阅路径仍会发 snapshot | 长期只作为已验证基线上的正常权威同步之一，不允许当 baseline 兜底 |
| 当前世界恢复模型 | 当前已有 canonical chunk snapshot、runtime delta 和持久化 projection 的局部能力，但 checkpoint + committed event log 尚未形成统一恢复链 | `world_current = latest checkpoint + committed voxel events after checkpoint`；运行时布局是物化视图，可重建但 ACK 前必须 durable |

## 被取代的旧结论

| 旧结论 | 当前事实 |
| --- | --- |
| 客户端可以只拿 seed 自生成远景基线 | 被真实地图/权威 store 方向取代；客户端不应持第二真值 |
| 远景 heightmap 可长期按运行时噪声生成 | 已诊断为平行真值缺陷，后续改派生 mip |
| 缺 chunk 可静默跑噪声 fallback | 已废止：正式运行时缺块启动失败并输出 `voxel_chunk_materialization_failed`；噪声/空 chunk 只能显式 dev/test opt-in |
| baseline 缺失可 snapshot/resync 自愈 | 必须拒绝入场，不允许兜底 |
| 运行时布局就是唯一不可删事实 | 运行时布局应是 `checkpoint + committed voxel events` 的物化结果；只有 checkpoint/event log 等 durable truth 完整时才允许删除并重建运行时布局 |
| 只靠初始压缩母包即可恢复当前世界 | 只能恢复初始世界；玩家造成的当前世界变化必须来自 committed event log 或后续 checkpoint |
| 客户端长期应 seed+maps+D+H 本地重算 baseline（同构路线，6-29/6-30 原计划） | 2026-07-06 投影路线终态：客户端 snapshot-only（近窗 1m + 远区 7m 双分辨率投影）；配方留服务端（懒物化仍是服务端存储目标）；同构路线降格为"处女地基底本地生成"定向加法，五条件 + 负载画像全命中才评估 |

## 证据源

- [`AGENTS.md`](../../../../AGENTS.md)
- [`docs/2026-06-28-权威体素唯一事实源-噪声降为migration.md`](../../../2026-06-28-权威体素唯一事实源-噪声降为migration.md)
- [`docs/2026-06-28-体素世界与远景渲染-当前真相(整合).md`](../../../2026-06-28-体素世界与远景渲染-当前真相(整合).md)
- [`docs/current_status/impl/2026-06-29-world-pack-streaming-handoff.md`](../../impl/2026-06-29-world-pack-streaming-handoff.md)
- [`docs/plans/2026-06-28-voxel-tile-budget-runtime-diff-decision.md`](../../../plans/2026-06-28-voxel-tile-budget-runtime-diff-decision.md)
- [`docs/2026-06-25-voxel-world-production-architecture.md`](../../../2026-06-25-voxel-world-production-architecture.md)
- [`clients/Voxia/docs/2026-06-28-streaming-window-follow-fix.md`](../../../../clients/Voxia/docs/2026-06-28-streaming-window-follow-fix.md)
- [`docs/voxel-server-authority/2026-06-29-voxel-baseline-streaming-boundary.md`](../../../voxel-server-authority/2026-06-29-voxel-baseline-streaming-boundary.md)
- [`docs/voxel-server-authority/glossary.md`](../../../voxel-server-authority/glossary.md)
- [`docs/voxel-server-authority/2026-07-06-projection-route-final-decision.md`](../../../voxel-server-authority/2026-07-06-projection-route-final-decision.md)
- [`docs/voxel-server-authority/2026-07-06-voxia-lod-layering-and-technology-design.md`](../../../voxel-server-authority/2026-07-06-voxia-lod-layering-and-technology-design.md)
