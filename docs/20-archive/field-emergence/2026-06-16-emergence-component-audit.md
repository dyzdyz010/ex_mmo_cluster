# 涌现层「元件库」审计(2026-06-16)

用户原则:**「涌现 = 做元件,上层组合交给涌现」**。本文盘点现有元件库,诚实区分**真元件**
(可组合、行为无关的原语)与 **coded 行为**(为某设备写死的规则),并据此给元件化路线。
来源:3 路并行代码盘点(materials/state · physics kernels · reaction/effects)。

## 1. 现有元件库(真元件)

### 1.1 材料属性元件(`MaterialCatalog` + `AttributeCatalog`)— 干净
- **9 维内禀物理属性**(每材料填表,Q16.16 定点,`:material_default` 静态查表):density /
  thermal_conductivity / specific_heat_capacity / ignition_temperature / melting_point /
  freezing_point / boiling_point / electric_conductivity / dielectric_strength。
- **4 维动态真值属性**(`:add_delta`,运行时 per-cell):temperature / humidity / moisture /
  burn_progress。
- 这些是**最干净的可组合元件**:纯参数,被多个 kernel 通用消费;加新材料只填表,加新反应只读
  属性比阈值。

### 1.2 物理 kernel 元件(`field/`)— 干净的通用物理引擎
- **TemperatureDiffusion**(7-stencil 热弛豫,field 层叠加)/ **ReactionKernel 内守恒 Fourier
  truth 级热扩散**(Q=rate·ΔT/(1/C_hot+1/C_cold),源失=汇得,能量守恒)。
- **ElectricPotential / ConductionPath(Joule 热)/ ElectricDischarge(击穿)/ CircuitCurrent
  (闭环电流)**:全部从材料 electric_conductivity / dielectric_strength + 拓扑算电物理。
- **joules→温度转换器**(`ChunkProcess`:dT=Q/(density·specific_heat·volume)):**所有热源共享的
  材料感知原语**——正是它让「电→火」涌现而非脚本化。
- **✅ 核实 R6 是真涌现**:全代码**无「电点燃木」规则**;电 kernel 只发 `:temperature` 热和
  `:powered` tag,从不发 `:burning`。电→火 = Joule 热 → 材料感知 dT → 守恒扩散 → 温度过
  材料 ignition_temperature(wood 300℃,其余 5000℃ 惰性)→ 纯温度驱动的 `ignite` 规则置 :burning。

### 1.3 效果原语(`ChunkProcess.apply_*_effect`)— 干净的通用世界变化
transform_material / set_tag / write_voxel_attribute(heat_energy_joules 连续注热 / target / 动态
delta)/ damage_block。全部 generic,经 SystemActor 门控(连续热/delta/damage 绕去抖 always-commit;
离散 material/temp 量化锁存)落 truth。

### 1.4 物理派生状态 tag(true_primitive)
flammable / conductive / wet / frozen / burning —— 各对应一条物理属性派生路径。

### 1.5 反应规则中的真元件
6 条相变/燃烧规则(ice_melts / water_freezes / water_boils / steam_condenses / ignite / burn /
burn_out)= **emergent-from-physics**(材料阈值 + 温度/burn_progress 输入,无设备耦合)。

## 2. coded 行为(用户批评成立的地方)

- **`powered_heater`(R9a)= 最该退的一条**:`电负载 + :powered → 每 tick 发 100MJ`。**100MJ 是
  凭空断言的定性常量,不从任何 I/R/电压物理推导**。
- **`door_open` / `door_close`(R9b)= 确认的「被设计执行器」**:`material: :door` 专属的
  `:powered↔:open` tag 状态机,纯设计机关、无物理。
- 设备 tag:powered / open(设备/电路行为态);magical / structural / transparent(**无物理属性
  支撑的占位语义**)。
- 电角色 source / load:**硬编码 material_id 白名单**(== power_block / in [electric_load, door]),
  非属性派生(对比 conductor 是 conductivity≥1.0 阈值派生 = 真元件)。
- `Rule.material` 过滤字段 = 把通用 tag_reaction 引擎变成 per-device dispatcher 的那道缝——
  **正是 coded 设备行为嫁接到数据引擎的位置,也正是「真 actuator 抽象」该替换的东西**。

## 3. 关键发现:powered_heater 为什么是「假元件」(最高杠杆)

`CircuitCurrentKernel` **已经算出**每个负载的 `current_amps` + `effective_resistance`
(R_eff=loop_len/avg_conductivity),但**只发 `:powered` tag,把电阻功耗 I²R 扔了**。唯一发 Joule
热的是 `ConductionPathKernel` 的有向 source→target 通道(Q=V·I·dt/len),与「闭环电阻负载」是两套
机制。所以 heater 的 100MJ/tick **与任何 I²R 完全脱节,是 fiat 断言的热**。

→ **最高杠杆元件化**:加材料属性 `electric_resistance`(或用 1/conductivity)+ 让 CircuitCurrentKernel
把负载热按 **I²R**(电流来自闭环解算 × 材料电阻)注成已有的 temperature/heat_energy_joules 原语。
则 **`powered_heater` 规则整条消失**——高电阻 electric_load 通电即发热,是「载流」的物理后果。
**一条物理律同时涌现出:电阻加热、导线过热、保险丝熔断、短路起火**(全是 I²R + 已有的熔/燃)。

## 4. 缺口(为更丰富涌现缺的元件)

### 4.1 抽象缺口(直接对治当前 coded 行为)
- **通用 actuator 元件**:声明式「输入 tag/阈值 → 声明的机械/可通行/位移 状态变化(per-material
  参数化)」,替换 door/piston/gate/elevator 各自一对 bespoke 规则。设备变数据而非代码。
- **声明式 tag→碰撞/物理属性 绑定**:`:open`/`transparent`→可通行/透光 应**声明在 tag/材料上**,
  而非硬编码在碰撞分支。任何设备切可通行无需 bespoke collision 代码。
- **拓宽 condition 字段**:`@condition_fields` 写死 temperature/burn_progress 两个;接成「任意已注册
  属性/field」→ 「电流密度高则点燃」「高电位电解」等可数据表达,不必新 coded kernel。
- **多 cell / 邻居效果原语**:现所有效果只改源 cell;缺「向邻/新 cell 生成」(燃烧→上方空气格出烟/
  蒸汽;熔冰→水流出)。流体/气体扩散无法作规则效果表达。
- **相变潜热**:相变现为瞬时阈值翻转(无潜热)→ 温度不在熔/沸点形成平台。加 per-cell 潜热累加器让
  热力学更真更稳。

### 4.2 物理域缺口(更大的涌现前沿)
- **力学/结构应力**:无承重/支撑图/应力传播 kernel → 烧断/熔断承重梁不会引发重力坍塌。支撑渗流
  kernel(每实心格需有到地路径否则塌)= 巨大涌现源。
- **流体/压力**:water/steam 只是点态相变,不流动/汇聚/找平/施压;无锅炉爆裂、无洪水蔓延、无浮力。
- **磁/感应**:有电场无磁场闭环 → 无电磁铁/感应/电机/发电机(电域的自然延伸)。
- **光/辐射换热**:热扩散只有传导;无视线热辐射 → 火/热金属无法**隔空**点燃(现仅传导相邻可点)。
- **冲击波/超压**:放电沿路径毁块,但无爆炸超压(挥发物/蒸汽超压 → 径向冲击 + 衰减 + 毁块)。
- **化学通用性**:燃烧不耗氧化剂(无浓度场/气体混合/双反应物)→ 无密闭室窒息灭火、无混气爆炸、
  无 wet+iron 生锈。

## 5. 元件化路线建议(按杠杆排序)

1. **I²R 负载加热(消除 powered_heater)** — 最高杠杆:1 条物理律 → 删 1 条 coded 规则 + 涌现
   加热/过热/熔断/短路起火。加 `electric_resistance` 属性 + CircuitCurrentKernel 发 I²R 热。
2. **通用 actuator 元件 + 声明式 tag→碰撞绑定** — 把 door(及未来 piston/gate/elevator)从
   per-device 规则收敛成一个数据化执行器元件;`:open`=可通行声明在 tag。
3. **物理域补元件**(选其一开新域):结构应力(坍塌)/ 流体压力(流动·洪水·锅炉)/ 磁感应(电机)/
   辐射换热(隔空点燃)。每个都是一个新物理 kernel + 几维材料属性,组合涌现一大类玩法。

注:1、2 是「把已有 coded 行为退回成元件」(纠偏);3 是「新增元件开新涌现域」(扩张)。
