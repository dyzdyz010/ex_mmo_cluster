# Render

职责：

- three.js 场景、摄像机和交互控制。
- Chunk mesh 的挂载、重建、命中与高亮。
- 本地/远端 avatar 的可视化，以及与调试 HUD 相关的最低限度表现。

边界：

- render 层不拥有世界真相；它只消费 `voxel/` 和 `movement/` 导出的只读状态。
- Chunk 网格的拓扑来自 `voxel/meshing`，render 不直接改写存储层。
