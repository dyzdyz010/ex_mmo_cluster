# 当前已知缺口

本文档是当前缺口的合并态 snapshot,不含改动记录;已完成能力见 impl/README.md 与各模块状态文档,演进过程与证据见原始日期文档(source_index.md 索引)。

## 服务端控制面

- **SceneNodeRegistry HA**：缺容量感知 failover 与自动迁移完整方案；stale owner repair 不能覆盖多节点容量调度和故障切换语义；实施载体为服务端控制面 HA 专项，触发条件是跨节点 scene failover / 容量调度验收。
- **Subscription liveness**：缺服务端自维护订阅活性、自动续租、超时与重连闭环；该缺口会让客户端无操作时的 lease / 订阅隐式失效；实施载体为订阅 worker / Gate-World-Scene 契约收口。
- **大范围 region/materialization 调度**：缺异步背压、预算、跨节点调度和可观测队列深度；没有这些约束，大范围物化会与在线 scene 运行争抢资源；实施载体为 materialization scheduler / region routing 专项。

## 体素 baseline / launcher 与包管理

- **8km 生产权威源覆盖与物化调度**：缺 d72 / 8km 生产 source pages 的权威覆盖、bounded materialization 和 delta dirty 调度；客户端 fixture / smoke 不能替代真实服务端 source；实施载体为里程碑 C（C1 pages writer、C2 dirty 聚合与 mip 基准、C3 失效通知与 HTTP 分发），覆盖规模参考 `macro_cell_count=21016`。
- **生产持久化 artifact**：缺服务端或离线管线生成的 source pages / mesh / SVDAG artifact 持久化、`source_revision` / `diff_chain_hash` 与容量淘汰策略；没有它，H gate 无法覆盖生产包版本更新和重拉；实施载体为里程碑 C2/C3。
- **launcher/update 包下载安装 UI 与 diff-chain 流程**：缺包下载、安装、hash 校验、region manifest/index、diff chain 完整校验和可诊断 UI；缺这条链路会使 baseline 入场硬校验停留在本地包或脚本层；同时缺 T-12 的 required-set 差集下载、热度驱动推荐预置集（全沙盒下热点为运行时涌现）、传送 gate 补拉与 shard 粒度分级（热区小 shard / 冷区大 shard）；实施载体为里程碑 C4。
- **runtime diff channel/priority/budget**：缺运行时 diff 的通道、优先级、预算和最终一致性策略；当前 snapshot 仍可能承担 bulk 数据来源；实施载体为服务端 dirty / outbox 设计收口。
- **32km / 稀疏 chunk / 地图导入调度**：缺完整 32km 生产生成预算、稀疏 chunk 策略、真实地图导入 migration 与完整 dirty/rebuild scheduler；缺口会影响从 demo pack 走向生产 world pack；实施载体为 world-pack materialization 与 data_service 派生表专项。
- **material 生产端派生**：缺 7m material mip 的服务端派生函数与一致性验证；现有 NIF 只导出 `column_height` / `heightmap_region`，无 material 函数，无法产出 C1 所需的 material 众数 payload；实施载体为里程碑 C1。

## Voxia 近远景渲染

> **里程碑 A（客户端渲染正确、零服务端依赖）进行中**：A1 / A2 / A3b 已收口，A4 收尾中。下面按里程碑列**当前剩余**缺口（已完成项与详细进度见 [`voxel-server-authority-phase-overview.md`](../../10-active/cross-cutting/voxel-server-authority-phase-overview.md) 与各 `phase-vlod-*` 稿）。截至 2026-07-08。

- **A1（显式 tier 契约 + 四环 7/14/28/56m 分带）✅ 已完成**（2026-07-06）：`-VoxiaSvoLodRings` 显式契约落地，8km quad 3.70M→1.39M（−62%），per-ring 锚点全命中。
- **A2（分组件 `UDynamicMeshComponent` + `StaticDraw` + 组件级剔除 + bulk-hide）✅ 已完成**（2026-07-07，8 次真实 RHI 实测）。
- **【归因反转·重要】8km device-removal 真凶已查明并修复**：A2 曾把 8km 默认 Lumen 崩溃归因为"远景几何 overdraw 超 TDR"，并据此把 merge 定为根治手段。**2026-07-07 A3.0 诊断在完整重启 + 干净 GPU 数据下证伪了该归因**——真凶是 far-mesh-go-live 路径 raymarch probe dispatch × proxy-mesh go-live 的 **GPU 跨队列时序竞态（潜伏 UB）**，与 overdraw / quad 数量 / 渲染后端 / Lumen 全部正交（`r16`=0.49M 与 `r72`=1.39M 同样崩）。**修复 = raymarch 默认关**（`clients/Voxia@1fc93d2`，`ShouldEnableSvoRaymarch()`→false），采纳为生产终态；8km facing + 默认 Lumen 稳态**已无 device-removal**。将来重启 raymarch（L4 超远景）前必须先根因修复跨队列 barrier/fence，不可依赖当前二进制布局的偶然掩盖。
- **A3b（per-cell masked greedy merge，重定位为纯几何/带宽优化）✅ 已完成**（2026-07-07）：quad 1.39M→593k（−57.3%），视觉等价（覆盖面积守恒 + seam 不回归），4 次真实 RHI 0 device-removal。附带远景默认材质由 Unlit 改 **Lit** 消色差（`-VoxiaSvoFarUnlitMaterial` 降为逃生门）。
- **A4（跨 depth 覆盖性 seam / 换环 fade / L1 collar）🔄 收尾中**：Step0（目视基线；高空"破洞"判定为机位假象非 bug）、Step1（跨 depth 覆盖性 seam 断言）、Step2（L1 3.5m collar，opt-in 非默认）、backlog A（远场逐面贴壁真材质 + 顶面地表化）已完成（2026-07-08）。**下一步 = A（光照）**：查远景竖直侧面为何偏暗——材质修复后近/远色差观感未变，真因转向光照/LOD（粗 LOD 竖直崖壁收不到 Lumen 天光方位补光），非材质。**仍缺**：Step3 换环 cross-fade、Step4-5 A5 顶点瘦身 + cache LRU、Step6 8km 长巡航 A 验收（收官）。
- **A5（远景顶点格式瘦身 424→~210B/quad + persistent cache LRU/容量上限）尚未开工**（并入 A4 Step4-5）。
- **真 7m mip page payload 与客户端 pages 真消费管线**：缺 `svo_source_pages_v1` 中真实 7m occupancy/material payload、page decode、7m→14/28/56m 规约降采样、按环建树和从 pages 构建 SVDAG payload；现状 page 仅作为 hash gate 输入，渲染仍吃预物化 artifact；实施载体为里程碑 B2/B3。
- **垂直稀疏多层 + 3D 环距 + near-skip 3D 化**：缺 manifest 占据层清单、3D Chebyshev ring distance 和按 L0 覆盖 Y 层裁剪的 near-skip；没有它，垂直玩法会出现整柱误裁或远景真空；实施载体为里程碑 B5。
- **长巡航与生产门槛验证**：缺跨至少 8 tiles 的 8km 长巡航、per-ring quad/内存预算断言、截图审计与长期帧时间分布；实施载体为里程碑 A 验收（A4 Step6）。**注**：远景 FPS 已实测为**像素-bound 非三角形-bound**，Lumen 全屏 GI（关掉 +36~40FPS）是最大单一 FPS 杠杆；旧的"overdraw 物理约束致 FPS 门槛不可达"口径已不成立。
- **heightmap LOD material palette**：缺 catalog 驱动的 material palette；当前 0x6B material section 已被 Voxia decode 并按顶点色表现，但材质色仍非 MaterialCatalog 驱动；实施载体为 LOD material 表现专项（不阻塞里程碑 A）。
- **raymarch 升格与 Nanite bake**：均为 defer，不是生产缺口。生产远景 renderer 已拍板为 L1-L3 SVO leaf-surface mesh + 分组件 DynamicMesh StaticDraw；raymarch 仅保温为 d≤72 AB profile / L4 候选（触发条件与门槛见 [`2026-07-05` 路线 §4.2](../../30-reference/overview/2026-07-05-voxia-voxel-lod-production-route.md) 与 [`2026-07-06` 设计 §3.3](../../30-reference/overview/2026-07-06-voxia-lod-layering-and-technology-design.md)）；Nanite 渲染/烘焙后端 defer（运行时构建 UE5.8 API 级不可行，离线 bake 触发条件为 editor 手工 A/B 数据显著）。

## 客户端-服务端 wire 契约

- **focus hydrate / promote 服务端契约**：缺正式 opcode 分配、服务端租约、权限、长程命中和 hydrate payload 生成；客户端 wire 边界与 outbox 生命周期已就绪但不能替代服务端 authority；实施载体为待服务端契约，需避开既有 `0x60` / `0x62` / `0x63` 语义。
- **far visual sync 服务端契约**：缺 request/result opcode、低频 visual map / SVO payload 生成和端到端 projection 更新策略；没有服务端 payload，客户端 `far_visual_sync_body_v1` 只能做配置或 loopback 验证；实施载体为里程碑 C3 与 T-11 HTTP page 分发语义。
- **remote-action 服务端契约**：缺 action request/result opcode、技能 authority、租约/权限/长程命中规则和 authoritative result frame；客户端 pending / retry / ACK 只能证明生命周期，不代表服务端接受或拒绝；实施载体为待服务端契约。

## 远程实体与对象 AOI

- **远程实体 AOI**：缺服务端远程实体 AOI 规则、兴趣分发和真实服务器帧接入；客户端 remote actor store / loopback 不能证明在线 AOI 正确；实施载体为服务端 AOI + interest contract。
- **对象 AOI 与 ObjectStateDelta body**：缺服务端对象 AOI / 兴趣分发规则，以及属性 / tag patch body 的正式 wire layout；当前 `0x6C` state flags 与调试 payload 不足以承载完整对象状态；实施载体为对象 wire layout 与服务端分发规则。
- **正式表现资产与大规模 proxy 调参**：缺远程 actor / object 的正式资产、材质细化、特效和生产规模调参；当前 static proxy / HISM 只验证确认态读模型与渲染提交；实施载体为 Gameplay / Art 集成。

## 局部场 / 涌现

- **FieldSource 生命周期**：缺 generic persistent FieldSource owner 存活探测、预算消耗、自动续租和跨 chunk lifecycle；缺口会让场源活性依赖外部隐式假设；实施载体为 FieldSource owner / lease 专项。
- **FieldEffect dispatcher batch mutation**：缺 batch mutation dispatcher；单 tick 多次 version bump / fan-out / persist enqueue 会放大写入和广播成本；实施载体为 FieldEffect dispatcher。
- **Phase 8 effect 边界**：缺 ignite / freeze / melt / damage / object / combat / source effect 的统一 dispatcher；没有统一入口会让 field kernel 绕过 authority 写回边界；实施载体为 Phase 8。
- **电路与材料物理**：缺完整电路仿真、材料熔断破坏和 tick-by-tick 能量扣减；当前局部场不能表达深层涌现玩法；实施载体为电/热/材料专项。
- **SurfaceElement runtime**：缺 SurfaceElement 物理参与、客户端完整渲染/解码和 delta 专用 op；缺口会让表面态无法进入权威 runtime 与客户端表现闭环；实施载体为 SurfaceElement protocol/runtime。
- **Prefab/object field participant projection**：缺 prefab / object 统一 field participant projection 覆盖；对象与局部场仍不能稳定互相影响；实施载体为 object-field projection。
- **深半导体 C4b**：缺二极管 / 三极管完整玩法和物理模型；该能力需要专门设计，不能由现有导电简化规则自然推出；实施载体为 C4b 专项设计。

## 客户端 / 验证治理

- **当前事实文档维护**：缺随代码变更同步更新 `docs/00-current-truth/**` 的稳定流程；缺口会让 snapshot 再次退化成改动记录或过期状态；实施载体为 PR / checkpoint 文档纪律。
- **三客户端验收角色区分**：缺持续在 PR / 验收中区分 Web parity oracle、Voxia 实跑焦点和 Bevy 参考实现；混用角色会误把单客户端证据当协议唯一真值；实施载体为验收说明模板与协议改动检查。
