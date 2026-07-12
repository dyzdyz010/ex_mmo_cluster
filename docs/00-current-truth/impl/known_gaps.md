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
- **material 生产端派生**：缺服务端 `chunk_xyz -> canonical dense material page` 的纯 3D 物化与一致性验证；现有 NIF 只导出 `column_height` / `heightmap_region`，仍是待退役高度场接口。客户端隐藏 v2 page/mip 只能作为消费 oracle，不能替代 C1 服务端 writer。

## Voxia 近远景渲染

> **旧里程碑 A 的性能/组件化子项已收口，但“客户端渲染正确”结论已于 2026-07-12 重新打开**：A1 / A2 / A3b / A4 / A5 与 8km 长巡航数据仍有效；live WorldGen `SurfaceMaterialId` 特判和非 generation 级原子呈现仍是缺陷。±8km 半精度绝对 UV 拉伸已通过“每 quad 减整数纹理周期”的共享 near/far 契约修复，保留 wrap 相位与 greedy；这只是旧 live 材质的正确性修复，不代表纯 3D cube-shell 已切流。新纯 3D P1 已完成；P2 hidden pages/mip/exact-surface/staging 与独立世界对齐 Real-RHI preview 已落。

- **A1（显式 tier 契约 + 四环 7/14/28/56m 分带）✅ 已完成**（2026-07-06）：`-VoxiaSvoLodRings` 显式契约落地，8km quad 3.70M→1.39M（−62%），per-ring 锚点全命中。
- **A2（分组件 `UDynamicMeshComponent` + `StaticDraw` + 组件级剔除 + bulk-hide）✅ 已完成**（2026-07-07，8 次真实 RHI 实测）。
- **【归因反转·重要】8km device-removal 真凶已查明，raymarch 最终禁用**：A2 曾把 8km 默认 Lumen 崩溃归因为"远景几何 overdraw 超 TDR"，并据此把 merge 定为根治手段。**2026-07-07 A3.0 诊断在完整重启 + 干净 GPU 数据下证伪了该归因**——真凶是 far-mesh-go-live 路径 raymarch probe dispatch × proxy-mesh go-live 的 **GPU 跨队列时序竞态（潜伏 UB）**，与 overdraw / quad 数量 / 渲染后端 / Lumen 全部正交（`r16`=0.49M 与 `r72`=1.39M 同样崩）。默认关闭后，8km facing + 默认 Lumen 稳态已无 device-removal；2026-07-10 显式 real-RHI 复核又在 dispatch/readback 成功后触发 D3D12 3D/Compute 队列超时。当前拍板是 raymarch 严格不用，现行验收不得传入任何 `VoxiaSvoRaymarch*` 参数。
- **A3b（per-cell masked greedy merge，重定位为纯几何/带宽优化）✅ 已完成**（2026-07-07）：quad 1.39M→593k（−57.3%），视觉等价（覆盖面积守恒 + seam 不回归），4 次真实 RHI 0 device-removal。附带远景默认材质由 Unlit 改 **Lit** 消色差（`-VoxiaSvoFarUnlitMaterial` 降为逃生门）。
- **A4（跨 depth 覆盖性 seam / 换环 fade / L1 collar / 8km 验收）✅ 已完成**（2026-07-08）：cross-fade、collar、覆盖性断言和长巡航验收均收口；2026-07-10 又补了 removed patch 延迟提交，未来大范围 coverage 翻转也不会先清空旧远景。
- **A5（远景顶点格式瘦身 + persistent cache 卫生）✅ 已完成**：紧凑格式已达约 91B/quad，worldgen shape 入 cache key，LRU/容量上限/孤儿清理已落地。
- **v2 page 到 live mesh 的真消费切流**：隐藏 `voxia_voxel_source_pages_v2` 已能 decode 完整 XYZ dense material lattice、构建六向 material mip 和精确逐材质 surface，并对小型 cube-shell 全有或全无 staging；但 live `svo_source_pages_v1` 仍只是 hash gate，渲染仍吃预物化 artifact。仍缺按环 mesh 输入、增量失效、live coverage 切换和删除 WorldGen `SurfaceMaterialId` 分支。
- **大世界 UV 与材质采样**：`M_VoxelWorldAligned` + 局部 DynamicMesh 的独立调试链已在 ±8km Real-RHI 可见通过，证明材质侧世界坐标路线可行；near PMC、生产 far、dither、透明与发光变体仍使用旧 UV/材质链。必须先补齐这些变体和同点 near/far audit，再切生产默认，不能只替换一条 opaque 稳态路径。
- **generation 级原子呈现**：现有 removed-patch 延迟退役和 fade 只保证局部/最终收敛，尚未把 near/far/mask 与 render fence 绑定为同一 generation 原子 commit；连续帧中间态闪烁仍未关闭。
- **垂直稀疏多层 + 3D 环距 + near-skip 3D 化**：缺 manifest 占据层清单、3D Chebyshev ring distance 和按 L0 覆盖 Y 层裁剪的 near-skip；没有它，垂直玩法会出现整柱误裁或远景真空；实施载体为里程碑 B5。
- **长期性能分布**：A4 Step6 的跨 tile 8km 长巡航、per-ring 预算与截图审计已完成；2026-07-11 near-only 1600x900 uncapped Real-RHI 两次干净复测已补逐帧环形统计：9261 chunks 数据 ready=`1779.9-1862.4ms`，加载至完整 near mesh 的均值 `131.230-135.272 FPS`、p95=`9.907-10.208ms`，稳态 10 秒均值 `136.012-138.634 FPS`、p95=`9.743-9.969ms`，稳态均无 `>16.67ms` 帧。相邻 3087-chunk slab 预取=`429.7ms`，跨 tile 激活/清理窗口平均 `134.279 FPS`、p95/p99/max=`10.211/11.545/15.257ms`、component reused=`256`。这关闭了“near 冷加载十几 FPS”和 near 跨界复用未验证的旧缺口，但 near-only 不能代表最终世界：同日完整 near+far、Lumen/硬件光追可见实跑的首窗 near/SVO data build=`2778.2/9157.1ms`，361-patch 上传=`3504.9ms`，收敛后 12 个样本平均 `106.0 FPS`、范围 `98.3-109.9 FPS`；首次上传极值 `113.69ms / 8.8 FPS`，82-patch 增量更新附近仍有 `30.15ms / 33.2 FPS`。因此完整环境 120+ 与跨 tile SVO 分位数、长时段和更多硬件档位仍是明确缺口，不能承诺所有帧都在 120 FPS 以上。远景 FPS 当前实测为**像素-bound 非三角形-bound**，Lumen 全屏 GI（关掉 +36~40FPS）仍是最大单一稳态 FPS 杠杆。
- **远景时序稳定与无缝流送（Phase 0/1 + Phase 2 前三切片 + Phase 3 near 预取/热路径已落地，整体未收口）**：换环 fade 已去除 `DitherTemporalAA` 的逐帧噪声并加入 `svo_visual_stability`；patch-native cache、dirty-boundary seam、默认取消 aggregate mesh / 无用 runtime SVDAG，以及 dirty macro-cell 与受影响 patch 聚合的并行任务均已落地。8km 跨 tile SVO build 从原始 `135948.497ms` 降到 `2015.912ms`（约 `-98.5%`）；第三切片同构 patch update 从 `113.545ms` 降到 `72.751ms`（约 `-35.9%`），82-task 聚合段为 `43.941ms`。WorldGen preview 已按速度预取相邻 3087-chunk slab；本轮又落地列高复用、有界 producer/apply、compact confirmed full-chunk、per-chunk PMC、settled revalidation 小预算、具备退出 join 的有界 observe writer、SVO reuse artifact COW store 与 `frame_perf`。decoder/store 同时硬拒绝越界 `macro_index` 与超过 4096 项的 snapshot，性能优化未放松 authority 边界。剩余实施项是稳态 77% TSR shimmer 定量归因、patch/DynamicMesh 真正离开 GameThread、SVO outer coverage hysteresis 与 validated sharded artifact pack。阶段真值见 [`phase-far-temporal-stability-and-seamless-streaming.md`](../../10-active/voxel-far-field/phase-far-temporal-stability-and-seamless-streaming.md)。
- **heightmap LOD material palette**：缺 catalog 驱动的 material palette；当前 0x6B material section 已被 Voxia decode 并按顶点色表现，但材质色仍非 MaterialCatalog 驱动；实施载体为 LOD material 表现专项（不阻塞里程碑 A）。
- **raymarch 不再是 backlog**：生产远景 renderer 已拍板为 L1-L3 SVO leaf-surface mesh + 分组件 DynamicMesh StaticDraw；2026-07-10 用户进一步拍板 raymarch 严格不用，因此 L4/raymarch 不再作为候选、A/B profile 或待办。旧路线中的 defer/触发条件仅为历史记录。Nanite 渲染/烘焙后端仍 defer（运行时构建 UE5.8 API 级不可行，离线 bake 触发条件为 editor 手工 A/B 数据显著）。

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
