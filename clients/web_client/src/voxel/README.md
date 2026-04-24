# Voxel

职责：

- 定义与 UE `test1` 对齐的空间、存储和 meshing 基础。
- 保存浏览器端体素世界真相层，不把 world truth 放在 three.js Mesh 上。
- 为编辑、渲染、网络 codec 和调试提供一致的数据入口。

边界：

- `core/` 负责坐标、常量和换算。
- `microgrid/` 负责 Macro 内 `8x8x8` Micro occupancy 的索引、边界治理和动态槽数 payload 规范。
- `storage/` 拥有 Chunk 真相层。
- `meshing/` 负责把真相层转成几何输入。
- `worldStore.ts` 拥有多 Chunk 世界级索引与演示世界生成。
- `worldStore.ts` 也提供本地 snapshot import/export，用字符串化 bigint 保存 refined micro occupancy，供 CLI 存档、导入导出和 e2e 回归使用。
- `prefab.ts` 负责浏览器本地 Prefab Definition/Instance 编排。当前阶段已按 UE
  `test1` 的 `FPrefabDefinitionData` / `FPrefabInstanceData` 分层建模：
  capture 生成定义，place 生成实例并写入所有覆盖到的 Chunk。内置
  `builtin_sphere`、`builtin_cylinder`、`builtin_stairs` 直接以 refined micro
  occupancy 预置；玩家 capture 的普通块模板则落成 full-macro refined
  occupancy，和内置模板共用同一条 micro mesher 入口。
- Prefab definition 保留 `partDefinitions` 和 `microPartIds`。放置到场景后，
  `FRefinedCellData.microPartIds` 会随 micro occupancy 一起写入 Chunk truth，
  后续魔法/破坏系统可用 part tag 区分 roof / door / wall / stairs 等局部语义，
  不需要把运行时 prefab 还原成嵌套模板树。
- Prefab definition 同步生成 `boundaryFaceMasks`；`sockets` 只保留为可选语义兼容层。
  默认 snap 由 `prefab.ts` 使用完整 micro occupancy 枚举 boundary contact candidate，
  计算整数 world micro anchor，再把 prefab micro occupancy rasterize 到受影响的
  macro cells；`ChunkStorage` 只接收事务检查后的 refined union 写入。
- 微格写入 API 只服务 prefab/refined 内部数据治理和后续局部破坏系统，不作为
  玩家可直接放置 micro 方块的编辑入口。CLI 暴露 `micro_cell` 读取检查，以及
  `prefab_boundary / prefab_snap_preview / prefab_place_snap` 验证 socket-free 微格边界贴合。
