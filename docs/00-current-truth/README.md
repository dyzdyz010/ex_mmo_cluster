# 当前唯一事实入口

> **本目录 = 五层文档结构中的 `00-current-truth`（当前事实·唯一权威）。** 想知道"现在到底是什么样"只信这里；上层文档地图与其它四层见 [`../README.md`](../README.md)。
>
> 本目录记录“此刻为真”的项目状态。日期型设计稿、阶段日志、handoff 和问题复盘仍保留在原位置，作为原始操作日志和证据源；读者需要判断当前状态时，优先读本目录。
> **形态约定（用体素术语）**：本目录 = snapshot（合并态投影），原始日期文档 = delta 库（事件历史），[source_index.md](source_index.md) = delta 库的索引。合并发生在写入时——本目录任何文档只呈现合并后的当前状态，不含改动记录。

## 文档治理模型

```mermaid
flowchart LR
  Raw["原始文档<br/>日期稿 / phase 日志 / handoff / 修复记录"]
  Analysis["治理分析<br/>取最新结论、排除过期假设、标明证据"]
  Current["当前唯一事实<br/>按功能模块维护"]
  Work["后续实现 / 验证"]

  Raw --> Analysis --> Current --> Work
  Work -- 状态变化后更新 --> Current
```

- **原始文档**：记录当时的设计、实现、验证和误判；不要求彼此一致。
- **当前唯一事实**：从原始文档和当前工作树归纳出的稳定状态；同一主题只在这里给一个当前答案。
- **维护原则**：新事实落地后更新本目录，并把新原始文档登记到 [source_index.md](source_index.md)。
- **冲突处理**：若原始文档与本目录冲突，以本目录为读者入口；原始文档保留为证据和历史上下文。

## 功能模块入口

| 模块 | 当前事实文档 | 主要职责 |
| --- | --- | --- |
| 文档治理与证据索引 | [source_index.md](source_index.md) | 原始文档归类、被取代结论、当前事实入口关系 |
| 服务端控制面 | [design/server/world-region-routing.md](design/server/world-region-routing.md) | World / Region / Scene / Chunk 关系、路由、租约、迁移、stale owner repair |
| 体素真值与基线 | [design/voxel/README.md](design/voxel/README.md) | 权威体素唯一事实源、WorldGen migration、launcher/入场校验、runtime diff 边界 |
| 客户端可操作区域 | [design/voxel/client_active_region.md](design/voxel/client_active_region.md) | 近场可编辑窗口、订阅跟随、debug overlay、点击生效条件 |
| 客户端流式与远景 | [design/client/streaming-lod.md](design/client/streaming-lod.md) | Voxia 近/远渲染、heightmap LOD、tile 口径、远景缺口 |
| 局部场与涌现 | [design/field/runtime.md](design/field/runtime.md) | FieldLayer / FieldRegion / FieldKernel / FieldRuntime / FieldSource / FieldEffect 状态 |
| 正交涌现系统 | [design/emergence/orthogonal-systems.md](design/emergence/orthogonal-systems.md) | 材料属性向量、光、化学、结构、客户端外观边界 |
| 建设 / Prefab / Surface | [design/voxel/building-prefab-surface.md](design/voxel/building-prefab-surface.md) | 建设原语、Prefab transaction、Object provenance、SurfaceElement |
| 实现状态速查 | [impl/README.md](impl/README.md) | 当前代码边界、主模块路径、默认验证入口 |
| 已知缺口 | [impl/known_gaps.md](impl/known_gaps.md) | 当前明确未完成、待设计或待验证项 |

## 当前最高层事实

1. **服务端权威优先仍是全局铁律**：移动、AOI、战斗、体素、object state、field truth 均以服务端 authority 为准；客户端只能预览、呈现或发 intent。
2. **体素确认态只来自服务端权威结果**：在线客户端确认态只能吃 `ChunkSnapshot` / `ChunkDelta` / `VoxelIntentResult` / `ObjectStateDelta` / `FieldRegionSnapshot`。
3. **体素基线校验必须硬失败**：进入场景前必须校验本地 world pack、region manifest、chunk baseline 和 diff chain；缺包或 hash 不匹配不能靠运行时 snapshot/resync 兜底进入场景。
4. **World/Scene/Gate 边界清晰**：Gate 负责协议 decode、鉴权、连接状态和转发；World 负责 region/scene 路由、租约、事务和迁移控制面；Scene / ChunkProcess 拥有 chunk hot truth 与 field runtime；DataService 保存 canonical persistence。
5. **WorldGen 只允许是纯 3D migration/materializer**：公共目标契约是 `chunk_xyz -> canonical 3D chunk`，不得向 streaming、LOD、cache 或 renderer 暴露 heightmap、column、terrain-only 或 `Y=0`。Voxia P1 已完成隐藏 cube-shell、canonical source 与 v2 XYZ page 契约；P2 已落六向 occupancy/material mip、精确逐材质 surface、全有或全无 shell staging，以及不读取顶点 UV 的独立 Real-RHI adapter/preview。所有新链仍 `live_enabled=false`，live WorldGen/source-pages 列路径仍是明确待迁移缺口。
6. **Voxia UE 客户端是当前真实客户端联调焦点**：近场交互、远景 LOD、debug overlay 和 stdio CLI 的最新实跑证据集中在 `clients/Voxia/docs/`；仓库级默认 parity 仍要求关注 `clients/web_client`，Bevy 仅作参考实现。
7. **局部场 Phase 7 已进入运行时扩展阶段**：温度、电导、电热、热烟、闭合电路、电介质击穿等第一批能力已形成可操作入口；source owner 存活、预算消耗、batched effect、跨 chunk 大范围编排和 Phase 8 结算仍未完成。
8. **当前文档治理不移动原始文档**：日期文档和阶段文档仍保留为操作日志；本目录负责把它们演进成当前状态。
9. **体素数据链路已拍板投影路线终态（2026-07-06）**：客户端是 snapshot-only 消费者——近窗 1m 投影（`0x62/0x63`）+ 远区 7m 投影（source pages）；配方（`base ⊕ overlay`）不跨 wire，客户端 WorldGen 永久定位 dev preview / fixture 源，同构路线（客户端本地推导）降格为特定负载画像下的定向优化选项。远景生产分带定为 L1-L3 四环 7/14/28/56m + collar，L4 defer。术语口径（base / delta / overlay / truth / snapshot）以 [`docs/30-reference/protocol/glossary.md`](../30-reference/protocol/glossary.md) 为准，裁决全文见 [`docs/30-reference/contracts/2026-07-06-projection-route-final-decision.md`](../30-reference/contracts/2026-07-06-projection-route-final-decision.md)。

## 维护规则

- **snapshot 纪律（硬性）**：本目录只保存合并态。禁止按日期追加「YYYY-MM-DD 更新 / 补充 / 后续更正」式叙事条目；新事实直接**改写**正文对应段落，旧表述被覆盖而非并列。决策与事实允许携带日期属性（如「2026-07-06 拍板」），但日期不得作为条目的组织方式。演进过程、逐日证据、被覆盖的旧状态一律留在原始日期文档（delta 库），由 source_index.md 指路。
- 新增模块事实时，先加到本页模块表，再落对应子文档。
- 子文档必须写“当前事实 / 证据源 / 被取代结论 / 后续缺口”。
- 文档内涉及流程、所有权、阶段边界时使用 Mermaid 图解释。
- 不把截图或单次视觉观察当唯一证据；需要对应 CLI、日志、代码路径或阶段文档。
