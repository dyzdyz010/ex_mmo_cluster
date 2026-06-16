# 涌现层目标架构:正交物理系统 × 材料属性向量(2026-06-16)

用户拍板(2026-06-16)涌现层根架构:**不枚举「设备=行为」,而是让正交的物理系统按材料属性
在每个方块上自动开关、经 truth 组合,行为从组合里涌现**。本文把它落成可执行规范:系统清单、
每系统由哪些材料属性 + 阈值开启、系统间如何经 truth 耦合、现状映射、迁移路线、不变量。

前置:`2026-06-16-emergence-component-audit.md`(元件库审计,真元件 vs coded 行为)。

## 1. 原则(formal)

1. **材料 = 一个物理属性向量**(载体是方块:宏格 + 微格)。属性分两类:静态内禀常量
   (`:material_default` 查表,如 density/conductivity)+ 动态 per-cell 真值(`:add_delta`,如
   temperature)。
2. **每个物理系统是一个普适引擎**,对一个方块:
   - **激活 = 材料属性派生**(该属性非哨兵 / 过阈),**不是 material_id 白名单**。
   - 用该材料的属性做参数运行。
   - 只经**共享效果原语**写 committed truth(material/attribute/tag)。
3. **系统间只经 committed truth 耦合**(A 写 temperature → B 读 temperature),**禁止系统→系统直接
   调用**。这条是「组合涌现」的保证:加一个系统不改别的系统,链路自己长出来。
4. **行为 = 共活系统 × 连通方块 × truth 耦合 的涌现结果**,**无 per-device 规则**。所谓「设备」是
   材料属性组合在玩家搭建的拓扑上跑出来的结果(电路、加热器、门 = 属性 + 拓扑,不是代码分支)。
5. **惰性安全**:无对应属性 / 哨兵值的材料不参与该系统(未知材料零行为,不被缺省阈值反转)。
6. catalogs append-only(wire 冻结);每系统带 model card(fidelity_class + safety_valve)。

## 2. 系统 × 材料属性矩阵(核心)

> 「开启 gate」= 满足即该系统在此方块激活;「参数」= 激活后用的材料属性;「耦合」= 经 truth 影响谁。

| 系统 | 开启 gate(属性派生) | 参数(材料属性) | 产出(写 truth 原语) | 经 truth 耦合到 | 现状 |
|---|---|---|---|---|---|
| **热扩散** | 普适(所有实心方块) | thermal_conductivity, density, specific_heat | temperature(注热/扩散) | 相变·化学·电(I²R) | ✅ 正交 |
| **相变** | melting/freezing/boiling_point 非哨兵 | 三阈值(+ **潜热 latent_heat 新**) | transform_material(冰↔水↔汽) | 热(潜热缓冲)·流体 | ✅ 正交(缺潜热) |
| **电磁** | conductivity≥阈→conductor;**目标:有 emf→source、有 resistance→load** | conductivity, dielectric_strength, **electric_resistance 新** | potential/current/ionization;**I²R 注热 新**;:powered | **热(I²R)**·化学(电解) | ⚠️ conductor 正交;source/load 白名单破;I²R 缺 |
| **化学/氧化** | **目标:温度≥反应阈 + 反应性属性**(普适系统) | ignition_temperature, **oxidation_rate/reactivity 新**, 反应物 | 注热·transform(→ash/rust)·tag(:burning) | 热·流体(产气) | ⚠️ 燃烧是特例规则,无通用化学系统 |
| **力学/结构** | **缺:有 strength/support 属性** | hardness, tensile/yield_strength | 应力/坍塌(damage·重力位移) | 热·化学(烧断梁→塌)·流体 | ❌ 缺 |
| **流体/压力** | **缺:相态=液/气** | viscosity, buoyancy, surface_tension | 流动/压力(**多 cell 效果 新**) | 相变(水→流·灭火)·热 | ❌ 缺 |
| **辐射换热** | **缺:有 emissivity/opacity** | emissivity, opacity | 视线热传递(隔空) | 热 | ❌ 缺(现仅传导) |
| **磁/感应** | **缺:有 permeability** | permeability, remanence | B 场/感应电动势 | 电(induction·电机) | ❌ 缺 |

注:电磁的「热扩散 ← I²R」就是正交链「电系统(因导电而开)× 电阻 → 热 → 热系统 → 过着火点 →
化学/燃烧系统」的第一段;`powered_heater` 规则是抄近路绕过它,该删。

## 3. 现状映射(从审计)

- **已正交(保留为范本)**:热扩散(普适)、相变(阈值数据规则)、conductor 角色(conductivity≥1.0
  阈值派生)、燃烧的**点燃**(温度≥ignition 阈,惰性=5000℃ 哨兵天然门控)。**R6 电→火确认是真涌现**
  (无「电点燃木」规则)——这正是目标架构已跑通的证据。
- **破了正交(要纠)**:
  - `source`/`load` 电角色 = 硬编码 material_id 白名单(`== power_block` / `in [electric_load, door]`)。
  - `powered_heater`(R9a)= 凭空断言 100MJ;电路已算 current+resistance 却丢弃 I²R。
  - `door_open/close`(R9b)= per-material-id coded actuator。
  - 设备 tag powered/open 是行为态;magical/structural/transparent 无物理属性支撑。

## 4. 目标改造(让一切属性派生 + 正交)

1. **系统参与改属性派生**:加电属性 `emf`(/voltage_source)→ source、`electric_resistance` → load;
   去 `power_source_material?`/`electric_load_material?` 的 id 白名单。任何材料配属性即参与。
2. **物理产物经 truth 自然耦合**,删抄近路规则:I²R 注热替代 `powered_heater`;化学/氧化做成普适系统
   替代燃烧特例。
3. **actuator 也正交化**:门不是 per-door 规则,而是一个通用「机械响应」系统——材料带「受激响应」
   属性(`:powered`/阈值 → 声明的状态变化:passability/位移),门/活塞/闸门只是不同属性参数实例。
   配套:**声明式 tag/state → 碰撞属性 绑定**(`:open`/`transparent` → 可通行/透光 声明在 tag/材料,
   非硬编码碰撞分支)。
4. **补缺系统**(逐个开新涌现域):化学/氧化 → 力学应力 → 流体压力 → 辐射 → 磁。每个 = 1 物理 kernel
   + 几维材料属性 + model card。
5. **效果原语补缺**:多 cell/邻居效果(燃烧→上方出烟;熔冰→水流出);拓宽 condition 字段到任意已注册
   属性/field(让「电流密度高则点燃」等可数据表达);相变潜热累加器。

## 5. 迁移路线(按杠杆,逐步 commit + 回归闸门)

- **✅ S1 电磁正交化(已完成 2026-06-16,纠 R9a + 示范正交)**:① 加 `electric_resistance` 材料属性
  (AttributeCatalog id 14 v4;electric_load=50Ω 发热元件、door=0 机械执行器不热);② CircuitCurrentKernel
  对闭环载流的 load cell 按 **I²R = current²·electric_resistance·gain** 发已有 temperature 注热原语
  (gain 5000 定性档,同 R6d 单 voxel 热源场网格稀释洞察);③ **删 `powered_heater` 规则**。
  **e2e 验收通过**:真实闭环电路(电源+iron 环+electric_load)→ 载流负载 I²R 自然发热(升至 362℃)→
  守恒热扩散 → 相邻冷冰(-10℃)熔化(进而汽化)——**全程无 heater 规则**。scene 全量 1010/0。
  门(load,R=0)同机制载流但不热——发热与否由材料属性正交分流,证「属性派生产热」+「系统经 truth
  组合涌现」。导线过热/熔断/短路起火同律涌现(后续给 wire 材料配 resistance 即可验证)。
- **✅ S2 source/load 属性派生(已完成 2026-06-16)**:加 `emf` 材料属性(AttributeCatalog id 15 v5;
  power_block emf=120V)。`power_source_material?` = `emf > 0`;`electric_load_material?` =
  `electric_resistance > 0`——**去掉 material_id 白名单**,任何配 emf/电阻的材料自动成为 source/load。
  door 配小电阻 0.5Ω(螺线管作动器)以经属性成为 :load。scene 全量 1010/0。注:source 电压仍来自
  field source_points(emf 目前作角色 gate;源电压由 emf 派生作后续微调)。
- **S3 actuator 正交化**:通用机械响应系统 + 声明式 tag→碰撞绑定,door/piston 收敛成数据。
- **S4+ 开新系统**:化学/氧化(普适)→ 力学应力(坍塌)→ 流体压力 → 辐射 → 磁。每个独立 step。

## 6. 不变量(纪律)

- 系统激活 = 材料属性派生,**禁 material_id 白名单**。
- 系统间**只经 committed truth 耦合**,禁直接调用。
- **无 per-device 规则**;设备 = 属性 + 拓扑的涌现。
- catalogs append-only;每系统 model card;惰性安全(无属性不参与)。
- 逐 step commit + scene 全量 0 净回归 + 决策稿留痕(沿用梯队/反应层纪律)。

---
**进度**:✅ S1 电磁正交化(I²R 产热 + 删 powered_heater)、✅ S2 source/load 属性派生(emf/电阻,去
material_id 白名单)完成。**下一步 S3**:actuator 正交化——通用「机械响应」系统(`:powered`/阈值 →
声明的机械/可通行状态变化,per-material 参数化)+ 声明式 tag→碰撞属性绑定,把 door(及未来 piston/
gate/elevator)从 per-device 规则收敛成数据。
