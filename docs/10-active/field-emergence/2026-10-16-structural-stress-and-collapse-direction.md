# 结构应力、支撑与塌方（建筑 + 地形）方向稿

状态：方向稿；**全局最低优先级**，其它主线收口后才进入实施；未实施，未写代码  
日期：2026-10-16  
归属：`field-emergence`（Phase 8 物理现象中的“结构完整度”，见
[`2026-05-16-phase8-physical-phenomenon-system-architecture.md`](2026-05-16-phase8-physical-phenomenon-system-architecture.md)）

关联：热模拟常驻原生拓扑（`apps/voxel_region/README.md` 2026-09-30 段）、
Prefab 宏格与 Designer 内核（[`../cross-cutting/2026-09-21-prefab-macro-cells-design.md`](../cross-cutting/2026-09-21-prefab-macro-cells-design.md)）、
保护区（`VoxelRegion.Protection`）、散体休止（R8-07 `loose_threshold_units`）。

## 1. 目标

1. **大世界中真实的建筑与地形塌方**：挖空支撑、烧毁承重、超跨悬挑都会按材料强度失稳，
   自然地形（岩体顶板、土体悬崖）也参与，不默认锚固。
2. **蓝图约束**：画蓝图 / Prefab 时即给出结构合理性评估；**结构不可行的蓝图只能是草稿，不能发布**，
   让建筑形态回到真实建筑学（柱、梁、拱、扶壁），杜绝“漂浮城堡”“单柱托大平台”。
3. 不改变既有 World 单 owner 事务、日志、复制与冷回放契约。

非目标：连续介质有限元、实时刚体碎片物理、动力学（地震波、冲击波传播）。

## 2. 现有基础（本仓事实）

- 尺度：1 macro = 1 m³，内部 8³ micro（12.5 cm）；L1 结构网格分辨率 16（`MmoContracts.Voxel.Structure`）。
- 材料目录已有 `density_kg_m3`（当前仅客户端显示重量，服务端不读）、`max_hp_per_macro`；
  热模拟按温度扣 HP，燃烧木屋已有逐位等价场景。
- 热模拟已验证的运行时模式：种子展开活跃域 → Rust NIF 常驻拓扑与动态值 → 逐步消息、步间让出
  World 邮箱 → 结果按事务提交 → 等价性摘要 + 基准。结构求解完全沿用这一模式。
- `World.Production` 已有局部 `:unsupported` 判定；散体材料已有休止阈值流动，可承接碎屑。

## 3. 业界依据与取舍（AGENTS.md §2.2.8）

| 依据 | 内容 | 本项目取舍 |
|---|---|---|
| Valheim 支撑传播（社区实测，官方未公开数值；[gamever 汇总](https://gamever.io/knowledge-base/why-your-valheim-build-collapsed-stability-support-and-the-numbers-behind-it)、[Cornerstone mod](https://thunderstore.io/c/valheim/p/VentureValheim/Cornerstone/)） | 支撑值从地面向外传播，每件按材料的竖直/水平损失衰减，低于下限即坍塌；石材水平损失 1/1 | 作为 S1 层：廉价、可增量，表达“材料决定最大悬挑”；数值只作量级参考 |
| 7 Days to Die（[wiki: Structural Integrity](https://7daystodie.wiki.gg/wiki/Structural_Integrity)、[Max Load](https://7daystodie.wiki.gg/wiki/Max_Load)） | 每块 Max Load / Mass 决定每侧能挂多少质量，横梁在多柱间分担 | 证明“质量 + 承载”在大规模多人沙盒里可玩；本项目用物理单位（kg、Pa）取代无量纲 |
| Livesley 1978 刚体块极限分析（Int. J. Numer. Methods Eng. 12:1853–1871；后续综述见 [WCEE2012](https://www.iitk.ac.in/nicee/wcee/article/WCEE2012_4233.pdf)） | 砌体视为刚体块，接触面只受压 + 摩擦，平衡可行性归结为线性规划；摩擦使问题非凸，工程上迭代 LP | 作为 S3 层蓝图评估内核；摩擦用线性化锥或迭代 LP |
| Whiting, Ochsendorf, Durand 2009, *Procedural Modeling of Structurally-Sound Masonry Buildings*, ACM TOG 28(5)（[PDF](https://people.csail.mit.edu/ewhiting/resources/pubs/WhitingOchsendorfDurand-09.pdf)） | 砌体的可行性取决于几何与静力平衡而非应力；线弹性理论区分不了可行与不可行的拱；用平衡 LP 驱动程序化建筑参数到可行 | 直接对应“蓝图约束”：Designer 用同一可行性度量给出评分与不可行位置 |
| Hoek–Brown 2002（[Hoek, Carranza-Torres, Corkum](https://www.eoas.ubc.ca/courses/eosc433/lecture-material/2002-HoekBrownCriterion.pdf)） | 岩体强度由完整岩单轴抗压强度与 GSI、mi、D 折算 | 地形材料目录的强度参数按此折算（离线算成每材料常量），运行时不跑非线性准则 |
| Barton Q 系统（Span/ESR 等效跨度；NGI Q-method handbook） | 无支护开挖的稳定上限是岩体质量与等效跨度的关系 | 岩体顶板的“最大无支撑跨度”按材料给常量，用于地形塌方的快速判定 |

原创部分（须实施前再报告）：把以上方法拼成“分层判定 + 运行时与蓝图同一内核”的组合，以及第 5 节的地形“生成即平衡”假设。

## 4. 方案：分层判定，同一内核

| 层 | 方法 | 管什么 | 运行位置 |
|---|---|---|---|
| S0 连通 | 改动点出发的有界 BFS / 并查集，判是否仍连到锚（基岩层或已判稳定的地形） | 悬空岛 | 每次编辑，同步、微秒级 |
| S1 支撑传播 | Valheim 式按材料竖直/水平衰减；地形岩体用“最大无支撑跨度” | 悬挑、顶板跨度 | 脏区增量，原生侧 |
| S2 承载流 | 每格重量（密度 × 实占体积）为源、锚为汇，边容量 = 材料抗压/抗剪强度 × 两格间 micro 实接触面积；最大流 < 总重即失稳，最小割给出失效面 | 细柱托重顶、压溃 | 脏连通分量，原生侧、步进提交 |
| S3 刚体块平衡 LP | Livesley / Whiting 式只受压 + 摩擦平衡 | 拱、扶壁、倾覆 | 蓝图/Prefab 设计时与按需评估；运行时不跑 |

关键不变量：**运行时判据不得比蓝图判据更严**——通过蓝图评估的建筑放置后不得自行坍塌。
实现上 S0–S2 的材料常量与 S3 共用一份目录字段，S3 可行 ⇒ S2 可行须有测试矩阵覆盖（拱、悬挑、单柱平台、倒金字塔）。
S2 不表达力矩，悬挑交给 S1；拱在 S2 中靠斜向接触传力近似，若出现“S3 判可行而 S2 判塌”的反例，以放宽 S2 为准。

耦合（涌现来源）：
- 热：强度按温度折减并乘 HP 比例；`Thermal.flush` 写回 HP 跨阈值时把该格标脏。
- 采掘 / 放置 / 液体：编辑提交即标脏；液体静水重量计入 S2 源。
- 坍塌结果：失效集合作为一笔 World 事务提交——格转为散体碎屑沿列下落、复用散体休止流动；
  落点下方角色走既有身体伤害入口。日志记录结果而非求解过程，冷回放不重算。
- 他人建筑（暂定，见 §7.2）：玩家编辑的 `prepare_intent` 先做 S0/S1 预判，失效集合含他人放置格
  （`placed_by` 溯源）时拒绝该编辑（如 `:would_collapse_foreign`），而不是让他人建筑违反物理地悬空；
  火、液体等非玩家直接动作引起的失稳照常坍塌。保护区内同理，越界部分不允许被动失稳。

## 5. 大世界可扩展性

- **地形“生成即平衡”（已定，必须）**：上线世界必须处于稳定态。worldgen（`voxim_worldgen`）生成后跑一遍确定性
  稳定化：S0–S2 判失稳的自然格按材料改为散体并沉降到休止，再迭代至无失效。稳定化是生成的一部分，
  随 `GeneratedStore` 区域缓存与内容版本走，结果逐位确定；区域生成带 halo（≥ 材料最大跨度），
  保证相邻区域独立生成后边界一致。验收：任意生成区域上运行时求解器零失效。
  运行时只有编辑形成的脏区才求解，成本正比于编辑活跃体量，与地图面积无关。
- **影响半径有界**：脏区按材料最大跨度向外扩展到有界范围（岩体按 Q 系统跨度常量，建筑按 S1 衰减上限），
  超过分量上限（初值 64k macro，基准后定）分块求解，块边界取保守判定。
- **不占 World 邮箱**：求解在独立进程 / dirty NIF，World 只接收失效集合并提交，沿用热模拟逐步消息模式。
- 量级估算（未实测，待基准）：S0/S1 单次编辑亚毫秒；S2 一万格分量约毫秒级、十万格约数十到数百毫秒；
  一栋房 400–800 格，一个村约 4 万格。

## 6. 阶段（全部排在其它主线之后）

- P0：材料目录字段（`compressive_strength_pa`、`shear_strength_pa`、`horizontal_loss`、`max_unsupported_span_m`，
  `density_kg_m3` 改为服务端读取）与参数发布兼容规则；S0 + 碎屑坍塌。
- P1：S1；`prepare_intent` 放置预警；客户端稳定度叠加层。
- P2：S2 + 热/液体耦合；燃烧木屋坍塌、挖地基两个基准场景。
- P3：S3 蓝图评估，接入 Prefab 发布判据：`Prefab.publish_one/2` 的 `diagnostics.publishable` 增加结构可行性，
  不可行只能留在草稿（`Prefab.Draft` / 草稿预览返回失效位置与利用率供 Designer 标注）。
  评估假设蓝图落在刚性地基上；放置时仍由运行时 S0–S2 按实地地基判定。
- 地形稳定化随 P0 一起做（上线前置条件），不晚于第一次启用地形塌方。
- 每阶段须有：纯算法单测、真实 World 回放等价、基准（照 `thermal_fire_benchmark_test.exs`）。

## 7. 决策

1. **已定**：结构不可行的蓝图只能是草稿，不能发布。
2. **暂定（用户倾向“不能”，未最终确认）**：玩家动作不得导致他人建筑坍塌，按 §4 在 `prepare_intent` 预判拒绝。
   未决：火灾蔓延、液体、无主建筑、公会共有建筑是否同样保护；预判须同步完成，S2 若太慢只用 S0/S1 预判。
3. **已定**：上线世界必须是稳定态，生成时做确定性稳定化（§5）。
4. **已定要做表现，形式未定**：服务端只发权威结果——坍塌事件（失效集合、S2 最小割给出的断裂面、
   各碎屑的落点与落地时刻，按 seq 与几何事务同序），客户端据此表演，最终状态以几何事务为准。候选形式：
   a. 按宏格沿列下落的简单动画（便宜、与权威落点一致）；
   b. 客户端按断裂面切块，用 UE Chaos Geometry Collection 做纯表现的刚体碎裂，结束时淡出并对齐权威几何；
   c. 先 a 后 b 渐进。另需决定：粉尘/音效、落地前的“预警”（裂纹、掉渣）是否由服务端在失效前若干步给出。

## 8. 进度日志

- 2026-10-16：方向稿；用户定为全局最低优先级。
- 2026-10-16：用户答复 §7：不可行蓝图仅草稿；倾向不波及他人建筑（暂定）；上线世界须稳定态；碎屑要表现、形式待定。
