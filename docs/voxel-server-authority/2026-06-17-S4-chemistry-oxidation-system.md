# S4 设计:化学/氧化普适系统(2026-06-17)

正交架构(`2026-06-16-orthogonal-systems-architecture.md`)第四刀,也是**第一个全新涌现域**。把当前
「燃烧特例规则」升格为通用化学:抽一层声明式 `ChemicalReaction` recipe 表(仿 S3 `Actuators`),**燃烧
与氧化(铁→锈)都由同一 recipe 模板生成**,结构上证死「燃烧=化学的一个实例」,氧化作第二实例证
「加化学反应=加数据」。

> 产物来源:多 agent workflow 的「理解现状」阶段(3 份独立读者交叉核验 reaction/engine/catalog/commit
> 通路,结论一致);设计/评审/对抗阶段因 API 过载(500/529)未跑通,综合 + 对抗核验由主循环据收敛映射 +
> 自审完成,关键风险见 §7。

## 0. 决策锁定(2026-06-17 用户拍板)

- **Q1 范围 = S4a + S4b 一起**:本轮直接抽 `ChemicalReaction`/`ChemicalReactions` recipe 表,把燃烧 +
  氧化都收敛成声明式 recipe(燃烧展开须与现行逐条等价)。
- **Q2 速率 = 规则常量**:`rate` 写在 recipe 里(类比 burn 0.025),氧化取小值(见 §7-R2)。每材料
  `oxidation_rate` 属性 defer 到加第二种可氧化材料时(YAGNI)。
- **Q3 微放热 = 加极小放热**:氧化 recipe emit 少量焦耳,展示 chemistry→temperature→守恒热扩散 跨系统
  truth 耦合(S4 正交看点),量级远低于燃烧、不触发邻居相变。

## 1. 支点:燃烧「已经是」一个化学实例

`reaction/rules.ex` 的 `ignite`/`burn`/`burn_out` 是**纯数据 `tag_reaction` 规则**,激活靠属性派生
(任意材料温度过自身 `ignition_temperature` 即点燃;惰性材料 = 哨兵 5000℃ `@inert_temperature_raw`
不可达,天然不燃),**无 material_id 白名单、无 coded kernel**。Engine 纯函数对 cell 求值,ReactionKernel
读 truth 构 cell + 守恒 Fourier 热扩散。S4 不是推倒重来,而是抽出这个「起燃→持续→完成」的 3 规则模板,
让燃烧与氧化都成为它的数据实例。

## 2. 统一 recipe 模板(燃烧与氧化同构)

新增 `SceneServer.Voxel.Reaction.ChemicalReaction`(struct)+ `ChemicalReactions`(规格表 + `to_rules/0`),
**完全仿 S3 `Actuator`/`Actuators`**。一条 recipe:

```elixir
%ChemicalReaction{
  id: :combustion,                      # 规则 id 前缀
  material: nil,                        # 反应物过滤:nil=任意过门材料;atom=仅该材料(反应物身份)
  gate_attr: "ignition_temperature",    # 起反应温度门(material_threshold,惰性=哨兵不可达)
  active_tag: :burning,                 # 反应中状态 tag(latch)
  progress_attr: "burn_progress",       # 进度属性(add_delta,满 1.0 完成)
  rate: 0.025,                          # 每 tick 进度增量(规则常量)
  heat_per_tick: 30_000_000.0,          # 每 tick 放热焦耳
  product: :ash                         # 完成产物
}
```

`to_rules/1` 把每条 recipe 展开成**三条既有 `tag_reaction` 规则**(Engine 不变):

1. **start**:`material` 过滤 + `forbid [active_tag]` + `condition {:temperature, :gte,
   {:material_threshold, gate_attr}}` → `add active_tag`。
2. **sustain**:`material` + `require [active_tag]` → `emit_heat_joules heat_per_tick` +
   `advance_attribute progress_attr rate`(连续效果)。
3. **complete**:`material` + `require [active_tag]` + `condition {progress_field, :gte, {:value, 1.0}}`
   → `transform product` + `remove active_tag`。(`progress_field` = `progress_attr` 的 atom 形。)

**燃烧 recipe**(`material: nil`,gate `ignition_temperature`,tag `:burning`,product `:ash`)展开出的
三条规则与现行 `@ignite`/`@burn`/`@burn_out` **逐条等价**(仅 rule id 名变)——结构上证「燃烧=化学实例」。

**氧化 recipe**:`%ChemicalReaction{id: :iron_oxidation, material: :iron, gate_attr:
"oxidation_temperature", active_tag: :rusting, progress_attr: "oxidation_progress", rate: 0.005,
heat_per_tick: <极小>, product: :rust}`。展开出 oxidize_start/oxidize/oxidize_complete 三条,与燃烧
**同模板异参数**——「加化学反应=加一条 recipe 数据」。

**为何氧化用 `material: :iron` 而非 `nil` + 哨兵**:燃烧产物对万物都是 ash(通用),故 `material: nil` +
`ignition_temperature` 哨兵属性派生即可;**氧化产物是反应物专属**(铁→锈,铜→铜绿不同),故 recipe 须
按反应物命名其产物——这与 `phase_transition` 的 `from_material`(冰→水)、S3 `Actuator` 的 `material:
:door` 同范式:**反应/配方天然命名其反应物,这是 recipe 身份,不是「系统激活白名单」**(后者指普适场系统
该碰哪些 cell,须属性派生;前者指一条具名反应消耗哪个反应物)。`oxidation_temperature` 仍作起反应温度门
(铁 0℃ 以上才锈、冻铁不锈),保留属性派生的激活条件。

## 3. 必要的 coded 改动(极小,一次性)

唯一需触 Elixir 的是「让 condition 能读 `oxidation_progress`」+ recipe 脚手架,皆 append 式:

1. **`reaction/engine.ex` `field_value/2`**:加通用兜底子句 `defp field_value(field, cell), do:
   Map.get(cell, field, 0.0)`(保留 `:temperature` 特例)。此后**新增任何进度类 condition 维度不再改
   Engine**。
2. **`reaction/rule.ex` `@condition_fields`**:append `:oxidation_progress`。
3. **`field/kernels/reaction_kernel.ex` `cell_state/2`**:注入 `oxidation_progress`(`scaled_attribute`),
   镜像现有 `burn_progress`。
4. **`reaction/chemical_reaction.ex` + `chemical_reactions.ex`**:recipe struct + 规格表 + `to_rules`
   展开(脚手架,仿 Actuator/Actuators)。`rules.ex`:删字面 `@ignite/@burn/@burn_out`,`@base` 仅留
   相变(ice/water/steam),`all = @base ++ ChemicalReactions.to_rules() ++ Actuators.to_rules()`。

**其余全是数据**:rust 材料、iron 氧化属性、新 attr/tag catalog、两条 recipe。`oxidation_progress` 走现成
通用 `add_delta` 通路,放热走 `emit_heat`,SystemActor/ChunkProcess 分流自动覆盖,transform 走现成
`transform_material`——**零新效果原语、零新 kernel、零 SystemActor/ChunkProcess 改动**。

## 4. 新增 catalog 项(append-only)

| 项 | catalog | id | merge_rule | dynamic | default | min/max | 说明 |
|---|---|---|---|---|---|---|---|
| `oxidation_temperature` | AttributeCatalog | 16 | material_default(0x05) | false | 哨兵 `@inert_temperature_raw`(5000℃) | absolute_zero / 5000℃ | 起反应温度门;iron 配低值、rust 配哨兵 |
| `oxidation_progress` | AttributeCatalog | 17 | add_delta(0x02) | true | 0 | 0 / 1.0(65536) | 动态氧化进度,满即相变(镜像 burn_progress id13) |
| `rusting` | TagCatalog | 11 | — | — | — | — | 氧化中 latch(对称 burning) |
| `rust` | MaterialCatalog | 12 | — | — | — | — | 氧化终产物:不导电、oxidation_temperature=哨兵(不再氧化) |

- **AttributeCatalog v5→6**:`attribute_catalog_test` 计数 15→17、版本断言、加 2 条 lookup。
- **TagCatalog v3→4**:`tag_catalog_test` 计数 10→11、版本、names 更新。
- **MaterialCatalog**:加 `@rust_material_id 12` + `:rust` 属性向量(electric_conductivity≈0、
  oxidation_temperature=哨兵);**iron(id5)追加 `oxidation_temperature`=低值**(起锈门)。**因氧化 recipe
  带 `material: :iron` 过滤,只 iron 被评估,无须给其余 10 材料配 `oxidation_temperature`**(消解 §7-R1)。
  `material_catalog_test` 加 rust + iron 氧化属性断言。

## 5. 正交性与 truth 耦合

- **燃烧激活=属性派生**(`material: nil` + `ignition_temperature` 哨兵);**氧化=具名反应物 recipe**
  (`material: :iron`,同 phase_transition from_material 范式)+ `oxidation_temperature` 起反应温度门。
  二者**同一 recipe 模板、同一 `to_rules` 展开** → 结构上是同源化学,非并列特例。
- **只经 committed truth 耦合**:氧化微放热 → 写 temperature truth → 既有守恒 Fourier 热扩散读温度传
  邻居 → 可触发相变/再燃。氧化不直接调热/流体系统。
- **跨系统组合涌现彩蛋**:iron 在通电回路里生锈 → 变 rust(不导电)→ **电路自然断开**(化学 × 电磁经
  truth 组合,无任何「锈了断电」规则)。作一条 e2e 展示(§10)。

## 6. model card / 安全阀

氧化挂在 **ReactionKernel 既有 `:qualitative` model card + `reaction_budget`(max_effects_per_tick
4096,覆盖反应+热扩散全部效果)**下,无新 kernel → 无新安全阀。`oxidation_progress` delta 受 ChunkProcess
clip 到 1.0 天然有界;放热远小于燃烧 30MJ。model card assumptions 补一条「氧化=缓慢放热,定性档,非真实
锈蚀动力学」。

## 7. 风险与缓解(含自审对抗发现)

- **R1(已被设计消解):缺省 0 让万物生锈** —— 原忧 `oxidation_temperature` 缺失键回退 0℃ 致常温万物
  生锈。**recipe 带 `material: :iron` 过滤后只 iron 被评估**,非 iron 永不匹配氧化规则 → 无须给全 12
  材料配属性,风险消失。仅 iron(低)+ rust(哨兵,防御)配 `oxidation_temperature`。
- **R2(major,已纳入设计):氧化太快破坏焦耳热 e2e** —— `circuit_joule_heating_e2e` 用 6 个 iron 跑
  **80 tick + ReactionKernel**;iron 在热回路里温度 ≥ 起锈门 → 起锈推进进度,速率过大会中途把 iron 转 rust
  (不导电)→ 断路 → 负载不热 → 冰不化 → **e2e 失败**。缓解:**rate=0.005**(锈成约 200 tick),80 tick
  仅 0.4 < 1.0,iron 保持 iron。氧化 e2e 则同步驱动 ≥200 tick 才见锈。实施须**核验所有「iron +
  ReactionKernel 多 tick」测试** iron 不被转走。
- **R3(minor,预期):rust 不导电改变涉 iron 电路涌现** —— 设计意图(§5 彩蛋);电路单测不挂
  ReactionKernel/tick 少,iron 不会锈;焦耳热 e2e 由 R2 速率护住。
- **R4(S4b):燃烧收敛进 recipe 行为漂移** —— 缓解:recipe 展开与现行 ignite/burn/burn_out **逐条等价**,
  加测试断言「燃烧三规则由 `ChemicalReactions.to_rules` 生成且等价」;燃烧全套 e2e/单测照过。
- **R5(minor):cell_state 多读一属性热循环开销** —— 边际;记 TODO,后续按 Rules 静态推导属性清单按需读。

## 8. 范围与 defer(显式,无 silent cap)

**IN(本步 S4a+S4b)**:`ChemicalReaction` recipe 模板 + 燃烧/氧化两实例;iron→rust 经 `material: :iron`
recipe + `oxidation_temperature` 温度门激活、`oxidation_progress` 累进、`:rusting` latch、极小放热经 truth
耦合、rust 终产物不再氧化;Engine `field_value` 通用化 + `@condition_fields` append + cell_state 注入。

**DEFER(显式声明)**:湿度促进生锈(humidity/moisture/wet 闲置项,需多条件 AND);产气/oxygen field
(无 oxygen 属性,隐含无限氧);邻居氧化蔓延(无邻居 transform 原语,每 iron cell 独立);多条件
`{:all,[...]}` condition 组合;每材料 `oxidation_rate` 属性(Q2 defer)。

**本步之后(S5+)**:力学应力坍塌 → 流体压力 → 辐射换热 → 磁感应,各独立 step。

## 9. 迁移步骤(逐 step commit + 全量回归闸门)

- **S4-1**:AttributeCatalog v5→6 加 `oxidation_temperature`/`oxidation_progress` + `attribute_catalog_test`。
- **S4-2**:TagCatalog v3→4 加 `:rusting` + `tag_catalog_test`。
- **S4-3**:MaterialCatalog 加 `rust`(id12)+ iron 配 `oxidation_temperature` + `material_catalog_test`。
- **S4-4**:Engine `field_value` 通用兜底 + Rule `@condition_fields += :oxidation_progress` + ReactionKernel
  `cell_state` 注入 oxidation_progress + `chemical_reaction.ex`/`chemical_reactions.ex`(recipe 模板 + 燃烧
  /氧化两 recipe + `to_rules`)+ `rules.ex` 迁移(`all = @base ++ ChemicalReactions.to_rules() ++
  Actuators.to_rules()`)。`chemical_reactions_test`(燃烧 recipe 展开逐条等价 + 氧化展开正确)+ `engine_test`
  加氧化行为 + 燃烧不变断言。
- **S4-5**:`oxidation_e2e_test`(iron 驱动 ≥200 tick → `:rusting` → oxidation_progress 累进 → 转 rust;
  惰性/未知材料不锈;[彩蛋] iron 通电回路锈→断路)。**scene 全量回归(0 净回归)**。

## 10. 测试计划

- **燃烧等价回归**:`engine_test`/`combustion_e2e_test`/`combustion_effects_test` 全绿;加「燃烧三规则由
  `ChemicalReactions.to_rules` 生成且与字面等价」断言(combustion-as-instance 结构证明)。
- **氧化单测**(`engine_test` + `chemical_reactions_test`):iron 过起锈门 → 加 `:rusting`、推进
  oxidation_progress;进度≥1 → 转 rust + 去 `:rusting`;rust 不再氧化;非 iron(material 过滤)不锈;
  未知材料不锈(`known_material?` 惰性安全)。
- **氧化 e2e**(`oxidation_e2e_test`,真 ChunkProcess):iron ≥200 tick → rust;惰性负例;[彩蛋] iron
  通电回路锈→断路(化学×电磁涌现)。
- **catalog 版本/计数测**:AttributeCatalog 17/v6;TagCatalog 11/v4;MaterialCatalog rust + iron 氧化属性。
- **scene 全量**:0 净回归。
