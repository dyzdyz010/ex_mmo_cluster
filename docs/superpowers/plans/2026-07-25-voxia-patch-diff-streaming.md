# Voxia Near/Far Patch Diff 流送实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在唯一 `AVoxiaUnifiedVoxelWorldActor` 生产根中，以固定 Near/Far Patch
事务、canonical boundary slot 和 SceneHost 单一账本替换现有 Tile/整代 presentation 路径，
并删除动态扩容、full fallback、receipt 伪造、no-far adapter 和确定性自动重试。

**Architecture:** Root 只发布窗口 `TargetKey`；confirmed voxel store 通过独立
`FConfirmedEditKey` 驱动受固定 stencil 影响的 PatchVersion。Near/Far BuildIndex 只拥有
构建事实，`UVoxiaVoxelPresentationSceneHost` 的 `PresentationCommitLedger` 唯一拥有
live/ownership/boundary/fence；Far 每次只提交一个 Patch 及其 26 个 canonical boundary-slot
after-image，Near 移动提交一个 Patch，单 Chunk confirmed edit 固定提交 1–8 个 Patch。

**Tech Stack:** UE 5.8、C++20/Unreal Core containers、DynamicMesh、Unreal Automation Test、
Null-RHI、Real-RHI、Voxia stdio CLI、Node.js smoke tests。

## Global Constraints

- 本计划是当前唯一实施计划，完整取代
  `docs/superpowers/plans/2026-07-24-voxia-tile-streaming-governance.md`；旧计划不得继续执行，
  其中与本计划一致的需求已重新归入对应 Task。
- 实施 worktree：
  `C:\Users\DYZ\Documents\dev\hemifuture\ex_mmo_cluster\.worktrees\voxia-phase2-macro-interaction`，
  分支 `codex/voxia-phase2-macro-interaction`。
- 下文 `Source/`、`scripts/`、`README.md` 路径均相对该 Voxia worktree；`docs/` 路径相对
  外层 `ex_mmo_cluster`。
- 当前机器 UE 5.8 由 Launcher manifest 注册在
  `C:\Program Files\Epic Games\UE_5.8`；不得继续使用旧 `D:\UE\UE_5.8` 路径。
- production near radius 固定为 1；Near Patch=`4³ chunks`，Far Patch=`8³ tiles`。
- near window=`21³ chunks`；Near 稳定/单轴/双轴/三轴 Patch 上限=`216/288/336/368`。
- Far rings radius=`4/8/24/40/72 tiles`、span=`1/1/2/4/8 tiles`；
  target/三轴 transition Patch 上限=`6859/7886`。
- 不存在通用 `PatchCommitSet`、运行时 dependency closure、动态 atlas 扩容或 27 Patch cap。
- 不保留 Tile/whole-generation compatibility adapter；任一可运行提交只能有一个
  presentation owner。
- 所有新增代码注释用中文；所有新行为先写失败 Automation/Node test，再写生产代码。
- server-confirmed voxel truth 只来自 `ChunkSnapshot` / `ChunkDelta`；点击不做 confirmed
  乐观呈现。
- Required 可以使用全部物理容量；Speculative 不得占满任何 worker/ready/staging pool。
- 同一确定性输入不自动 retry；Busy 只由 slot/fence 事件重新唤醒，Fatal 停止动作并保留
  可诊断错误。
- 每项提交前运行最小 Automation；阶段切换前运行 Development build 与
  `Automation RunTests Voxia.Presentation`。

---

### Task 1: 固定空间、身份和结果合同

**Files:**

- Create:
  `Source/Voxia/Presentation/VoxiaPatchStreamingContract.h`
- Create:
  `Source/Voxia/Presentation/VoxiaPatchStreamingContract.cpp`
- Create:
  `Source/Voxia/Presentation/VoxiaPatchStreamingContractAutomationTest.cpp`
- Modify:
  `Source/Voxia/Presentation/README.md`

**Interfaces:**

- Produces:
  `FVoxiaPatchTargetKey`、`FVoxiaConfirmedEditKey`、`FVoxiaNearPatchId`、
  `FVoxiaFarPatchId`、`FVoxiaNearPatchVersion`、`FVoxiaFarPatchVersion`、
  `FVoxiaFarFaceSlotId`、`FVoxiaFarEdgeSlotId`、`FVoxiaFarCornerSlotId`、
  `EVoxiaPatchWorkState`、`FVoxiaPatchWorkResult`、
  `FVoxiaPatchStreamingSpatialContract`。
- `source_fingerprint` 只绑定不可变 baseline/schema/source contract，不含 rolling confirmed
  revision。

- [ ] **Step 1: 写身份和空间边界红测**

```cpp
IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FVoxiaPatchStreamingContractAutomationTest,
	"Voxia.Presentation.PatchStreamingContract",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FVoxiaPatchStreamingContractAutomationTest::RunTest(const FString&)
{
	using namespace Voxia::Presentation;

	TestEqual(TEXT("负 chunk 使用 floor division"),
		FVoxiaPatchStreamingSpatialContract::NearPatchForChunk(FIntVector(-1, -4, -5)).Coord,
		FIntVector(-1, -1, -2));
	TestEqual(TEXT("负 tile 使用 floor division"),
		FVoxiaPatchStreamingSpatialContract::FarPatchForTile(FIntVector(-1, -8, -9)).Coord,
		FIntVector(-1, -1, -2));

	TArray<FIntVector> Offsets;
	FVoxiaPatchStreamingSpatialContract::BuildNearMesherOffsets(Offsets);
	TestEqual(TEXT("mesher stencil 恰好 27 项"), Offsets.Num(), 27);

	TSet<FVoxiaNearPatchId> Affected;
	FVoxiaPatchStreamingSpatialContract::CollectAffectedNearPatches(
		FIntVector(3, 3, 3), Affected);
	TestEqual(TEXT("单 Chunk confirmed edit 最多命中 8 Patch"), Affected.Num(), 8);

	TestEqual(TEXT("stable near Patch 上限"),
		FVoxiaPatchStreamingSpatialContract::MaxNearTargetPatches, 216);
	TestEqual(TEXT("三轴 near transition 上限"),
		FVoxiaPatchStreamingSpatialContract::MaxNearTransitionPatches, 368);
	TestEqual(TEXT("Far target 上限"),
		FVoxiaPatchStreamingSpatialContract::MaxFarTargetPatches, 6859);
	TestEqual(TEXT("Far transition 上限"),
		FVoxiaPatchStreamingSpatialContract::MaxFarTransitionPatches, 7886);
	return true;
}
```

- [ ] **Step 2: 构建并运行红测**

Run:

```powershell
& "C:\Program Files\Epic Games\UE_5.8\Engine\Build\BatchFiles\Build.bat" VoxiaEditor Win64 Development -Project="$PWD\Voxia.uproject" -WaitMutex
```

Expected: compilation fails because `VoxiaPatchStreamingContract.h` and the named types do
not exist.

- [ ] **Step 3: 实现最小强类型合同**

```cpp
namespace Voxia::Presentation
{
enum class EVoxiaPatchWorkState : uint8
{
	Ready,
	Waiting,
	Busy,
	Cancelled,
	Fatal
};

struct VOXIA_API FVoxiaPatchTargetKey
{
	uint64 WorldSnapshotId = 0;
	uint64 SourceFingerprint = 0;
	uint64 DesiredWindowSerial = 0;
	FIntVector CenterTile = FIntVector::ZeroValue;
	int32 NearRadiusTiles = 1;

	bool IsValid() const;
	bool operator==(const FVoxiaPatchTargetKey& Other) const = default;
};

struct VOXIA_API FVoxiaConfirmedEditKey
{
	FIntVector Chunk = FIntVector::ZeroValue;
	uint64 ServerRevision = 0;
	uint64 DeltaFingerprint = 0;

	bool IsValid() const;
	bool operator==(const FVoxiaConfirmedEditKey& Other) const = default;
};

struct VOXIA_API FVoxiaNearPatchId
{
	FIntVector Coord = FIntVector::ZeroValue;
	bool operator==(const FVoxiaNearPatchId& Other) const = default;
};

struct VOXIA_API FVoxiaFarPatchId
{
	FIntVector Coord = FIntVector::ZeroValue;
	bool operator==(const FVoxiaFarPatchId& Other) const = default;
};

uint32 GetTypeHash(const FVoxiaNearPatchId& Id);
uint32 GetTypeHash(const FVoxiaFarPatchId& Id);

struct VOXIA_API FVoxiaPatchStreamingSpatialContract
{
	static constexpr int32 NearPatchChunks = 4;
	static constexpr int32 FarPatchTiles = 8;
	static constexpr int32 NearWindowChunks = 21;
	static constexpr int32 MaxNearTargetPatches = 216;
	static constexpr int32 MaxNearTransitionPatches = 368;
	static constexpr int32 MaxFarTargetPatches = 6859;
	static constexpr int32 MaxFarTransitionPatches = 7886;

	static int32 FloorDiv(int32 Value, int32 Divisor);
	static FVoxiaNearPatchId NearPatchForChunk(const FIntVector& Chunk);
	static FVoxiaFarPatchId FarPatchForTile(const FIntVector& Tile);
	static void BuildNearMesherOffsets(TArray<FIntVector>& OutOffsets);
	static void CollectAffectedNearPatches(
		const FIntVector& ChangedChunk,
		TSet<FVoxiaNearPatchId>& OutPatchIds);
};
}
```

`FVoxiaNearPatchVersion` 必须保存 exact owned mask fingerprint、source、
confirmed-input、content、dependency 五项身份；`FVoxiaFarPatchVersion` 必须保存 exact page
owner、source、content、dependency、boundary-profile 五项身份。完整相等才可 retained。

`FVoxiaPatchWorkResult` 只能表达五种互斥结果：`Ready` 表示结果已就绪，`Waiting`
表示仍缺合法输入，`Busy` 表示固定物理槽或 fence 尚未释放，`Cancelled` 表示输入快照已经
过期，`Fatal` 表示相同确定性输入不可重试的失败。`Fatal` 必须携带非空诊断信息；
`Waiting/Busy` 不得被转换成同输入定时重试。

- [ ] **Step 4: 构建并运行 GREEN**

Run Development build, then:

```powershell
& "C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" "$PWD\Voxia.uproject" -ExecCmds="Automation RunTests Voxia.Presentation.PatchStreamingContract; Quit" -unattended -nullrhi -nosound -ReportExportPath="$PWD\Saved\AutomationReport_patch_contract"
```

Expected: `index.json` reports `succeeded=1, failed=0`.

- [ ] **Step 5: Commit**

```powershell
git add Source/Voxia/Presentation/VoxiaPatchStreamingContract.* Source/Voxia/Presentation/README.md
git commit -m "feat(streaming): add fixed patch spatial contracts"
```

### Task 2: 统一 Near mesher stencil

**Files:**

- Modify:
  `Source/Voxia/Gameplay/VoxiaWorldActor.cpp`
- Modify:
  `Source/Voxia/Gameplay/VoxiaWorldActor.h`
- Modify:
  `Source/Voxia/Gameplay/VoxiaNearActivePresentation.h`
- Modify:
  `Source/Voxia/Gameplay/VoxiaNearActivePresentation.cpp`
- Modify:
  `Source/Voxia/Gameplay/VoxiaNearActivePresentationAutomationTest.cpp`
- Create:
  `Source/Voxia/Gameplay/VoxiaNearMesherStencilAutomationTest.cpp`

**Interfaces:**

- Consumes:
  `FVoxiaPatchStreamingSpatialContract::BuildNearMesherOffsets`。
- Produces:
  `CollectNearMeshTargetsForConfirmedChunk`、`CollectNearMeshSourceClosure`；
  freeze、fingerprint、invalidation 共用同一 27-offset 合同。

- [ ] **Step 1: 写 edge/corner 依赖红测**

测试冻结一个中心 Chunk 的 27 个输入，分别只改变 face、edge、corner Chunk，要求
`ComputeNearMeshPresentationFingerprint` 三次都改变；单 changed Chunk 的 mesh targets
必须为 27，source closure 必须为 125。

- [ ] **Step 2: 运行红测**

Expected: corner/edge 用例失败，因为当前 fingerprint/target path 只覆盖 self + 六面。

- [ ] **Step 3: 替换手写邻域**

- `FreezeNearActiveChunkMeshInput` 使用唯一 27 offsets 填充现有 `Neighborhood[3][3][3]`。
- `ComputeNearMeshPresentationFingerprintImpl` 对相同 27 offsets 混入 confirmed content 与
  field dependency。
- confirmed invalidation 由 changed Chunk + 27 reverse offsets直接得到 27 mesh targets；
  禁止搜索邻 Patch。
- 删除 `EVoxiaNearBoundaryCompletionAction::QueueRepair`；task 创建时缺依赖返回 Waiting，
  planner 已 complete 后缺依赖返回 Fatal。

- [ ] **Step 4: 运行 GREEN**

Run `Voxia.Gameplay.NearMesherStencil` 与 `Voxia.Gameplay.NearActivePresentation`。
Expected: both Success，旧 QueueRepair 测试已改为 Reject/Fatal。

- [ ] **Step 5: Commit**

```powershell
git add Source/Voxia/Gameplay/VoxiaWorldActor.* Source/Voxia/Gameplay/VoxiaNearActivePresentation.* Source/Voxia/Gameplay/VoxiaNearMesherStencilAutomationTest.cpp
git commit -m "fix(streaming): unify near mesher dependency stencil"
```

### Task 3: 纯 PresentationCommitLedger

**Files:**

- Create:
  `Source/Voxia/Presentation/VoxiaPresentationCommitLedger.h`
- Create:
  `Source/Voxia/Presentation/VoxiaPresentationCommitLedger.cpp`
- Create:
  `Source/Voxia/Presentation/VoxiaPresentationCommitLedgerAutomationTest.cpp`

**Interfaces:**

- Consumes: Task 1 的 typed IDs、PatchVersion、work result。
- Produces:
  `FVoxiaNearMoveCommit`、`FVoxiaNearEditCommit`、`FVoxiaFarPatchCommit`、
  `FVoxiaPresentationCommitLedgerSnapshot`、`FVoxiaPresentationCommitLedger`。

- [ ] **Step 1: 写固定事务形状红测**

覆盖：

- NearMove 只能含 1 个 Patch；
- NearEdit 只能含 1–8 个 Patch，且所有 PatchId 唯一；
- FarPatchCommit 只能含 1 个 Far Patch 和恰好
  `6 face + 12 edge + 8 corner` after-images；
- 相同 SlotId 只能有一份 live artifact；
- commit 成功时 geometry/version、exact ownership mask、boundary slots 和
  `commit_serial` 同时变化；
- validation 失败时 ledger 完全不变。

- [ ] **Step 2: 运行红测**

Expected: compile failure because ledger does not exist.

- [ ] **Step 3: 实现纯值账本**

```cpp
struct FVoxiaPresentationCommitLedgerSnapshot
{
	TMap<FVoxiaNearPatchId, FVoxiaNearPatchVersion> LiveNear;
	TMap<FVoxiaFarPatchId, FVoxiaFarPatchVersion> LiveFar;
	TSet<FIntVector> ExactNearOwnedChunks;
	TMap<FVoxiaFarFaceSlotId, uint64> LiveFaceArtifacts;
	TMap<FVoxiaFarEdgeSlotId, uint64> LiveEdgeArtifacts;
	TMap<FVoxiaFarCornerSlotId, uint64> LiveCornerArtifacts;
	uint64 CommitSerial = 0;
};

class VOXIA_API FVoxiaPresentationCommitLedger
{
public:
	FVoxiaPatchWorkResult Commit(const FVoxiaNearMoveCommit& Commit);
	FVoxiaPatchWorkResult Commit(const FVoxiaNearEditCommit& Commit);
	FVoxiaPatchWorkResult Commit(const FVoxiaFarPatchCommit& Commit);
	FVoxiaPresentationCommitLedgerSnapshot Snapshot() const;
	void Reset();
};
```

Commit 先在局部 after-image 上完成全部验证，最后一次 move 赋给 live maps；不得在验证途中
写入 live 状态。

- [ ] **Step 4: 运行 GREEN 并提交**

Run `Voxia.Presentation.PresentationCommitLedger`。

```powershell
git add Source/Voxia/Presentation/VoxiaPresentationCommitLedger.*
git commit -m "feat(streaming): add single presentation commit ledger"
```

### Task 4: Canonical Far boundary slot 与纯 shell builder

**Files:**

- Create:
  `Source/Voxia/FarField/VoxiaFarPatchBoundaryShell.h`
- Create:
  `Source/Voxia/FarField/VoxiaFarPatchBoundaryShell.cpp`
- Create:
  `Source/Voxia/FarField/VoxiaFarPatchBoundaryShellAutomationTest.cpp`
- Modify:
  `Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.h`
- Modify:
  `Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.cpp`
- Modify:
  `Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilderAutomationTest.cpp`

**Interfaces:**

- Produces:
  `FVoxiaFarPatchBoundaryProfile`、`FVoxiaFarBoundaryIncidentSnapshot`、
  `FVoxiaFarPatchBoundaryShell`、`FVoxiaFarPatchBoundaryShellBuilder::Build`。

- [ ] **Step 1: 写 canonical identity 红测**

相邻 Patch 从两侧解析共享 face 必须得到同一 `FVoxiaFarFaceSlotId`；四个 incident Patch
解析同一 edge、八个 incident Patch 解析同一 corner 也必须同 ID。每 Patch 的 incident set
必须恰好 26，负坐标与正坐标结果对称。

- [ ] **Step 2: 写 old/new 闭合红测**

覆盖 `A_new+B_old`：

- solid/solid→air/solid；
- solid/air→solid/solid；
- same LOD、fine/coarse、coarse/fine；
- target 外侧 permanent wall；
- target 内尚未 live provisional wall；
- candidate 提交后邻 Patch version 不变化。

- [ ] **Step 3: 实现纯 builder**

`Build` 输入 candidate profile、target membership fingerprint、26 个邻位 immutable profile；
输出 26 个 SlotId 的完整 after-image。无几何必须输出 remove，不得省略。输入缺失或 stitch
无法构造时返回 Fatal；snapshot fingerprint 变化由调用方返回 Cancelled。

- [ ] **Step 4: 让 scene builder 按 Far Patch 产出 profile**

`BuildFarPatchStages` 不再只给 `FarPatchFingerprints`；每个
`FVoxiaVoxelPresentationFarPatchStage` 同时携带 immutable boundary profile 与完整
dependency fingerprint。暂不改变 live publication。

- [ ] **Step 5: GREEN 与提交**

Run `Voxia.Voxel.FarPatchBoundaryShell` 和
`Voxia.Gameplay.CanonicalVoxelShellSceneBuilder`。

```powershell
git add Source/Voxia/FarField/VoxiaFarPatchBoundaryShell.* Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.*
git commit -m "feat(streaming): build canonical far boundary slots"
```

### Task 5: SceneHost 成为唯一 live presentation owner

**Files:**

- Modify:
  `Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.h`
- Modify:
  `Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.cpp`
- Modify:
  `Source/Voxia/Gameplay/VoxiaVoxelPresentationOwnership.h`
- Modify:
  `Source/Voxia/Gameplay/VoxiaVoxelPresentationOwnership.cpp`
- Modify:
  `Source/Voxia/Gameplay/VoxiaVoxelPresentationOwnershipAutomationTest.cpp`
- Modify:
  `Source/Voxia/Gameplay/VoxiaWorldPresentationProof.cpp`
- Modify:
  `Source/Voxia/Gameplay/VoxiaWorldPresentationProofAutomationTest.cpp`

**Interfaces:**

- SceneHost owns one `FVoxiaPresentationCommitLedger` plus UObject/fence handles keyed by typed
  PatchId/SlotId。
- `FreezeCommitLedger()` returns a single immutable snapshot containing Patch maps、exact mask、
  seam/boundary fingerprints、commit serial。

- [ ] **Step 1: 写单次快照与 exact receipt 红测**

要求 proof 只消费一次 ledger snapshot；依次读取 near registry、ownership state、root mirror
再取最大 epoch 的旧方式不能满足测试。旧 boundary face 只比较 source fingerprint、改写
generation 的用例必须失败。

- [ ] **Step 2: 集成 ledger**

- `FRuntimeResourceSet` 从整代 `FarPatchFingerprints/FarPatchComponents` 迁移为 typed
  Patch handle map。
- ownership live mask 只由 ledger exact owned chunks 生成。
- `GetLiveFarPatchFingerprints`、`IsRendererChunkNearOwned` 等查询改为只读 ledger snapshot。
- root/registry 不再可写 live 镜像。

- [ ] **Step 3: 删除 receipt 伪造**

删除 `TransitionFallbackTargetGeneration`、`TransitionFallbackSourceGeneration`、
`TransitionFallbackSourceFingerprint`、`ClearRendererTransitionBoundaryFallback` 及
`StageRendererTileOwnership` 中复用旧 face/重写 generation 的分支。retained 只接受完整
PatchVersion/BoundaryVersion exact match。

- [ ] **Step 4: GREEN 与提交**

Run ownership、world proof、presentation ledger 和 `Voxia.Presentation` 全组。

```powershell
git commit -am "refactor(streaming): make scene host the presentation truth"
```

### Task 6: FarBuildIndex、Patch cursor 与单 Patch publish

**Files:**

- Create:
  `Source/Voxia/FarField/VoxiaFarPatchBuildIndex.h`
- Create:
  `Source/Voxia/FarField/VoxiaFarPatchBuildIndex.cpp`
- Create:
  `Source/Voxia/FarField/VoxiaFarPatchBuildIndexAutomationTest.cpp`
- Modify:
  `Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.*`
- Modify:
  `Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.*`
- Modify:
  `Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.*`
- Modify:
  `Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.*`

**Interfaces:**

- `FVoxiaFarPatchBuildIndex::SetTarget(TargetKey, TargetPatchVersions)`。
- `ApplyDirtyPages` 只通过固定 reverse index 标记受影响 FarPatchId。
- `PopNextRequiredPatch` 在所有 speculative 之前返回 required。
- SceneHost `StageFarPatchCommit` / `CommitFarPatch` 一次只接受一个
  `FVoxiaFarPatchCommit`。

- [ ] **Step 1: 写 BuildIndex 红测**

覆盖 unchanged retained、单 page dirty 只命中 reverse-index Patch、Required 抢占、
Speculative 原地 promotion、stale result Cancelled、complete 后缺依赖 Fatal。

- [ ] **Step 2: 写逐 Patch可见红测**

第一个 Far Patch ready 后可独立 commit；邻 Patch ledger 不变；整 target 未完成时
SceneHost 已有新的 live Patch；incident slot snapshot 变化只取消 transaction 并从新快照计划。

- [ ] **Step 3: 实现 index 与 cursor**

复用 page residency、surface/material/lighting cache、cancellation work-unit 与 mesh shard；
删除“完整 `FVoxiaWorldGenVoxelShellBuildResult` 才能发布”的调用门槛。

- [ ] **Step 4: 接入唯一生产根**

Unified root 派发 TargetKey；Pure3D builder 退为 source-neutral build service，不拥有
production live state。SceneHost 每帧可以提交多个写集合互不冲突且 staging-ready 的固定
transaction；冲突只按 PatchId/SlotId/ownership subrect 判定。

- [ ] **Step 5: GREEN 与提交**

Run FarBuildIndex、shell builder、canonical scene builder、unified transaction tests。

```powershell
git add Source/Voxia/FarField/VoxiaFarPatchBuildIndex.* Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.* Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.* Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.* Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.*
git commit -m "feat(streaming): publish far patches independently"
```

### Task 7: 固定 Bootstrap/AdjacentStep/Relocate 与静态 atlas

**Files:**

- Replace:
  `Source/Voxia/Presentation/VoxiaNearFarTileHandoff.*`
- Replace:
  `Source/Voxia/Presentation/VoxiaNearFarHandoffCoordinator.*`
- Modify:
  corresponding Automation tests
- Modify:
  `Source/Voxia/Presentation/VoxiaNearOwnershipMask.*`
- Modify:
  `Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.*`

**Interfaces:**

- Produces:
  `EVoxiaPatchTargetKind { Bootstrap, AdjacentStep, Relocate }`、
  `FVoxiaPatchTransitionPlan`。
- AdjacentStep 只接受每轴 `-1/0/1` 且至少一轴非零；near radius 必须等于 1。

- [ ] **Step 1: 写固定模式红测**

覆盖 Bootstrap=`21³`、AdjacentStep 最大=`28³` atlas、Relocate 阻塞移动；radius change、
非相邻 AdjacentStep、live near 落入第三窗口全部 Fatal。

- [ ] **Step 2: 删除动态行为**

删除 `BuildExpandedCopyForChunks`、`BuildPaddedCopyForChunks`、
`RebaseExtendedOwnership`、capacity doubling、CoarseGate、从 actual live 猜 previous center、
`FullFallback` action/counter/reason 与一百万 Tile 上限。

- [ ] **Step 3: 原位替换 root latch**

删除 `FVoxiaNearFarHandoffTargetLatch` 的 CommittedToFinish/Settling/queued target；
Root 只保存最新 `FVoxiaPatchTargetKey`。Bootstrap/Relocate 是显式输入，不是错误恢复算法。

- [ ] **Step 4: GREEN 与提交**

Run handoff、ownership mask、unified transaction tests。

```powershell
git commit -am "refactor(streaming): enforce fixed patch transition modes"
```

### Task 8: NearBuildIndex 与 4³ Chunk Patch 提交

**Files:**

- Create:
  `Source/Voxia/Gameplay/VoxiaNearPatchBuildIndex.h`
- Create:
  `Source/Voxia/Gameplay/VoxiaNearPatchBuildIndex.cpp`
- Create:
  `Source/Voxia/Gameplay/VoxiaNearPatchBuildIndexAutomationTest.cpp`
- Modify:
  `Source/Voxia/Gameplay/VoxiaNearActivePresentation.*`
- Modify:
  `Source/Voxia/Gameplay/VoxiaWorldActor.*`
- Modify:
  `Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.*`
- Modify:
  `Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.*`

**Interfaces:**

- `SetWindowTarget(TargetKey)` 生成最多 216 个目标 Patch 及 partial owned mask。
- `ApplyConfirmedEdit(FConfirmedEditKey)` 生成 27 mesh targets、125 source closure、
  1–8 个 Patch transaction。
- movement `PopReadyMoveCommit` 每次 1 Patch；edit `PopReadyEditCommit` 原子 1–8 Patch。

- [ ] **Step 1: 写 NearBuildIndex 红测**

覆盖 sparse/air exact mask、负坐标、movement 首 Patch 不等整 Tile、single Chunk edit
1/2/4/8 Patch fanout、无关 PatchVersion 不变、未收到服务端 delta 不创建 edit candidate。

- [ ] **Step 2: 实现 BuildIndex 与 assembler**

Chunk CPU mesh store 保留 worker 粒度；Tile registry、whole-window barrier、
candidate/live/retiring batch 不再拥有可见 truth。PatchVersion ready 后交给纯 planner，
SceneHost 执行固定 transaction。

- [ ] **Step 3: 删除 deterministic retry**

删除 `PublishNearActiveChunkMeshResult` 的 `QueueRetry`、near prepare cooldown/restart budget、
Required retry budget、completion `QueueRepair`。Busy 等 fence/slot 事件；确定性 mesh/material/
publication 失败立即 Fatal。

- [ ] **Step 4: GREEN 与提交**

Run NearBuildIndex、NearMesherStencil、NearActivePresentation、confirmed presentation、
phase2 presentation tests。

```powershell
git add Source/Voxia/Gameplay/VoxiaNearPatchBuildIndex.* Source/Voxia/Gameplay/VoxiaNearActivePresentation.* Source/Voxia/Gameplay/VoxiaWorldActor.* Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.* Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.*
git commit -m "feat(streaming): commit near presentation by chunk patches"
```

### Task 9: 删除重复 owner、no-far 与 legacy far production path

**Files:**

- Delete:
  `Source/Voxia/Presentation/VoxiaNoFarCoverageOwnershipSink.*`
- Delete:
  `Source/Voxia/FarField/VoxiaNoFarRenderFenceOwnershipSink.*`
- Delete or move out of production module:
  `Source/Voxia/Net/VoxiaLegacyFarBuildRuntime.*`
- Modify:
  `Source/Voxia/Net/VoxiaTransportSubsystem.*`
- Modify:
  `Source/Voxia/Gameplay/VoxiaWorldActor.*`
- Modify:
  `Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.*`
- Modify:
  `Source/Voxia/Presentation/VoxiaFarOwnershipSink.h`
- Delete/update associated Automation tests。

**Interfaces:**

- production root 在任何 near commit 前构造唯一 SceneHost presentation service。
- probe fake 只能定义在 Automation test translation unit，不进入 production module。

- [ ] **Step 1: 写 source-ownership 红测**

`VoxiaTransportFacadeOwnershipAutomationTest` 要求 production Transport header 不再出现
`LegacyFarBuildRuntime`、VHI/SVO/heightmap build state；root contract 要求不存在
`ExplicitNoFar/Pure3DFarPending/PendingRendererOwnershipSink`。

- [ ] **Step 2: 删除 production adapter 和热换绑**

删除 no-far classes、single-chunk sink + optional Tile API、pending sink 安装/逐 Tick 重试、
`FMath::Max(1, HandoffGeneration/DesiredWindowSerial)` 零身份补值。

- [ ] **Step 3: 隔离 append-only wire history**

保留 wire decoder、golden fixture 与 archive tests；删除 production Transport 的 legacy
runtime state、build request、XZ-only patch identity/uploader/probe flag。

- [ ] **Step 4: 引用归零、GREEN 与提交**

Run:

```powershell
rg -n "ExplicitNoFar|Pure3DFarPending|PendingRendererOwnershipSink|TransitionFallback|LegacyFarBuildRuntime|QueueRepair|QueueRetry|FullFallback|RebaseExtendedOwnership" Source/Voxia
```

Expected: production files zero matches；若 archive/golden test 保留，必须位于明确 archive test
路径且不被 production owner include。

```powershell
git commit -am "refactor(streaming): remove duplicate presentation paths"
```

### Task 10: Actual coverage、派生 settled、容量和可观测面

**Files:**

- Modify:
  `Source/Voxia/Gameplay/VoxiaAuthorityCoverage.*`
- Modify:
  `Source/Voxia/Gameplay/VoxiaSafeViewGuard.*`
- Modify:
  `Source/Voxia/Gameplay/VoxiaWorldPresentationProof.*`
- Modify:
  corresponding Automation tests
- Modify:
  `Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.*`
- Modify:
  `Source/Voxia/Debug/VoxiaDebugCliSubsystem.*`
- Modify:
  `scripts/voxia_stdio_cli.js`
- Modify:
  corresponding Node tests

**Interfaces:**

- actual coverage=`SceneHost ledger exact near-owned Chunk mask`。
- `settled(TargetKey)` 是纯谓词，不保存 SettledEpoch。
- `resources_quiescent` 独立观察 post-fence/release queue。

- [ ] **Step 1: 写 coverage/settled 红测**

覆盖非规则 partial mask、outside depth 0/1/2/3、Required pending、Fatal；settled 要求
target/live maps exact、无 pending edit/Required/active transaction、gap/overlap/seam/orphan=0，
但不等待 post fence。

- [ ] **Step 2: 写容量红测**

验证 Near `216/288/336/368/2208`，Far `6859/7886/205036/410072`；live/staged/retiring/free/
release queue 全部计数。超过合同 Development check + structured Fatal；合法池占用返回 Busy。

- [ ] **Step 3: 实现单次 snapshot proof 和 CLI**

CLI 输出 `target_key`、target kind、pending edit、Required/Speculative、build index counts、
active transaction、Patch/Slot IDs、commit serial、actual owned count、outside depth、
failure、resources_quiescent。64 位身份全部十进制字符串。

- [ ] **Step 4: GREEN 与提交**

Run authority coverage、safe view guard、world proof、debug CLI、Node tests。

```powershell
git commit -am "feat(streaming): expose exact patch streaming truth"
```

### Task 11: 文档与完整验收

**Files:**

- Modify:
  `README.md`
- Modify:
  `Source/Voxia/Presentation/README.md`
- Modify:
  `Source/Voxia/FarField/README.md`
- Modify:
  `Source/Voxia/Gameplay/README.md`
- Modify:
  `Source/Voxia/Net/README.md`
- Modify:
  `docs/00-current-truth/design/client/streaming-lod.md`
- Modify:
  `docs/10-active/voxel-far-field/2026-07-12-pure-3d-voxel-shell-migration.md`
- Modify:
  `docs/10-active/voxel-far-field/2026-07-12-a10-cancellable-incremental-voxel-shell-streaming.md`
- Modify:
  `docs/10-active/voxel-far-field/2026-07-25-voxia-patch-diff-streaming-design.md`

**Interfaces:**

- 所有 README/current-truth 只描述一条现役 Patch 路径；旧 Tile/whole-generation/no-far/legacy
  仅可在 archive 历史中出现。

- [ ] **Step 1: 更新文档和实施日志**

记录每个删除路径、最终 owner、CLI 字段、测试命令与 observe 产物；设计稿状态改为已实施，
不得提前写完成。

- [ ] **Step 2: 全量静态检查**

Run `git diff --check`、中文注释扫描、旧符号引用归零、production module include 归零。

- [ ] **Step 3: 全量 Development/Automation/Node**

Run Development build、`Automation RunTests Voxia`、全部相关 Node tests。要求
0 failure、0 warning。

- [ ] **Step 4: Null-RHI 生命周期**

覆盖 Bootstrap、±XYZ、双轴、三轴、连续 10 Tile、快速折返、180°、Relocate、session retry、
新游戏、菜单、EndPlay；结构化结果要求 gap/overlap/seam/orphan/stale receipt=0。

- [ ] **Step 5: Real-RHI**

验证 first near/far Patch 不等完整 target、玩家走完 7 Chunk 前 Required 前向 coverage ready、
exited-near far replacement 在下一次 AdjacentStep 前完成、资源数达到固定平台。

- [ ] **Step 6: 最终提交与推送**

客户端提交推送 `codex/voxia-phase2-macro-interaction`；外层文档提交推送 `master`。只有在所有
门禁成功后把设计和 current-truth 写成完成。
