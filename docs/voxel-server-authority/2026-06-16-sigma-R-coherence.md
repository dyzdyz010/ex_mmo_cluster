# σ/R 一致性(2026-06-16,S3 顺手项)

正交架构(`2026-06-16-orthogonal-systems-architecture.md`)电磁系统的一处属性向量**内部矛盾**收口。
S1/S2 给 `electric_load` 同时配了 `electric_conductivity`(σ)= 8.0 MS/m(相当导电)**与**
`electric_resistance`(R)= 50 Ω(很大),两者物理上互斥:一种材料不可能既高导电又高电阻。

## 决策:让 σ 与 R 方向一致,而非引入"R 由 σ 派生"的硬公式

候选 A(全派生):去掉 `electric_resistance`,令 R_cell = R_unit/σ 对**所有**导体生效。
**否决。** 这会让每个导体(含 iron 导线)都成为耗散 load → 破坏 source/load/wire 三态语义、把
`load_count==0` 闸门(field_runtime)与"无 load 不产生 power effects / open 时 effects 恰只含 load 一格"
(circuit_current_kernel_test)等断言全部推翻。"是不是一个功能性 load"本就不是体材料 σ 能表达的——
同一块金属做导线还是做发热线圈取决于几何/用途,故 S2 用独立 `electric_resistance` 作 load 门是对的。

候选 B(一致,采纳):**保留 `electric_resistance` 作 load 功能门 + I²R 发热参数**(语义不变),
只把矛盾的 σ 修正为与 R 方向一致:

- **发热元件 electric_load:σ 8.0 → 2.0 MS/m**(劣导体,nichrome 类)。此时"导电性弱(低 σ)⇒
  集总电阻大(R=50)"内部自洽,不再是"高导电却高电阻"。仍 ≥ 导体阈 1.0 → 照常参与电路。
- door:σ=8(金属门,良导体)+ R=0.5(小螺线管线圈)——"高 σ ⇒ 低 R ⇒ 几乎不发热",方向同样自洽,
  S1 不变量(门作动而基本不热)保留。
- iron/power_block:导线/源,高 σ、无集总 load 电阻(R=0,不作 load),不变。

一致性准则(写给后续 load 材料):**耗散/发热元件 = 低 σ + 高 R;导线 = 高 σ + ~0 集总 R。**
σ 与 R 须方向反相;R 不强制等于某个 R_unit/σ 常量(集总值仍是按器件设定的功能参数)。

## 不破坏验证

- 电路电流在该回路被 `current_limit_amps`(20A)钳制,与 load 的 σ 无关 → I²R 发热(I²·50·gain)
  与改前**逐字节相同**,焦耳热 e2e 升温/熔冰不变。
- `load = electric_resistance>0` 门不变 → iron 仍非 load,kernel_test 的精确 effect 断言不变。
- material_catalog_test 只断言 electric_load σ>0(2.0>0)→ 不变。

scene 全量 0 净回归。
