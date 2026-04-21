# Material

职责：

- 提供浏览器端最小可用的方块材质/状态视觉解析。
- 先对齐 UE `MaterialId + StateFlags -> visual payload` 的分层思想，再逐步补齐完整注册表和 Overlay 配置。

边界：

- material 层不拥有世界真相。
- 当前阶段只提供代码内置目录与颜色/状态叠加解析，后续再切到数据驱动注册表。
