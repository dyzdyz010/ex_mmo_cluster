# Render

职责：

- three.js 场景、摄像机和交互控制。
- 程序化天空、大气雾色、太阳/月亮昼夜循环和客户端侧表现光照；这些只影响浏览器渲染，不改变服务端时间或玩法状态。
- 渲染器由 `rendererBackend.ts` 统一选择：默认 WebGPU 优先，初始化失败或浏览器能力不足时回退 WebGL。
- Chunk mesh 的挂载、重建、命中与高亮。
- Chunk mesh 使用程序化 mosaic material atlas + vertex color 呈现不同方块材质，避免依赖外部贴图资源。
- Chunk mesh 重建默认走 `chunkMeshWorker.ts` module worker。主线程只接收 mesh data 并替换
  `BufferGeometry`，observe 日志会记录 `chunk_rebuild_scheduled`、`chunk_rebuilt` 和
  `chunk_rebuild_failed`；Worker 不可用时回退同步重建。
- `prefabPreviewGeometry.ts` 负责 prefab 线框预览几何生成；交互中的放置图示使用低成本 `micro-wire`，保留真实 micro occupancy 形状但不渲染半透明实体。
- 命中高亮按世界真相选择粒度：普通 solid 宏格画宏格盒；命中 prefab/object 内部
  occupied micro 时，按最小 prefab/object 单位画贴合真实 micro occupancy 的外露表面边界线，
  不画 prefab 的轴对齐包围盒，也不显示平面内部微格网格线；孤立 refined micro 没有
  prefab/object 归属时退回宏格盒。命中几何仍由 `chunkRenderer.ts` 计算，目标语义由
  `voxel/overlayTarget.ts` 只读投影，不把 prefab/object 身份塞进 Three.js raycast。
- 选中 prefab 时，render 层只渲染非半透明材质的微格线框 preview；hover 预览会把鼠标命中的 `adjacentMicro` 作为 `anchorMicroCoord` 传给 snap 层，避免全宏格候选搜索。实际写入与精确 snap 仍由 `WorldEditController -> WorldStore` 完成。
- 本地/远端 avatar 的可视化，以及与调试 HUD 相关的最低限度表现。
- 本地 avatar 显示高度由地表中心高度加 movement airborne offset 组成，避免
  Space 跳跃被地表吸附逻辑吞掉视觉反馈。

边界：

- render 层不拥有世界真相；它只消费 `voxel/` 和 `movement/` 导出的只读状态。
- render 层拥有浏览器渲染后端的初始化、回退与诊断信息；业务层只能读取
  `RendererDebugSnapshot`，不能绕过后端工厂直接创建 renderer。
- Chunk 网格的拓扑来自 `voxel/meshing`，render 不直接改写存储层。
- 鼠标左/右键只发出宏格编辑意图；具体破坏 occupied macro 或放置 adjacent macro 由 `WorldEditController` 负责。
- render 层可为 refined/prefab 命中保留 micro selection 派生数据，但当前不把
  micro 作为玩家可直接放置/删除的编辑入口。
- field / selection overlay 共享 `overlayTarget` 的只读投影结果：玩家目标高亮使用
  selection projection，prefab 命中按外露表面边界显示；FieldDebugOverlay 使用 field
  projection 把服务端宏格场值映射成宏格 overlay 或 prefab/refined 外露表面边界线，
  不再为 prefab field overlay 绘制内部微格网格。
- Refined micro mesh 会剔除同宏格与相邻宏格中已占用 micro 的内部面，避免 prefab / 局部凿除后渲染隐藏面。
- `world_import` 后 render 会移除不再存在的 chunk mesh，避免旧世界残影。
