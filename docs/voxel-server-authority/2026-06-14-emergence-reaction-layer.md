# 涌现反应层设计(Reaction Layer · 功能完善阶段起点)

> 上层背景:架构对齐迁移(梯队 0–4)主体完成后转入**功能完善**(用户目标:"按涌现思路,先把现有代码里
> 的功能做到位")。本稿是功能完善第一块——闭合断裂的涌现回路。
> 纪律沿用:决策稿先行 → 逐 step commit(`mix format` + 回归)→ 进度日志 → 不 push → 不留兼容。
> 规范关联:RULE-11/AUTH-11(派生→权威经 system_actor)、RULE-15/16(锁存+幂等)、EMG-1/3/7(模型卡)。

## 1. 问题:涌现回路断在最后一步

源码精读(2026-06-14)确认:**物理量、材料阈值、tag 三块拼图都在,就差"反应层"把它们接起来。**

```
kernel 算场(温度/电流/电离)→ SystemActor 锁存 → ChunkProcess 写温度进 voxel truth → 【断】
                                                            ↓ 没有任何东西读已提交 truth 触发世界变化
```

- 5 个 field kernel 只算数;只有 conduction/discharge 把热量写回 `:temperature` truth,其余产空 effect。
- `MaterialCatalog` 已定义 `ignition_temperature`/`melting_point`/`freezing_point`/`boiling_point`(冰
  melting=0℃、木 ignition=300℃、铁 melting=1538℃…)却是**死元数据**——无代码拿温度比对触发转变。
- tag(`flammable/burning/wet/frozen`)是死的;电流不驱动任何东西;README 自标"还没有 Phase 8
  damage/ignite/breakdown 结算"。

## 2. 用户拍板(2026-06-14)

- **先后**:先搭**行为无关的反应层骨架**(立 ReactionRuntime/Engine + 规则引擎 + SystemActor 接线 +
  模型卡 + 一条最小 demo 规则把回路立住),再逐一填 燃烧 / 相变 / 电→世界 三类行为。
- **规则表征**:**两者结合**——材料相变走 `MaterialCatalog` 阈值表驱动(数据化,材料 X@温度 T → 材料 Y);
  tag 反应走声明式规则;coded reaction kernel 只承载复杂时序/级联。

## 3. 设计:反应层 = 引擎(纯)+ 驱动(field 复用)+ 效果(经 SystemActor)

**关键洞察:刚搭的架构就是为这块准备的。** 反应是典型的 derived→authoritative 写(由温度物理派生,写材料
truth),正是 `SystemActor`(AUTH-11 唯一桥)的目标消费者;复用 `SimRuntime` tick、模型卡(EMG-1/3/7)、
candidate_effect 锁存(RULE-15/16)。**不新建并行权威路径,不破坏任何承重契约。**

### 3.1 新模块

| 模块 | 职责 | 形态 |
|---|---|---|
| `SceneServer.Voxel.Reaction.Rule` | 反应规则结构:`:phase_transition`(阈值驱动,from_material + 条件{attr,op,阈值名} + to_material)/ `:tag_reaction`(when_tags + 条件 → add/remove tag,骨架先定形不全接) | 纯数据 struct |
| `SceneServer.Voxel.Reaction.Rules` | 规范规则表 `all/0` + `for_material/1`;seed ice→water demo + 结构留位 | 纯数据 |
| `SceneServer.Voxel.Reaction.Engine` | **纯**:`evaluate(cells, rules) → [reaction_effect]`;cell=`%{macro_index, material_id, temperature_celsius, tags}`;产 `{:transform_material, %{macro_index, from_material_id, to_material_id, rule_id}}` | 纯函数,驱动无关 |
| `SceneServer.Voxel.Field.Kernels.ReactionKernel` | 骨架驱动:field-kernel adapter,读 `context.storage` 已提交 truth(材料 + `effective_attribute_at "temperature"`)over region aabb → 建 cell 列表 → 调 Engine → 返 reaction effects;带 `model_card`(EMG-1/3/7) | field kernel |

**反应读"已提交 truth"而非 field 层**:reaction 消费权威态(`Storage.normal_block_at` 材料 +
`effective_attribute_at` 温度),field 层是产生 truth 温度的物理(conduction/discharge 写回 / set_temperature
正式路径)。truth-based 反应对齐审计建议("daemon reads abnormal attributes from storage")。

### 3.2 效果通路(复用 SystemActor + ChunkProcess)

- **SystemActor**:加 `gate({:transform_material, attrs})` 子句。**复用 bucket 锁存**:`latch_key =
  {cell, kernel_id, macro_index, :material}`,`bucket = to_material_id`(离散材料 id 即桶,无需量化)。
  同 {cell,macro,目标材料} 已提交 → latched 幂等跳过(防同 tick 重复转);目标变(水→蒸汽)→ 新桶提交。
  candidate_effect_id 稳定(RULE-16)。
- **ChunkProcess**:`apply_field_effect` 加 `:transform_material` 分支 → `apply_transform_material_effect`:
  读 `normal_block_at(macro)` 现材料,**校验 == from_material_id**(防过期转,显式 reject 不静默),
  `put_solid_block` 换 to_material(保留/重置属性),bump chunk_version,push snapshot,emit
  `voxel_material_transformed`。

### 3.3 catalog 补料

- 加 `water` 材料(id 8):demo 转变目标。属性 density≈1000、thermal_conductivity≈0.6、freezing_point=0
  (可逆冻回)、boiling_point=100、flammable 否、electric_conductivity 低。后续燃烧补 `ash`/`steam`/`lava`。

### 3.4 模型卡(EMG-1/3/7)

ReactionKernel 模型卡:`fidelity_class: :qualitative`(阈值锁存式相变,非严格热力学/潜热);
`safety_valve: %{type: :reaction_budget, max_transforms_per_tick: N}`(防失控级联);assumptions
("阈值瞬时相变无潜热延迟"、"chunk-local"、"truth 温度驱动")。

## 4. 子步(逐步 commit + 回归闸门,仿梯队做法)

- **R1**:`Reaction.Rule` + `Reaction.Rules` + `Reaction.Engine` 纯核 + 全量单测(数据化阈值 eval、
  ice→water demo 规则、行为无关结构)。`MaterialCatalog` 加 water。**新模块,构造上 0 回归。**
- **R2**:`:transform_material` 端到端——SystemActor `gate` 子句(transform 锁存幂等)+ ChunkProcess
  `apply_transform_material_effect`(put_solid_block + from 校验 + 版本 bump + snapshot + observe)。
  单测:transform 锁存幂等、from 不匹配 reject、应用后材料变 + 版本 +1 + 快照。
- **R3**:`ReactionKernel`(field adapter,读 truth,模型卡)+ 接 field tick 链。端到端 demo 测试:
  置冰格 → set_temperature ≥ 0℃ → tick → 冰变水(storage + snapshot)。回归 scene 全量 0 净回归。

> 排序理由:R1 纯核独立可测;R2 把效果通路打通(回路的"写"端);R3 接驱动闭环。三步后:**温度物理 →
> 读 truth → 阈值规则 → 材料转变 → 快照下行 → 客户端可见**,涌现回路闭合,且骨架行为无关——燃烧/电→世界
> 只是往 `Rules` 加规则 + 必要 coded kernel。

## 4b. R5 燃烧设计(旗舰涌现 · 反馈回路)

用户拍板(2026-06-14):burning 用 **tag `:burning` + `burn_progress` 属性**;放热用**统一能量单位
焦耳**(burning 每 tick 注入固定燃烧焓,各 cell 温升由自身 `密度×比热容×体积` 决定,点燃判据仍是温度对比
`ignition_temperature`)。底座勘探确认:per-cell tag(`tag_set_ref`/`intern_tag_set`)+ `:burning`(tag id 5)
+ 焦耳→ΔT 热路径(`heat_energy_joules`)均已存在;**需新建** ash 材料、`burn_progress` 属性(catalog)、
`:set_tag` 效果 handler。

### 涌现回路
```
flammable(= ignition_temperature 可达)+ 温度≥ignition → ignite(加 :burning tag)
  → burning 每 tick:注入燃烧焦耳(自身升温维持高温)+ burn_progress += Δ
    → 焦耳经热扩散 kernel 传邻居 → 邻居达 ignition → ignite ♻ 蔓延
  → burn_progress≥1 → burn_out(→ ash + 去 :burning;ash ignition inert 不复燃)
```
**flammability 无需单独标记**:inert 材料 ignition=5000℃(不可达)→ 同一温度阈值机制天然只让可燃物点燃。

### 关键设计:连续效果 vs 一次性锁存(重要)
SystemActor 的 bucket 锁存是**去抖**(RULE-15,阈值跨越提交一次)。但燃烧的**注热 + 进度推进是每 tick
连续**的——若被去抖锁存,火无法自维持。故区分:
- **一次性锁存**(去抖):`transform_material`(冰→水、木→ash)、`set_tag` 加/减(ignite 加 :burning 一次)、
  `target_temperature` 阈值写。
- **连续提交**(绕去抖):`heat_energy_joules`(累加能量注入)、`burn_progress` `:add_delta`(每 tick 累进)。
SystemActor `gate` 据效果类型分流:带 `heat_energy_joules` 或 add_delta 属性写 → always commit(连续);
target/transform/tag → 锁存。**(R5b 落地;注:现有 conduction/discharge 连续 Joule 注热同受益此修正。)**

### Engine 泛化(R5a)
- Rule 加 `require_tags`/`forbid_tags`/`effects`(tag_reaction);condition field 可读 `:temperature` 或
  `:burn_progress`;threshold 加 `{:value, v}`(比率)。
- cell 状态加 `burn_progress` + `tags`。Engine 对 tag_reaction:require ⊆ tags、forbid ∩ tags=∅、condition 成立
  → 物化 effects(一 cell 可中多条 tag_reaction → 多效果)。effect 模板:`{:add_tag,t}`/`{:remove_tag,t}`/
  `{:emit_heat_joules,j}`/`{:advance_attribute,attr,Δ}`/`{:transform,mat}`。
- 燃烧规则:ignite(forbid [:burning],temp≥ignition → add :burning)/ burn(require [:burning] → emit 焦耳 +
  advance burn_progress)/ burn_out(require [:burning],burn_progress≥1 → transform ash + remove :burning)。

### R5 子步
- **R5a**:catalog 加 ash(material)+ burn_progress(attribute,`:add_delta`)。Engine + Rule 泛化(tag_reaction
  + 多效果)+ 燃烧规则。纯核 + 单测。
- **R5b**:`:set_tag` 效果 handler(intern tag set 加/减)+ write_voxel_attribute 泛化到任意动态属性
  (burn_progress)+ **SystemActor 连续/锁存分流**。单测。
- **R5c**:ReactionKernel 读 tags + burn_progress + ignition;端到端旗舰 demo:点燃木 → 燃烧放热 → 蔓延到
  邻居木 → 烧尽成 ash。scene 全量 0 净回归。

## 4c. R6 电→火(跨系统涌现 · 用户选)

用户拍板(2026-06-15):先做**放电点燃/伤害(跨系统涌现)**。白送机会:放电/导电 kernel 已把 Joule 热写回
truth(thermal_coupling 默认开),反应层读 truth 温度点燃可燃物——**只需把 ReactionKernel 接进电 region,
放电热即自动点燃旁边木头 → 电生火**,复用现有一切。

### 接线 + 物理(scout 确认)
- **接线点**:`field_source.ex` 电 `kernel_specs`(conduction/discharge)追加 `%{id: :reaction, module:
  ReactionKernel, opts: %{}}`——conduction + discharge region 都获反应。
- **热量够**:放电穿木约 235℃/tick(120V/6A/100ms/joule_scale 1e4,~3 格路径)→ 2 tick 破 300℃ 点燃。
  **木电导=0** → conduction 不穿木;**discharge(介质击穿)能穿木** → 故展示=放电生火。
- **回归极小**:现有电测试用非可燃材料(iron/power_block/dirt);唯一含木的 conduction 测试走 iron 路径
  (木非导电被跳过)。ReactionKernel `required_layers [:temperature]` 给电 region 加空温度层(0x73 无害)。

### R6 子步
- **R6a ✅**:`field_source.ex` 电 kernel_specs 接 ReactionKernel(production 接线,conduction/discharge
  region 都获反应)+ alias;field_source_test 两处 kernel_specs 断言更新。电全量 24/0 零回归。
- **R6b 受阻 → 暴露架构缺口(待与用户定 heat-spread)**:demo"放电点燃木"失败,诊断发现**木只升到
  20.018℃**——放电几乎不给木注热。根因物理:**木电导=0 → 放电无电流穿木 → 无 Joule 热**;放电弧穿空气
  不穿实心木;且**truth 温度无邻居扩散**(现有温度扩散只动 field 层不动 truth)。故"热的导电体(铁)
  无法把热传给相邻可燃物(木)"——**"电→火"不白送,缺一个 truth 级热扩散机制**。
  - **R6a 仍正确保留**:反应 kernel 随电场跑是对的(电材料一旦有自身阈值规则[如铁熔]即生效);只是
    跨格热传播这块需新机制。
  - **设计决策(R6c,待用户)**:给反应层加 **truth 级邻居热扩散**——每 cell 向更冷的相邻 solid cell
    按温差传热(Fourier 式,自限平衡)。这同时:(a)让导电体热传给相邻可燃物 → 电生火;(b)把现 R5c
    燃烧的"flat 15MJ 辐射"升级为物理热扩散(更对、更自洽);(c)填补 R5c 起就记下的"truth 温度无扩散"缺口。
    需定:守恒(传热同时源放热)/ 扩散系数 / 失控防护。
- **R6c ✅ 守恒 Fourier 热扩散完成**(用户拍板:守恒模型 + 统一燃烧蔓延)。ReactionKernel 替"flat 辐射"
  为守恒热扩散:每对相邻 solid cell `Q = rate × ΔT / (1/C_h + 1/C_c)`(C=密度×比热×体积),**源放热=冷端
  得热**(能量守恒),rate=0.25<1 自限不过冲;cell_state 补读 heat_capacity;净焦耳(可±)汇总成连续注热
  经 SystemActor + ChunkProcess clip。**统一**:燃烧 cell 自加热很烫 → 自然扩散点燃邻居(combustion 蔓延
  e2e 仍过)。**端到端 demo 全验**:(i)冰熔/水冻/沸 (ii)燃烧点燃→自维持→蔓延→ash (iii)**电→火**:导电
  Joule 加热铁 → 守恒热扩散把铁热传相邻木 → 木点燃(跨系统:电+热扩散+燃烧组合涌现)。reaction 59 全绿。
  **遗留 follow-on(电热增益平衡)**:生产 `@conduction_heat_response_gain=1e4` 偏低,放电/导电实际注热
  远不达 ignition(demo 用 joule_scale 1e9 验机制);"电→火"落生产需调电热增益(独立 balance 项,不破机制)。
- **R6d ✅ 电热增益调平**:`@conduction_heat_response_gain` 1e4 → **1e9**,使持续导电/放电把导电体加热到
  ignition 量级(铁约 ~10℃/tick)→ 经守恒热扩散点燃相邻可燃物。**关键洞察**:守恒热扩散把热在连通固体
  质量间**均摊**,故点燃单格须把整连通块加热到 ignition;单 voxel Joule 热极小,需大增益压过均摊才
  gameplay 可见——故 1e9(粗 1m³ + 定性档 gameplay 增益,playtesting 可下调/拆分导电vs放电)。**电→火 e2e
  demo 改用生产增益 1e9 验证生产可用**(30 tick 内点燃);field_source_test joule_scale 断言随之更新。
  scene 全量 986/0 零净回归。**至此"电→火"生产可用。**

## 4d. R7 电路驱动负载 + R8 放电击穿伤害(把 inert 电计算接到世界后果)

用户拍板(2026-06-15)"都做,按顺序"。现有 `circuit_current`(算闭环电流)+ `ionization`(算电离)算了数
但无世界后果(同当初温度)。做到位:

### R7 电路驱动负载(circuit → load `:powered`)
- 加 `:powered` tag(tag_catalog id 9,version→2)。
- `CircuitCurrentKernel`:闭环电流分析已知哪些 load cell(electric_load 材料)在闭合回路中。对在 active
  closed component 的 load cell 发 `{:set_tag, add: [:powered]}`,其余 region 内 load cell 发 remove
  `:powered`(断路即去电)。经 SystemActor(set_tag always-commit)→ ChunkProcess → 负载 truth 标 `:powered`。
- **负载"通电"成权威 truth 状态** = 任何设备(门/灯/机器)的基础:设备读自身 load 的 `:powered` 决定行为。
  本步落"通电状态"权威化(自包含、可观测);具体设备行为(开门/点亮)是其上层,后续按需接。
- demo:搭闭环(电源+负载+导体成环)→ 负载 `:powered`;断一节导体(破环)→ 负载失 `:powered`。

### R8 放电离子化击穿伤害(ionization → block 伤害)
- 放电/导电沿路径写 ionization(field 层)。做到位:**高电离沿放电路径对方块造成击穿伤害**(降 health,
  归零即毁)。自包含先做**方块伤害**(NormalBlockData.health);实体伤害(接 combat voxel_damage_router/
  object_registry / `PartState.health` Phase4 既有体系)更重,作后续。
- **定:kernel-driven**(非 rule-driven)。理由:ionization/击穿路径是 `ElectricDischargeKernel` 已算的
  **派生 field 态**(非 committed truth),反应规则只读 truth 不读 field 层;放电 kernel 已沿 Dijkstra
  击穿路径迭代并发热效果——伤害与发热同源同路径,直接由 kernel 发最自然(同 R7 circuit→`:powered`)。
- **新效果类型** `{:damage_block, %{macro_index, amount, source}}`:
  - `ElectricDischargeKernel`:除沿路径发热(`discharge_heat_effects`)外,新发 `discharge_damage_effects`
    ——对路径上**实心 macro 块且 health>0** 的 cell 发 `:damage_block`(`amount` 每 tick 配置,默认
    `@default_breakdown_damage`)。**health>0 门控在 kernel 端**:health=0 视为"未跟踪耐久/不可被电击穿毁"
    (避免误毁默认 0 块),空 cell(被电离的空气)无块跳过。放电模式(`conduction_mode == :discharge`)本就
    显式 opt-in,故击穿伤害**默认开**,经 `breakdown_damage` opt 可调/可关。
  - SystemActor:`gate({:damage_block,_})` → **连续 always-commit**(持续电弧逐 tick 累损,同 heat/delta 绕锁存)。
  - ChunkProcess:`apply_damage_block_effect` 读实心块**权威重校**(非实心/已毁/health=0 → 显式 reject),
    `new = health - amount`;`new<=0` → `Storage.clear_macro_cell`(毁块转 empty,`destroyed?: true`),否则
    `put_solid_block %{block | health: new}`;bump 版本 + push 快照 + emit applied。
- demo:放电穿带 health 的实心方块 → 逐 tick health 降 → 归零毁(转 empty,快照反映)。

## 4e. R9 通电设备行为(把 R7 `:powered` 接到具体设备动作)

R7 把负载"通电"做成了**权威可观测 truth 态**(`:powered` tag),但 `:powered` 还没有任何具体设备
后果——这正是 R7 当时点名的 follow-on(「具体设备行为是其上层,后续按需接」)。R9 沿同一行为无关
骨架把 `:powered` 接到设备动作。

**骨架扩展(最小、数据化)**:`tag_reaction` 规则加**可选 `material` 过滤**——设备行为是设备材料
专属的(加热器放热、门开合不同),不能让所有 `:powered` 负载一视同仁。Rule 加 `material` 字段
(tag_reaction 用,`new!` 校验真实材料);Engine `tag_effects` 加一条 `material_matches?` 过滤
(`material: nil` → 不限;否则 cell 材料须等于该材料)。phase_transition 不受影响。**不动 Engine/通路
其余、不动 SystemActor/ChunkProcess**(复用既有 emit_heat_joules 等效果)。

### R9a 旗舰:通电加热器(circuit → 热 → 熔/燃 跨系统涌现)
- 复用 **`electric_load` 材料**(R7 已对它置 `:powered`,无需新材料/新电角色)。语义:通电负载耗能即
  生热(电阻加热器)。
- 新规则 `:powered_heater`:`kind: :tag_reaction, material: :electric_load, require_tags: [:powered],
  effects: [{:emit_heat_joules, @heater_joules_per_tick}]`。ReactionKernel 读 truth(R5c 已读 per-cell
  tag)→ Engine 命中 → emit_heat → SystemActor 连续注热 → ChunkProcess 落温度 truth。
- **涌现链(全部复用)**:circuit 闭合 → R7 `:powered` → 加热器放热 → R6c 守恒热扩散传邻 → R4 熔邻冰 /
  R5 点燃邻木。把 R4–R7 串成一条:**接通电路 → 邻近冰熔化 / 木燃烧**。
- 热量常量定性档 game-feel(模型卡 `:qualitative`,同燃烧/电热),playtesting 可调。
- 验收:Rule 校验(material 过滤合法/非法)+ Engine(通电 load 放热、断电不放、通电非 load 材料不放=
  material 过滤)单测;e2e(通电 load 逐 tick 升温,邻冰熔/邻木燃)。scene 全量 0 净回归。

### R9b 通电门/机关(后续)
- `door` 设备材料:`:powered` → transform 为开(可通行/移除);失电 → 关。需 Engine 加"缺某 tag"
  条件(powered→开 + 反向 unpowered→关),且门的"开/可通行"是新 truth 维度(passability)。比加热器多
  一层状态机 + 新维度,作 R9a 之后。

## 5. 验收

- 回路闭合:加热冰格 → 冰在 truth 中变水 → snapshot 反映 → web_client 可见(主线端)。
- 反应经 SystemActor(RULE-11/AUTH-11)+ 锁存幂等(RULE-15/16);ChunkProcess from 校验显式 reject。
- 反应层骨架**行为无关**:规则数据化 + coded 留口;模型卡(EMG-1/3/7)+ 安全阀预算。
- scene 全量 0 净回归。

## 进度日志(时间倒序)

- 2026-06-15:**R8 放电击穿伤害完成,放电沿路径毁块**。把一直在算却无后果的 `ionization`/放电击穿接到 truth:
  (1)新效果类型 `{:damage_block, %{macro_index, amount, source}}`。(2)`ElectricDischargeKernel.tick` 除沿
  Dijkstra 击穿路径发热外,新发 `discharge_damage_effects`——对路径上**实心 macro 块且 health>0** 的 cell
  逐 tick 发 `:damage_block`(health=0 / 空 cell / 非实心 kernel 端跳过,避免误毁默认块);放电模式显式 opt-in
  故击穿伤害默认开,`breakdown_damage: false`/`%{enabled:false}` 关、`%{damage_per_tick:n}` 调
  (默认 `@default_breakdown_damage 25`)。(3)SystemActor:`gate({:damage_block,_})` 连续 always-commit
  (持续电弧逐 tick 累损,同 heat/delta 绕锁存)。(4)ChunkProcess:`apply_damage_block_effect` 读实心块
  **权威重校**(非实心 `:damage_target_not_solid` / health=0 `:damage_target_no_health` / amount≤0
  `:invalid_damage_amount` 显式 reject 不静默);`new=health-amount`,`new<=0` → `clear_macro_cell` 毁块
  (`destroyed?: true`)否则写回降 health;bump 版本 + push 快照。(5)field_source 放电 kernel spec 显式
  `breakdown_damage: %{enabled: true}`。(6)模型卡更正(描述/safety_valve note/assumptions 加击穿伤害)。
  测试:kernel 4(发射/health>0 门控/关闭/调量)+ ChunkProcess handler 6(减/毁/3 类 reject/快照)+ e2e 1
  (放电穿 health 块逐 tick 减至毁,快照反映)+ field_source spec 断言更新。scene 全量 **1001/0 零净回归**。
  实体伤害(`PartState.health` Phase4 既有 / voxel_damage_router)作后续。
- 2026-06-15:**R7 电路驱动负载完成,负载"通电"成权威 truth**。把一直在算却无世界后果的 `circuit_current`
  接到 truth:(1)`tag_catalog` append `:powered`(id 9,catalog_version 1→2,append-only 不破 wire)。
  (2)`CircuitCurrentKernel.tick` 除派生三层(电流/电位/离子化)外,新发 `:set_tag` 效果——闭合
  source-fed 回路中的 load cell(`electric_load` 材料,`ParticipantProjection.electric_role?(:load)`)
  加 `:powered`,region 内其余 load 去 `:powered`(断路即失电);经 SystemActor(set_tag always-commit)
  → ChunkProcess → 负载 truth。**负载通电成权威可观测状态 = 任何设备(门/灯/机器)行为的自包含基础**;
  具体设备动作是其上层,后续按需接。(3)模型卡更正:不再"纯派生不写权威",改"派生三层 + 负载 :powered
  派生→权威(RULE-11/AUTH-11)"。(4)`circuit_current_kernel_test` 10 处旧 `[]` 断言改绑 `_power_effects`
  (无负载的 1 处仍 `[]` 验"无负载不扰动")+ 加 `describe "R7:闭环电流驱动负载 :powered"` 4 焦点测
  (闭环→load `:powered`;开路含 load→去 `:powered`;无 load→无效果;破环→`:powered` 翻转清除)。
  scene 全量 **990/0 零净回归**(986+4 新测)。
- 2026-06-15:**R5d 对抗式评审修复**。多 agent 评审 workflow(4 维度 × 找→对抗核验)对反应层评 32 发现、
  确认 3 真 bug,全修 + 加测:(1)[high] 注热温度写无 clip → 越界 `put_attribute_for_cell` raise 崩
  ChunkProcess(燃烧辐射注热可达上界):`build_heat_energy_attribute_storage` clip target/delta 到温度边界
  饱和;`apply_field_effects` 单效果 rescue 防御纵深。(2)[high] `max_transforms` 安全阀不覆盖辐射(失控
  级联真正传播路径):改 `max_effects_per_tick` 覆盖每 tick 全部效果(reaction 优先,radiation 溢出截断);
  模型卡更正。(3)[medium] `resolve_threshold` 未知材料缺省阈值 0 反转惰性安全(未知材料 ≥0℃ 点燃):
  `MaterialCatalog.known_material?` 门控,未知材料不参与 material_threshold 反应。3 新单测;scene 全量 **985/0**。
- 2026-06-15:**R5 燃烧(旗舰涌现)全部完成,火能蔓延**。
  - R5a:Rule/Engine 泛化 tag_reaction + 多效果物化;燃烧规则 ignite/burn/burn_out;catalog 加 ash +
    burn_progress(id 13 add_delta,catalog_version→3)。inert ignition=5000℃ 天然门控可燃性。50/0。
  - R5b:ChunkProcess `:set_tag` handler(tag 名→id→合并 tag_set→intern,空集 ref0,幂等)+
    write_voxel_attribute 泛化到动态属性 delta(RMW + clip,burn_progress)+ **SystemActor 连续/锁存分流**
    (heat_energy_joules/delta 连续注入绕去抖,否则火不自维持;现有 conduction 连续 Joule 同受益)。17/0,
    ChunkProcessTest 46/46 零回归。
  - R5c:ReactionKernel 补读 burn_progress + per-cell tag;**truth 级蔓延机制 = burning cell 每 tick
    向相邻 solid cell 辐射热**(现有温度扩散只动 field 层不动 truth 而反应读 truth)。**端到端旗舰 demo**:
    点燃木 → 自维持燃烧放热 + 进度 → 燃尽成 ash;辐射热点燃相邻木(火蔓延)。3 e2e 全绿;**scene 全量
    982/0 零净回归**。
  - **燃烧涌现回路闭合**:flammable + 温度 → ignite(:burning)→ 注焦耳自维持 + 蔓延 → burn_out(ash)。
    后续涌现(电→世界等)同此骨架。
- 2026-06-14:**R3 ReactionKernel 驱动 + 端到端闭环完成,涌现回路打通**。新建
  `SceneServer.Voxel.Field.Kernels.ReactionKernel`(field-kernel adapter:读 region AABB 内已提交
  truth 的材料 + `effective_attribute_at "temperature"` → `Engine.evaluate` → `{:transform_material}`
  效果,经 `FieldTickWorker`→`SystemActor`→`ChunkProcess` 落 truth;`required_layers: [:temperature]`
  但读 truth 非 field 层;模型卡 EMG-1/3/7:`:qualitative` + `safety_valve reaction_budget`
  max_transforms_per_tick 截断防失控级联)。并入 `ModelCardRegistry`(6 kernel)。**端到端 demo
  (冰熔化)闭环验证**:置冰格 → `write_temperature_attribute` −10℃ → 反应 tick 不熔(阈值门控)→
  加热 +5℃ → 反应 tick 熔为水 → 订阅者收下行快照。3 e2e + 引擎/模型卡测试全绿(29/0)。scene 全量
  955 仅 1 个**预存 `:sys.get_state` 竞态 flaky**(`field_tick_worker_kernel_test` reuse-lifetime,
  与反应层无关,隔离 10/10 全过)→ **0 净回归**。
  **回路闭合:温度物理 → 读 truth → 阈值规则 → 材料转变 → 快照下行 → 客户端可见。骨架行为无关——
  燃烧/电→世界只需往 `Rules` 加规则 + 必要 coded kernel。**
- 2026-06-14:**R2 transform_material 效果通路完成**(SystemActor gate transform 锁存 + ChunkProcess
  apply_transform_material_effect:from 校验 + put_solid_block + 版本 bump + snapshot)。6 测试,
  ChunkProcessTest 46/46 零回归。
- 2026-06-14:**R1 纯核完成**(Rule/Rules/Engine 数据化规则引擎 + water 材料)。15 测试,material/
  attribute 既有测试全绿。
- 2026-06-14:决策稿落定。用户拍板"先搭行为无关骨架 + 规则两者结合"。拆 R1(纯核)/R2(效果通路)/
  R3(驱动闭环)。先执行 R1。
