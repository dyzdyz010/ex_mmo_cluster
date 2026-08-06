# Voxia Prefab 最近合法位置吸附 Implementation Plan

**Goal:** 普通 prefab place 不再显示无效红框；原始 anchor 不可放置时沿同一命中面确定性搜索最近合法 anchor 并只显示可直接提交的绿色线框，范围内无确定解时隐藏。replace 保持原 anchor/朝向/父级语义，无效时隐藏。

**Design:** [`2026-08-04-voxia-prefab-nearest-valid-snap-design.md`](../../10-active/cross-cutting/2026-08-04-voxia-prefab-nearest-valid-snap-design.md)（用户已逐段批准）

**Architecture:** 新增纯客户端 `FVoxiaPrefabPlacementSnapResolver`（`Gameplay/`），只负责按 `(distance_squared, du, dv)` 固定顺序枚举面内候选并选择第一个通过既有 `FVoxiaPrefabPlacementPlanner` 与 `IVoxiaInteractiveCoverageQuery` 的候选。`FVoxiaPrefabPreviewState` 的 place 分支只持有一份 `FVoxiaPrefabPlacementSnapResult`，其中只有一份 `PlacementPlan`；HUD、`build_interaction` 与右键 intent 全部从该结果读取最终 resolved anchor。

**Tech Stack:** Unreal Engine 5.8、C++20/UE Core、UE Automation、Node.js stdio CLI smoke、RuntimeMock authority。

## Global Constraints

- 现役客户端只有 `clients/Voxia`；Web/Bevy 不读取、不修改、不验证。
- 唯一生产事实保持 `/Game/Voxia/Maps/L_VoxiaProductionWorld`、`VoxiaClientGameMode` 与 `AVoxiaUnifiedVoxelWorldActor`；不新增地图、GameMode、Actor 或第二 production root。
- `FVoxiaPrefabPlacementPlanner` 是候选合法性的唯一来源；resolver 不复制 occupancy / no-floating / footprint overlap / conflict set 算法，也不得用简化 AABB 冒充合法。
- `FVoxiaPrefabSurfaceQuery` 是 SolidMacro/RefinedProjection 的唯一精确 surface 解释器；resolver 不自行展开第二套体素读取语义。
- 唯一 face-alignment 公式：现 `FVoxiaBuildInteractionController::TryBuildFaceAlignedAnchor` 迁出为共享纯 helper，controller 与 resolver 共用同一份，不保留第二份 bounds 对齐实现。
- place 分支与 replace 分支显式互斥；切换模式必须清空非活动分支，禁止两份 plan 同时看似可提交。
- 客户端仍不产生乐观 confirmed truth；点击只提交 intent，confirmed 世界仍只由 authority transaction 更新。
- 搜索有界：`radius = clamp(max(span_u, span_v), 1, 16)`，候选满足 `du*du + dv*dv <= radius*radius`，硬上限 `1024` 个候选，命中首个合法候选立即停止。
- 未知 confirmed truth 必须 fail-closed（隐藏），不得跳过未知候选后宣称更远候选“最近”。
- 新增和修改的代码注释统一使用中文。
- 每个生产行为先写真实行为测试并观察 RED，再写最小实现；不得以源码字符串 grep 代替可观察行为测试。
- 结构化产物写入 `.demo/observe/`，截图不能成为唯一证据。

## 与设计文档的两处显式偏差（实施期决定，需回写设计进度）

1. **CLI 键名命名空间**：设计 §8 示例把 snap 字段平铺进 `build_interaction.prefab_preview`，其中 `"reason"` 与既有 `prefab_preview.reason`（placement 校验原因）冲突。实施改为嵌套 `prefab_preview.snap.{state,source_anchor_world_micro,resolved_anchor_world_micro,offset_world_micro,face_normal_world_micro,search_radius_micro,tested_candidate_count,reason,terminal_detail}`。字段集合与语义与设计一致，只消除键名歧义。
2. **replace 不产生 snap 状态**：设计明确“replace 不参与搜索”。因此 `prefab_preview.snap` 在 replace 分支与非 prefab 工具下为 JSON `null`，而不是复用 `direct/hidden` 表达 replace 有效性。replace 的可见性仍由 `visual_feedback` 表达。

## 文件结构与职责

新增：

```text
clients/Voxia/Source/Voxia/Gameplay/
  VoxiaPrefabPlacementSnap.h            # 纯值：SnapState / SnapResult / 面内基与候选枚举 / face-alignment helper
  VoxiaPrefabPlacementSnap.cpp
  VoxiaPrefabPlacementSnapAutomationTest.cpp
```

主要修改：

```text
clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.h/.cpp
clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildVisualFeedback.h/.cpp
clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildVisualFeedbackAutomationTest.cpp
clients/Voxia/Source/Voxia/Gameplay/VoxiaPhase3PrefabInteractionAutomationTest.cpp
clients/Voxia/Source/Voxia/Gameplay/VoxiaPawn.h/.cpp                 # snap CPU metrics 只读门面
clients/Voxia/Source/Voxia/Debug/VoxiaPrefabDebugDiagnostics.h/.cpp  # prefab runtime-metrics 增加 placement_snap
clients/Voxia/Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp
clients/Voxia/Source/Voxia/Debug/VoxiaPrefabDebugDiagnosticsAutomationTest.cpp
clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.js
clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.test.js
clients/Voxia/README.md
clients/Voxia/Source/Voxia/Gameplay/README.md
clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/README.md
docs/00-current-truth/impl/README.md
docs/10-active/cross-cutting/2026-08-04-voxia-prefab-nearest-valid-snap-design.md
docs/10-active/cross-cutting/2026-08-04-voxia-build-targeting-feedback-design.md
docs/10-active/cross-cutting/_session-handoff.md
```

## 执行前置

```powershell
Set-Location 'C:\Users\DYZ\Documents\dev\hemifuture\ex_mmo_cluster\.worktrees\voxia-phase3-prefab-runtime'
git status --short
git branch --show-current   # 期望 codex/voxia-phase3-prefab-runtime
$VoxiaUeRoot = 'C:\Program Files\Epic Games\UE_5.8'
$VoxiaProject = Join-Path $PWD 'Voxia.uproject'
```

构建前关闭现有 Voxia/UnrealEditor 实例，避免 DLL 锁定。

---

### Task 1: 纯 snap 值契约、面内候选枚举与共享 face-alignment

**Files:**
- Create: `Source/Voxia/Gameplay/VoxiaPrefabPlacementSnap.h/.cpp`
- Create: `Source/Voxia/Gameplay/VoxiaPrefabPlacementSnapAutomationTest.cpp`

**Produces:**

```cpp
enum class EVoxiaPrefabSnapState : uint8 { Direct, Snapped, Hidden };

struct FVoxiaPrefabPlacementSnapResult
{
    EVoxiaPrefabSnapState State = EVoxiaPrefabSnapState::Hidden;
    FInt64Vector SourceAnchorWorldMicro = FInt64Vector::ZeroValue;
    TOptional<FInt64Vector> ResolvedAnchorWorldMicro;
    TOptional<FInt64Vector> OffsetWorldMicro;
    FIntVector FaceNormalWorldMicro = FIntVector::ZeroValue;
    int32 SearchRadiusMicro = 0;
    int32 TestedCandidateCount = 0;
    FString Reason = TEXT("prefab_snap_not_updated");
    FString TerminalDetail;
    Voxia::PrefabRuntime::FVoxiaPrefabPlacementPlan PlacementPlan;

    bool IsSubmittable() const;                     // 非 Hidden 且 PlacementPlan.IsValid()
    FInt64Vector SubmittableAnchorWorldMicro() const; // 只从本结果读取最终 anchor
};
```

**面内基（设计 §5.1）**：法向轴 X→(U=Y,V=Z)、Y→(U=X,V=Z)、Z→(U=X,V=Y)；法向正负不改变 U/V 顺序。

**半径与候选顺序（设计 §5.2）**：先编译一次相对 footprint 得到 world-micro 轴向 Min/Max，`span = max - min + 1`；`radius = clamp(max(span_u, span_v), 1, 16)`；候选按 `(du*du+dv*dv, du, dv)` 升序，`(0,0)` 为首项，总数超过 `1024` 时以 `snap_candidate_budget_exceeded` 隐藏。

**候选验证顺序（设计 §5.3）**：checked int64 应用 (du,dv) → `QueryFace` 确认同法向 exposed → 共享 face-alignment 得到 candidate anchor → `PlanPlace` → 全部 affected macro 可交互 → 返回首个成功。

**失败分类（设计 §6）**：

| 类别 | 判定 | 行为 |
| --- | --- | --- |
| 确定不可放置 | surface `Current==Air` 或 `Occluded`；plan reason ∈ `{occupied_by_solid_macro, occupied_by_prefab_micro, prefab_floating}` | 下一候选 |
| 当前不可交互 | plan 合法但 affected macro 不在 coverage | 下一候选 |
| 未知 confirmed truth | surface `Current/Neighbor==Unavailable`；plan reason ∈ `{world_query_unavailable, world_macro_missing, prefab_world_projection_invalid}` | 立即隐藏 `snap_search_indeterminate` + `terminal_detail` |
| 结构错误 | 法向非单位轴、朝向不允许、编译失败、signed64 溢出、候选预算破坏 | 立即隐藏并保留具体 reason |
| 候选耗尽 | 全部候选确定不可用 | 隐藏 `no_valid_anchor_within_snap_budget` |

未知 plan reason 一律按结构错误 fail-closed，不得默认跳过。

- [ ] **Step 1: 先写 Automation 行为测试并观察 RED**

`Voxia.Gameplay.PrefabPlacementSnap.*` 覆盖：

```text
- 原 anchor 合法 → Direct、offset [0,0,0]、resolved==source、tested==1
- 原 anchor 被 solid 阻挡、相邻面内合法 → Snapped、offset 只在切向轴、resolved==source+offset
- 等距候选（+U/-U/+V/-V 同时合法）→ 固定选择 (du,dv) 字典序最小者，重复调用结果一致
- 六种法向 ×（正/负坐标）× 跨 macro/chunk 边界
- 当前 builtin 全部 24 个 Orientation24 均返回稳定结果
- 更近候选 surface Unavailable → Hidden/snap_search_indeterminate（不得跳过后返回更远候选）
- 同面 Air / Occluded 候选被跳过
- coverage 排除首个合法候选 → 继续搜索下一个
- 半径耗尽 → Hidden/no_valid_anchor_within_snap_budget
- 非单位轴法向、未允许朝向 → Hidden 并保留结构原因
- 命中微格接近 int64 边界 → Hidden 并保留溢出原因
- radius 与 tested_candidate_count 始终落在 [1,16] / [0,1024]
- Hidden 不携带 ResolvedAnchor/Offset/可提交 plan
```

- [ ] **Step 2: 实现最小 resolver 并 GREEN**

```powershell
& "$VoxiaUeRoot\Engine\Build\BatchFiles\Build.bat" VoxiaEditor Win64 Development "-Project=$VoxiaProject" -WaitMutex -NoLiveCoding -NoUBA -MaxParallelActions=2
& "$VoxiaUeRoot\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" $VoxiaProject -unattended -nop4 -nullrhi -nosound '-ExecCmds=Automation RunTests Voxia.Gameplay.PrefabPlacementSnap;Quit' "-ReportExportPath=$PWD\.demo\observe\voxia-prefab-snap\snap-green-20260805" '-TestExit=Automation Test Queue Empty'
```

- [ ] **Step 3: mutation 自审并提交**

假设发生「U/V 轴对调」「排序键去掉 du」「未知 reason 默认跳过」「radius clamp 用 `<` 边界」「offset 允许法向分量」中任一变化，确认至少一条测试失败。

```
git commit -m "feat(gameplay): resolve nearest valid prefab anchor"
```

---

### Task 2: Controller 单一 immutable preview plan 与隐藏无效候选

**Files:** `VoxiaBuildInteractionController.h/.cpp`、`VoxiaBuildVisualFeedback.h/.cpp`、`VoxiaPhase3PrefabInteractionAutomationTest.cpp`、`VoxiaBuildVisualFeedbackAutomationTest.cpp`

**契约变化：**

- `FVoxiaPrefabPreviewState` 去掉独立可变的 `Plan` 与 `AnchorWorldMicro`；place 分支只保留 `SnapResult`，replace 分支只保留 `ReplacePlan`；对外只暴露只读 `SubmittableAnchorWorldMicro()` / `SubmittablePlan()`。
- `RebuildPrefabPreview` 的 place 分支改为调用 resolver；`Hidden` 时 `bValid=false`、`InvalidReason = SnapResult.Reason`。
- `RefreshVisualFeedback` 的 `PrefabPlace` 分支：`Hidden` → 发布 `mode=prefab_place, visible=false, valid=false, style=none, line_count=0, anchor=[0,0,0]`；否则用 resolved anchor + `SnapResult.PlacementPlan.Footprint` 构建绿色 exact 帧。
- `PrefabReplace` 分支：合法保持红/黄/绿差分；不合法改为发布同形隐藏帧（不再生成 `Invalid` 角色线段）。
- `FVisualFeedbackSourceKey` 增加 `SnapState`、`SourceAnchorWorldMicro`，保证 direct↔snapped↔hidden 转换必然重建帧。
- `PlaceSelected` 只从 `SnapResult` 读取 anchor / conflict set，并要求 `IsSubmittable()`；`Hidden` 时不发 intent。
- `BuildPrefabPlace` 只接受已合法 plan（不再接受 `bValid=false`），新增 `BuildPrefabPlaceHidden(PrefabId, OrientationId, Revision, Reason)`；`BuildPrefabReplace` 增加同形隐藏路径。

- [ ] **Step 1: 先写 RED**

`Voxia.Gameplay.Phase3PrefabInteraction.*` 与 `Voxia.Gameplay.BuildVisualFeedback.*` 新增：

```text
- 直接 anchor 被占用、相邻合法：preview 必须 valid、visual_feedback 必须 visible 且 role_counts.invalid==0（当前红框实现必须 RED）
- 无解场景：visual_feedback.visible==false、line_count==0、style=none、click 不产生 intent
- 提交 intent 的 AnchorWorldMicro 必须等于 SnapResult.ResolvedAnchorWorldMicro
- invalid replace：hidden、零 invalid line、不发 intent、selection anchor/层级不变
- valid replace 差分颜色与既有 remove/retained/add identity 不回归
- 热栏切换 / 旋转 / revision 变化 / coverage 变化 / InvalidateHoverSelection / EndPlay 后不得残留旧 snap
- place 与 replace 分支互斥：切换后非活动分支必须为空
```

- [ ] **Step 2: 实现并 GREEN**（build + `Automation RunTests Voxia.Gameplay`）

- [ ] **Step 3: mutation 自审并提交**

```
git commit -m "feat(gameplay): publish only submittable prefab preview"
```

---

### Task 3: 可观测面、Node validator 与 Phase 3 smoke 路线

**Files:** `VoxiaBuildInteractionController.cpp`（`SnapshotJson`）、`VoxiaPawn.*`、`VoxiaPrefabDebugDiagnostics.*`、`VoxiaDebugCliSubsystem.cpp`、`run_phase3_prefab_runtime_smoke.js/.test.js`

**JSON 契约：**

```json
"prefab_preview": {
  "prefab_id": "8",
  "anchor_world_micro": [130, -9, 24],
  "orientation_id": 7,
  "observed_world_revision": "42",
  "valid": true,
  "reason": "",
  "occupied_micro_count": 96,
  "affected_macro_count": 3,
  "snap": {
    "state": "snapped",
    "source_anchor_world_micro": [128, -9, 24],
    "resolved_anchor_world_micro": [130, -9, 24],
    "offset_world_micro": [2, 0, 0],
    "face_normal_world_micro": [0, 1, 0],
    "search_radius_micro": 8,
    "tested_candidate_count": 9,
    "reason": "nearest_valid_anchor",
    "terminal_detail": null
  }
}
```

`prefab runtime-metrics` 增加 `placement_snap` CPU 计时（与 raycast/collision 同形）。

**Node validator 硬失败条件：**

- `snap.state` ∉ `{direct, snapped, hidden}`；replace/非 prefab 工具时 `snap != null`；place 时 `snap == null`。
- `search_radius_micro` ∉ `[1,16]`（hidden 结构错误允许 0）；`tested_candidate_count` ∉ `[0,1024]`。
- `direct` 且 `offset != [0,0,0]` 或 `resolved != source`。
- `snapped` 且 `offset` 含法向轴非零分量，或 `source + offset != resolved`。
- `hidden` 且 `resolved/offset` 非 null，或 `visual_feedback.visible == true`，或 `anchor_world_micro != [0,0,0]`。
- 可见 place 时 `visual_feedback.anchor_world_micro != prefab_preview.anchor_world_micro != snap.resolved_anchor_world_micro`。
- 64 位坐标/revision 经 JavaScript Number 丢精度。

**Phase 3 smoke 路线新增：**

1. `prefab_place_snapped`：先放置一个 prefab，再用 `look_at` 精确瞄准使 direct anchor 与其重叠，断言 `snap.state == "snapped"`、`offset` 非零且只在切向轴、`visual_feedback` 绿色可见、`place` intent anchor 等于 `resolved_anchor_world_micro`。
2. `prefab_place_hidden`：构造预算内无解场景，断言 hidden、无线段、`place` 不发 intent。
3. `prefab_replace_hidden`：无效 replace 断言 hidden、零 invalid line、不发 intent、selection 不变。
4. `REQUIRED_BUILD_VISUAL_FEEDBACK_SEMANTICS` 用 `prefab_place_snapped` / `prefab_place_hidden` 替换 `prefab_place_invalid`；trace validator 允许 hidden 事件（`visible=false, line_count=0, style=none`）。
5. 持续 XYZ 移动 / Near-Far 流送 / 卸载重载后不得保留 stale snap。

- [ ] **Step 1: 先扩 `run_phase3_prefab_runtime_smoke.test.js` 并观察 RED**
- [ ] **Step 2: 实现 C++ 可观测面与 JS validator，`node --test clients/Voxia/scripts/*.test.js` GREEN**
- [ ] **Step 3: 提交**

```
git commit -m "feat(debug): observe prefab snap resolution"
```

---

### Task 4: 全量门禁、实跑与文档收口

- [ ] **Step 1:** Development build（exit 0）
- [ ] **Step 2:** 全量 `Automation RunTests Voxia`，失败/未运行必须为 0
- [ ] **Step 3:** `node --test clients/Voxia/scripts/*.test.js` 全通过
- [ ] **Step 4:** Phase 3 Null-RHI 全路线 `passed=true`
- [ ] **Step 5:** 1920×1080 Real-RHI 全路线通过，且 frame/GT/GPU p95 不劣于既有门禁；同时记录 snap CPU 计时
- [ ] **Step 6:** 更新 `clients/Voxia/README.md`、`Gameplay/README.md`、`PrefabRuntime/README.md`、`docs/00-current-truth/impl/README.md`、两份设计文档状态与 `_session-handoff.md`
- [ ] **Step 7:** 提交并交付用户可见复核（吸附手感需用户确认后才能把状态改为完成）

## 完成条件（设计 §10）

1. 普通 place 可见线框永远对应当前 revision/coverage 下可提交的 exact plan；
2. invalid place/replace 不显示红框、不发送 intent；
3. 最近排序、预算、失败分类与完整 XYZ 契约由 Automation 冻结；
4. HUD、CLI、真实输入只消费一个 resolved preview plan；
5. 全量 Automation、Node、Null-RHI/Real-RHI 与持续流送门禁通过；
6. 唯一 production root 与 server-authoritative confirmed truth 边界未改变；
7. 用户在最新可见窗口确认吸附手感后才可写成完成。

## 进度日志

- 2026-08-05：计划创建，等待逐 Task 执行。
- 2026-08-06：Task 1–4 全部完成。客户端提交 `cfd4ece`（resolver + Automation）、`fb96946`（controller 单一 immutable plan 与隐藏语义）、`ceb9ace`（`prefab_preview.snap` 与 `placement_snap` 指标 + Node validator）、`6d2e5ef`（Phase 3 封闭竖井确定性路线）、`1a64b45`（客户端文档）。
  - 门禁：Development build success；UE Automation `216/216`（1 项外部 `generate_204` warning）；Node `134/134`；Phase 3 Null-RHI `20/20`；1920×1080 Real-RHI `20/20`，frame p95/p99=`5.958/7.044ms`。
  - mutation 自审：把 planner 未知原因从 fail-closed 改成跳过，`Voxia.Gameplay.PrefabPlacementSnap` 精确失败于 terminal detail 与候选计数两条断言；已回滚。
  - 与设计的两处偏差（`prefab_preview.snap.*` 命名空间、隐藏帧锚点归零）已写入设计文档 §11.1。
  - 三项未闭合项（用户可见复核、吸附搜索 CPU 峰值 `5.60ms`、封闭地下口袋放置的 presentation 停滞）已写入设计文档 §11.3/§11.4 与 session handoff。
