# Voxel

职责：

- 定义与 UE `test1` 对齐的空间、存储和 meshing 基础。
- 保存浏览器端体素世界真相层，不把 world truth 放在 three.js Mesh 上。
- 为编辑、渲染、网络 codec 和调试提供一致的数据入口。

边界：

- `core/` 负责坐标、常量和换算。
- `storage/` 拥有 Chunk 真相层。
- `meshing/` 负责把真相层转成几何输入。
- `worldStore.ts` 拥有多 Chunk 世界级索引与演示世界生成。
