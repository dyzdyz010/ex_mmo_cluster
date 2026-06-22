# 光:第二个全新正交物理系统(光成真机制)

日期:2026-06-23
状态:决策稿(待逐 step 实现)
范围:`apps/scene_server`(权威光场 + kernel + 反应耦合 + wire)+ `clients/bevy_client`(解码 + 渲染)
目标(用户 /goal):**把光变成真机制**——光作为服务端权威场参与 gameplay,直到形式化验证
(kernel 形式属性 + 模型卡)+ 全测试(含实机 cargo/mix run)无错 + 客户端渲染完全正确。

## 背景

继 S4 化学(第一个全新涌现域)后,光是**第二个全新正交物理系统**。此前「热致白炽」只是
纯客户端渲染派生(从温度场算 emissive);现在把光提升为**服务端权威场**:发射→传播→影响世界。
遵循「正交物理系统 × 材料属性向量」架构:普适 kernel、激活由属性派生(非 id 白名单)、
系统间只经 committed truth 耦合、无 per-device 规则。

## 关键架构事实(recon 结论,带出处)

- **FieldRegion `@field_types` 是封闭白名单**(field_region.ex:16,18),field_types 由各 kernel
  `required_layers/1` 派生。加 `:light` 须改此白名单(唯一硬门)。
- **最近 kernel 模板 = ConductionPathKernel**:source → 按邻居 + per-cell 材料属性传播/衰减 →
  写 field 层(`FieldLayer.put`,带距离衰减 conduction_path:390-401)。光 = 从发光源 flood、
  按 opacity 衰减、不透明 cell 阻断。**传播纯 Elixir**(同 conduction_path 的 Elixir 路径,无需 Rust)。
- **kernel 双输出**:直接写 field 层(observe/wire,不动 truth)+ emit effects(truth)。两者独立。
- **注册**:kernel 须进 `model_card_registry.ex @kernel_modules`,且其 spec 须进某 region 的 `:kernels`
  (经 FieldSource.kernel_specs)方运行。tick 由 FieldTickWorker fold over region.kernels 驱动。
- **wire**:field_codec 加 `@field_mask_light 0x10` + compute_field_mask + encode/decode 值数组。
  光值用 **u8**(0..255,同 ionization,紧凑;ionization u8 纯属 codec 选择非 FieldLayer 属性)。
  线协议规范 §0x73 须更新(且 doc 已对 0x08 electric_current 失修,顺手补)。
- **反应耦合**:recon 默认建议「光落 truth 反应再读」(温度先例),但 light_level 每 tick 重算需
  override 语义,与 delta-accumulate 的 effect 路径有摩擦。**改用更轻的 Option A:同 tick 内读 field 层**——
  FieldTickWorker fold over region.kernels **按序**且 region 逐 kernel 线程传递,故令 **LightKernel 排在
  ReactionKernel 之前**:LightKernel 写 `:light` 层进 region → ReactionKernel 同 tick 从同一 region 读
  `:light` 层(无 truth 往返、无 override 语义)→ 光敏 effect(:illuminated tag)经现成 tag 路径落 truth。
  即**光是场(同温度场),只有它的 gameplay 效果(tag)是 truth**;无需 light_level truth 属性。
  两门:(a) `Rule.@condition_fields`(rule.ex:26)加 `:light`;(b) `ReactionKernel.cells_in_region`
  把 `FieldRegion.get_layer(region, :light)` 线程进 cell_state,加一行 `FieldLayer.get(light_layer, idx)`
  注入 cell.light(layer 缺省全 0 → 惰性安全)。Engine 仍纯(只读 cell.light)。
- **属性**:`priv/catalogs/attribute_catalog_v1.exs` append-only(现 max id 18,v7);bump v8。

## 设计

### 光源(属性派生,非白名单)
单 cell 发射强度 = `light_emission`(静态材料属性,如 ember/lamp 自发光)
+ `thermal_emission(temperature)`(温度过 Draper 525℃ 的热辐射,统一「金属高温发光」)。
两者皆物理态派生。

### 传播(纯 Elixir,形式可验)
多源 BFS flood(`LightPropagation` 纯模块):每 cell 光强 = max over 源的
`emission × 距离衰减 × 路径透射`;每步乘衰减因子并按 per-cell `opacity` 吸收;
光强跌破 ε 或遇全不透明 cell 停。frontier 预算熔断(EMG 安全阀)。
**形式属性(模型卡 assumptions + 属性测试守)**:
1. 单调衰减——光强随离源距离非增(无凭空增亮)。
2. 确定性——给定源集 + opacity 场,输出逐字节确定(无 Date/random)。
3. 有界——光强 ∈ [0, max_emission];frontier ≤ budget。
4. 源主导——无源 → 全 0;加源单调不减亮度。
5. 遮挡——全不透明 cell 后光强 = 0(墙挡光)。

### 影响世界(光敏元件,光作 condition)
新 tag `:illuminated`。新材料 `photo_sensor`(append-only id)。两条 tag_reaction(gate 在新
`:light` condition 维度,可逆,同 door `:powered↔:open` 范式;light 由 ReactionKernel 从同 tick 的
`:light` 层注入 cell.light):
- `photo_sensor` + `light ≥ threshold` + forbid[:illuminated] → add :illuminated
- `photo_sensor` + `light < threshold` + require[:illuminated] → remove :illuminated
即「光照→元件点亮 / 遮光→熄灭」,经 :illuminated tag 真改 truth 态。后续可接 actuator/passability 组合涌现。
**kernel 顺序硬约束**:LightKernel 必须排在 ReactionKernel 之前(同 tick region 线程,光层先写后读)。

### 客户端
解码 `:light` 场(wire mask 0x10,u8)。渲染:光场可作 ambient/glow 可视化;
热致白炽现可由权威光场驱动(增量2,本稿先把权威光场 + 解码 + 一个光场渲染立住)。Layer-3 像素。

## 属性 / 目录(append-only,bump v8)
- id19 `light_emission`(W,fixed32,material_default,static)——发光源强度(0 = 不发光,惰性安全)。
- id20 `opacity`(0..1,fixed32,material_default,static)——不透明度;default 1.0(实心默认挡光),
  ice/obsidian 等透光材料显式低值。空 cell 由 kernel 特判为透明(opacity 0,不经目录)。
- (Option A 下**不需要** light_level truth 属性——光是场,反应同 tick 读层。)
- 材料 `photo_sensor`(append-only,光敏)。tag `:illuminated`(tag_catalog append,bump)。
- 给 `ember` 配 `light_emission`(余烬自发光,自然);后续热致发光由 LightKernel 读温度派生。

## 逐 step 提交
1. 目录:attributes 19/20/21 v8 + 材料 photo_sensor + tag :illuminated + 单测
2. `LightPropagation` 纯传播核心 + **形式属性测试**(5 条不变量)
3. `LightPropagationKernel`(写 :light 层 + emit light_level truth effect)+ model_card + 注册 + 单测
4. FieldRegion `:light` 白名单 + wire codec(0x10 u8 encode/decode)+ round-trip 测 + 线协议规范更新
5. 反应耦合:Rule.@condition_fields += :light + ReactionKernel 注入 cell.light + photo_sensor 两规则 + 单测
6. kernel spec 接入 region(FieldSource)+ e2e(光源→传播→photo_sensor 点亮)
7. 客户端:wire `:light` 解码 + 光场渲染 + Layer-3 像素
8. 形式属性回归 + 全 scene 套件 + 全 bevy 套件 + 实机 run 验证

形式化:无定理证明器,故「形式化」= kernel 不变量显式化(模型卡)+ 严格属性测试(确定性/单调/
有界/遮挡/源主导,多输入)+ wire round-trip + e2e。不 push;mix 经 PowerShell `cmd /c "mix ..."`;
Layer-3 须 --test-threads=1。

## 后续增量(本稿外)
热致白炽改由权威光场驱动;光参与可见度/光合;彩色光/光谱。

---

# 实现现状(as-built,2026-06-23)

原 8 step 全部落地,并按 /goal「直到形式化验证 + 各种测试含实机无错 + 客户端渲染完全正确」
扩展到饱和。光从「纯客户端渲染派生」演进为**有权威场、有色彩、与全部涌现系统组合的一等正交光学系统**。

## 架构(最终)

- **`LightPropagation`**(纯 Elixir,无 NIF):多源最亮优先 flood = `-log(衰减)` 上的 Dijkstra。
  **关键修正**:opacity 门控「光穿过 cell 外传」(onward,源全透/非源 `1-opacity`)而非「cell 受光」——
  否则不透明 photo_sensor 收光 0 永不亮。形式不变量(模型卡 + 200 例属性测试):
  确定性 / 单调衰减 / 有界 / 源主导 / 遮挡。
- **`LightPropagationKernel`**(registry 第 7 kernel,**排 ReactionKernel 前**——同 tick region 线程,
  光层先写、反应后读):读 truth 投影源(`light_emission` + 热致 ≥Draper 525℃)+ opacity;
  **彩色**按源色分组各 flood、逐 cell 取最亮组(intensity 与无色逐字节等价);写 `:light` + `:light_color` 层。
- **耦合(Option A)**:光是场,ReactionKernel **同 tick 读 `:light` 层**注入 `cell.light`
  (`Rule.@condition_fields += :light`);只反应产物(tag/transform)落 truth。无 light_level truth 属性。

## 目录(最终,append-only)

- AttributeCatalog v6→**v10**:light_emission(19)/opacity(20)/growth_progress(21,dynamic)/
  light_color(22,packed RGB888 raw)。
- Material(append-only):photo_sensor(17 光敏)/sprout(18 光合幼苗)/glowstone(19 冷蓝纯光源);
  ember 配 light_emission + 暖橙 light_color;obsidian/sprout 低 opacity。bevy material_color 同步补 17-19。
- Tag:illuminated(12)。

## 世界效果(光成真机制,4 模式 × 全系统组合)

| 模式 | 规则 | 桥接系统 |
|------|------|---------|
| 改态 | photo_sensor + light≥32 ↔ `:illuminated`(可逆) | 反应 |
| 驱动设备 | Actuator{photo_sensor,:illuminated,:open} → 可通行 | 设备/passability(**与电门 :powered→:open 对称**) |
| 长生命 | sprout + light≥32 + 相邻 water → growth_progress 累进 → 成熟 wood | 多反应物 + 反应进度 |
| 放大镜 | photo_sensor + light≥128 → emit_heat → 扩散熔/燃 | 热 |

## wire(0x73)

- `FIELD_MASK_LIGHT 0x10`(u8 强度,wire-last after ionization)+ `FIELD_MASK_LIGHT_COLOR 0x20`
  (3 u8 RGB/cell,附加,不破 0x10 格式)。线协议规范 §0x73 已更新(顺手补历史失修的 0x08)。
- 客户端渲染:light overlay 暖白强度 ramp;**彩色**把 packed RGB 烤进 marker id
  (`LIGHT_COLOR_PACKED_BASE 0x0100_0000 + packed`,u32 精确)→ `field_color` 解包 → 按 cell 实色渲染。

## 验证(全绿)

- 形式化:`LightPropagation` 五不变量 + 200 例 seeded 属性测试 + 模型卡。
- scene_server **1165 tests 0 failures**(含 catalog/codec/kernel/4 个全 DB truth e2e:
  点亮/遮光/光门可通行/光合成熟/放大镜升温)。
- bevy **282 lib + 16 Layer-3 GPU**(RTX 5060 实测:光场暖白、彩色光暖/冷正确上屏、全材料无 magenta)。
- 跨语言 wire golden 双锁:`field_region_light`(0x10)+ `field_region_light_color`(0x30),server↔bevy 字节级。
- 双端编译 warning-clean(server `--warnings-as-errors`、client 零警告);客户端 `--voxel-headless` boot exit 0。

# 后续方向决策树(待用户拍板)

光学在「场 × 机制 × 色彩」三维已饱和。剩余为**性质不同的大方向**:

1. **可见度/视野**(gameplay,最大值):光决定玩家所见——暗处隐藏、亮处显形。
   **难点**:需**弥漫光**(全 chunk ambient + 源),而非当前稀疏 `:light` 源区域;
   触及核心场景渲染(当前固定 AmbientLight → 改为光场调制)+ 服务端 region provisioning。**大,需设计拍板**。
2. **热致白炽渲染统一**(渲染清理):客户端 incandescence(温度→黑体,client 派生)改由权威光场驱动。
   **争议**:incandescence(发射,源的黑体色)与光场(照度)语义不同,统一会丢源色信息。**价值存疑**。
3. **彩色光谱 deeper**:波长选择性反应(只对红光光合的植物等)。小,但偏 niche。
4. **转新涌现域**:S5 力学应力坍塌 / 流体压力(与光无关的新正交系统)。

推荐:若续光学,**可见度**价值最高但最大;否则转 S5 新域。均需用户定 scope/方向。
