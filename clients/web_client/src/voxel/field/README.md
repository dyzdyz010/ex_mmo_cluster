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
- `heatSmokeEffect.ts` 是纯数据粒子模拟：导电路径产生的焦耳热越高，每个 electric snapshot 生成的烟粒子越多。
- `heatSmokeRenderer.ts` 只把 `HeatSmokeSimulation` 的粒子写入灰色 instanced cube，不修改 block material。

业务规则：

- 发热视觉优先表现为烟雾粒子，烟量和 `power_draw.estimated_tick_energy_joules` 成正比。
- 方块本体颜色不表达电热耦合；需要看温度数值时使用 Field Overlay / CLI snapshot。
- 电场连通、热量估算和温度 truth 仍由服务端权威链路决定，客户端只消费事件和 field snapshot。
- 宏格 field cell 继续显示为宏格 overlay；refined/prefab field cell 显示为对应
  prefab/refined occupancy 的外露表面边界线，不画内部微格网格。烟雾粒子仍附着到
  occupied micro 中心，而不是宏格中心。
