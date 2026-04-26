# Prefab 微格放置（cross-macro micro snap）设计

**日期**：2026-04-26
**范围**：仅 `clients/bevy_client`（per CLAUDE.md 客户端策略）
**输入问题**：用户瞄准 voxel face 上的某个 micro 点放置 prefab，当前实现强制 macro 对齐——prefab 永远落在相邻 macro 的 (0,0,0) micro 角，无法贴着面的特定 micro 点放。

## 用户决策（brainstorm 阶段已定）

| 维度 | 选择 |
|---|---|
| 放置粒度 | **Yes-B**：完全微格自由，prefab 可跨 macro 边界 |
| Overlap 策略 | **A**：严格拒绝任何 micro slot overlap（与现有 boundary snap 一致） |
| Anchor 语义 | **B**：prefab 接触面（-face_normal）中央 micro 对齐到用户瞄的 adjacent_micro |
| 客户端范围 | bevy_client 单端，web_client 冻结不动 |

## 架构与数据流

```
UI (camera ray hit)
  → VoxelRaySelection { adjacent_micro: Some(MicroCellTarget), face_normal, ... }
      ↓
BoundarySnapRequest {
  prefab_name, hit_macro, face_normal, rotation,
+ anchor_micro: Option<MicroCellTarget>,    // 新字段，None = 走旧的宏格行为
}
      ↓
preview_prefab_boundary_snap
  ├─ 若 anchor_micro = Some(target):
  │    1. 计算 prefab 接触面中央 micro = contact_face_center(prefab, face_normal, rotation)
  │    2. 计算 micro_shift = target.macro_coord*MICRO + target.micro - origin_macro*MICRO - contact_center
  │    3. raster = prefab.rasterize_with_micro_shift(origin_macro, rotation, micro_shift)
  │       → 每个原 PrefabRasterCell 可能被拆成最多 8 个目标 macro，bit-shift micro mask
  │    4. 对每个 raster cell 检查现有 refined_cell 的 overlap_count（严格 A）
  │    5. 检查 contact_slots（与 hit_macro 共享 micro 邻居数，至少 1）
  └─ 若 anchor_micro = None:
       原宏格逻辑不变（向后兼容现有 cli / 测试调用方）
      ↓
place_prefab_boundary_snap → preview.ok 才 commit_prefab_raster
```

## 组件改动清单

| 文件 | 改动 |
|---|---|
| `voxel/prefab/boundary.rs` | `BoundarySnapRequest` 新增 `anchor_micro: Option<MicroCellTarget>` |
| `voxel/prefab/registry.rs` | 新增 `LocalPrefab::rasterize_with_micro_shift(origin: MacroCoord, rotation: Rotation, shift: IVec3) -> Vec<PrefabRasterCell>`；现有 `rasterize` 改为 `rasterize_with_micro_shift(origin, rotation, IVec3::ZERO)` 的薄封装 |
| `voxel/prefab/mask.rs`（或 micro mask 定义所在） | 新增 `MicroMask::shift_to_neighbours(shift: IVec3) -> [(MacroOffset, MicroMask); up_to_8]`，把单个 mask 按 (dx, dy, dz) ∈ [0, MICRO_PER_MACRO) 平移到最多 8 个目标 macro，每个目标 macro 拿到一个新的 micro mask |
| `voxel/prefab/boundary.rs` | 新增 `contact_face_center(prefab: &LocalPrefab, face_normal: MacroCoord, rotation: Rotation) -> MicroCoord`：6-case match，按 face_normal 取 prefab 接触面中央 micro |
| `voxel/world/store.rs::preview_prefab_boundary_snap` | 接受 anchor_micro，调用 rasterize_with_micro_shift；保留原 anchor=None 路径 |
| `voxel/plugin.rs`（input 路径） | 构造 BoundarySnapRequest 时塞 `anchor_micro: selection.adjacent_micro` |

**注意**：所有修改保持 `place_prefab` (纯宏格 fallback) 不变。`preview_prefab_boundary_snap` 在 `anchor_micro = None` 时也走旧逻辑——确保现有 voxel parity test、cli test 不需要改。

## 关键算法

### 1. contact_face_center

```rust
fn contact_face_center(prefab: &LocalPrefab, face_normal: MacroCoord, rotation: Rotation) -> MicroCoord {
    let bounds = prefab.definition.bounds_in_macro_cells; // 当前所有 builtin 都是 (1,1,1)
    let max_x = bounds.x * MICRO_PER_MACRO - 1;
    let max_y = bounds.y * MICRO_PER_MACRO - 1;
    let max_z = bounds.z * MICRO_PER_MACRO - 1;
    let cx = (max_x + 1) / 2;
    let cy = (max_y + 1) / 2;
    let cz = (max_z + 1) / 2;
    // 接触面 = -face_normal
    let local = match (face_normal.x, face_normal.y, face_normal.z) {
        (0,  1, 0) => MicroCoord::new(cx, 0, cz),     // top → prefab 底面中央
        (0, -1, 0) => MicroCoord::new(cx, max_y, cz), // bottom → 顶面中央
        ( 1, 0, 0) => MicroCoord::new(0, cy, cz),     // east → 西面中央
        (-1, 0, 0) => MicroCoord::new(max_x, cy, cz), // west → 东面中央
        (0, 0,  1) => MicroCoord::new(cx, cy, 0),     // south → 北面中央
        (0, 0, -1) => MicroCoord::new(cx, cy, max_z), // north → 南面中央
        _ => MicroCoord::new(cx, cy, cz),             // 非轴向 fallback：中心
    };
    apply_rotation_to_micro(local, bounds, rotation)
}
```

### 2. MicroMask::shift_to_neighbours

8x8x8 = 512-slot bitfield。shift 后每个 slot 落到目标 macro `(orig_macro + (i+dx)/8, ...)` 的 micro `((i+dx)%8, ...)`。

实现：
```rust
pub fn shift_to_neighbours(self, shift: IVec3) -> SmallVec<[(MacroOffset, MicroMask); 8]> {
    let mut buckets: BTreeMap<MacroOffset, MicroMask> = BTreeMap::new();
    for slot in self.iter_set_bits() {
        let MicroCoord { x: i, y: j, z: k } = MicroCoord::from_slot_index(slot);
        let nx = i as i32 + shift.x;
        let ny = j as i32 + shift.y;
        let nz = k as i32 + shift.z;
        let macro_off = MacroOffset::new(
            nx.div_euclid(MICRO_PER_MACRO as i32),
            ny.div_euclid(MICRO_PER_MACRO as i32),
            nz.div_euclid(MICRO_PER_MACRO as i32),
        );
        let dest = MicroCoord::new(
            nx.rem_euclid(MICRO_PER_MACRO as i32) as u8,
            ny.rem_euclid(MICRO_PER_MACRO as i32) as u8,
            nz.rem_euclid(MICRO_PER_MACRO as i32) as u8,
        );
        buckets.entry(macro_off).or_default().set(dest);
    }
    buckets.into_iter().collect()
}
```

shift 在 `[0, MICRO_PER_MACRO)` 范围内时最多 8 个目标 macro；shift 可能为负（micro 命中点不能确保 prefab 全部在 +face 方向）；用 `div_euclid`/`rem_euclid` 处理负数除法。

### 3. rasterize_with_micro_shift

外层逻辑：
```rust
pub fn rasterize_with_micro_shift(
    &self,
    origin: MacroCoord,
    rotation: Rotation,
    shift: IVec3,
) -> Vec<PrefabRasterCell> {
    let macro_raster = self.rasterize(origin, rotation); // 原宏格 raster
    let mut by_dest: BTreeMap<MacroCoord, RasterAccumulator> = BTreeMap::new();
    for cell in macro_raster {
        for (macro_off, sub_mask) in cell.data.micro_occupancy_mask.shift_to_neighbours(shift) {
            let dest_macro = cell.macro_coord.offset(macro_off.into());
            by_dest.entry(dest_macro).or_default()
                .merge_mask_and_metadata(sub_mask, &cell.data);
        }
    }
    by_dest.into_iter().map(|(macro_coord, accum)| PrefabRasterCell {
        macro_coord,
        data: accum.into_prefab_cell(),
    }).collect()
}
```

`RasterAccumulator` 在同一个目标 macro 收到多个原 cell 的贡献时，合并 micro mask + 复制 material/state/part 元数据（按 micro slot 索引）。

## 错误处理

| 场景 | 行为 |
|---|---|
| `anchor_micro = None` | 走旧的宏格 boundary snap（向后兼容） |
| `anchor_micro = Some(...)` 但 face_normal 非轴向 | 接触面中央回退为 prefab 几何中心 |
| 任何 raster cell 与现有 refined cell 有 micro overlap | reject_reason = "micro_overlap"，与现有一致 |
| raster 后所有 dest macro 都没有与 hit_macro 接触的 micro 邻居 | reject_reason = "no_contact" |
| Cross-macro shift 导致 contact_slots 计算需考虑多个 dest macro | 累加每个 dest macro 与 hit_macro 共享面的 micro 邻接数 |
| Caller 传 `anchor_micro` 但 `place_prefab_boundary_snap` 退回 `place_prefab`（旧 macro fallback）的 should_fallback_to_macro_prefab_place 路径 | 修改 fallback 条件：当 anchor_micro 提供时，micro overlap 不退化（用户已经表达了精确意图，不应该悄悄换语义） |

## 测试策略

新增 `tests/voxel_parity.rs` 测试：
1. **contact_face_center 6 个面对应正确**：sphere prefab，对每个面 normal 验证返回的 micro 中心
2. **cross-macro micro shift 拆分正确**：构造一个简单 2x2x2 micro mask，shift (5, 0, 0) 后验证拆到 2 个目标 macro，每个 mask 占一半
3. **micro_overlap 严格拒绝**：先放一个 prefab；再用相邻偏移触发 overlap；assert reject_reason = "micro_overlap"
4. **micro 自由放置成功 + 跨 macro 完成**：场景包括 hit 在 hit_macro 边角，导致 prefab 跨 2 个 macro
5. **anchor_micro=None 行为不变**：旧的 macro 测试不应改

`voxel_parity.rs` 共预期 8 → 13 个测试。

## 不在范围

- web_client 同步（CLAUDE.md 已冻结）
- 服务端 prefab 协议（当前 prefab 是客户端本地状态）
- Ghost preview 渲染（独立 UX 任务）
- 新 prefab 类型 / 旋转算法重写

## 输出文件

- `docs/2026-04-26-prefab-micro-snap-design.md`（本文）
- `docs/2026-04-26-prefab-micro-snap-plan.md`（writing-plans 阶段）
