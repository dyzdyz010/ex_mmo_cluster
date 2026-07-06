# GPT-5.5 LOD2/LOD3 远景方案评审 — 2026-07-06

> 状态：评审稿（未拍板）。评审对象：[`docs/design/20260706ue58_voxel_lod2_lod3_architecture.md`](../design/20260706ue58_voxel_lod2_lod3_architecture.md)（GPT-5.5 撰写的 UE5.8 体素远景 LOD2/LOD3 架构建议）。
> 评审基准：[`2026-07-05-voxia-voxel-lod-production-route.md`](./2026-07-05-voxia-voxel-lod-production-route.md)（已拍板生产路线）与冻结决策链（6-28 权威体素唯一真值 → 6-29 baseline=delta + W-3/W-8/W-11/S4 → 6-30 FarField 抽取 + D-10 → 7-01 SVO 3D + LOD 环 → 7-05 路线）。
> 证据方法：3 份 codex(gpt-5.5) 代码调研（客户端 SVO/FarField、服务端协议/数据源、WorldGen parity/baseline/近窗）+ 本机 UE 5.8 源码树实地核查（`D:\UE\UE_5.8`）+ 3 个 fable 对抗评审（数据源 steelman/裁决、LOD 预算数学、逐条采纳矩阵）。codex 报告关键结论均经 fable 抽查源文件核实（发现并纠正一处：客户端山地 octaves 实际与服务端一致，真实分歧仅 lowland 振幅 340 vs 150、mask 区间、客户端独有浮空岛）。

## 0. 总评

GPT-5.5 的方案是一份**对"传统 UE 开放世界 + 程序化体素"合格的通用架构文**，方向与本仓已拍板路线大面积重合——但它是**盲写**的：不知道本仓已有 FarField/SVO 资产（≈70% 构件已有等价物且本仓版本更严格），不知道已冻结的数据源/H gate/正交纪律。因此：

1. **不能按它的蓝图动工**（那等于重写一个已通过 23/23 automation + 真实 RHI smoke 的子系统，并反转已冻结的失败语义）；
2. **它的一个根本性主张（客户端 worldgen 为第一数据源）应拒绝**（见 §2 裁决）；
3. **它有 5 条真正的净增量值得吸收**（§5），其中"分带失效过滤"正中服务端侧的设计空白；
4. 本轮独立调研还发现了 **GPT 和现状文档都没有指出的三个高杠杆工程点**（§4：默认分级错配、RuntimeMesh O(N²) 全量重建、per-cell greedy merge）。

## 1. GPT 方案思路复述（公允版）

- 分层：LOD0(0-300m@1m) / LOD1(300m-1km@2-4m) / LOD2(1-4km@16m, region=4×4×4tile=448m) / LOD3(4-8km@64m, macro cell=8×8×8tile=896m)。
- 数据源：客户端本地 deterministic worldgen 采样低精度 mip + 服务端 compact diff 修正为主；服务端物化下发为"必要时"次选。
- 渲染：occupancy mip → shell extraction → greedy meshing → Runtime Proxy（UDynamicMeshComponent 原型 → 自定义 UPrimitiveComponent 正式）；稳定区域缓存为 StaticMesh/Nanite Stable Proxy（离线 build worker + CDN）；HLOD/WP/RVT/impostor 可选。
- 动态：EFarProxyState 8 态状态机；大事件走 Event Overlay（VFX + runtime crater 先行，真值 diff 后到，bake 最后）；小 diff 不触碰 LOD3。
- 服务端只管 seed/diff/snapshot/event/version，不管 UE 资产。

其中"服务端不管 UE 资产""远景 visual-only 无碰撞""后台构建分帧提交""小 diff 分带过滤"与本仓一致或正确；分歧集中在数据源优先级、空间容器单位、以及对 UE 能力边界与本仓工程纪律的缺失。

## 2. 数据源裁决（本次评审最重要结论）

**裁决：维持 2026-07-05 路线——预物化 SVO source pages 为唯一生产远景源；GPT 的"客户端 worldgen mip 采样为主"在当前状态是被禁路径，登记为满足可判定条件后的终态带宽优化。**

Steelman 后仍被推翻的关键依据（详细论证见评审工作产物，要点）：

| # | 论点 | 依据 |
| --- | --- | --- |
| A-1 | 客户端 WorldGen 已**故意** 3D 分歧（lowland 340 vs 150、mask 区间、浮空岛），parity 断言已显式移除；"把分歧压回 ulp 级"的唯一可执行契约就是 bit-exact fixture 工程本身，不存在更便宜的"approximately-exact" | `VoxiaWorldGenV1.cpp:16-42`、`VoxiaWorldGenV1AutomationTest.cpp:25`、`lib.rs:24-29` |
| A-2 | 6-29 **S4 过渡仲裁**锁死顺序：parity CI 未绿期间，远景一律以服务端下发为唯一真值源，二者不得同时驱动渲染；而 source_pages 正向闭环今天已真实 RHI 跑通 | 6-29 设计稿 :242；7-05 路线 §9 |
| A-3 | **釜底抽薪**：按 W-Q6=A 拍板，"2.5D 锁定、3D 归 delta"——浮空岛/洞穴/巨构这些远景里唯一值得看的 3D 内容终态来自设计师 delta，客户端 worldgen 只能重算最无聊的基底；"带宽∝修改量"里的修改量恰是全部亮点内容 | memory + `world_gen.ex:11` |
| A-4 | diff→mip 合并的正确性：远景 chunk 在 L0 窗外，客户端没有 1m confirmed truth，无法把 1m chunk delta 正确投影成 16m/64m occupancy——被修改区域**必然**退化为服务端 mip 物化下发（即 GPT 的"次选"本来就得建）；混合源还需要第二个跨端契约（mip 派生规则 bit-exact） | `codec.ex:147`、`outbox.ex:4` |
| A-6 | authored 世界单向不对称：pages 管线对未来 authored/真实地图原样可用（只换生产端输入）；worldgen 采样届时是死代码 | 元决策（6-30） |
| A-7 | 纪律冲突：采纳 GPT 等于把刚建好的"缺源硬失败、不回退本地噪声"契约反转 | 7-05 路线 §3/§6 + 负向 gate 实跑证据 |
| A-8 | pages 绝对成本不高：7m 叶 occupancy+material 压缩后 ~1-2KB/cell，radius=72 单 Y 层 ≈ 20-40MB；且服务端派生 pages **不需要**全量 1m 物化——未修改区用服务端自家 NIF `column_height` 按 mip 分辨率直采（单实现、无 parity 问题）⊕ 已修改 chunk 合并降采样。GPT"程序化重算胜过搬字节"的核心洞察被完整保留，只是重算放在只有一份实现的服务端 | — |

**客户端本地推导重启的可判定条件（全部满足才重启）**：① WorldGen 跨端 golden fixture CI 常绿 ≥ 一个发布周期（含双端消 `powf`、FMA 纪律、`worldgen_impl_version` 协商）；② 3D 内容归属重新拍板或测算"客户端可重算基底占远景视觉信息比例"；③ mip 派生规则跨端 fixture；④ 运行时 kill-switch 可整体切回 pages；⑤ 实测 pages 分发成本确实构成瓶颈（按 A-8 估算大概率不成立——这本身就是最诚实的判定）。

**source page 该装什么（填实现状空壳）**：**叶分辨率（7m）的降采样 occupancy + material mip，per macro-cell**。不是原始 chunk（71TB 问题）、不是 SVO 节点（服务端建树成本高且编码即协议、mesh 路径吃不动）、更不是 mesh（artifact 依赖 BoundarySignature 随玩家窗口位形变化，服务端不可能预发；raymarch 也吃不了）。14m/56m 由客户端整数降采样得到（天然确定，无 FP 问题）。该定义顺带修复 codex A 指出的"source_pages 不提供 runtime SVDAG truth 导致 raymarch-only 与 source_pages 不兼容"。

## 3. LOD 分级与预算（数学结论）

量化模型：quads/cell ≈ k×(112/L)²，k 用两个独立实测点标定（k=4.06/4.17，差 3%；2.5D 生产内容 k≈1.85，数字约减半）。radius=72 环内 cell 数：near(d2-8)=280、mid(d9-24)=2112、far(d25-72)=18624。

| 配置 | 分级 | 全场 quads | GPU 估算 | 判定 |
| --- | --- | ---: | ---: | --- |
| (a) 当前默认（samples=4+环8/24） | 近**和中环都 7m**、远 28m | 3.70M（=实测） | ~0.85GB | mid 环 2112 cells 在 7m 是全场 45% 的冗余 quads |
| (b) 路线目标（samples=2+环8/24） | 7m/14m/56m | 1.14M | ~0.25GB | **推荐基线**：每带 ≤(a) 密度，纯降本 3.2× |
| (c) GPT（4m/16m/64m） | — | 2.25M（2m 版 5.46M） | — | 4m 版可行但叶尺寸不在 112m 幂次格点上（16/64/4/2m 均不可表达，2m 需 depth5-6 超 clamp）；2m 版无 merge 不可行 |

**推荐：(b) 为基线 + 两个修正**（吸收 GPT 隐含的"带内边缘恒定 ~20px 角尺寸"准则）：
- 修正 1（+18% quads，立即可做）：d25-40 加第三环 depth2=28m，把 d24/25 处 14m→56m 的 4 倍跳变拆成两次 2 倍跳；
- 修正 2（greedy merge 落地后）：L0 边缘 collar d2-4 用 depth5=3.5m（需放宽 clamp 1..4→5），解决窗口边 7m@224m≈38px 的"巨块感"（代码注释自认的问题）。
- 同时把 **tier 升为显式一等契约**（config + observe + manifest 字段），替代现在 samples/ring 推导且 Transport 与脚本默认不一致的状态（codex A §2 缺口）。

## 4. 渲染侧工程排序（含 UE 5.8 源码核查结论）

UE 能力边界核查（在 `D:\UE\UE_5.8` 源码实地验证）：

- **Nanite 运行时构建 = 硬不可行**（NaniteBuilder 是 editor-only 模块；运行时 `UStaticMesh::BuildFromMeshDescriptions` 强制 fast-build 不产 Nanite 数据；Nanite Assembly 构建器整文件 WITH_EDITOR）。GPT 结论对但论据更硬：这是 API 边界不是性能取舍。→ Stable Nanite Proxy 只能走离线 build worker；**但先做 editor 手工烘焙 A/B 实验再决定是否建 farm**（对已按 LOD 环抽稀的远景壳，Nanite 固定开销未必赢）。
- **WP/HLOD 对本项目输入为空集**（纯运行时世界零静态 actor）——从方案中剔除。
- **RVT**：任何 Primitive 都可写（GPT 的前提之一其实错了），但它是 2D 平面投影缓存，与"远景摆脱 2.5D"方向冲突且远景顶点色材质无可缓存的昂贵混合——不用。
- **Impostor**：被已有 raymarch(SVDAG) 路线支配（10.7km@120FPS、逐像素视差/轮廓正确）——仅留作极远孤立浮空岛备胎。
- **关键发现（GPT 与现状都漏掉）**：UE5.8 `UDynamicMeshComponent` 已内建**静态 draw path**（`SetMeshDrawPath(StaticDraw)`，产 cached MeshDrawCommand）与分块局部更新（decomposition）；而当前 RuntimeMesh 后端的真实瓶颈是**单组件全量重建**：`ContinueSvoUpload` 每帧批次结束调 `RefreshSvoRuntimeMesh()` 从全部已积累 patch 重建整棵 `FDynamicMesh3` 再 `SetMesh`（`VoxiaWorldActor.cpp:2046-2049,1007-1026`），361 patch 流完 ≈ O(N²) ≈ 23 个全量 mesh 当量；(a) 规模单次全量重建 1.5-4s CPU + 1.3-1.9GB 瞬态——实测 min 42.8 FPS 尖峰主要来源。

**排序**：

| # | 工程 | 量化收益 | 成本 |
| --- | --- | --- | --- |
| 1 | 切默认分级到 (b) + 显式 tier 契约 | quads 3.7M→1.14M（−69%），GPU 0.85→0.25GB | 极低（配置+文档） |
| 2 | RuntimeMesh 按 patch 分组件（池化）+ `SetMeshDrawPath(StaticDraw)` + 按环分频更新 | 消除 O(N²) 流式重建与秒级尖峰；免费获得视锥剔除（单组件剔除率为 0，分组件典型可剔 50-70%） | 中（ProcMesh section 模式是现成参照） |
| 3 | per macro-cell masked greedy merge（`FVoxiaGreedyMesher` mask 路径已存在，近景在用；SVO 路径逐 leaf 面 EmitQuad 绕过了它） | quads 再 ÷2-4 → 全场 0.35-0.55M；**作用域限 cell 内**（跨 cell merge 会摧毁 artifact cache 粒度与 98.8% 移动复用率） | 中 |
| 4 | 顶点格式瘦身（现 424B/quad：双精度 FVector×2 + 3×FVector2D） | CPU/磁盘 artifact −50%；cache key 已含 renderer_artifact_version 可滚动 | 低-中 |
| 5 | 垂直稀疏多层 coverage：`VerticalRadiusTiles>0` 立方 cell + manifest per-column 占据层清单 + LOD 环距改 3D Chebyshev | 解锁浮空岛/高山远景（现运行时单 Y 带不可见）；quads +50-150%，#3 之后仍达标。拒绝"全 Y 柱 root bounds"方案（各轴同步二分致垂直分辨率隐性劣化 8×） | 中-高（含 manifest/H gate 口径） |
| 6 | LOD 环边界 skirt + 真跨 LOD seam check | 现 seam_check 不验证跨 depth 裂缝（codex A §4）；复用现有 skirt 常量 | 低-中 |
| defer | 自定义 UPrimitiveComponent/FPrimitiveSceneProxy | 顶点打包省 2-3× 显存、artifact 直传砍 FDynamicMesh3 中间态 | 触发条件：#2 做完后 hitch/显存仍是实测瓶颈 |
| defer | Nanite bake + build worker | 未验证收益 | 先做 editor 手工 A/B；farm/版本税/第二套缓存治理成本高 |

raymarch 维持路线拍板的 L4/AB 定位不变；其证据（radius=96 payload 仅 9.3MB、120FPS）支持把这条线保温——对本世界形态（3D 崖壁/浮空岛）它是渐近正确的超远距候选，升格仍以路线 §4.2 门槛为准。

## 5. 逐条采纳矩阵（16 条）

| # | GPT 主张 | 裁定 | 理由 |
| --- | --- | --- | --- |
| 1 | LOD 分层表 | 已有等价物 | 距离带/精度与 L0-L4 几乎重合（16m vs 14m、64m vs 56m）；侧面强化"tier 显式契约化"待办 |
| 2 | 448m/896m 空间容器 | 改造后采纳（低优先） | 远环放大 macro cell 有规模价值；448m 在现有 clamp(1..4) 内可配，896m 需解 clamp 并重做 cache key/boundary signature 语义 |
| 3 | 客户端 worldgen mip 为主源 | **拒绝**（过渡期）/登记终态可选 | 见 §2 |
| 4a | Shell extraction | 已有等价物 | `EmitSvoLeafSurface` 即六向暴露面测试，且多 skirt/浮岛底面 |
| 4b | greedy meshing | **采纳**（量化优化项） | 半个真缺口：octree 同质合并已承担大半，剩余在同深度 Mixed leaf 拼成的平坦面 |
| 5 | EFarProxyState 8 态 god-enum | 已有等价物（现有拆分更正交） | build/upload/suppression 三轨已覆盖 5 态；Event/StableCached/Replacing 等特性落地时再引入 |
| 6 | DynamicMesh→自定义 SceneProxy | 前半=现状；后半 defer 登记 | 触发条件=长巡航帧时间证据不达标（先吃 §4#2 的免费杠杆） |
| 7 | Stable Proxy Cache(RegionId+SnapshotVersion) | 已有等价物（本仓更严） | 本仓 cache key 七维版本；GPT 两维 key 是版本纪律倒退，且依赖不存在的服务端 SnapshotVersion |
| 8 | Event Overlay / MajorTerrainEvent | 推迟（概念登记） | 服务端无区域级事件广播；**0x6D/0x6E 已被 Tag/AttributeCatalogSnapshot 占用**，需新 opcode（0x76+）；权威载体应挂 field/emergence→ChunkProcess 链；玩法未到大事件阶段 |
| 9 | 分带失效过滤（小 diff 不进 LOD3） | **采纳（最有价值一条）** | 正中两端空白（客户端无 dirty 输入 API、服务端无区域级聚合）；须加两条本仓化改造：阈值判定在服务端权威侧 + 最终一致性上界（小 diff 累积/周期重派生仍失效，否则远景与真值永久漂移） |
| 10 | 渲染优先级阶梯+淡入淡出 | 改造后采纳（S5 同期） | fallback 必须限定"source 已验证、mesh 构建中"的时间窗，缺源仍硬失败 |
| 11 | WP/HLOD | 推迟（实为剔除） | 纯运行时世界输入为空集 |
| 12 | UE Build Worker + CDN | 改造后采纳（并入 S5） | bake 产物必须进既有 manifest/H gate 链，不另开无凭证渠道；先 A/B 实验 |
| 13 | RVT/atlas/texture array | 推迟 | 材质保真轨道，与 LOD 架构正交；RVT 模型不匹配 3D 远景 |
| 14 | 性能规则清单 | 大部分已满足 | 采纳 2 条为 S4 验收检查项：远景动态阴影策略断言、新旧 proxy 交叉淡入淡出 |
| 15 | MVP 六阶段顺序 | 拒绝顺序 | GPT=visual-first（先本地 worldgen 出画面），本仓拍板 authority-first 且 S1-S3 已实跑过半；采纳=回退 |
| 16 | 缺失面 | — | 见 §6 |

**净增量 TOP-5**：① 分带失效过滤契约（#9，写入 S2 服务端设计）；② Event Overlay 视觉先行模式（#8，未来大事件的正确心智模型）；③ 跨 leaf greedy meshing（#4b）；④ 自定义 SceneProxy 演进终点（#6，接缝已留好）；⑤ 远环放大 macro cell 容器（#2）。

## 6. GPT 方案缺失面（本仓硬要求、GPT 零覆盖）

H gate/基线硬失败；CLI 可观测先行与结构化验收（无一个 readiness 字段设计）；三入口覆盖；focus suppression/近远双显示契约；near-window 半开所有权契约；版本纪律（两维 key）；authored 世界兼容（整个数据源地基届时坍塌）；显式失败 vs 静默降级（其 fallback 阶梯默认掩盖缺数据）；系统正交（god-enum/god-struct）。

## 7. 窗口边缘→8km 的真实差距清单（下一阶段建议）

服务端（当前全部空白，是主要瓶颈）：
1. chunk delta → macro-cell dirty 聚合（挂 per-chunk outbox/commit 之后；含 #9 的分带阈值与最终一致性上界）；
2. `svo_source_pages_v1` 服务端 writer（page 派生 = 未修改区 NIF mip 直采 ⊕ 已修改 chunk 合并降采样；payload 按 §2 定义装 7m 叶 occupancy+material）；
3. `source_revision` / `diff_chain_hash` 的服务端真值（现只在客户端 fixture）；
4. 远景失效通知面（W-8 的落地；**注意 0x6D/0x6E 已被占用**，客户端 `-VoxiaInterestFarSyncOpcode` 适配层已就绪待分配）。

客户端：§4 排序表 #1-#6（分级切换、分组件上传、greedy merge、顶点瘦身、垂直多层、跨 LOD seam）+ 编辑→macro cell dirty 的输入 API（现 dirty 只是构建输出）。

工具链：launcher/offline 真实 source pages + 包内 artifact 生成（路线 §9 未完成清单第一条的具体化）。

## 8. 证据产物索引

- codex 调研三份：会话 scratchpad `codex_out_a/b/c.md`（客户端 SVO/FarField、服务端、WorldGen/baseline/近窗，均带 file:line）。
- UE 5.8 能力边界核查报告、数据源裁决、LOD 预算数学、采纳矩阵：见本次会话工作流产物（关键结论已内联本稿）。
- 实测锚点：`_session-handoff.md:32-37`（8km 3.7M quads / avg 69-85 FPS；radius=96 raymarch-only 120 FPS）、7-05 路线 §9（source_pages 真实 RHI 闭环）。
