# Render

职责：

- three.js 场景、摄像机和交互控制。
- Chunk mesh 的挂载、重建、命中与高亮。
- 命中高亮只渲染当前命中面轮廓；放置位置由该面法线推导，不再同时显示破坏/放置整块红绿框。
- 选中 prefab 时，render 层只渲染 ghost preview；实际写入仍由 `WorldEditController -> WorldStore` 完成。
- 本地/远端 avatar 的可视化，以及与调试 HUD 相关的最低限度表现。

边界：

- render 层不拥有世界真相；它只消费 `voxel/` 和 `movement/` 导出的只读状态。
- Chunk 网格的拓扑来自 `voxel/meshing`，render 不直接改写存储层。
- 鼠标左/右键只发出编辑意图；具体破坏 occupied macro 或放置 adjacent macro 由 `WorldEditController` 负责。
- `world_import` 后 render 会移除不再存在的 chunk mesh，避免旧世界残影。
