# C4b 深半导体(二极管 + 三极管/逻辑门)· 决策稿

- 日期:2026-06-24
- 状态:**决策已确认(2026-06-24)**——①三极管=单 cell+面端子 MVP;②diode 硬截断;③朝向=state_flags;④cell 朝向=玩家放置朝向(MVP 服务端推断、推迟 0x70 变体);⑤本轮只做电路图有向化(电势场/channel 推后);⑥step0 先补 signal_high。按 §6 逐 step 实现中。
- 关联:[[gameplay-roadmap-and-construction-scope]]、`docs/2026-06-23-construction-system-fixed-component-list.md`(C4b 是冻结清单唯一剩项)、[[field-provisioning-framework]]、[[emergence-reaction-layer]]
- 依据:5-agent understand workflow(`c4b-circuit-recon`,2026-06-24)对电路子系统的实读测绘。

## 1. 现状(recon 结论)

电路子系统是一条 **truth → 投影 → 拓扑 → kernel → effect → truth** 的闭环,**当前全程无向、纯标量近似**:

- **真值层**:放置走 `0x70 VoxelEditIntent` → `tcp_connection` 落 `Storage`(`state_flags` 恒 0、`face_normal` 只算落点偏移不入库)。
- **投影层** `ParticipantProjection.build`:导电实心块给 `all_face_connections()`(全 6 面**双向**网格);roles 纯按 `material_id` 的 **material-default** 属性派生(`electric_roles_for_material`),**读不到任何 per-cell 状态**(只调 `default_attribute_value`,从不读 `attribute_set_ref`/effective attrs/`state_flags`)。
- **拓扑层** `CircuitComponentAnalysis`:每 macro 子分量=segment,`connect_face_neighbors` **双向对称写边**;`closed_loop_segment_ids`/`prune_open_ends` 剪 degree≤1 叶子得**无向 2-core**;`active_circuit_component?` 要求 2-core 含 source+load。
- **kernel 层** `CircuitCurrentKernel.tick`:`energize`(BFS 跳数衰减写电位,非 KVL/KCL)→ I²R 注热 → 闭环 load 置 `:powered`、`logic_threshold>0` 的 cell 电位≥阈→ `:signal_high`。
- **effect** 经 SystemActor → `ChunkProcess.apply_set_tag_effect`(名→TagCatalog id,**未注册名静默丢弃**)落 truth。

**关键判断**:电阻/比较器能纯数据 append 成立,是因为它们**不需要方向**。diode(单向)/transistor(门控)是这套无向标量范式**唯一兜不住的**,必须在「投影面连通」+「拓扑建图」两处引入方向,并在 kernel 加门控决策。`state_flags` 已在 scene 内部 Codec 全程 round-trip,但 `field/` 下无代码读它——**这正是 per-cell 朝向天然但当前断开的载体**。

## 2. ⚠️ 发现的 C4a 遗留断点(必须先补)

`:signal_high` **未登记 tag_catalog**(v5 到 id12)。即:**已上线的 C4a comparator 发的 `:signal_high`,经 `apply_set_tag_effect` 名→id 解析失败被静默丢弃,根本没落 truth**——现有 comparator_test 只断言 kernel effect、未验证落 truth,所以看似过测、实则信号链不通。逻辑门链消费/门控 `:signal_high` 是硬前提,故 **step0 先补**(tag_catalog v5→6 append `signal_high` id13 + 落 truth 回归测)。

## 3. 朝向承载体决策:选 `state_flags` 位段(方案 A)

**否决**「朝向藏 `attribute_set_ref` 指向的属性集」(方案 B):投影层只读 material-default、根本到不了 `attribute_set_ref`,B 反需额外改投影读 effective attrs,**比 A 改动更大**。

**方案 A**:朝向编进 `NormalBlockData.state_flags`/`MicroLayer.state_flags`(u32),位图(避开 `part_state` 已占的 damaged/destroyed 位):
- `bits[0..2]` = conduct in_face ordinal(0..5)
- `bits[3..5]` = out_face ordinal
- `bits[6..8]` = control/gate face ordinal(transistor 用)
- `bits[16..]` 留给损坏语义,文档化。
- **零 wire 改动**:`state_flags` 已在 scene Codec round-trip(`storage→snapshot→客户端`链已带);但它进 `chunk_hash` 与 MicroLayer 合并签名,填非 0 需**同步 golden-fixture + bevy decoder 跨语言 parity**(不破 wire layout)。

## 4. 二极管设计

1. **数据(纯 append)**:`attribute_catalog` v12→13 +`conduction_axis`(id25, fixed32, material_default, default 0;编码 0=无向回退普通双向导体/1=+x…6=-z,anode→cathode);`material_catalog` +`@diode_material_id 22`(`electric_conductivity≥1` 入图)+ `diode_material?` 谓词(仿 `power_source_material?` 模式,无 id 白名单)。
2. **朝向存取**:放置时把**玩家放置朝向**(非 hit `face_normal`)写 `state_flags`;`ParticipantProjection.build_solid_entry` 解码 → diode cell 的 `face_connections` 退化成只连 `{in_face→out_face}` 有向对。
3. **投影有向化**:`electric_component` 加 `:conduct_dir`(或 `face_connections` 改有向集);`connection_key/2` 对 diode 不对称排序;`electric_faces_connected?` 按方向过滤。
4. **拓扑有向化**:`connect_face_neighbors` 双向对称写边 → 方向感知(普通导体仍双向、diode 仅导通向单向边);adjacency 升级有向(`%{out, in}`);`closed_loop` 改**有向环判定**(source 沿允许方向有向可达 load 并成环);`active_circuit_component?` 有向版。
5. **kernel 反偏断流**:`CircuitCurrentKernel` BFS 吃有向图。**硬截断**(反偏从有向 2-core 删边→回路开路→电流=0、load 去 `:powered`),不用软阻(软阻要重写标量 R 模型)。

## 5. 三极管/逻辑门设计

1. **建模(MVP 推荐单 cell)**:control(base)端=`state_flags bits[6..8]` 标的 control face,main path=另两面(collector/emitter)。避免跨 cell 多端节点语义(改动小一档)。物理不精确但够做逻辑门链。
2. **数据(append)**:`material_catalog` +`@transistor_material_id 23`;**复用 `logic_threshold`(id24)** 作 base 导通门限(与比较器同属性);+`transistor_material?` 谓词。
3. **投影端子区分**:`electric_role` 枚举扩 `:gate`;从 `state_flags` 解出哪个面是 control face。
4. **拓扑门控边**:transistor 的 collector-emitter 边标为**门控边**,存在性依赖 base 端电位——图连通不再纯静态。
5. **kernel 两遍求解(核心)**:`CircuitCurrentKernel.tick` 在 energize 前插一步:先解 control 子网电位 → 每个 transistor cell 判 `base 端 |potential|≥logic_threshold`(复用 comparator 范式)→ 决定其主通路本 tick 是否导通 → 导通则并入闭环重解主网。即**单 tick 两遍/不动点**,松绑「静态拓扑即激活」假设。
6. **输出零成本**:transistor 输出若只是再开门/亮灯,直接复用 `Actuators`(`trigger_tag`/`active_tag`)+ TagPhysics,与 `:powered`/`:illuminated` 门对称、无新代码(前提:`signal_high` 已登记)。
7. **逻辑门**:AND=两 transistor 串联、OR=两 transistor 并联。

## 6. 逐 step 计划

| step | 内容 | 性质 |
|---|---|---|
| **0** | tag_catalog v5→6 append `signal_high`(id13)+ 落 truth 回归测 | 补 C4a 断点,diode/transistor 共用前提 |
| **1** | diode 数据:attribute v12→13 +`conduction_axis`、material +id22 + 谓词、同步三 catalog test | **纯 append,可独立 commit** |
| **2** | diode 朝向存取:放置写 `state_flags` + 投影解码有向 `face_connections` + 投影单测 | |
| **3** | diode 拓扑有向化(核心):方向感知写边 + adjacency 有向 + 有向环判定 + 拓扑单测 | **横切重构** |
| **4** | diode kernel(BFS 吃有向图 + 反偏断流)+ `diode_test.exs` e2e(正偏/反偏) | **diode 端到端可验收** |
| **5** | transistor 数据 + 端子角色(投影区分 control vs main-path) | 建模拍板后 |
| **6** | transistor 门控求解(最重):门控边一等概念 + 两遍/不动点求解 + provisioner 稳定性(hysteresis) | **最难** |
| **7** | `transistor_test.exs`(截止/导通)+ AND/OR 门组合 + region 稳定性测 | |
| **8** | parity/视觉收尾:golden-fixture 更新 + bevy decoder `state_flags` 解码 + 0x70/0x66 drift audit;若加朝向/端子渲染则补 Layer-3 像素测 | |

每 step commit、测试绿、客户端改动补自动化测试。

## 7. 待用户拍板的决策

1. **三极管建模**:单 cell(MVP,改动小、物理不精确)还是多 cell 组合构件(改动大、物理精确)?——**本稿推荐单 cell MVP**。
2. **diode 单向口径**:硬截断(删边开路,贴合 2-core)还是软阻(高电阻,需重写 R 模型)?——**推荐硬截断**。
3. **朝向承载体**:`state_flags` 位段(A,推荐)还是属性集(B)?——**推荐 A**(投影读不到 attribute_set_ref)。
4. **cell 朝向来源**:玩家相机/放置朝向(推荐,MVP 服务端侧推断填 `state_flags`、推迟 0x70 变体)还是 hit `face_normal`?
5. **本轮 scope**:只做电路图(diode/transistor)有向化(推荐),还是连 `ConductionPathKernel`/电势场的无向 neighbor 搜索也一起有向化?——**推荐只做电路图,点对点 channel/电势场推后**。
6. **C4a signal_high 断点**:step0 先补(推荐)。

## 8. 风险(实现时盯紧)

- **有向化是横切重构**:写边/segment_graph @type/closed_loop 2-core/kernel BFS/active 谓词/provisioner 计数全联动,漏改一处→反偏 diode 仍被当闭环误置 `:powered`。
- **门控先有鸡先有蛋**:base 电位在 energize 后才有值、门控发生在 energize 前——必须两遍/不动点,否则首 tick 误判。
- **门控边界抖动→region 反复起停**:provisioner 数闭环若依赖门控态,临界电位震荡 → 需 hysteresis 或 detect 用门控前静态导电拓扑。
- **`state_flags` 进 chunk_hash + MicroLayer 合并签名**:填非 0 改 hash/合并行为,未同步 golden-fixture/bevy decoder 破跨语言 parity。
- **comparator 取电位绝对值**:引入极性后正负有物理意义,门控/比较器仍取 abs 可能误判符号——需重新界定。
- **signal_high 隐性断点**:不补 v6,逻辑门链看似过测实则不通。
- **有向环检测成本**:16³ macro 下确认廉价,与 `conduction_path` 熔断纪律一致,最坏加熔断。

## 9. 不发散纪律

只做 diode + transistor/逻辑门(冻结清单内最后一项)。电势场/点对点 channel 有向化、流体、新涌现系统一律不在本轮。清单冻结后如需加项,先回 `construction-system-fixed-component-list` 改清单再做。
