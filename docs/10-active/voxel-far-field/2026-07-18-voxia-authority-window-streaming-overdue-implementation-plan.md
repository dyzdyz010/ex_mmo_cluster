# Voxia Authority Window Streaming Overdue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Voxia 在玩家进入新 tile 时保持可玩并后台流送，只在玩家越出旧 committed 完整 XYZ 权威窗口达到 3 chunks 且 staging 尚未提交时显示全屏恢复。

**Architecture:** 新增纯数据 `FVoxiaAuthorityCoverageBounds` 作为 committed coverage 的唯一空间契约；presentation proof 提交时原子冻结 bounds。session readiness 首次成功后保持单调，root 另行维护 streaming/coverage 观察状态；safe-view 按 committed bounds 的 XYZ/L∞ 外部深度工作，不再用 exact-center equality 或固定 2 秒触发全屏恢复。

**Tech Stack:** Unreal Engine 5.8、C++20、UE Automation Framework、Slate、Voxia stdio CLI/JSON observe、PowerShell、Node.js。

## Global Constraints

- 唯一正式入口仍为 `production_all_features` / `AVoxiaUnifiedVoxelWorldActor`，不得新增第二 production root。
- 空间契约只认完整 XYZ：tile=`7×7×7 chunks`，near=`3×3×3 tiles=9261 chunks`，单轴换窗 entered/exited=`3087`、retained=`6174`。
- 外部深度使用旧 committed chunk bounds 的 XYZ/L∞；`Max+1/2/3` 对应 depth `1/2/3`，超期阈值固定为 `3`。
- confirmed truth、snapshot/revision、H gate、provider identity、ownership 和 render fence 失败必须显式硬失败；禁止本地 fallback、未知当空气或半成品发布。
- 首次 playable 后 session readiness 单调；正常 desired/live、near/far 暂时不一致只进入 streaming，不回退 initial loading。
- 代码注释统一使用中文；公共类型和方法同步中文文档；Gameplay README、阶段文档与 current-truth 在实现完成后更新。
- 默认不读取、不修改、不验证 `clients/web_client` 与 `clients/bevy_client`；服务端和 wire 不在本次范围。

---

### Task 1: 建立 committed authority coverage 纯空间契约

**Files:**
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaAuthorityCoverage.h`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaAuthorityCoverage.cpp`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaAuthorityCoverageAutomationTest.cpp`

**Interfaces:**
- Consumes: `Voxia::Voxel::VoxiaTileSizeInChunks`、`FIntVector`。
- Produces: `FVoxiaAuthorityCoverageBounds::FromCenterTile`、`ContainsChunk`、`OutsideDepthByAxis`、`OutsideDepthChunks`、`SnapshotJson`，供 presentation proof、root、safe-view 和 CLI 复用。

- [ ] **Step 1: 写 coverage bounds 失败测试**

```cpp
const FVoxiaAuthorityCoverageBounds Bounds =
	FVoxiaAuthorityCoverageBounds::FromCenterTile(FIntVector(11, 0, -51));
TestEqual(TEXT("最小 chunk 是完整 XYZ tile cube"), Bounds.MinChunk, FIntVector(70, -7, -364));
TestEqual(TEXT("最大 chunk inclusive"), Bounds.MaxChunk, FIntVector(90, 13, -344));
TestTrue(TEXT("cube 内属于 committed coverage"), Bounds.ContainsChunk(FIntVector(90, 13, -344)));
TestEqual(TEXT("正 X 外一格 depth=1"), Bounds.OutsideDepthChunks(FIntVector(91, 13, -344)), 1);
TestEqual(TEXT("正 X 外三格 depth=3"), Bounds.OutsideDepthChunks(FIntVector(93, 13, -344)), 3);
TestEqual(TEXT("负坐标角落使用 L∞"), Bounds.OutsideDepthByAxis(FIntVector(68, -10, -368)), FIntVector(2, 3, 4));
TestEqual(TEXT("角落 depth 取最大轴"), Bounds.OutsideDepthChunks(FIntVector(68, -10, -368)), 4);
```

- [ ] **Step 2: 运行测试并确认因类型不存在而失败**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Build\BatchFiles\Build.bat' VoxiaEditor Win64 Development -Project='C:\Users\DYZ\Documents\dev\hemifuture\ex_mmo_cluster\.worktrees\voxia-phase1-hardening-closeout\Voxia.uproject' -WaitMutex
```

Expected: compile FAIL，指出 `VoxiaAuthorityCoverage.h` 或 `FVoxiaAuthorityCoverageBounds` 不存在。

- [ ] **Step 3: 实现最小 coverage bounds 类型**

```cpp
namespace Voxia::Gameplay
{
struct FVoxiaAuthorityCoverageBounds
{
	static constexpr int32 RadiusTiles = 1;
	static constexpr int32 OverdueThresholdChunks = 3;

	bool bValid = false;
	FIntVector CenterTile = FIntVector::ZeroValue;
	FIntVector MinChunk = FIntVector::ZeroValue;
	FIntVector MaxChunk = FIntVector::ZeroValue;

	static FVoxiaAuthorityCoverageBounds FromCenterTile(const FIntVector& CenterTile);
	bool ContainsChunk(const FIntVector& Chunk) const;
	FIntVector OutsideDepthByAxis(const FIntVector& Chunk) const;
	int32 OutsideDepthChunks(const FIntVector& Chunk) const;
	FString SnapshotJson() const;
};
}
```

`FromCenterTile` 必须按每轴 `(Center-1)*7` 与 `(Center+2)*7-1` 计算 inclusive bounds；`OutsideDepthChunks` 只能返回 `max(X,Y,Z)`，不能使用二维距离或欧氏距离。

- [ ] **Step 4: 编译并运行 focused automation**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -NullRHI -ExecCmds='Automation RunTests Voxia.Gameplay.AuthorityCoverage;Quit' -TestExit='Automation Test Queue Empty' -log
```

Expected: `Voxia.Gameplay.AuthorityCoverage` 为 `Success`，进程 exit `0`。

- [ ] **Step 5: 提交 coverage 几何契约**

```powershell
git add Source/Voxia/Gameplay/VoxiaAuthorityCoverage.h Source/Voxia/Gameplay/VoxiaAuthorityCoverage.cpp Source/Voxia/Gameplay/VoxiaAuthorityCoverageAutomationTest.cpp
git commit -m "feat(streaming): define committed authority coverage bounds"
```

### Task 2: 让 presentation proof 原子拥有 committed bounds

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldPresentationProof.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldPresentationProof.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldPresentationProofAutomationTest.cpp`

**Interfaces:**
- Consumes: `FVoxiaAuthorityCoverageBounds::FromCenterTile`。
- Produces: `FVoxiaWorldPresentationProofSnapshot::Coverage`、`CoversChunk`、`OutsideDepthByAxis`、`OutsideDepthChunks`；后续 root 不再用 exact-center 判断相机安全。

- [ ] **Step 1: 扩展 proof 测试并先观察失败**

```cpp
TestTrue(TEXT("proof 覆盖整个 committed 3x3x3 cube"),
	Proof.CoversChunk(FIntVector(20, -14, 34)));
TestEqual(TEXT("proof cube 外两格仍未超期"),
	Proof.OutsideDepthChunks(FIntVector(29, -14, 34)), 2);
TestEqual(TEXT("proof cube 外三格达到超期阈值"),
	Proof.OutsideDepthChunks(FIntVector(30, -14, 34)), 3);
TestTrue(TEXT("快照暴露有效 committed bounds"), Proof.Snapshot().Coverage.bValid);
```

Run focused build; Expected: FAIL，因为 proof 尚无 coverage API。

- [ ] **Step 2: 在成功 commit 时生成并冻结 bounds**

在 `TryCommit` 全部门禁通过后执行：

```cpp
State.CenterTile = Candidate.CenterTile;
State.Coverage = FVoxiaAuthorityCoverageBounds::FromCenterTile(Candidate.CenterTile);
```

并新增：

```cpp
bool FVoxiaWorldPresentationProof::CoversChunk(const FIntVector& Chunk) const;
FIntVector FVoxiaWorldPresentationProof::OutsideDepthByAxis(const FIntVector& Chunk) const;
int32 FVoxiaWorldPresentationProof::OutsideDepthChunks(const FIntVector& Chunk) const;
```

未提交 proof 必须返回“不覆盖”和显式无效状态；stale/failed commit 不得改变旧 `Coverage`。

- [ ] **Step 3: 将 coverage 追加到 proof JSON**

`FVoxiaWorldPresentationProofSnapshot::SnapshotJson()` 保留现有字段字序和语义，并追加：

```json
"coverage":{"valid":true,"center_tile":[2,-3,4],"min_chunk":[7,-28,21],"max_chunk":[27,-8,41],"overdue_threshold_chunks":3}
```

- [ ] **Step 4: 运行 AuthorityCoverage 与 WorldPresentationProof 测试**

Expected: 两项均 `Success`，旧 stale/gap/overlap 断言继续通过。

- [ ] **Step 5: 提交 proof coverage**

```powershell
git add Source/Voxia/Gameplay/VoxiaWorldPresentationProof.* Source/Voxia/Gameplay/VoxiaWorldPresentationProofAutomationTest.cpp
git commit -m "feat(streaming): bind presentation proof to authority coverage"
```

### Task 3: 把 safe-view 硬恢复从固定时间改为 3-chunk 深度

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaSafeViewGuard.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaSafeViewGuard.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaSafeViewGuardAutomationTest.cpp`

**Interfaces:**
- Consumes: `OutsideDepthChunks` 与单调 `NowSeconds`。
- Produces: `FVoxiaSafeViewGuard::Evaluate(int32 OutsideDepthChunks, double NowSeconds)`；decision JSON 新增每轴/总 depth 由 root snapshot 补齐，guard 自身暴露总 depth 与 threshold。

- [ ] **Step 1: 将测试改成距离语义并确认旧实现失败**

```cpp
TestEqual(TEXT("coverage 内直接发布"), Guard.Evaluate(0, 0.0).Action, EVoxiaSafeViewAction::Safe);
TestEqual(TEXT("外一格保持 last-safe"), Guard.Evaluate(1, 1.0).Action, EVoxiaSafeViewAction::Hold);
TestEqual(TEXT("时间增长不能触发全屏"), Guard.Evaluate(1, 30.0).Action, EVoxiaSafeViewAction::SoftNotify);
TestNotEqual(TEXT("外两格仍不是硬恢复"), Guard.Evaluate(2, 60.0).Action, EVoxiaSafeViewAction::HardFail);
TestEqual(TEXT("外三格立即判定流送超期"), Guard.Evaluate(3, 60.1).Action, EVoxiaSafeViewAction::HardFail);
TestEqual(TEXT("coverage 恢复显式上报"), Guard.Evaluate(0, 60.2).Action, EVoxiaSafeViewAction::Recovered);
```

Expected: compile FAIL，因为旧签名是 `Evaluate(bool,double)`，且旧逻辑仍按 `2s` hard fail。

- [ ] **Step 2: 实现 depth 驱动 guard**

```cpp
FVoxiaSafeViewDecision FVoxiaSafeViewGuard::Evaluate(
	const int32 OutsideDepthChunks,
	const double NowSeconds)
{
	const int32 Depth = FMath::Max(0, OutsideDepthChunks);
	if (Depth == 0) { /* Safe / Recovered，清理 hold */ }
	else if (Depth >= FVoxiaAuthorityCoverageBounds::OverdueThresholdChunks)
	{
		LastDecision.Action = EVoxiaSafeViewAction::HardFail;
	}
	else if (NowSeconds - UnsafeStartedAtSeconds >= 0.250)
	{
		LastDecision.Action = EVoxiaSafeViewAction::SoftNotify;
	}
	else
	{
		LastDecision.Action = EVoxiaSafeViewAction::Hold;
	}
}
```

保留 `UnsafeDurationSeconds` 仅作观察量；它不得再决定 HardFail。decision snapshot 追加 `outside_depth_chunks` 与 `overdue_threshold_chunks=3`。

- [ ] **Step 3: 运行 SafeViewGuard focused test**

Expected: `Voxia.Gameplay.SafeViewGuard` 为 `Success`；测试明确证明 `30s` 的 depth 1 不 hard fail。

- [ ] **Step 4: 提交距离门禁**

```powershell
git add Source/Voxia/Gameplay/VoxiaSafeViewGuard.* Source/Voxia/Gameplay/VoxiaSafeViewGuardAutomationTest.cpp
git commit -m "fix(streaming): gate safe-view recovery by coverage depth"
```

### Task 4: 补齐正常 streaming / safe-view flow 与 UI 投影

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSession.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSession.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSessionAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/SVoxiaClientFlowOverlay.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientFlowViewModelAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientFlowSubsystem.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientFlowSubsystem.cpp`

**Interfaces:**
- Consumes: root 的 streaming、safe-view hold、ready、overdue 通知。
- Produces: `FVoxiaClientFlowMachine::BeginStreaming`、`BeginSafeViewHold`；subsystem 的 `NotifyRootStreaming`、`NotifyRootSafeViewHeld`；正常流送保持 GameOnly。

- [ ] **Step 1: 写 flow 失败测试**

```cpp
TestTrue(TEXT("进入新 tile 只进入正常 streaming"), Flow.BeginStreaming(0.60, Error));
TestEqual(TEXT("streaming 不回退 loading"), Flow.Snapshot().Phase, EVoxiaClientFlowPhase::Streaming);
TestTrue(TEXT("越出旧 coverage 进入非阻塞 hold"), Flow.BeginSafeViewHold(0.70, Error));
TestEqual(TEXT("hold 仍保留同一 root generation"), Flow.Snapshot().ActiveGeneration, uint64(1));
TestTrue(TEXT("staging commit 后恢复 playable"), Flow.MarkPlayable(1, 0.80, Error));
```

追加非法转换测试：无 active session、initial loading 未 ready、failed/leaving 状态均拒绝 normal streaming。

- [ ] **Step 2: 实现 flow 转换**

```cpp
bool BeginStreaming(double NowSeconds, FString& OutError);
bool BeginSafeViewHold(double NowSeconds, FString& OutError);
```

- `BeginStreaming` 允许 `Playable`、`Streaming`、`SafeViewHold`；重复调用幂等。
- `BeginSafeViewHold` 允许 `Playable`、`Streaming`、`SafeViewHold`；重复调用幂等。
- `MarkPlayable` 允许 `InitialLoading`、`Streaming`、`SafeViewHold`、`StreamingRecoveryLoading`。
- `BeginStreamingRecovery` 继续只接受 playable/streaming/hold，并要求非空 reason。

- [ ] **Step 3: 写 UI 失败测试并修改文案**

```cpp
State.Phase = EVoxiaClientFlowPhase::Streaming;
const FVoxiaClientFlowViewModel Streaming = FVoxiaClientFlowViewModel::Project(State);
TestFalse(TEXT("正常后台流送不显示全屏"), Streaming.bVisible);
TestEqual(TEXT("正常后台流送保留游戏输入"), Streaming.InputMode, EVoxiaClientInputMode::GameOnly);

State.Phase = EVoxiaClientFlowPhase::SafeViewHold;
const FVoxiaClientFlowViewModel Hold = FVoxiaClientFlowViewModel::Project(State);
TestTrue(TEXT("coverage 外宽限显示非阻塞提示"), Hold.bVisible && !Hold.bBlocking);

State.Phase = EVoxiaClientFlowPhase::StreamingRecoveryLoading;
const FVoxiaClientFlowViewModel Overdue = FVoxiaClientFlowViewModel::Project(State);
TestEqual(TEXT("超期文案不冒充重建世界"), Overdue.Status, FString(TEXT("权威覆盖流送超时，正在补齐…")));
```

`Retrying` 可继续显示“正在重新建立权威覆盖…”，但不得再出现“重新建立世界”。

- [ ] **Step 4: 接入 subsystem 通知方法**

```cpp
void NotifyRootStreaming(const AVoxiaUnifiedVoxelWorldActor* Root);
void NotifyRootSafeViewHeld(const AVoxiaUnifiedVoxelWorldActor* Root);
```

两者必须验证 `ActiveRoot` 身份；被拒绝的转换写 `LogVoxia` error，不得静默改状态。

- [ ] **Step 5: 运行 ClientWorldSession 与 ClientFlowViewModel tests**

Expected: 两项 `Success`；normal streaming overlay hidden，safe hold 非阻塞，overdue UI-only。

- [ ] **Step 6: 提交流程与 UI**

```powershell
git add Source/Voxia/Gameplay/VoxiaClientWorldSession.h Source/Voxia/Gameplay/VoxiaClientWorldSession.cpp Source/Voxia/Gameplay/VoxiaClientWorldSessionAutomationTest.cpp Source/Voxia/Gameplay/SVoxiaClientFlowOverlay.cpp Source/Voxia/Gameplay/VoxiaClientFlowViewModelAutomationTest.cpp Source/Voxia/Gameplay/VoxiaClientFlowSubsystem.h Source/Voxia/Gameplay/VoxiaClientFlowSubsystem.cpp
git commit -m "fix(streaming): separate playable flow from coverage recovery"
```

### Task 5: 在唯一 root 中接入单调 readiness、coverage depth 与结构化观察

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaAuthorityCoverage.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaAuthorityCoverage.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaAuthorityCoverageAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCameraManager.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientFlowSubsystemAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageSchedulerAutomationTest.cpp`

**Interfaces:**
- Consumes: committed proof bounds、distance guard、flow notifications、near/far readiness。
- Produces: root `session_ready`、`streaming_state`、committed/staging/player/depth JSON；`voxel_authority_stream_*` observe；camera 只按 coverage 决定 last-safe。

- [ ] **Step 1: 写 root 纯策略失败测试**

把无需 Actor 的判定放入 `VoxiaAuthorityCoverage`：

```cpp
const FVoxiaAuthorityStreamingDecision Inside = DecideAuthorityStreaming(Bounds, FIntVector(90, 13, -344), true);
TestEqual(TEXT("旧 committed cube 内保持正常相机"), Inside.Action, EVoxiaAuthorityStreamingAction::Playable);
const FVoxiaAuthorityStreamingDecision Grace = DecideAuthorityStreaming(Bounds, FIntVector(92, 13, -344), true);
TestEqual(TEXT("depth 2 只保持 safe view"), Grace.Action, EVoxiaAuthorityStreamingAction::SafeViewHold);
const FVoxiaAuthorityStreamingDecision Overdue = DecideAuthorityStreaming(Bounds, FIntVector(93, 13, -344), true);
TestEqual(TEXT("depth 3 且 staging pending 才超期"), Overdue.Action, EVoxiaAuthorityStreamingAction::RecoveryLoading);
const FVoxiaAuthorityCoverageBounds NewBounds =
	FVoxiaAuthorityCoverageBounds::FromCenterTile(FIntVector(12, 0, -51));
const FVoxiaAuthorityStreamingDecision Committed = DecideAuthorityStreaming(NewBounds, FIntVector(93, 13, -344), false);
TestEqual(TEXT("新窗口已提交时不恢复"), Committed.Action, EVoxiaAuthorityStreamingAction::Playable);
```

该纯策略避免将几何阈值藏在 Actor Tick 中。Task 5 在 `VoxiaAuthorityCoverage.h` 增加以下完整接口：

```cpp
enum class EVoxiaAuthorityStreamingAction : uint8
{
	Playable,
	SafeViewHold,
	RecoveryLoading,
	InvalidCoverage
};

struct FVoxiaAuthorityStreamingDecision
{
	EVoxiaAuthorityStreamingAction Action = EVoxiaAuthorityStreamingAction::InvalidCoverage;
	FIntVector OutsideDepthByAxis = FIntVector::ZeroValue;
	int32 OutsideDepthChunks = 0;
};

FVoxiaAuthorityStreamingDecision DecideAuthorityStreaming(
	const FVoxiaAuthorityCoverageBounds& Committed,
	const FIntVector& PlayerChunk,
	bool bStagingPending);
```

规则固定为：invalid bounds→`InvalidCoverage`；depth `0`→`Playable`；depth `1..2`→`SafeViewHold`；depth `>=3` 且 staging pending→`RecoveryLoading`；depth `>=3` 但没有 staging→`InvalidCoverage`，由 root 作为确定性错误显式失败。

- [ ] **Step 2: 改造 root readiness 为首次提交后单调**

`IsReady()` 只要求：root/source 授权、snapshot identity 仍匹配、没有 fatal error、presentation proof 已至少提交一次。normal staging 期间 near/far 当前 readiness 或 exact-center mismatch 不得令它返回 false。

新增私有辅助：

```cpp
bool IsStreamingPending(FIntVector& OutStagingCenter) const;
void NotifyStreamingState(const FIntVector& StagingCenter);
void EmitAuthorityStreamState(const TCHAR* EventName, const FString& Reason = FString()) const;
```

首次 proof commit 仍发 `voxel_world_root_ready`；后续 generation commit 发 `voxel_authority_stream_committed` 并通知 flow `MarkPlayable`。staging 首次出现或 center supersede 分别发 `voxel_authority_stream_started` / `voxel_authority_stream_superseded`。

- [ ] **Step 3: 改造 safe-view evaluation**

```cpp
const FIntVector CandidateChunk = Voxia::Voxel::ChunkForSim(Voxia::WorldToSim(CandidateWorldCm));
const int32 OutsideDepth = PresentationProof.OutsideDepthChunks(CandidateChunk);
const FVoxiaSafeViewDecision Decision = SafeViewGuard.Evaluate(OutsideDepth, NowSeconds);
```

- depth `0`：camera 正常；若从 hold 恢复且 staging 仍在，flow 回到 `Streaming`。
- depth `1..2`：通知 `NotifyRootSafeViewHeld`，保持 last-safe view，输入不中断。
- depth `>=3`：通知 `NotifyRootRecoveryRequired(..., "authority_coverage_stream_overdue")`。
- 未有首次 proof：继续 InitialLoading hold，不进入 3-chunk 恢复。

- [ ] **Step 4: 扩展 root/flow JSON，不新增第二 CLI**

在现有 `ProbeJson` / `SnapshotJson` 追加：

```json
"session_ready":true,
"streaming":{"state":"preparing","staging_present":true,"staging_center_tile":[10,0,-51]},
"authority_coverage":{"committed_generation":1,"committed_center_tile":[11,0,-51],"min_chunk":[70,-7,-364],"max_chunk":[90,13,-344],"player_chunk":[91,3,-354],"outside_depth_by_axis":[1,0,0],"outside_depth_chunks":1,"overdue_threshold_chunks":3}
```

保留原 `ready`、`centers`、`presentation_proof` 字段，避免 CLI 破坏；`ready` 改为 session 单调语义，`centers.aligned` 继续诚实表示当前 near/far 是否收敛。

- [ ] **Step 5: 发出结构化事件**

事件必须包含 `world_snapshot_id`、committed/staging generation 与 center、bounds、player chunk、每轴 depth、L∞ depth、threshold、near/far/proof ready、reason：

```text
voxel_authority_stream_started
voxel_authority_stream_superseded
voxel_authority_stream_committed
voxel_authority_safe_view_held
voxel_authority_stream_overdue
voxel_authority_stream_recovered
voxel_authority_stream_failed
```

高频 hold 事件按状态边沿发出，不能逐帧刷日志。

- [ ] **Step 6: 编译并运行 focused Gameplay tests**

Run tests:

```text
Voxia.Gameplay.AuthorityCoverage
Voxia.Gameplay.WorldPresentationProof
Voxia.Gameplay.SafeViewGuard
Voxia.Gameplay.ClientWorldSession
Voxia.Gameplay.ClientFlowViewModel
Voxia.Gameplay.ClientFlowSubsystem
Voxia.Gameplay.WorldCoverageScheduler
```

Expected: 全部 `Success`，无 `LogVoxia: Error`。

- [ ] **Step 7: 提交 root 集成**

```powershell
git add Source/Voxia/Gameplay/VoxiaAuthorityCoverage.h Source/Voxia/Gameplay/VoxiaAuthorityCoverage.cpp Source/Voxia/Gameplay/VoxiaAuthorityCoverageAutomationTest.cpp Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp Source/Voxia/Gameplay/VoxiaCameraManager.cpp Source/Voxia/Gameplay/VoxiaClientFlowSubsystemAutomationTest.cpp Source/Voxia/Gameplay/VoxiaWorldCoverageSchedulerAutomationTest.cpp
git commit -m "fix(streaming): keep root playable across authority handoff"
```

### Task 6: 增加 CLI/runner 回归与可控移动验收

**Files:**
- Modify: `clients/Voxia/scripts/voxia_stdio_cli.js`
- Modify: `clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.js`
- Test: existing `client_flow_state`、`client_flow_probe`、`safe_view_state`、`voxel_world_root_state`、`teleport`

**Interfaces:**
- Consumes: Task 5 的追加 JSON 字段与事件。
- Produces: normal tile handoff、depth 1/2/3、commit recovery 的自动化路线；不新增生产 CLI command。

- [ ] **Step 1: 给 runner 加 JSON 断言帮助函数**

```js
function assertAuthorityCoverage(root, expected) {
  const coverage = root && root.authority_coverage;
  if (!coverage) throw new Error("authority_coverage_missing");
  if (Number(coverage.overdue_threshold_chunks) !== 3) {
    throw new Error("authority_overdue_threshold_mismatch");
  }
  if (expected.sessionReady !== undefined && root.session_ready !== expected.sessionReady) {
    throw new Error("authority_session_ready_mismatch");
  }
}
```

- [ ] **Step 2: 增加 normal handoff route**

路线必须：

1. `until_voxel_world_root_ready 300000`；
2. 记录 committed center/bounds；
3. 用 `teleport` 移到相邻 tile 内、仍位于旧 committed bounds 的坐标；
4. 在 near/far 暂时不一致时轮询 `client_flow_probe`；
5. 断言 `session_ready=true`、phase=`streaming|playable`、view_model `visible=false`；
6. 等待新 generation commit，断言 center 对齐且从未观察到 `streaming_recovery_loading`。

- [ ] **Step 3: 增加纯逻辑 depth route**

使用 Automation Test 中的 coverage/flow 纯类型覆盖 depth `1/2/3`，runner 只负责验证真实 normal handoff。不要依赖硬编码 sleep 或让真实窗口故意卡住数分钟。

- [ ] **Step 4: 运行 Null-RHI focused route**

Run:

```powershell
node .\scripts\voxia_stdio_cli.js --nullrhi --cmd "until_voxel_world_root_ready 300000; client_flow_probe; teleport 123050 -567750 5110; client_flow_probe; voxel_world_root_state"
```

Expected: tile handoff 时 session 保持 ready，未出现 recovery phase；观察产物写入 `.demo/observe/`。

- [ ] **Step 5: 提交 runner 回归**

```powershell
git add scripts/voxia_stdio_cli.js scripts/run_phase1_world_lifecycle_smoke.js
git commit -m "test(streaming): cover nonblocking authority handoff"
```

### Task 7: 同步文档并完成分层验证

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/README.md`
- Modify: `clients/Voxia/README.md`
- Modify: `docs/00-current-truth/design/client/streaming-lod.md`
- Modify: `docs/00-current-truth/impl/known_gaps.md`
- Modify: `docs/10-active/cross-cutting/_session-handoff.md`
- Modify: `docs/10-active/voxel-far-field/2026-07-18-voxia-authority-window-streaming-overdue-design.md`
- Modify: this plan checkboxes

**Interfaces:**
- Consumes: 所有实现与验证产物。
- Produces: 当前事实、可复现命令、证据路径、剩余风险；不把未通过门禁写成完成。

- [ ] **Step 1: 更新 Gameplay README 与客户端 README**

明确：

- session readiness 首次提交后单调；
- committed coverage 与 staging coverage 分离；
- safe-view 按完整 XYZ/L∞ depth；
- depth `3` 是慢流送全屏阈值，不是 confirmed truth 宽松阈值；
- 确定性错误仍立即 hard fail；
- CLI 观察字段和 normal handoff 命令。

- [ ] **Step 2: 运行 fresh Development build**

Run Build.bat command from Task 1.

Expected: `BUILD SUCCESSFUL` / exit `0`。

- [ ] **Step 3: 运行全量 Voxia automation**

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -NullRHI -ExecCmds='Automation RunTests Voxia;Quit' -TestExit='Automation Test Queue Empty' -log
```

Expected: 全部发现的 `Voxia` 测试 success，0 failed / warning / not-run；记录准确测试数和日志路径。

- [ ] **Step 4: 运行 Null-RHI 全路线**

```powershell
node .\scripts\run_phase1_world_lifecycle_smoke.js --null-rhi --res 1280x720
```

Expected: 所有功能路线 pass、clean exit、无 release pending、无 recovery 误触发。

- [ ] **Step 5: 运行受影响 Real-RHI movement/return 路线**

```powershell
node .\scripts\run_phase1_world_lifecycle_smoke.js --real-rhi --res 1280x720 --performance-only
```

随后可见启动 `production_all_features`，从边界附近出生点连续移动跨 tile，验证进入新 tile 不出现全屏恢复。严格性能门禁仍按既有规则报告，不过滤 D3D12 外部尖峰。

- [ ] **Step 6: 更新 current-truth 与 handoff**

只写入实际验证结果；若 Real-RHI 性能门禁仍受已知 DXGI 尖峰影响，明确区分“功能行为通过”和“严格性能门禁未闭合”。设计稿状态改为 `implemented` 仅在功能/自动化/CLI/可见入口都完成后进行。

- [ ] **Step 7: 提交客户端文档与外层文档**

客户端仓库：

```powershell
git add Source/Voxia/Gameplay/README.md README.md
git commit -m "docs(streaming): document authority coverage handoff"
```

外层仓库：

```powershell
git add docs/00-current-truth docs/10-active
git commit -m "docs(voxia): record authority streaming handoff results"
```

- [ ] **Step 8: 完成前验证工作区与提交账本**

```powershell
git status --short --branch
git log --oneline -8
```

Expected: Voxia worktree 与外层仓库均无未跟踪实现文件或未提交相关改动；最终说明区分实现、验证证据、残余性能风险。
