# Voxel Field Client

职责：

- 解码服务端推送的 `FieldRegion` 快照，并把局部场状态转换成浏览器可见的调试层。
- 保持可视层和体素真相层分离：field overlay 可以画温度、电势、热烟，但不拥有方块材质或世界状态。
- 为 CLI / 自动化测试暴露可读快照，避免只靠截图判断局部场是否工作。

边界：

- `fieldProtocol.ts` 只负责 wire snapshot decode。
- `fieldDebugOverlay.ts` 管理 Three.js overlay 生命周期、region mesh 与 CLI snapshot。
- `fieldDebugOverlay.ts` 不自行判断目标身份；它通过 `voxel/overlayTarget.ts` 的只读投影
  把 field snapshot 的宏格值映射成宏格方块或 prefab/micro 线框。
- `heatSmokeEffect.ts` 是纯数据粒子模拟：导电路径产生的焦耳热越高，或服务端
  `smoke_density` 场越浓，每个 field snapshot 生成的烟粒子越多。
- `heatSmokeRenderer.ts` 只把 `HeatSmokeSimulation` 的粒子写入灰色 instanced cube，不修改 block material。
- `lightningBoltRenderer.ts` 只负责瞬时击穿视觉反馈：预分配一组 `LineSegments` buffer，
  按事件写入有限线段并快速过期，不参与导电/击穿判定。

业务规则：

- 发热和燃烧扩散的视觉优先表现为烟雾粒子；电热烟量和
  `power_draw.estimated_tick_energy_joules` 成正比，燃烧烟量来自服务端
  `smoke_density` 层。
- 烟粒子预算按 active field cell / prefab projection group 公平采样，不能按展开后的
  micro 点顺序截断；否则密集 prefab 会吃完整帧预算，让后续宏格或其它回路看起来不冒烟。
- prefab 烟雾以 prefab/owner projection 为发射单位，同一个 projection 只保留一个 keyed
  live 烟雾实例，后续 snapshot 刷新该实例；不要再按 occupied micro slot 生成粒子。
- 烟雾模拟可以按帧推进，但实例矩阵上传由 overlay 节流；renderer 直接写 instance matrix
  buffer，避免在烟粒子很多时每个 RAF 都走 `Object3D.updateMatrix()` / `setMatrixAt()` 热路径。
- overlay 关闭时，渲染层只缓存每个 region 的 latest field snapshot，不 materialize mesh、不生成烟雾、
  不推进 smoke simulation；打开 overlay 时再 replay 缓存快照。不要把 `rootGroup.visible=false`
  当成性能边界。
- 方块本体颜色不表达电热耦合；需要看温度数值时使用 Field Overlay / CLI snapshot。
- 电场连通、热量估算、温度、烟雾、氧气和材料燃烧 truth 仍由服务端权威链路决定，
  客户端只消费事件和 field snapshot。
- 闪电特效必须由已提交的击穿请求事件触发，不能作为独立客户端伤害或物理 truth。
- 宏格 field cell 继续显示为宏格 overlay；refined/prefab field cell 显示为对应
  prefab/refined occupancy 的外露表面边界线，不画内部微格网格。烟雾粒子仍附着到
  occupied micro 中心，而不是宏格中心。
