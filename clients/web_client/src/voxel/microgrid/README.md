# Microgrid

职责：

- 治理单个 Macro 内 `8x8x8` Micro occupancy 的索引、边界与动态槽数 payload。
- 提供 Refined cell 的确定性读写，支撑 prefab 形状、后续局部破坏和部件语义。
- 让 storage、meshing 和 CLI 读取面共用同一套微格判断，避免各层各自解释 bitset。

边界：

- `governance.ts` 不拥有世界状态，只处理单个 refined cell 的确定性读写与校验。
- `storage/ChunkStorage` 负责把这些纯函数应用到 Chunk truth。
- `meshing/` 只消费治理后的快照，不回写微格数据。
- 玩家编辑入口只操作宏格或 prefab；micro 不是可直接放置的玩家方块。
- Socket snap 的写入仍以 macro/chunk 为分页骨架：prefab 先被 rasterize 成每个
  macro 的 incoming micro mask，事务层检查 `existing & incoming`，无重叠才把
  material/state/part/instance payload 做 refined union。任何 slot 重叠都会拒绝
  整次放置，不留下半写入 prefab。
- CLI/observe 是验收入口：`prefab_snap_preview` 暴露 anchor、affected macro 数、
  incoming slots 和 overlap slots；`prefab_place_socket` 成功或拒绝后写出
  `prefab_snap_committed / prefab_snap_rejected / prefab_overlap_conflict`。
