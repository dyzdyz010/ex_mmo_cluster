# Voxia 建造命中与 Prefab 放置预览反馈 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Voxia 唯一生产流程中加入始终可见的宏格命中面和 prefab 精确放置/替换/删除线框，同时保证显示候选与提交 intent 共用同一份缓存 plan。

**Architecture:** `FVoxiaBuildInteractionController` 继续拥有命中、selection 和 prefab plan，并发布不可变 `FVoxiaBuildVisualFeedbackFrame`。纯 builder 负责把宏格面、compiled footprint 和 confirmed coverage 转成有预算的 UE 世界坐标线段；`AVoxiaHUD` 只投影并绘制，focus/stream controller 不再调用建造 overlay。正式 world truth、碰撞和 authority 路径不变。

**Tech Stack:** Unreal Engine 5.8、C++20/UE Core、AHUD/Canvas、UE Automation、Node.js stdio CLI smoke、RuntimeMock authority。

**Design:** [`2026-08-04-voxia-build-targeting-feedback-design.md`](../../10-active/cross-cutting/2026-08-04-voxia-build-targeting-feedback-design.md)

## Global Constraints

- 现役客户端只有 `clients/Voxia`；Web/Bevy 不读取、不修改、不验证。
- 唯一生产组合根保持 `production_all_features` / `AVoxiaUnifiedVoxelWorldActor`，不新增 actor、地图、组件或第二入口。
- 点击只提交 intent；confirmed 世界仍只由 authority transaction 更新，不加入客户端乐观确认。
- 反馈帧只能消费 controller 已缓存的 confirmed hit、`FVoxiaPrefabPlacementPlan`、`FVoxiaPrefabReplacePlan` 和 confirmed selection coverage；禁止第二次 raycast、第二次规划或坐标算法副本。
- Prefab 点击提交必须消费生成当前反馈帧的同一份缓存 plan；revision 变化时 fail-closed。
- 宏格反馈固定四条线；exact prefab 上限为 2048 个微格、8192 条线；macro fallback 上限为 512 个宏格、4096 条线；再超限时降级为 12 线 AABB。
- `visual_feedback.mode` 只能是 `none|macro_face|prefab_place|prefab_replace|prefab_selection`，`style` 只能是 `none|exact|simplified`。
- 正式反馈不依赖 `-VoxiaDebugCanvasHUD`、`-VoxiaStreamDebug` 或 transport debug panel。
- 正常无效候选以红色保留；没有可靠 confirmed hit/footprint 时清空旧线框并暴露稳定原因。
- 新增和修改的代码注释统一使用中文。
- 每个生产行为先写真实行为测试并观察 RED，再写最小实现；不得以源码字符串 grep 代替用户可观察行为测试。
- 结构化产物写入 `.demo/observe/`，截图不能成为唯一证据。

---

## 文件结构与职责

新增：

```text
clients/Voxia/Source/Voxia/Gameplay/
  VoxiaBuildVisualFeedback.h
  VoxiaBuildVisualFeedback.cpp
  VoxiaBuildVisualFeedbackAutomationTest.cpp
  VoxiaBuildVisualFeedbackProjection.h
  VoxiaBuildVisualFeedbackProjection.cpp
  VoxiaBuildVisualFeedbackProjectionAutomationTest.cpp
```

- `VoxiaBuildVisualFeedback.*`：纯值类型、宏格/微格/coverage 适配、线段去重、预算降级和 JSON；不接触 UObject、World、Canvas 或 gateway。
- `VoxiaBuildVisualFeedbackProjection.*`：把世界线段通过注入的单点投影函数转换为屏幕线段，并解析正式颜色；不读取 gameplay 状态。
- 两个 Automation 文件分别验证几何/预算与投影/颜色，不使用 mock world 或源码文本断言。

主要修改：

```text
clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.h/.cpp
clients/Voxia/Source/Voxia/Gameplay/VoxiaPawn.h/.cpp
clients/Voxia/Source/Voxia/Gameplay/VoxiaHUD.h/.cpp
clients/Voxia/Source/Voxia/Gameplay/VoxiaFocusRemoteInteractionController.cpp
clients/Voxia/Source/Voxia/Gameplay/VoxiaPhase2InteractionAutomationTest.cpp
clients/Voxia/Source/Voxia/Gameplay/VoxiaPhase3PrefabInteractionAutomationTest.cpp
clients/Voxia/Source/Voxia/Gameplay/VoxiaPawnControllerOwnershipAutomationTest.cpp
clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.js
clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.test.js
clients/Voxia/README.md
clients/Voxia/Source/Voxia/Gameplay/README.md
clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/README.md
docs/00-current-truth/impl/README.md
docs/10-active/cross-cutting/2026-08-04-voxia-build-targeting-feedback-design.md
docs/10-active/cross-cutting/_session-handoff.md
```

## 执行前置

从现有隔离 worktree 执行客户端步骤：

```powershell
Set-Location 'C:\Users\DYZ\Documents\dev\hemifuture\ex_mmo_cluster\.worktrees\voxia-phase3-prefab-runtime'
git status --short
git branch --show-current
git rev-parse --git-dir
git rev-parse --git-common-dir
```

预期：branch 为 `codex/voxia-phase3-prefab-runtime`，`git-dir` 与 `git-common-dir` 不同，工作树无未说明改动。构建前关闭现有 Voxia/UnrealEditor 游戏实例，避免 DLL 锁定；不要结束无关 Unreal 进程。

统一发现 UE 5.8：

```powershell
$VoxiaUeCandidates = @(
  $env:VOXIA_UE_ROOT,
  'D:\Epic Games\UE_5.8',
  'D:\UE\UE_5.8',
  'C:\Program Files\Epic Games\UE_5.8'
)
$VoxiaUeRoot = $VoxiaUeCandidates |
  Where-Object { $_ -and (Test-Path (Join-Path $_ 'Engine\Build\BatchFiles\Build.bat')) } |
  Select-Object -First 1
if (-not $VoxiaUeRoot) { throw 'UE 5.8 root not found' }
$VoxiaProject = Join-Path $PWD 'Voxia.uproject'
```

---

### Task 1: 纯反馈帧、精确几何和有界降级

**Files:**
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildVisualFeedback.h`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildVisualFeedback.cpp`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildVisualFeedbackAutomationTest.cpp`

**Interfaces:**
- Consumes: `FVoxiaCompiledPrefabFootprint`、`FVoxiaPrefabReplacePlan`、`TArray<FVoxiaCoverageSlice>`、UE client-space confirmed hit center/normal。
- Produces:

```cpp
enum class EVoxiaBuildVisualFeedbackMode : uint8
{
	None,
	MacroFace,
	PrefabPlace,
	PrefabReplace,
	PrefabSelection
};

enum class EVoxiaBuildVisualFeedbackStyle : uint8
{
	None,
	Exact,
	Simplified
};

enum class EVoxiaBuildVisualLineRole : uint8
{
	Editable,
	Invalid,
	PreviewAdded,
	PreviewRetained,
	PreviewRemoved,
	SelectedLeaf,
	SelectedParent
};

const TCHAR* BuildVisualFeedbackModeLabel(
	EVoxiaBuildVisualFeedbackMode Mode);
const TCHAR* BuildVisualFeedbackStyleLabel(
	EVoxiaBuildVisualFeedbackStyle Style);
const TCHAR* BuildVisualLineRoleLabel(
	EVoxiaBuildVisualLineRole Role);

struct FVoxiaBuildVisualLine
{
	FVector StartWorldCm = FVector::ZeroVector;
	FVector EndWorldCm = FVector::ZeroVector;
	EVoxiaBuildVisualLineRole Role = EVoxiaBuildVisualLineRole::Invalid;

	bool operator==(const FVoxiaBuildVisualLine& Other) const;
};

struct FVoxiaBuildVisualFeedbackFrame
{
	EVoxiaBuildVisualFeedbackMode Mode = EVoxiaBuildVisualFeedbackMode::None;
	EVoxiaBuildVisualFeedbackStyle Style = EVoxiaBuildVisualFeedbackStyle::None;
	bool bVisible = false;
	bool bValid = false;
	bool bSimplified = false;
	FString Reason = TEXT("not_updated");
	uint64 PrefabId = 0;
	uint64 SelectedInstanceId = 0;
	FInt64Vector AnchorWorldMicro = FInt64Vector::ZeroValue;
	uint8 OrientationId = 0;
	uint64 ObservedWorldRevision = 0;
	TArray<FVoxiaBuildVisualLine> Lines;

	FString SnapshotJson() const;
};

class FVoxiaBuildVisualFeedbackBuilder
{
public:
	static constexpr int32 MaxExactMicroCells = 2048;
	static constexpr int32 MaxExactLines = 8192;
	static constexpr int32 MaxSimplifiedMacros = 512;
	static constexpr int32 MaxSimplifiedLines = 4096;

	static FVoxiaBuildVisualFeedbackFrame BuildNone(const FString& Reason);
	static FVoxiaBuildVisualFeedbackFrame BuildMacroFace(
		const FVector& HitWorldCenterCm,
		const FVector& HitClientFaceNormal,
		bool bEditable,
		const FString& Reason);
	static FVoxiaBuildVisualFeedbackFrame BuildPrefabPlace(
		uint64 PrefabId,
		const FInt64Vector& AnchorWorldMicro,
		uint8 OrientationId,
		uint64 ObservedWorldRevision,
		bool bValid,
		const FString& Reason,
		const Voxia::PrefabRuntime::FVoxiaCompiledPrefabFootprint& Footprint);
	static FVoxiaBuildVisualFeedbackFrame BuildPrefabReplace(
		const Voxia::PrefabRuntime::FVoxiaPrefabReplacePlan& Plan,
		bool bValid,
		const FString& Reason);
	static FVoxiaBuildVisualFeedbackFrame BuildPrefabSelection(
		uint64 SelectedInstanceId,
		bool bSelectedLeaf,
		uint64 ObservedWorldRevision,
		const TArray<Voxia::PrefabRuntime::FVoxiaCoverageSlice>& Coverage);
};
```

- Later tasks consume: `BuildVisualFeedbackModeLabel`、`BuildVisualFeedbackStyleLabel`、`BuildVisualLineRoleLabel` 的稳定小写标签和 `FVoxiaBuildVisualFeedbackFrame::SnapshotJson()`。

- [ ] **Step 1: 写几何与预算 RED Automation**

在新测试文件中先声明 `Voxia.Gameplay.BuildVisualFeedback`，直接调用上述期望 API。手工期望宏格 +X 面为：

```cpp
const FVoxiaBuildVisualFeedbackFrame Macro =
	FVoxiaBuildVisualFeedbackBuilder::BuildMacroFace(
		FVector(100.0, 200.0, 300.0),
		FVector(1.0, 0.0, 0.0),
		true,
		TEXT("ready"));
TestEqual(TEXT("宏格面固定四边"), Macro.Lines.Num(), 4);
for (const FVoxiaBuildVisualLine& Line : Macro.Lines)
{
	TestEqual(TEXT("+X 命中面含 1cm 视觉偏移"), Line.StartWorldCm.X, 151.0);
	TestEqual(TEXT("同一平面"), Line.EndWorldCm.X, 151.0);
	TestEqual(TEXT("可编辑角色"), Line.Role,
		EVoxiaBuildVisualLineRole::Editable);
}
```

测试 helper 只负责构造真实 `FVoxiaCompiledPrefabFootprint`/coverage fixture：以 `FVoxiaWorldMacroKey::FromWorldMicro` 和 `FVoxiaMicroSlot::FromWorldMicro` 分组，不用 production builder 计算期望值。至少加入这些行为断言：

```cpp
// 单个 world micro (-1,-8,-9) 的 UE client bounds 必须是：
// X [-12.5,0]、Y [-112.5,-100]、Z [-100,-87.5]，且恰好 12 条边。
// 两个 X 相邻微格的外表面网格恰好 20 条去重线段。
// +X/-X/+Y/-Y/+Z/-Z 六个命中方向分别落在 center 对应轴的 +/-51cm 平面，另两轴范围均为 +/-50cm。
// 同一 cell 集合打乱 slice/cell 顺序后 Lines 完全相同。
// 无效 place 的几何仍可见，全部 role=Invalid。
// replace 三个彼此分离 cell 分别得到 12 条 Removed/Retained/Added。
// leaf selection 全部 SelectedLeaf，parent selection 全部 SelectedParent。
// 2049 cell 进入 Simplified；1024 个隔离 cell 因 8192 line 上限进入 Simplified。
// 在 512 个隔离 macro 中各放两个不相邻微格：exact 超过 8192，macro 超过 4096，最终只剩 12 线 AABB。
// MAX_int64 边界无法安全形成高侧顶点时返回 invisible + visual_coordinate_out_of_range。
```

- [ ] **Step 2: 运行 Development build，确认 RED**

```powershell
& "$VoxiaUeRoot\Engine\Build\BatchFiles\Build.bat" VoxiaEditor Win64 Development `
  "-Project=$VoxiaProject" -WaitMutex -NoLiveCoding -NoUBA -MaxParallelActions=2
```

Expected: FAIL，首个错误来自 `VoxiaBuildVisualFeedback.h`/builder 类型尚不存在；不能是测试 fixture 拼写或旧代码错误。

- [ ] **Step 3: 实现最小纯 builder**

实现时使用整数网格顶点键 `{domain XYZ boundary coordinate, edge axis}` 去重，再在输出阶段转换为 UE client 坐标 `{X, Z, Y}`。对每个 cell 只枚举邻接空气的六个面，每面产生四条边；相同边按以下固定优先级归并：

```cpp
Invalid > PreviewRemoved > PreviewAdded > PreviewRetained
        > SelectedParent > SelectedLeaf > Editable
```

精确构建先检查 cell 数，再检查去重边数。任何 exact 超限都丢弃整份 exact 结果，按 macro occupancy 重建；macro 仍超限时从完整 cell bounds 生成 12 线 AABB。禁止截断一半线段。

`SnapshotJson()` 输出：

```json
{"mode":"prefab_place","visible":true,"valid":true,"style":"exact","line_count":84,"simplified":false,"reason":"ready","prefab_id":"8","selected_instance_id":null,"anchor_world_micro":[128,-9,24],"orientation_id":7,"observed_world_revision":"42"}
```

`uint64 == 0` 输出 `null`；JSON 不包含全部端点，避免 CLI payload 无界膨胀。
可见且有效的 frame 统一规范化为 `reason="ready"`；无效/不可见 frame 保留传入的稳定机器原因，禁止空 reason。

- [ ] **Step 4: 运行 build 和 focused Automation，确认 GREEN**

```powershell
& "$VoxiaUeRoot\Engine\Build\BatchFiles\Build.bat" VoxiaEditor Win64 Development `
  "-Project=$VoxiaProject" -WaitMutex -NoLiveCoding -NoUBA -MaxParallelActions=2
$VoxiaReport = Join-Path $PWD 'Saved\AutomationReport\build_visual_feedback'
& "$VoxiaUeRoot\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" $VoxiaProject `
  -unattended -nop4 -nullrhi -nosound `
  '-ExecCmds=Automation RunTests Voxia.Gameplay.BuildVisualFeedback;Quit' `
  "-ReportExportPath=$VoxiaReport" '-TestExit=Automation Test Queue Empty'
```

Expected: build exit 0；`Voxia.Gameplay.BuildVisualFeedback` 全部 `Success`，无越界 ensure/warning。

- [ ] **Step 5: 做 mutation 自审并提交**

逐项假设 production 发生“面 normal 轴交换错误、负坐标 truncation、丢失 invalid role、预算使用 `>=` 错边界、exact 截断”中的任一变化，确认至少一条测试会失败。

```powershell
git add Source/Voxia/Gameplay/VoxiaBuildVisualFeedback.* `
  Source/Voxia/Gameplay/VoxiaBuildVisualFeedbackAutomationTest.cpp
git commit -m "feat(gameplay): build bounded targeting feedback frames"
```

---

### Task 2: Controller 单一发布、生命周期与 CLI snapshot

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPhase2InteractionAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPhase3PrefabInteractionAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPawn.cpp`

**Interfaces:**
- Consumes: Task 1 的 builder/frame 和 controller 已有 `bHasHit`、`PrefabPreview`、`SelectedPrefabScope`、`PrefabSelectionModel`。
- Produces:

```cpp
const FVoxiaBuildVisualFeedbackFrame& VisualFeedback() const;
void InvalidateHoverSelection(const FString& Reason);

private:
	bool FinishSelectionUpdate(bool bResult);
	void RefreshVisualFeedback();
	struct FVisualFeedbackSourceKey
	{
		EVoxiaBuildVisualFeedbackMode Mode =
			EVoxiaBuildVisualFeedbackMode::None;
		Voxia::WorldModel::FVoxiaWorldMacroKey HitMacro;
		FVector HitCenterCm = FVector::ZeroVector;
		FIntVector HitFaceNormal = FIntVector::ZeroValue;
		bool bEditable = false;
		uint64 PrefabId = 0;
		bool bReplace = false;
		FInt64Vector AnchorWorldMicro = FInt64Vector::ZeroValue;
		uint8 OrientationId = 0;
		uint64 ObservedWorldRevision = 0;
		bool bValid = false;
		FString Reason;
		uint64 SelectedInstanceId = 0;
		uint64 SelectionFingerprint = 0;
		bool bSelectedLeaf = false;

		bool operator==(const FVisualFeedbackSourceKey& Other) const;
	};
	FVisualFeedbackSourceKey MakeVisualFeedbackSourceKey() const;
	TOptional<FVisualFeedbackSourceKey> PublishedVisualFeedbackKey;
	FVoxiaBuildVisualFeedbackFrame VisualFeedbackFrame;
```

- `SnapshotJson()` additive 增加顶层 `visual_feedback`，保留现有 `voxia_build_interaction_controller_v1` 和已有字段。
- Later tasks consume: `AVoxiaPawn::GetBuildVisualFeedback()` 只读 façade。

- [ ] **Step 1: 写 controller RED 行为断言**

在 Phase 2 已有 signed64 material 命中 fixture 后加入：

```cpp
const FVoxiaBuildVisualFeedbackFrame& MacroFeedback =
	Controller.VisualFeedback();
TestEqual(TEXT("材质命中发布宏格面"), MacroFeedback.Mode,
	EVoxiaBuildVisualFeedbackMode::MacroFace);
TestTrue(TEXT("正常宏格反馈可见"), MacroFeedback.bVisible);
TestEqual(TEXT("宏格反馈固定四边"), MacroFeedback.Lines.Num(), 4);
```

把 coverage 改为不可交互后，断言仍是可见 `MacroFace`、`bValid=false`、四条 `Invalid`，而 no-hit/`ResetInteractionEvidence()` 后为 invisible `None` 且 `Lines.Num()==0`。

在 Phase 3 现有 `FirstPreview` 后加入：

```cpp
const FVoxiaBuildVisualFeedbackFrame& PlaceFeedback =
	Controller.VisualFeedback();
TestEqual(TEXT("prefab plan 发布正式候选"), PlaceFeedback.Mode,
	EVoxiaBuildVisualFeedbackMode::PrefabPlace);
TestTrue(TEXT("候选与 plan 共用 anchor"),
	PlaceFeedback.AnchorWorldMicro == FirstPreview.AnchorWorldMicro);
TestEqual(TEXT("候选与 plan 共用方向"),
	PlaceFeedback.OrientationId, FirstPreview.OrientationId);
TestEqual(TEXT("候选与 plan 共用 revision"),
	PlaceFeedback.ObservedWorldRevision, FirstPreview.ObservedWorldRevision);
```

在 `PlaceSelected` 后把实际 request 与 `PlaceFeedback` 的 prefab id/anchor/orientation/revision 逐项比较。coverage invalid 时断言候选仍可见、`bValid=false` 且所有 line 为 `Invalid`。现有 refined selection fixture 中分别选择 leaf/parent，断言 `PrefabSelection` 的 cyan/orange role；replace fixture 断言 mode 为 `PrefabReplace` 且三类 role 都存在。

用 `FJsonSerializer` 解析 `SnapshotJson()`，断言 `visual_feedback` 是 object，`line_count` 为数值、revision 为十进制字符串；不要只用 `Contains()`。

- [ ] **Step 2: build，确认 RED**

运行 Task 1 的 Development build 命令。

Expected: FAIL，首个错误是 controller 尚无 `VisualFeedback()`/frame 字段。

- [ ] **Step 3: 实现单点发布和自维护清理**

`RefreshVisualFeedback()` 严格按下列优先级发布：

```cpp
const FVoxiaHotbarSlot* Selected = SelectedHotbarSlot();
if (!bHasHit)
	VisualFeedbackFrame = FVoxiaBuildVisualFeedbackBuilder::BuildNone(
		LastBuildSelectionReason);
else if (Selected != nullptr && Selected->Kind == EVoxiaHotbarKind::Prefab)
{
	VisualFeedbackFrame = PrefabPreview.bReplace
		? FVoxiaBuildVisualFeedbackBuilder::BuildPrefabReplace(
			PrefabPreview.ReplacePlan,
			PrefabPreview.bValid,
			PrefabPreview.InvalidReason)
		: FVoxiaBuildVisualFeedbackBuilder::BuildPrefabPlace(
			PrefabPreview.PrefabId,
			PrefabPreview.AnchorWorldMicro,
			PrefabPreview.OrientationId,
			PrefabPreview.ObservedWorldRevision,
			PrefabPreview.bValid,
			PrefabPreview.InvalidReason,
			PrefabPreview.Plan.Footprint);
}
else if (bHitRefined && PrefabSelectionModel.HasSelection() &&
	SelectedPrefabScope.IsConfirmedReadable())
{
	VisualFeedbackFrame = FVoxiaBuildVisualFeedbackBuilder::BuildPrefabSelection(
		PrefabSelectionModel.SelectedInstanceId(),
		PrefabSelectionModel.IsSelectedLeaf(),
		PrefabSelectionModel.ObservedWorldRevision(),
		SelectedPrefabScope.InclusiveCoverage);
}
else if (!bHitRefined)
	VisualFeedbackFrame = FVoxiaBuildVisualFeedbackBuilder::BuildMacroFace(
		HitWorldCenterCm,
		HitClientFaceNormal,
		IsCachedBuildHitEditable(),
		LastBuildSelectionReason);
else
	VisualFeedbackFrame = FVoxiaBuildVisualFeedbackBuilder::BuildNone(
		LastPrefabSelectionReason);
```

`FVisualFeedbackSourceKey` 必须结构化比较 mode、hit macro/center/face、editable、prefab id、replace 标志、anchor、orientation、observed revision、valid/reason、selected instance、selection fingerprint 和 leaf/parent 层级。`RefreshVisualFeedback()` 先与 `PublishedVisualFeedbackKey` 比较；相同则直接返回，不重新生成最多 8192 条线。Catalog immutable 且 world revision 单调，因此这些字段相同就代表几何输入相同；不得只比较 cell count，也不得每 Tick 重建大 footprint。

把 `UpdateSelectionFromRay` 中所有 return 收口为 `FinishSelectionUpdate(result)`，保证成功、no-hit、overflow、prefab query 失败都会发布完整新帧。以下状态变更也必须调用 `RefreshVisualFeedback()`：

- `Initialize` / `ResetInteractionEvidence` / `InvalidateHoverSelection`；
- 合法 hotbar 切换、`RotatePreview`；
- `SelectPrefabParent` / `SelectPrefabChild`；
- remove hold 开始、取消或状态跨越；
- replace 完成后 selection identity 映射。

上述调用可以频繁发生，但只有 source key 变化时才真正重建 frame；测试增加“相同射线和同 revision 重复刷新后 frame 地址内容/line 顺序不变”的断言。

`InvalidateHoverSelection` 清 hit、preview、selection 和线段，但不抹掉最近 intent receipt。把 `AVoxiaPawn::DebugTeleportWorld` 里直接写 controller 私有 hit 字段的代码替换为：

```cpp
BuildController.InvalidateHoverSelection(TEXT("moved_awaiting_raycast"));
```

`SnapshotJson()` 最终结构为：

```cpp
return FString::Printf(
	TEXT("%s,\"prefab_replace\":{%s},\"visual_feedback\":%s}"),
	*SnapshotWithoutClosingBrace,
	*ReplaceFields,
	*VisualFeedbackFrame.SnapshotJson());
```

- [ ] **Step 4: 运行 focused tests，确认 GREEN**

```powershell
& "$VoxiaUeRoot\Engine\Build\BatchFiles\Build.bat" VoxiaEditor Win64 Development `
  "-Project=$VoxiaProject" -WaitMutex -NoLiveCoding -NoUBA -MaxParallelActions=2
$VoxiaReport = Join-Path $PWD 'Saved\AutomationReport\build_feedback_controller'
& "$VoxiaUeRoot\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" $VoxiaProject `
  -unattended -nop4 -nullrhi -nosound `
  '-ExecCmds=Automation RunTests Voxia.Phase2.Interaction+Voxia.Phase3.PrefabInteraction+Voxia.Gameplay.BuildVisualFeedback;Quit' `
  "-ReportExportPath=$VoxiaReport" '-TestExit=Automation Test Queue Empty'
```

若 UE 5.8 不接受 `+` 过滤表达式，则分别运行三次相同命令，每次只保留一个 suite。Expected: 全部 `Success`；现有 place/remove/replace 请求数量和 confirmed truth 断言不变。

- [ ] **Step 5: 提交 controller 集成**

```powershell
git add Source/Voxia/Gameplay/VoxiaBuildInteractionController.* `
  Source/Voxia/Gameplay/VoxiaPhase2InteractionAutomationTest.cpp `
  Source/Voxia/Gameplay/VoxiaPhase3PrefabInteractionAutomationTest.cpp `
  Source/Voxia/Gameplay/VoxiaPawn.cpp
git commit -m "feat(gameplay): publish build targeting feedback"
```

---

### Task 3: HUD 投影绘制与 stream debug 解耦

**Files:**
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildVisualFeedbackProjection.h`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildVisualFeedbackProjection.cpp`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildVisualFeedbackProjectionAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPawn.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPawn.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaHUD.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaHUD.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaFocusRemoteInteractionController.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPawnControllerOwnershipAutomationTest.cpp`

**Interfaces:**
- Consumes: Task 2 的 immutable frame。
- Produces:

```cpp
struct FVoxiaBuildVisualScreenLine
{
	FVector2D Start;
	FVector2D End;
	EVoxiaBuildVisualLineRole Role = EVoxiaBuildVisualLineRole::Invalid;
};

struct FVoxiaBuildVisualProjection
{
	int32 SourceLineCount = 0;
	int32 SkippedLineCount = 0;
	TArray<FVoxiaBuildVisualScreenLine> Lines;
};

class FVoxiaBuildVisualFeedbackProjector
{
public:
	using FProjectEndpoint =
		TFunctionRef<bool(const FVector&, FVector2D&)>;
	static void Project(
		const FVoxiaBuildVisualFeedbackFrame& Frame,
		FProjectEndpoint ProjectEndpoint,
		FVoxiaBuildVisualProjection& OutProjection);
	static FLinearColor ColorForRole(EVoxiaBuildVisualLineRole Role);
};
```

- `AVoxiaPawn::GetBuildVisualFeedback() const` 只转发 `BuildController.VisualFeedback()`。
- `AVoxiaHUD::DrawBuildVisualFeedback(const AVoxiaPawn&)` 是唯一正式 renderer；HUD 复用成员 `ProjectionScratch` 避免每帧反复分配。

- [ ] **Step 1: 写投影和颜色 RED Automation**

```cpp
FVoxiaBuildVisualFeedbackFrame Frame;
Frame.bVisible = true;
Frame.Lines = {
	{FVector(1, 2, 3), FVector(4, 5, 6), EVoxiaBuildVisualLineRole::PreviewAdded},
	{FVector(-1, 2, 3), FVector(4, 5, 6), EVoxiaBuildVisualLineRole::Invalid}};
FVoxiaBuildVisualProjection Projection;
FVoxiaBuildVisualFeedbackProjector::Project(
	Frame,
	[](const FVector& World, FVector2D& Screen)
	{
		if (World.X < 0.0) { return false; }
		Screen = FVector2D(World.X * 2.0, World.Z * 3.0);
		return true;
	},
	Projection);
TestEqual(TEXT("保留成功投影线"), Projection.Lines.Num(), 1);
TestEqual(TEXT("失败端点使整线跳过"), Projection.SkippedLineCount, 1);
TestTrue(TEXT("新增角色以绿色为主"),
	FVoxiaBuildVisualFeedbackProjector::ColorForRole(
		EVoxiaBuildVisualLineRole::PreviewAdded).G > 0.9f);
TestTrue(TEXT("无效角色以红色为主"),
	FVoxiaBuildVisualFeedbackProjector::ColorForRole(
		EVoxiaBuildVisualLineRole::Invalid).R > 0.9f);
```

再覆盖 invisible frame 不调用 projection、NaN 屏幕坐标跳过、source/skipped count 保持正确。

- [ ] **Step 2: build，确认 RED**

运行统一 Development build。

Expected: FAIL，首个错误来自 projection 类型尚不存在。

- [ ] **Step 3: 实现 projector 和正式 Canvas renderer**

`AVoxiaHUD::DrawHUD()` 顺序改为：

```text
Super::DrawHUD
Canvas/Pawn resolve
DrawBuildVisualFeedback
DrawTuningPanel
transport diagnostic panel（可缺失）
DrawCrosshair
DrawHotbar
```

`DrawBuildVisualFeedback` 使用 owning `APlayerController::ProjectWorldLocationToScreen` 投影每个端点，并用 `FCanvasLineItem` 绘制：

```cpp
FVoxiaBuildVisualFeedbackProjector::Project(
	Pawn.GetBuildVisualFeedback(),
	[PlayerController](const FVector& WorldCm, FVector2D& Screen)
	{
		return PlayerController->ProjectWorldLocationToScreen(
			WorldCm, Screen, false);
	},
	ProjectionScratch);
for (const FVoxiaBuildVisualScreenLine& Line : ProjectionScratch.Lines)
{
	FCanvasLineItem Item(Line.Start, Line.End);
	Item.SetColor(FVoxiaBuildVisualFeedbackProjector::ColorForRole(Line.Role));
	Item.LineThickness = 2.0f;
	Canvas->DrawItem(Item);
}
```

反馈绘制必须位于 `Transport == nullptr` 的提前返回之前；transport 缺失时仍画 feedback/crosshair/hotbar。正常运行不得读取 `IsVoxelDebugOverlayEnabled()`。

从 `FVoxiaBuildInteractionController` 删除 `DrawOverlay` 声明、实现和 `DrawDebugHelpers.h` include；从 `FVoxiaFocusRemoteInteractionController::DrawOverlay` 删除 `Pawn.BuildController.DrawOverlay(Pawn)`，其 stream/tile debug guard 和诊断保持不变。编译器由此保证 focus controller 无法再调用旧建造 renderer。

`AVoxiaPawn::Tick` 在 `bRuntimeReady == false` 时调用：

```cpp
BuildController.InvalidateHoverSelection(TEXT("runtime_not_ready"));
```

删除 `VoxiaPawnControllerOwnershipAutomationTest` 对 `EDIT TARGET` 和 `NO confirmed voxel hit` 源码字符串的两条断言；这些行为已经由 Task 1/2 的真实 frame 测试覆盖。不要新增相反的源码 grep。

- [ ] **Step 4: focused build/Automation，确认 GREEN**

```powershell
& "$VoxiaUeRoot\Engine\Build\BatchFiles\Build.bat" VoxiaEditor Win64 Development `
  "-Project=$VoxiaProject" -WaitMutex -NoLiveCoding -NoUBA -MaxParallelActions=2
$VoxiaReport = Join-Path $PWD 'Saved\AutomationReport\build_feedback_hud'
& "$VoxiaUeRoot\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" $VoxiaProject `
  -unattended -nop4 -nullrhi -nosound `
  '-ExecCmds=Automation RunTests Voxia.Gameplay.BuildVisualFeedbackProjection;Quit' `
  "-ReportExportPath=$VoxiaReport" '-TestExit=Automation Test Queue Empty'
& "$VoxiaUeRoot\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" $VoxiaProject `
  -unattended -nop4 -nullrhi -nosound `
  '-ExecCmds=Automation RunTests Voxia.Gameplay.PawnControllerOwnership;Quit' `
  "-ReportExportPath=$VoxiaReport-ownership" '-TestExit=Automation Test Queue Empty'
```

Expected: 两套全部 `Success`；build controller 不再链接 `DrawDebugHelpers`；focus debug 仍可编译。

- [ ] **Step 5: 提交正式 HUD**

```powershell
git add Source/Voxia/Gameplay/VoxiaBuildVisualFeedbackProjection.* `
  Source/Voxia/Gameplay/VoxiaBuildVisualFeedbackProjectionAutomationTest.cpp `
  Source/Voxia/Gameplay/VoxiaPawn.* `
  Source/Voxia/Gameplay/VoxiaHUD.* `
  Source/Voxia/Gameplay/VoxiaBuildInteractionController.* `
  Source/Voxia/Gameplay/VoxiaFocusRemoteInteractionController.cpp `
  Source/Voxia/Gameplay/VoxiaPawnControllerOwnershipAutomationTest.cpp
git commit -m "feat(ui): render build feedback in canvas HUD"
```

---

### Task 4: stdio smoke 契约与客户端文档

**Files:**
- Modify: `clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.test.js`
- Modify: `clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.js`
- Modify: `clients/Voxia/README.md`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/README.md`
- Modify: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/README.md`

**Interfaces:**
- Consumes: `build_interaction.visual_feedback`。
- Produces: exported `visualFeedbackFromBuild(build, expectedMode)` validator；Phase 3 trace 新增 `build_visual_feedback` 事件。

- [ ] **Step 1: 写 Node RED 测试**

从 smoke module import `visualFeedbackFromBuild`，加入一个完整合法 fixture 和逐字段 mutation：

```js
const build = {
  contract: "voxia_build_interaction_controller_v1",
  prefab_preview: {
    anchor_world_micro: [128, -9, 24],
    orientation_id: 7,
    observed_world_revision: "42",
  },
  visual_feedback: {
    mode: "prefab_place",
    visible: true,
    valid: true,
    style: "exact",
    line_count: 84,
    simplified: false,
    reason: "ready",
    anchor_world_micro: [128, -9, 24],
    orientation_id: 7,
    observed_world_revision: "42",
  },
};
assert.equal(visualFeedbackFromBuild(build, "prefab_place").line_count, 84);
```

分别把 mode 改成未知值、`line_count` 改成 8193、anchor/orientation/revision 改成与 preview 不同，断言抛出稳定 code：`phase3_build_visual_feedback_invalid` 或 `phase3_build_visual_feedback_plan_mismatch`。

- [ ] **Step 2: 运行 Node test，确认 RED**

```powershell
node --test scripts/run_phase3_prefab_runtime_smoke.test.js
```

Expected: FAIL，`visualFeedbackFromBuild` 未导出/未定义。

- [ ] **Step 3: 实现 validator 并接入真实路线**

Validator 必须检查：mode/style 枚举、boolean、稳定 reason、整数 `0..8192`、`visible => line_count > 0 && style != none`、`!visible => line_count == 0`。Prefab place/replace 时，把 visual anchor/orientation/revision 与 `prefab_preview` 逐项比较。

`waitForPrefabPreview` 返回 `{build, preview, visualFeedback}`；`placeAssembly` 和 `collectOrientationCoverage` 断言：

```js
visualFeedback.mode === "prefab_place"
visualFeedback.visible === true
visualFeedback.valid === preview.valid
visualFeedback.line_count > 0
visualFeedback.anchor_world_micro === preview.anchor_world_micro
visualFeedback.orientation_id === preview.orientation_id
visualFeedback.observed_world_revision === preview.observed_world_revision
```

每次确认有效 place preview 时写一条：

```json
{"type":"build_visual_feedback","mode":"prefab_place","visible":true,"valid":true,"style":"exact","line_count":84,"anchor_world_micro":[128,-9,24],"orientation_id":7,"observed_world_revision":"42"}
```

同时把上述事件加入 Node 测试的 `createValidTrace()` fixture。更新 `validatePhase3Trace`，要求至少一条有效 `build_visual_feedback` 且 plan identity 完整；在 result checks 增加 `build_visual_feedback: true`。

- [ ] **Step 4: 运行 Node GREEN 和 focused UE 回归**

```powershell
node --test scripts/run_phase3_prefab_runtime_smoke.test.js
& "$VoxiaUeRoot\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" $VoxiaProject `
  -unattended -nop4 -nullrhi -nosound `
  '-ExecCmds=Automation RunTests Voxia.Phase3.PrefabInteraction;Quit' `
  "-ReportExportPath=$(Join-Path $PWD 'Saved\AutomationReport\build_feedback_cli')" `
  '-TestExit=Automation Test Queue Empty'
```

Expected: Node 全部 pass；UE focused suite `Success`。

- [ ] **Step 5: 同步客户端 README 并提交**

文档必须写明：

- HUD renderer 只消费 immutable frame；
- `build_interaction.visual_feedback` 字段与预算；
- 黄色宏格面、绿/红 placement、replace 三色、leaf 青/parent 橙；
- stream debug flag 不再控制建造反馈；
- Online authority、Prefab Designer 和 world truth 边界没有变化。

```powershell
git add scripts/run_phase3_prefab_runtime_smoke.js `
  scripts/run_phase3_prefab_runtime_smoke.test.js `
  README.md Source/Voxia/Gameplay/README.md `
  Source/Voxia/Voxel/PrefabRuntime/README.md
git commit -m "test(gameplay): verify build targeting feedback routes"
```

---

### Task 5: 全量验证、Real-RHI 证据与当前真值收口

**Files:**
- Modify: `docs/00-current-truth/impl/README.md`
- Modify: `docs/10-active/cross-cutting/2026-08-04-voxia-build-targeting-feedback-design.md`
- Modify: `docs/10-active/cross-cutting/_session-handoff.md`

**Interfaces:**
- Consumes: Task 1–4 的客户端提交和 `.demo/observe/` 新鲜证据。
- Produces: 当前真值、设计状态、复现命令、残余风险和用户可见运行入口。

- [ ] **Step 1: clean status 与全量 Development build**

```powershell
git status --short
& "$VoxiaUeRoot\Engine\Build\BatchFiles\Build.bat" VoxiaEditor Win64 Development `
  "-Project=$VoxiaProject" -WaitMutex -NoLiveCoding -NoUBA -MaxParallelActions=2
```

Expected: worktree clean；build exit 0，不能以旧二进制代替。

- [ ] **Step 2: 全量 UE Automation 和全部 Node tests**

```powershell
$VoxiaReport = Join-Path $PWD 'Saved\AutomationReport\build_feedback_all'
& "$VoxiaUeRoot\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" $VoxiaProject `
  -unattended -nop4 -nullrhi -nosound `
  '-ExecCmds=Automation RunTests Voxia;Quit' `
  "-ReportExportPath=$VoxiaReport" '-TestExit=Automation Test Queue Empty'
node --test scripts/*.test.js
```

Expected: UE `0 failed / 0 not-run`，Node `0 failed`。记录实际总数，不能沿用历史 `213/213` 或 `124/124`。

- [ ] **Step 3: Null-RHI Phase 3 全链路**

```powershell
node scripts/run_phase3_prefab_runtime_smoke.js --null-rhi --res 1280x720
```

Expected: summary `passed=true`；trace 有 `build_visual_feedback`、place/remove/replace、XYZ unload/reload、XYZ continuous streaming、parity 和 CPU 证据；退出码 0。记录生成的 `.demo/observe/voxia_phase3_*_null_rhi_1280x720/`。

- [ ] **Step 4: Real-RHI 正常参数可见验证**

```powershell
node scripts/run_phase3_prefab_runtime_smoke.js --visible-rhi --res 1920x1080
```

要求命令行不出现 `-VoxiaDebugCanvasHUD` 或 `-VoxiaStreamDebug`。验证并记录：

1. material 工具瞄准 confirmed 宏格时出现黄色透视面框；不可编辑候选为红色；
2. prefab 热栏出现与最终 placement 同位置的绿/红线框，R 旋转后立即同步；
3. replace 同时显示 removed 红、retained 黄、added 绿/无效红；
4. leaf 删除范围青色，parent/root 范围橙色；
5. crosshair/hotbar 位于线框之上，stream debug overlay 保持关闭；
6. `.demo/observe/` trace 中 frame plan 与提交 request 的 anchor/orientation/revision 一致。

若自动路线结束太快不便人工观察，则在相同 worktree 另启一次可见 `voxia_stdio_cli.js`，停在有效 prefab preview 状态交给用户查看；不要修改正式地图或增加 probe root。

- [ ] **Step 5: 回写当前真值并提交外层文档**

在设计稿把状态改为“已实现并验收”，加入实际 client commits、Automation/Node/Null/Real-RHI 数量和 observe 路径。`impl/README.md` 的 Voxia interaction/prefab 行补充 formal HUD feedback 与 `visual_feedback`；handoff 顶部记录当前完成点，仍明确 Online/Designer 后置。

```powershell
Set-Location 'C:\Users\DYZ\Documents\dev\hemifuture\ex_mmo_cluster'
git status --short
git add docs/00-current-truth/impl/README.md `
  docs/10-active/cross-cutting/2026-08-04-voxia-build-targeting-feedback-design.md `
  docs/10-active/cross-cutting/_session-handoff.md
git commit -m "docs(voxia): close build targeting feedback"
```

Expected: 外层提交只包含上述文档；客户端 worktree 仍 clean。若 Real-RHI 只完成自动 trace 而未完成用户肉眼确认，设计状态必须写“自动门禁通过，用户可见复核待确认”，不能冒充最终人工验收。

---

## 最终验收清单

- [ ] 正常启动且无 stream/debug 参数时，宏格命中面可见。
- [ ] prefab frame 与点击 request 的 prefab id、anchor、orientation、revision 完全一致。
- [ ] invalid placement 有几何时保留红色；无可靠几何时不残留旧线框。
- [ ] replace/selection 颜色角色完整。
- [ ] exact/macro/AABB 三档预算测试均通过，frame 永不超过 8192 条线。
- [ ] HUD 不 raycast、不 plan、不写 confirmed state；focus controller 不再调用 build renderer。
- [ ] 真实鼠标/热栏、Automation、stdio CLI/observe 三入口均有证据。
- [ ] Development build、全量 Automation、Node、Null-RHI、Real-RHI 全部使用本次新二进制。
- [ ] 唯一生产根、完整 XYZ、RuntimeMock/Online 边界保持不变。
