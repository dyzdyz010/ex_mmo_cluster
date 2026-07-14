# 世界单元形态分类法 + 表面元件层(2026-06-17)

讨论拍板稿。给"游戏世界里一个单元能有哪些形态"立一套**正交分类法**,并据此决定新增形态——
**表面元件(surface element)**——的归属与数据模型。配合正交物理系统线(S1–S5)与"大规模渲染体素"
主目标。本稿是形态轨的 north star,**先成文、不实施**,排期与 S5 物理线由用户定先后。

> 产物来源:3 路并行 Explore(宏/微格+邻接、prefab+object/part、线协议下行)交叉核验现状 + 与用户两轮
> 共识(2026-06-17)。

> **实施进度(2026-06-17,服务器侧数据+wire 层已通)**:
> - **M1** `SurfaceCatalog`(类型表 append-only:rust_decal/frost/scorch/torch/lever + 面 ordinal)。commit 74394a3。
> - **M2** `SurfaceElement` struct + `Storage` 面槽旁路(put/get/clear/list,**零 occupancy 不变量**)。commit 64107dd。
> - **M3** `ChunkProcess` 权威 ops(put/clear/surface_element_at + bump 版本 + 重快照;活进程级零 occupancy)。commit e2a71b9。
> - **M4** wire `0x08 SurfaceElements`(append-only 可选段,仅非空发射,空 chunk 字节/hash 全等向后兼容;codec round-trip)。commit beb34aa。
> - scene 全量 1071/0(golden 不破)。**留作下游**:M5 物理参与(ParticipantProjection 面级)、golden fixture、ChunkDelta 专用 op、S4 皮相化(本轮不动 S4)。当时列出的 Bevy/Web 渲染+解码器计划只作归档历史；现役客户端落地必须在 Voxia 另行设计和验收。

## 1. 形态分类法:两条正交轴 + 两个叠加层

不枚举"方块/prefab/贴面/火炬"这类零散形态,而是把形态拆成正交维度——**每个具体形态是维度空间里的
一个点**(同 S1–S4 把行为拆成正交系统的哲学)。

**轴 A —— 绑定基底(几何上"长在哪")**:
- **(V) 体积填充**:占据 cell,参与邻接/碰撞/遮挡/面剔除。
- **(S) 表面绑定**:贴在某 cell 的**面**上,**零体积、不影响邻接**。← 本稿新增。
- **(F) 自由脱网**:世界坐标实体,不绑网格(debris/掉落/怪)。← 未来。

**轴 B —— 布置粒度(自由度)**:宏格对齐(粗) / 微格对齐(细) / 连续(自由实体)。

**叠加层 1 —— 逻辑身份**:terrain(匿名 truth) vs object(ObjectRegistry 持逻辑状态 + 多 part + 跨 chunk)。
**叠加层 2 —— 物理参与**:由**材料属性向量派生**,每系统独立开关(S1–S4 铁律),与基底/粒度正交。

现有 + 新增形态在空间里的位置:

```
                  微格对齐(细)              宏格对齐(粗)
体积填充(V)   →   微格 prefab               宏格 solid block
表面绑定(S)   →   [不做:微格自由贴面]        表面元件(单宏格面)   ← 新增
自由脱网(F)   →   ——                        ——(未来:debris/掉落/怪)
```

**对称**:`宏格块 : 微格 prefab = 表面元件 : (被砍掉的微格自由贴面)`。用户拍板**砍掉表面层的微格细粒度
(D-1)**,故表面元件只剩"单宏格面"一档。

## 2. 现状(3 路 Explore 交叉核验)

| 形态 | 状态 | 实质 / 关键文件 |
|---|---|---|
| 宏格 macro cell | ✅ | 1m³,16³=4096/chunk,三态 empty/solid/refined;`storage.ex`/`macro_cell_header.ex` |
| 微格 micro cell | ✅ | refined 内 8³=512,bitmask + MicroLayer;`refined_cell_data.ex`/`micro_layer.ex` |
| 微格 prefab | ✅ | Blueprint(v2 occupied_slots)→ PrefabRaster → 微格 + owner provenance,world-micro 锚 + 4 旋转;`blueprint_catalog.ex`/`prefab_raster.ex` |
| Object/Part 层 | ✅ | ObjectRegistry 持逻辑态(health/flags/covered_chunks),几何靠微格 owner 反指;wire `0x6C ObjectStateDelta`;`object_registry.ex`/`part_state.ex` |
| 面元/贴面/decal | ⚠️ **只设计未实现** | 归档实现证据：`web_client` 曾有 `surfaceAttachment.ts` 数据模型(`anchorMacro+anchorMicro+face+faceMask+visibilityPolicy`),不变量 `occupancyMask→0n`、`hide_when_neighbor_occupied`；`bevy_client` 当时无渲染。以上不作为当前客户端状态。服务端零 struct/存储/wire。设计稿 `2026-05-21-auto-circuit-and-surface-prefab-plan.md`/`2026-05-19-prefab-field-participant-projection.md`("surface prefab 是独立 participant,不是假的 microOccupancyMask") |
| 宏格面附着物(火炬) | ❌ 无 | 最接近就是上面那个预留 |
| debris/自由实体 | ❌ 无 | 仅 ObjectRegistry 破坏链留 observe 钩子 |
| wire | — | ChunkSnapshot `0x62` TLV section `0x01–0x07`,无表面 section；归档 `bevy_client` 当时的 mesher 只有暴露面剔除、无 decal 路径，这只作为历史实现证据，不代表当前客户端状态 |

## 3. 拍板锁定的决策(2026-06-17)

- **D-1 表面绑定以"单宏格面"为单位**。去掉微格自由贴面(轴 B 细粒度)。表面元件 = `(host_macro, face)`
  一个面一份,无面上 micro 位置自由度。
- **D-2 表面元件一律走 terrain-bypass**——**被动条件**(氧化/霜/焦痕/苔藓)与**单面功能装置**(火炬/拉杆)
  皆然。**object 层保持原样,只服务多 cell 体积 prefab**(门/机器)。唯一破例升级到 object:某贴面要变成
  可拾取库存物品 / 独立所有权耐久追踪(那它已不是"贴面"而是"物品实体",另议)。论证见 §4。
- **D-3 状态/状态机/物理参与复用现有正交机制**:per-face 的 `attribute_set_ref`/`tag_set_ref` 承载状态
  (氧化度/抛光度/亮灭);状态机用现成 `Actuator`(material+trigger_tag+active_tag)/`ChemicalReaction`/
  `TagPhysics` 数据表;物理参与由属性向量**派生**,只经 committed truth 耦合。**无 per-element 规则、无新
  coded kernel**。
- **D-4 "单独处理"= 面级编辑意图**。抛光/清氧化 = 定位 `(macro, face)` → 改/删该面 truth → ChunkDelta,
  **整条复用现成 voxel-intent 权威路径**(租约/版本/增量同步),且与涌现系统**同构**(锈是系统写的面 truth,
  清锈是把面 truth 写回去)。

## 4. object vs terrain 论证(为何"需要单独处理"反而坚定选 terrain)

"单独处理"(抛光/清氧化)拆开是"定位某面 → 改它的表面状态 → 持久且下行"。四项需求逐条比:

| 需求 | terrain(按 `(macro,face)` 存面槽) | object(持 object_id) |
|---|---|---|
| 寻址 | 面位置**就是**主键;raycast 命中面 → 直拿 `macro+face` 打意图。**零反查** | 要 `(macro,face)→object_id` 反查索引 |
| 状态承载 | 面槽自带 attribute/tag ref → 氧化度=per-face `oxidation_progress`,同 S1–S4 per-cell 属性 | 用 part_states/health 装"氧化层对象",语义别扭 |
| 处理动作 | 删面槽/清属性,**复用 voxel-intent → ChunkProcess → ChunkDelta** | 另起一条"与 object 交互"路径(ObjectStateDelta) |
| 宿主联动 | 面槽 key 在 `(macro,face)`;宿主毁/相变 → ChunkProcess 本地顺手清,chunk-local | 跨进程通知 ObjectRegistry,多一跳多一类失败 |
| 规模 | 面 truth 随 chunk 紧凑存、随 chunk 进出,**海量氧化也扛** | 每贴面一 object(Postgres 行+registry+版本),海量必爆 |

**核心**:"要单独处理"的天然 handle 就是**面的位置本身**(面不移动,比 object_id 更稳更直接);object_id
在这里是多余的间接层。且**处理 = 局部面 truth 编辑 = 复用编辑权威路径 + 直接和 S1–S4 组合**。

**object 唯一独占价值** = 把跨多 cell/多 chunk 的东西聚成一个逻辑实体、各 part 独立损毁、有放置者/生命周期。
表面元件锁成**单宏格面单份** → 天然不跨 cell/不多 part/不需聚合 → 这价值用不上。连火炬/拉杆这类**单面
装置**也不需要 object(亮灭/开关 = per-face tag 状态机,正好 S3 Actuator 那套数据表;emit 热/光由属性派生)。

## 5. 落地草图(不实施,给后续 step)

1. **`SurfaceCatalog`(append-only)**:表面元件类型(rust_decal/frost/scorch/torch/lever…),各带:渲染
   mesh/quad 引用、默认材料属性向量、可见性策略(`hide_when_neighbor_occupied`/`always_visible`)。
2. **Storage 加"面槽"旁路**:per-chunk 的 `{host_macro, face, surface_type_id, owner_actor_id?,
   attribute_set_ref, tag_set_ref}` 列表,**零 occupancy**(绝不进 occupancy mask)。6 面 × 4096 宏格的
   稀疏表(绝大多数面无元件)。
3. **wire 加 append-only TLV section `0x08 SurfaceElements`**(ChunkSnapshot 现 `0x01–0x07`)+ ChunkDelta
   面级 op;catalog snapshot 同步。
4. **ParticipantProjection 面级扩展**:它**已经是面级的**(`face`+`face_contacts`)——表面元件的属性向量
   作为该面的额外 participant 注入(如贴面线缆在两面间架电连接、火炬 emit_heat 写宿主格温度 truth)。
5. **客户端渲染旁路（归档历史决策）**：当时规划由 Bevy 主线 + Web oracle 对**仅暴露面 + 视锥内**的表面元件按 surface_type 批渲；这只作历史设计证据，不代表当前客户端职责。唯一现役客户端仍是 `clients/Voxia`，如需落地必须按 Voxia 当前路线另行设计与验收；
   被邻接覆盖即隐(truth 留存)。接"大规模渲染"主目标的 LOD/剔除纪律。

## 6. 与涌现层的 synergy(皮相级现象的归宿)

表面元件层给 S1–S4 一个**"可见表面现象"的干净出口**,且暗示一条 S4 精修:

- 现 S4 是 iron **整块** material 换 rust;更物理的是**氧化=表皮现象**——氧化层作**面 truth**
  (per-face `oxidation_progress`)在表面累积,本体仍 iron,直到锈透才动 bulk。"清氧化"恰好刮掉这层面 truth、
  露出干净本体。
- **皮相级现象**(氧化/结霜/焦痕/抛光/苔藓)→ 表面元件层;**bulk 相变**(熔化/烧穿/燃尽)→ 仍动整格。
  两者正交又可组合。
- 这条**等表面元件层落地后再回头精修 S4**,本稿先记一笔,不在本轮动 S4。

## 7. 不变量(纪律)

- 表面元件**零 occupancy**,**绝不改宿主邻接/碰撞/面剔除**;渲染与否只由"宿主面是否暴露"决定,被覆盖
  即隐、truth 留存。
- 表面元件是**独立 participant**,**不伪造进 microOccupancyMask**(承袭 2026-05-19 预留不变量)。
- 状态用 per-face attribute/tag;状态机/物理参与复用 Actuator/ChemicalReaction/TagPhysics + **属性派生激活、
  只经 truth 耦合、无 per-element 规则**。
- catalog / wire **append-only**(版本 bump + 测试同步);惰性安全(无属性的面不参与系统)。
- 逐 step commit + scene 全量 0 净回归 + 决策稿留痕(沿用本仓纪律)。

## 8. 范围与 defer(显式,无 silent cap)

**IN(本形态轨)**:单宏格面表面元件(terrain-bypass)+ SurfaceCatalog + Storage 面槽 + wire `0x08` +
ParticipantProjection 面级接入 + 客户端暴露面渲染。被动条件与单面装置同机制。

**DEFER(显式声明)**:
- **微格自由贴面**(D-1 砍掉)。
- **微格面绑定**(refined 表面上精细贴面)——v1 只宏格面。
- **多面/跨面表面元件**(大招牌横跨数面)。
- **自由脱网实体**(debris/掉落/怪,基底 F)——破坏链 observe 钩子已留,另轨。
- **S4 氧化皮相化**(§6)——等表面层落地再回头精修,本轮不动 S4。

## 9. 待用户拍板(排期与细节)

- **Q1 排期**:形态轨(表面元件层)与 S5 物理线(力学/流体/辐射/磁)**两条正交独立轨**,先做哪条?
  *倾向*:形态层能立刻给 S1–S4 涌现产物一个**可见表面出口**(氧化/焦痕看得见),且打通后能精修 S4;
  但 S5 是把物理域补全。两者皆可先,由用户定。
- **Q2 存储表示**:面槽用"per-chunk 稀疏列表"还是"per-macro 6 面定长槽"?(性能/紧凑 vs 简单)留待形态轨
  开工设计 step 细化。
- **Q3 首个落地实例**:形态层 PoC 选哪个表面元件先打通端到端?候选:rust_decal(直接接 S4,证皮相化)
  / torch(证单面装置 + emit 热光)/ lever(证 S3 Actuator 接表面)。
