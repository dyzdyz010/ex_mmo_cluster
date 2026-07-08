# Prefab 微格放置 — 实施计划

按依赖顺序的 5 个 commit，每个 commit 跑测后再下一个。

## Commit 1：MicroMask::shift_to_neighbours + 单测
- `voxel/world/micro_mask.rs`（或现存定义所在）：新增 `shift_to_neighbours(shift: IVec3) -> Vec<((i32,i32,i32), MicroMask)>`
- 单测：
  - 全 0 mask → 空
  - 单 slot at (0,0,0) shift (0,0,0) → 1 个 dest macro (0,0,0) with same slot
  - 单 slot at (7,0,0) shift (1,0,0) → 1 个 dest macro (1,0,0) with slot (0,0,0)
  - 全填充 mask shift (5,0,0) → 2 个 dest macros，每个 mask 占对应一半 = 256 slots
  - 负 shift (-3,0,0) → div_euclid 处理负数除法

## Commit 2：contact_face_center helper + 单测
- `voxel/prefab/boundary.rs`（新私有 fn）：
  - 6 face_normal cases + fallback
  - 应用 rotation 到 micro coord（用现有 `rotate_micro_offset` 类的 helper，如果不存在就新增）
- 单测：sphere prefab (1,1,1) bounds，6 face_normal 各对应中央，rotation Rot0 与 Rot90 都验

## Commit 3：rasterize_with_micro_shift + Accumulator + 单测
- `voxel/prefab/registry.rs`：
  - 新 fn `rasterize_with_micro_shift(origin, rotation, shift: IVec3) -> Vec<PrefabRasterCell>`
  - `rasterize` 改为 `self.rasterize_with_micro_shift(origin, rotation, IVec3::ZERO)` 的 wrapper
  - 内部用 `shift_to_neighbours` 拆每个 cell；累加器合并同一 dest macro 的多个贡献
- material/state/part 元数据：每个 micro slot 索引按 `MicroCoord::to_slot_index()` 重新写入目标 cell 的 vec
- 单测：
  - shift ZERO → 与原 rasterize 输出等价
  - shift (5,0,0) on 1x1x1 prefab → 2 个 dest cells，micro count 之和 = 原 cell micro count
  - shift (5,3,7) on 1x1x1 prefab → 最多 8 个 dest cells

## Commit 4：BoundarySnapRequest.anchor_micro + preview/place 用 + 集成测试
- `voxel/prefab/boundary.rs`：`BoundarySnapRequest` 加 `anchor_micro: Option<MicroCellTarget>`
- `voxel/world/store.rs::preview_prefab_boundary_snap`：
  - `anchor_micro = None` → 旧逻辑（不动）
  - `anchor_micro = Some(t)` → 计算 contact_face_center → shift → rasterize_with_micro_shift → overlap/contact 检查
- `voxel/world/store.rs::place_prefab_boundary_snap` & `should_fallback_to_macro_prefab_place`：
  - anchor_micro 提供时，micro_overlap reject 不退化到 place_prefab（fallback 仅当真正没目标边界）
- 集成测试 `tests/voxel_parity.rs`：
  - 旧测试不动（保证 backward compat）
  - 新增 4 个：
    1. `prefab_boundary_snap_anchor_micro_top_face_centers_prefab` — face=+Y，anchor 微格命中点正确
    2. `prefab_boundary_snap_micro_overlap_strict_reject` — 二次相同 anchor 触发 micro_overlap
    3. `prefab_boundary_snap_cross_macro_micro_split` — 命中点接近 macro 边角，prefab 跨 2 个 dest macro
    4. `prefab_boundary_snap_anchor_none_matches_legacy_macro_path` — None vs 旧路径 byte-equal

## Commit 5：plugin.rs 把 selection.adjacent_micro 接进来
- `voxel/plugin.rs` 处理 `place_requested` 路径：
  - 构造 BoundarySnapRequest 时：`anchor_micro: selection.adjacent_micro`
- 手测：build GUI、跑服务、放 prefab 在 voxel face 上看对齐效果。
- observe 加 trace `voxel::prefab_micro_snap` 记录 anchor_micro 与最终 dest macro 列表

## 验收门
- 每个 commit 后 `cargo test --lib` + `cargo test --test voxel_parity` 全绿
- 最后 `cargo fmt && cargo clippy --tests -- -D warnings` clean
- GUI smoke：rebuild、boot server、放 prefab，trace 显示 anchor_micro 非 (0,0,0) 时 placement 跨 macro

## Out of scope
- web_client 同步（冻结）
- ghost preview 渲染
- prefab 元数据格式重设计
