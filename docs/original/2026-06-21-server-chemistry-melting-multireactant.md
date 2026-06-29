# 服务端化学扩展:熔化相变 + 多反应物 A+B→C

日期:2026-06-21
状态:决策稿(待逐 step 实现)
范围:`apps/scene_server` 反应层(`Reaction.Engine` / `Rules` / `MaterialCatalog` / `ReactionKernel`),
外加 bevy 客户端材质上色跟进。

## 背景

涌现反应层(R1–R8)已闭合「物理→truth→规则→世界变化」回路。当前相变只有
ice↔water↔steam(温度阈值瞬时相变),化学只有单 cell 自身状态驱动的反应
(combustion / iron oxidation,start/sustain/complete recipe)。两个明显缺口:

1. **熔化**:固体在高温下应熔成液态材料(iron→molten_iron、stone→lava),目前没有。
2. **多反应物**:反应只看 cell 自身,无法表达 `A + 相邻 B → C`(如 lava 遇 water)。
   `Reaction.Engine.evaluate/2` 是**纯逐 cell 函数**,`evaluate_cell/2` 只拿到单个 cell,
   完全看不到邻居——这是当前架构的硬约束。

## 关键事实(recon 结论,带出处)

- 相变 `:ice_melts`(`reaction/rules.ex:14-21`)是温度阈值相变的精确模板:
  `condition: {:temperature, :gte, {:material_threshold, "melting_point"}}`,读 `from_material`
  **自身**的 `melting_point` 属性。熔化与之结构完全相同,**不需改 Engine**。
- 迟滞:melt 用 `:gte`、freeze 用严格 `:lt`,同阈值下 0℃ 冰熔但水不立即回冻,防振荡
  (`rules.ex:23-24`)。新熔化/凝固对沿用此纪律。
- 材质 id **append-only**(`material_catalog.ex:23`)。当前 1–13;新增从 14 起。属性 Q16.16
  定点(`round(value * 65_536)`),`@inert_temperature_raw`(5000℃)= 该相变实质不可达。
- Engine **无邻居读**:`evaluate/2` = `Enum.flat_map(cells, &evaluate_cell/2)`(`engine.ex:36`),
  cell map 仅含自身字段。多反应物必须把邻居信息**作为 cell 数据喂进去**。
- **`ReactionKernel` 已有邻居基建**:`neighbors_in_region/2`(`reaction_kernel.ex:200`,六向、
  AABB 内)+ 热扩散里的 `by_index = Map.new(cells, &{&1.macro_index, &1})`(`:158`)。
  多反应物复用这两者即可在 `Engine.evaluate` 前给每个 cell 填 `neighbor_materials`。

## 设计

### 26a 熔化(零 Engine 改动)

新材质(`material_catalog.ex`,append-only):
- **id 14 `molten_iron`**:复制 iron;`freezing_point = 1538℃`(可回凝);
  `oxidation_temperature = inert`(熔铁不锈)。
- **id 15 `lava`**:复制 stone;`freezing_point = 1200℃`(= stone `melting_point`,迟滞回凝)。

新相变规则(`reaction/rules.ex` 的 `@base`,逐字照抄 `:ice_melts`/`:water_freezes` 形态):
- `:iron_melts` iron→molten_iron `temperature ≥ melting_point`(铁 1538℃)
- `:molten_iron_solidifies` molten_iron→iron `temperature < freezing_point`(严格 `<` 迟滞)
- `:stone_melts` stone→lava `temperature ≥ melting_point`(石 1200℃)
- `:lava_solidifies` lava→stone `temperature < freezing_point`

熔化产物的温度由现有守恒 Fourier 热扩散(`ReactionKernel`)自然驱动:电加热的铁
/ 燃烧热 → 邻格升温 → 跨阈熔化。无需新热源。

### 26b 多反应物 A + 相邻 B → C(最小 Engine 扩展)

采用「邻居材料作为 cell 数据」方案(保持 Engine 纯逐 cell,邻居信息由 caller 预算):

1. **cell 形状**:加可选 `neighbor_materials: [atom]`(默认 `[]`)。
2. **`Rule`**:加 `require_neighbor_materials: []` / `forbid_neighbor_materials: []`
   (与现有 `require_tags`/`forbid_tags` 平行),`new!/1` 校验为已知材料 atom 列表。
3. **`Engine`**:`:tag_reaction` 匹配在 `tags_match?` 旁加 `neighbors_match?`——
   `require_*` 全部出现在 `cell.neighbor_materials`、`forbid_*` 一个都不出现。纯函数,
   不耦合其他 cell。
4. **`ReactionKernel`**:`cells_in_region` 后,用已有 `neighbors_in_region` + `by_index`
   给每个 cell 填 `neighbor_materials`(邻格材料 id → atom 名)。

演示规则(经典 A+B→C,新产物 **id 16 `obsidian`** 证明产物依赖**双反应物**):
- `:lava_quench_to_obsidian` lava + 相邻 water → **obsidian**(熔岩遇水淬成黑曜石玻璃)
- `:water_flash_to_steam` water + 相邻 lava → steam(水侧被熔岩闪蒸)

一个 tick 内两条对同一快照求值,lava→obsidian、water→steam 同时发,下一 tick 不再相邻反应。
纯邻接门控(lava 定义上够热),不再叠加温度条件,作 A+B→C 最清晰示例。

### 冲突分析

phase_transition(至多一条)与 tag_reaction transform 可能同 tick 对同格各发一条
`:transform_material`。本设计刻意让产物对齐避免歧义:
- water 同时可能 `water_boils`(phase)与 `water_flash_to_steam`(tag)→ 都产 steam,无冲突。
- lava 同时可能 `lava_solidifies`(phase,仅低温)与 `lava_quench_to_obsidian`(tag)→
  低温 lava 本就要凝固,遇水成 obsidian 优先级语义可接受(产物不同但 obsidian 更具体);
  正常熔岩(高温)不触发 `lava_solidifies`,只走淬火,无冲突。

### 客户端跟进(不留「服务端产物客户端 magenta」)

bevy `chunk_render.rs::material_color` 当前到 id 13;补 14/15/16:
- 14 molten_iron:炽亮橙红 `[1.0, 0.5, 0.15]`
- 15 lava:暗炽橙 `[0.85, 0.30, 0.08]`
- 16 obsidian:近黑带蓝紫高光 `[0.10, 0.08, 0.14]`

(辉光留待 #24 emissive 轨;此处仅补基础色避免 magenta。)

## 测试计划

- `reaction/rules` 或 `material_catalog` 单测:14/15/16 已知、属性正确、id append-only。
- Engine 单测:`neighbors_match?` 正/负;`require/forbid_neighbor_materials` 校验。
- 相变单测:iron@≥1538→molten_iron、molten_iron@<1538→iron、stone@≥1200→lava、lava 回凝。
- 多反应物单测:lava+邻 water→obsidian、water+邻 lava→steam;无邻则不反应。
- ReactionKernel 单测:`neighbor_materials` 正确填充(用已有 region/storage fixture)。
- bevy `material_color` 单测:14/15/16 非 magenta。

## 逐 step 提交

1. 材质 14/15/16(catalog)+ 单测
2. 熔化相变规则 + 单测(零 Engine 改动)
3. Engine/Rule 邻居门控扩展 + 单测
4. ReactionKernel 填充 neighbor_materials + 单测
5. 多反应物演示规则 + 单测
6. bevy material_color 14/15/16 + 单测

不 push;Windows 下 `cmd /c "cd /d D:\dev\ex_mmo_cluster && mix ..."`。
