# 当前唯一事实入口

> **Voxim 当前主线**：同级 Voxim 为当前客户端，Voxia 仅作参考；[M1 现行边界](../10-active/movement-sync/2026-09-08-voxim-m1.md)以 Voxim 的 starter/plan/brief 为路线权威。Session/Voxel byte SSOT 已抽到纯 mmo_contracts；31 个 G0 fixture 不变。新 Movement、authority、QUIC 与 bootstrap runtime **待实施**，没有旧移动兼容义务。下列 Voxia/SceneHost/RuntimeMock 细节仅描述参考实现，不构成 Voxim 当前生产路径或 M1 验收。



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
| 客户端流式与远景 | [design/client/streaming-lod.md](design/client/streaming-lod.md) | Voxia 唯一根、完整 XYZ、Near/Far Patch-diff、唯一 SceneHost ledger、阶段 2 宏格挖放与阶段 3 Prefab RuntimeMock；Online provider 后置 |
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
5. **完整 3D 是体素流式与 LOD 的唯一现行空间契约**：公共契约是 `chunk_xyz -> canonical 3D chunk/page`，near 为 XYZ cube，far 为稀疏 cube shell；不得向 streaming、LOD、cache 或 renderer 暴露 heightmap、column、terrain-only 或 `Y=0`。Voxia 的 near XYZ 与 Pure3D far 已在唯一开发根 live；Online authority production cutover 仍未开始，隔离 probe 不等于第二生产路径。
6. **Voxia 参考实现已切到其唯一 Near/Far Patch-diff 架构并合入独立仓库 `master`**：
   `-VoxiaWorldGenPreview` 只启动 `AVoxiaUnifiedVoxelWorldActor` / `production_all_features` 根，
   正式 Editor/Game 地图唯一为 `/Game/Voxia/Maps/L_VoxiaProductionWorld`，默认 `RuntimeMock`；
   Online 仍显式 fail-closed。Root 分开维护 requested/live `FVoxiaPatchTargetKey`、可见发布优先级、
   派生 readiness 与单槽 Near source 激活租约。普通连续移动每个 XYZ 轴只能推进一 tile，
   当前 handoff 完整前后继 Near source 必须 deferred（Far 对预测下一 tile 的投机预构建不等这把
   租约，只构建不发布）；只有调用方显式声明的 `explicit_relocate`
   可以直达完整目标，禁止按距离猜意图。Transport 只有取得 Root 实际授予中心后才激活
   required Near，Root 又只在 Transport active/required Near 与请求目标一致后发布 TargetKey。
   Near 固定 `4³ chunks` Patch，Far 固定 `8³ tiles` Patch；SceneHost ledger 是 live Patch、exact
   ownership、boundary、seam、component 与 fence 的唯一事实。Far metadata handoff 只等待
   manifest 已消费与 producer terminal，不等待 speculative mailbox 清空；当前事务按 PatchId
   取件，取件帧 yield、次帧才启动 presentation transaction。Far、26-slot 外壳、真实
   `LayerFace` 及逐 live-Far 精确凭证原子提交。相邻换区保留旧 live target/Far；共享 Near
   Patch 先发布新旧 chunks 并集，精确 Far 接管后再收窄到严格 9261 chunks。SceneHost 持续
   维护 Near 完整性和 renderer coverage，`playable`、`handoff_complete`、`settled` 分离。
   移动安全门同时读取最后完整 Near 与活动 Patch target：完整 Near 外最多 3 chunks，活动
   target 只约束 handoff 滞后轴，第 4 格阻断，返回/沿边放行。Far 后台复用只接受提交账本中的
   完整 Patch version，且只允许 `AdjacentStep`；会清空 live ledger 的 Bootstrap/Relocate 必须重建。
   2026-08-03 Phase 3 树通过 clean Development build、Automation `213/213`（`0` failed/not-run；
   `1` 条 success-with-warning 仅为外部 `generate_204` HTTP 超时）、Node `124/124`、
   35 路完整 Phase 1、Phase 2 与 Phase 3 `18/18`；
   58 次 source acquisition 的普通移动最大单轴步长为 `1`，572 个 renderer transition sample
   的 gap/overlap/orphan 均为 `0`。1280×720 Real-RHI 连续两轮通过，末轮 frame p95=
   `7.692/7.692ms`、GT p95=`2.485/2.542ms`、GPU p95=`2.750/2.699ms`、Far release=`29/29/0`，
   未放宽门槛。Phase 3 又完成 1920×1080 可见短路线与 30 分钟真实连续 XYZ 流送：34 个
   往返样本的 confirmed prefab 资源 current 零漂移，coverage/seam/`LogVoxia Error` 均为 0，
   exact micro raycast/collision 均值为 `39.676/10.578µs`。更多硬件、Online authority 与 B/C
   尚未开始。
   **当前可见性口径**：2026-07-27 用户实跑曾确认 Near/Far 层间墙空间语义错误。架构已改为真实 `LayerFace`，并修复跨 Far Patch 分界跳过、退场旧 Near 污染新目标分界，以及目标轮换提前丢失 live-Far 凭证；最新完整 Real-RHI 结构化路线通过。由于用户尚未在 2026-08-03 合并树上重新做可见判断，该视觉项仍标记为“待人工复验”，不能只凭 slot、组件、fence 或 `gap=0` 宣布视觉关闭。
7. **Voxim 是当前主线，Voxia 为参考，Web / Bevy 已逻辑归档**：默认客户端设计、实现、联调与进度判断以 Voxim 阶段证据为准；以下阶段 2/3 为 Voxia 参考结果；归档目录只保留历史证据，只有用户显式点名时才临时纳入。阶段 2 普通宏格交互、Far LOD 外露材质归约/最终 ownership 与阶段 3 Prefab RuntimeMock 已 closeout；阶段 3 具备 immutable catalog/Orientation24、层级 instance/coverage、原子 place/remove/replace、Near/Far presented snapshot、CLI/observe、资源与 CPU 门禁。它不表示 Online wire/authority 或 Prefab Designer 已实施；Online 生产化仍需独立服务端设计与实施。
8. **局部场 Phase 7 已进入运行时扩展阶段**：温度、电导、电热、热烟、闭合电路、电介质击穿等第一批能力已形成可操作入口；source owner 存活、预算消耗、batched effect、跨 chunk 大范围编排和 Phase 8 结算仍未完成。
9. **被取代的 XZ column 设计统一进入 `docs/20-archive/**`**：它们可以保留历史证据和 append-only decoder 测试，但不能继续留在 current/default/launcher/CLI acceptance 路由。
10. **Online 客户端仍是 snapshot/delta-only 消费者，离线 Mock 也保持 adapter 边界**：近窗消费 canonical chunks，远区消费 XYZ source pages/cube shell；Phase 2 点击只发 intent，Mock authority 私有裁决后以类型化事件驱动唯一 confirmed mirror，presentation 不能回写 truth。旧 0x6A/0x6B heightmap、VHI 与 v1 column source 只保留协议历史兼容，不是生产终态。
11. **运行时根事实与文档根事实同样唯一**：参数可单独验证子系统，但只有一个包含全部已批准成果的组合根可以承担联合调试和效果验收。任何新成果未接入该根、未通过根级 readiness/CLI 前，只能写成 probe/地基；开发根通过也不能冒充在线 authority cutover。
12. **Voxia 的唯一正式场景组合资产是 `L_VoxiaProductionWorld`**：UDS、UDW、雾、后处理、补光和有界完整 XYZ LOD 预览直接保存在关卡并可由 UE 编辑器调整；`ScenePresentationSubsystem` 校验并维护显式引用，校验通过后 Flow 才动态创建唯一运行时根。editor preview 不进入 confirmed truth、cook、root readiness 或 SceneHost ledger；旧 `Lvl_NearWindow` 只允许显式 headless/probe。

## 维护规则

- **snapshot 纪律（硬性）**：本目录只保存合并态。禁止按日期追加「YYYY-MM-DD 更新 / 补充 / 后续更正」式叙事条目；新事实直接**改写**正文对应段落，旧表述被覆盖而非并列。决策与事实允许携带日期属性（如「2026-07-06 拍板」），但日期不得作为条目的组织方式。演进过程、逐日证据、被覆盖的旧状态一律留在原始日期文档（delta 库），由 source_index.md 指路。
- 新增模块事实时，先加到本页模块表，再落对应子文档。
- 子文档必须写“当前事实 / 证据源 / 被取代结论 / 后续缺口”。
- 文档内涉及流程、所有权、阶段边界时使用 Mermaid 图解释。
- 不把截图或单次视觉观察当唯一证据；需要对应 CLI、日志、代码路径或阶段文档。
