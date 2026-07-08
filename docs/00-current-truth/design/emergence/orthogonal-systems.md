# 正交涌现系统当前事实

> 当前唯一事实文档。覆盖材料属性向量驱动的热、电、光、化学、结构等系统，以及客户端外观读取边界。

## 核心原则

```mermaid
flowchart LR
  Material["Material / Tags / Attributes<br/>常态事实"]
  Systems["Orthogonal systems<br/>heat / electric / light / chemistry / structure"]
  Truth["Committed voxel/object truth"]
  Render["Client rendering<br/>pure function of truth"]

  Material --> Systems
  Systems --> Truth
  Truth --> Render
```

- 系统激活由材料属性、tag、voxel/object truth 派生。
- 禁止为单个 device 或 material 写隐式特判；需要能力时先补属性和正交系统入口。
- 系统之间通过 committed truth 耦合，而不是直接互相调用隐藏状态。
- 客户端外观是服务端 truth 的纯函数，不本地模拟燃烧、导电、热扩散或结构坍塌。

## 材料与属性

当前材料系统已支持多类物性：

- 热：`temperature`、`thermal_conductivity`、`density`、`specific_heat_capacity`、熔点/沸点/冻结点/点燃阈值。
- 电：`electric_conductivity`、`dielectric_strength`、power source defaults。
- 化学：reaction recipe、氧化、燃烧等由材料与环境条件触发。
- 结构：structural 属性、支撑、应力、坍塌候选。
- 光：light / light color / photo sensor / illuminated tag 等已进入服务端权威光场方向。

## 光系统

当前事实：

- 光已经从“客户端白炽/视觉派生”升级为服务端权威光场。
- 相关能力包括 `:light` / `:light_color` wire、LightPropagationKernel、photo_sensor、illuminated tag、光门、光合、放大镜热效应等组合。
- 旧的“光只是客户端 shader/白炽表现”只能作为渲染参考，不是当前系统事实。

## 化学 / 氧化

当前事实：

- S4 化学氧化系统已完成。
- 燃烧与铁氧化都收敛为 `ChemicalReaction` recipe。
- `iron -> rust` 会通过 committed truth 和材料属性自然退出导电；不需要专门的“锈了断电”规则。

## 结构 / 坍塌

当前事实：

- 结构支撑/坍塌已有 as-built 能力。
- `structural` 属性、`StructuralSupport`、`StructuralStressKernel`、`:collapse_block` effect、field-commit 后重 sweep 已形成链路。
- 烧梁/放电毁梁可引发后续坍塌链路。

仍未完成：

- 跨 chunk 支撑 v2。
- 应力幅值和力学精度 v2。
- 落下重堆叠 / 二次碰撞 v2。

## 客户端渲染边界

- Voxia 外观必须读取服务端 `material_id`、tag、field overlay、object state。
- 禁止恢复旧 `state_flags` 涌现位作为 burning/frozen/wet/charred 之类通用外观来源。
- `state_flags` 当前真实用途偏向 diode/transistor 投影，不是通用材料状态层。
- 热烟是客户端 Field Overlay 可视层，不是 voxel truth；温度 truth 由服务端 effect 写回。

## 被取代的旧结论

| 旧结论 | 当前事实 |
| --- | --- |
| `state_flags` 可承载 burning/frozen/wet/charred | 已被 material/tag/field 纯函数渲染取代 |
| 光只是客户端白炽效果 | 已有服务端权威光场 as-built |
| 锈蚀断电需要专用规则 | iron/rust 材料属性变化自然退出导电 |
| 每个装置可单独写规则 | 当前方向是正交物理系统 + 属性向量 |

## 证据源

- [`docs/30-reference/overview/2026-06-16-orthogonal-systems-architecture.md`](../../../30-reference/overview/2026-06-16-orthogonal-systems-architecture.md)
- [`docs/20-archive/field-emergence/2026-06-17-S4-chemistry-oxidation-system.md`](../../../20-archive/field-emergence/2026-06-17-S4-chemistry-oxidation-system.md)
- [`docs/20-archive/field-emergence/2026-06-23-light-as-orthogonal-system.md`](../../../20-archive/field-emergence/2026-06-23-light-as-orthogonal-system.md)
- [`docs/20-archive/field-emergence/2026-06-23-mechanical-stress-structural-collapse.md`](../../../20-archive/field-emergence/2026-06-23-mechanical-stress-structural-collapse.md)
- [`clients/Voxia/docs/2026-06-27-voxia-emergence-render-design.md`](../../../../clients/Voxia/docs/2026-06-27-voxia-emergence-render-design.md)
