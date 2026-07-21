# Voxia 阶段 2 普通宏格交互实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 在唯一 `production_all_features` Mock 根中完成普通宏格选择、挖除、放置、异步确认、会话 overlay、near/far 呈现和三入口闭环，同时建立阶段 3 可直接扩展的唯一 confirmed aggregate 与 authority adapter 骨架。

**Architecture:** 新增 profile-neutral `WorldModel` 与 `Authority` 子系统。`UVoxiaConfirmedWorldSubsystem` 是客户端 confirmed mirror 的唯一 owner，只有 `FVoxiaConfirmedWorldReducer` 可以写入；`UVoxiaWorldIntentSubsystem` 拥有 intent ledger 和 `IWorldAuthorityAdapter`，Mock adapter 私有持有 authority state 并只产生类型化事件。现有 root、renderer、Build controller 只消费 query/gateway/snapshot，不直接读取 Mock、Transport 或写 store。

**Tech Stack:** Unreal Engine 5.8、C++20/UE Core、GameInstanceSubsystem、UE Automation、DynamicMesh/Pure3D presentation、Node.js stdio CLI smoke。

**Status:** `implemented_and_reviewed`。最终实现固定 SHA 为
`15ab99476930f485460552914cb1744040dd2f72`；fresh Development build、`141/141` UE Automation、
`75/75` Node、Null-RHI 联合闭环与 1920×1080 D3D12 Real-RHI 30 分钟长稳已通过，
双代码专家复审 `Critical/Important/Minor=0/0/0`。

## Global Constraints

- 实施基线为 `clients/Voxia@origin/master d5a27f7`；执行时先用 `superpowers:using-git-worktrees` 创建独立 Voxia worktree，不在落后 28 个提交的当前 checkout 上修改。
- 本计划只修改 `clients/Voxia` 与对应主仓文档，不修改 `apps/*`、wire codec、opcode 或 DataService。
- 普通地形只支持完整宏格 place/break；阶段 2 的真实输入、CLI 和 Mock 必须硬拒绝任何 micro edit。
- Mock authority 是 session-local authority 替身；client confirmed mirror 仍只消费类型化 authority event，点击不得直接改变 confirmed truth。
- `accepted` 不更新 raycast、collision、mesh 或 confirmed store；只有 reducer 提交 transaction 后才是 confirmed，只有 presentation proof 后才是 presented。
- 所有空间身份使用完整 XYZ；world-micro/world-macro 算术使用 signed 64-bit 与 `VoxiaCoords.h` 的 floor-div/floor-mod。
- `AVoxiaUnifiedVoxelWorldActor` / `production_all_features` 仍是唯一生产根；旧 Online/Transport 与 legacy actor 只能作为 compatibility/probe。
- 新交互必须同时提供真实输入、Automation、stdio CLI/结构化日志入口，observe 写入 `.demo/observe/`。
- 代码中的新增或修改注释统一使用中文。
- 每个 task 都先 RED、再最小 GREEN、再 focused 验证和独立提交；不得沿用阶段 1 的旧通过证据。

---

## 文件结构

新增稳定目录：

```text
clients/Voxia/Source/Voxia/Voxel/WorldModel/
  README.md
  VoxiaWorldDomainTypes.h
  VoxiaWorldIntent.h
  VoxiaWorldConflictSet.h
  VoxiaWorldConflictSet.cpp
  VoxiaConfirmedWorldState.h
  VoxiaConfirmedWorldReducer.h
  VoxiaConfirmedWorldReducer.cpp
  VoxiaConfirmedWorldSubsystem.h
  VoxiaConfirmedWorldSubsystem.cpp
  VoxiaSessionSparseOverlay.h
  VoxiaSessionSparseOverlay.cpp

clients/Voxia/Source/Voxia/Authority/
  README.md
  VoxiaWorldAuthorityAdapter.h
  VoxiaIntentLedger.h
  VoxiaIntentLedger.cpp
  VoxiaMockWorldAuthorityAdapter.h
  VoxiaMockWorldAuthorityAdapter.cpp
  VoxiaWorldIntentSubsystem.h
  VoxiaWorldIntentSubsystem.cpp
```

新增测试：

```text
clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaWorldDomainAutomationTest.cpp
clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldReducerAutomationTest.cpp
clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaSessionSparseOverlayAutomationTest.cpp
clients/Voxia/Source/Voxia/Authority/VoxiaIntentLedgerAutomationTest.cpp
clients/Voxia/Source/Voxia/Authority/VoxiaMockWorldAuthorityAutomationTest.cpp
clients/Voxia/Source/Voxia/Gameplay/VoxiaPhase2InteractionAutomationTest.cpp
clients/Voxia/Source/Voxia/Gameplay/VoxiaPhase2PresentationAutomationTest.cpp
clients/Voxia/scripts/run_phase2_macro_interaction_smoke.js
clients/Voxia/scripts/run_phase2_macro_interaction_smoke.test.js
```

已有文件只做边界接线：

```text
Source/Voxia/Gameplay/VoxiaBuildInteractionController.h/.cpp
Source/Voxia/Gameplay/VoxiaPawn.h/.cpp
Source/Voxia/Gameplay/VoxiaClientWorldSession.h/.cpp
Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h/.cpp
Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeSnapshot.h
Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenter.h/.cpp
Source/Voxia/Gameplay/README.md
Source/Voxia/Net/VoxiaConfirmedWorldStores.h/.cpp
Source/Voxia/Net/VoxiaTransportSubsystem.h/.cpp
Source/Voxia/Voxel/VoxiaVoxelStore.h/.cpp
Source/Voxia/Debug/VoxiaDebugCommandCatalog.cpp
Source/Voxia/Debug/VoxiaDebugCommandHandlers.h/.cpp
README.md
```

## Task 1：冻结阶段 2 ownership 与禁止路径门禁

**Files:**
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/README.md`
- Create: `clients/Voxia/Source/Voxia/Authority/README.md`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPhase2InteractionAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeContract.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeContractAutomationTest.cpp`

**Interfaces:**
- Consumes: R0 的 `FVoxiaUnifiedWorldRuntimeContract` 与生产根反射门禁。
- Produces: `voxia_phase2_world_authority_v1` 合同 label、WorldModel/Authority 允许依赖与禁止依赖文档。

- [x] **Step 1: 写 ownership contract RED 测试**

在 `VoxiaPhase2InteractionAutomationTest.cpp` 要求 R0 contract 暴露阶段 2 authority label：

```cpp
IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FVoxiaPhase2ProductionBoundaryTest,
	"Voxia.Phase2.Contract.ProductionBoundary",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FVoxiaPhase2ProductionBoundaryTest::RunTest(const FString& Parameters)
{
	TestEqual(
		TEXT("阶段 2 authority 合同"),
		FVoxiaUnifiedWorldRuntimeContract::Phase2WorldAuthorityContract(),
		FString(TEXT("voxia_phase2_world_authority_v1")));
	return true;
}
```

- [x] **Step 2: 运行测试证明 RED**

Run:

```powershell
& "C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" `
  ".\clients\Voxia\Voxia.uproject" -unattended -nullrhi -nosound -nop4 -nosplash `
  '-ExecCmds=Automation RunTests Voxia.Phase2.Contract; Quit' `
  '-TestExit=Automation Test Queue Empty'
```

Expected: FAIL，`Phase2WorldAuthorityContract` 尚未定义。

- [x] **Step 3: 写目录职责与合同 label**

`WorldModel/README.md` 固定依赖方向：Authority event → reducer → snapshot → query/presentation；
`Authority/README.md` 固定 Input → ledger → adapter，adapter 不写 client store。合同增加：

```cpp
static constexpr const TCHAR* Phase2WorldAuthorityContract()
{
	return TEXT("voxia_phase2_world_authority_v1");
}
```

README 同时写明：production Gameplay 最终只能依赖 confirmed query 与 interaction gateway；禁止直接依赖 Mock、codec 或 confirmed mutator。旧直连路径由 Task 6 的 cutover 测试冻结并在同一 task 转绿。

- [x] **Step 4: 运行原 R0 ownership 测试**

Run: `Automation RunTests Voxia.Gameplay.UnifiedWorldRuntimeContract`

Expected: PASS；新 label 与既有 R0 合同同时通过。

- [x] **Step 5: 提交合同基线**

```powershell
git -C clients/Voxia add Source/Voxia/Voxel/WorldModel/README.md Source/Voxia/Authority/README.md Source/Voxia/Gameplay/VoxiaPhase2InteractionAutomationTest.cpp Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeContract.cpp Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeContractAutomationTest.cpp
git -C clients/Voxia commit -m "test(world): freeze phase2 authority boundaries"
```

## Task 2：WorldModel 类型、坐标与 conflict algebra

**Files:**
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaWorldDomainTypes.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaWorldIntent.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaWorldConflictSet.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaWorldConflictSet.cpp`
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaWorldDomainAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Voxia.Build.cs`

**Interfaces:**
- Consumes: `Voxia::FloorDiv`/`FloorMod` 与 `FInt64Vector` 坐标合同。
- Produces: `FVoxiaWorldMacroKey`、`FVoxiaMacroSpaceRecord`、`FVoxiaMacroIntent`、`FVoxiaWorldConflictSet::Overlaps`。

- [x] **Step 1: 写坐标、三态和冲突 RED 测试**

```cpp
TestEqual(TEXT("-1 macro"), FVoxiaWorldMacroKey::FromWorldMicro({-1, -1, -1}).X, -1LL);
TestEqual(TEXT("-1 slot"), FVoxiaMicroSlot::FromWorldMicro({-1, -1, -1}).X, 7);
TestEqual(TEXT("-8 slot"), FVoxiaMicroSlot::FromWorldMicro({-8, -8, -8}).X, 0);
TestEqual(TEXT("-9 macro"), FVoxiaWorldMacroKey::FromWorldMicro({-9, -9, -9}).X, -2LL);

FVoxiaWorldConflictSet MacroClaim = FVoxiaWorldConflictSet::ForMacro(MacroKey);
FVoxiaWorldConflictSet PrefabClaim = FVoxiaWorldConflictSet::ForMask(MacroKey, OneMicroMask);
TestTrue(TEXT("普通宏格与任意微格冲突"), MacroClaim.Overlaps(PrefabClaim));
TestFalse(TEXT("同宏格不重叠微格可并存"), PrefabClaim.Overlaps(OtherMicroMaskClaim));
```

- [x] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.WorldModel.Domain`

Expected: FAIL，类型和 `Overlaps` 尚不存在。

- [x] **Step 3: 实现最小纯类型**

```cpp
enum class EVoxiaResolvedMacroSpaceKind : uint8
{
	Empty,
	SolidMacro,
	RefinedProjection
};

enum class EVoxiaMacroLookupStatus : uint8
{
	SourceUnavailable,
	Missing,
	Resolved
};

struct FVoxiaMacroSpaceRecord
{
	EVoxiaResolvedMacroSpaceKind Kind = EVoxiaResolvedMacroSpaceKind::Empty;
	uint16 MaterialId = 0;
};

struct FVoxiaWorldSpaceClaim
{
	FVoxiaWorldMacroKey Macro;
	TVoxiaMicroMask512 Mask;
};

bool FVoxiaWorldConflictSet::Overlaps(const FVoxiaWorldConflictSet& Other) const
{
	for (const FVoxiaWorldSpaceClaim& A : SpaceClaims)
	{
		for (const FVoxiaWorldSpaceClaim& B : Other.SpaceClaims)
		{
			if (A.Macro == B.Macro && A.Mask.Intersects(B.Mask))
			{
				return true;
			}
		}
	}
	for (const FVoxiaWorldEntityClaim& Claim : EntityClaims)
	{
		if (Other.EntityClaims.Contains(Claim))
		{
			return true;
		}
	}
	return false;
}
```

`FVoxiaMacroIntent` 只允许 `Place`/`Break` 和 macro key；不定义 micro action。

- [x] **Step 4: 运行 focused test**

Run: `Automation RunTests Voxia.WorldModel.Domain`

Expected: PASS，覆盖 X/Y/Z 的 `-1/-8/-9`、All512、同宏格不相交与 entity claim。

- [x] **Step 5: 提交纯合同**

```powershell
git -C clients/Voxia add Source/Voxia/Voxel/WorldModel Source/Voxia/Voxia.Build.cs
git -C clients/Voxia commit -m "feat(world): add macro occupancy contracts"
```

## Task 3：唯一 confirmed state 与原子 reducer

**Files:**
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldState.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldReducer.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldReducer.cpp`
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldSubsystem.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldSubsystem.cpp`
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldReducerAutomationTest.cpp`

**Interfaces:**
- Consumes: Task 2 domain types。
- Produces: `FVoxiaConfirmedWorldTransaction`、`FVoxiaConfirmedWorldSnapshot`、`FVoxiaConfirmedWorldReducer::Apply`、`UVoxiaConfirmedWorldSubsystem::Snapshot/QueryMacro`。

- [x] **Step 1: 写 reducer RED 测试**

测试 Empty→Solid→Empty、revision、duplicate、out-of-order、invalid atomicity：

```cpp
FVoxiaConfirmedWorldSnapshot State = MakeEmptySnapshot(TEXT("session-a"));
const auto Place = MakeMacroTransaction(0, 1, Macro, EVoxiaMacroMutationKind::PutSolid, 7);
const FVoxiaApplyResult Applied = Reducer.Apply(State, Place);
TestEqual(TEXT("revision"), Applied.Snapshot.ConfirmedWorldRevision, 1ULL);
TestEqual(TEXT("material"), Applied.Snapshot.QueryResolved(Macro).MaterialId, 7);

const FVoxiaApplyResult Duplicate = Reducer.Apply(Applied.Snapshot, Place);
TestEqual(TEXT("duplicate"), Duplicate.Kind, EVoxiaApplyResultKind::Duplicate);

const auto Invalid = MakeInvalidMixedTransaction(1, 2, Macro);
const FVoxiaApplyResult Rejected = Reducer.Apply(Applied.Snapshot, Invalid);
TestEqual(TEXT("旧 revision 保持"), Rejected.Snapshot.ConfirmedWorldRevision, 1ULL);
```

- [x] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.WorldModel.Reducer`

Expected: FAIL，reducer/subsystem 未定义。

- [x] **Step 3: 实现 candidate-then-publish reducer**

```cpp
FVoxiaApplyResult FVoxiaConfirmedWorldReducer::Apply(
	const FVoxiaConfirmedWorldSnapshot& Current,
	const FVoxiaConfirmedWorldTransaction& Transaction) const
{
	if (!Transaction.MatchesNamespace(Current))
	{
		return FVoxiaApplyResult::Malformed(Current, TEXT("authority_namespace_mismatch"));
	}
	if (SeenEvents.ContainsExact(Transaction.EventId, Transaction.MutationHash))
	{
		return FVoxiaApplyResult::Duplicate(Current);
	}
	if (Transaction.BaseWorldRevision > Current.ConfirmedWorldRevision)
	{
		return FVoxiaApplyResult::Buffered(Current);
	}
	if (Transaction.BaseWorldRevision < Current.ConfirmedWorldRevision)
	{
		return FVoxiaApplyResult::Resync(Current, TEXT("stale_unknown_event"));
	}

	FVoxiaConfirmedWorldSnapshot Candidate = Current.CloneForMutation();
	if (!ApplyEntityMutations(Candidate, Transaction) ||
		!MaterializeMacroSpace(Candidate, Transaction) ||
		!ValidateParity(Candidate))
	{
		return FVoxiaApplyResult::Malformed(Current, TEXT("confirmed_transaction_invariant_failed"));
	}
	Candidate.PublishRevision(Transaction.NewWorldRevision);
	return FVoxiaApplyResult::Applied(MoveTemp(Candidate), BuildChangeSet(Transaction));
}
```

Subsystem 只公开 const snapshot/query 和 `ApplyAuthorityEvent`；不公开 macro mutator。

- [x] **Step 4: 运行 reducer 与 ownership test**

Run: `Automation RunTests Voxia.WorldModel.Reducer`

Expected: PASS；invalid transaction 不改变 state/revision/dirty set。

- [x] **Step 5: 提交 reducer**

```powershell
git -C clients/Voxia add Source/Voxia/Voxel/WorldModel
git -C clients/Voxia commit -m "feat(world): add atomic confirmed reducer"
```

## Task 4：Frozen base + SessionSparseOverlay

**Files:**
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaSessionSparseOverlay.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaSessionSparseOverlay.cpp`
- Create: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaSessionSparseOverlayAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Voxel/VoxiaWorldGenCanonicalPageMaterializer.h`
- Modify: `clients/Voxia/Source/Voxia/Voxel/VoxiaWorldGenCanonicalPageMaterializer.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSession.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSession.cpp`

**Interfaces:**
- Consumes: Stage 1 frozen world snapshot/source identity、Task 3 reducer。
- Produces: `IVoxiaFrozenWorldBaseQuery`、`FVoxiaSessionSparseOverlay::Resolve`、session start/end reset。

- [x] **Step 1: 写 overlay RED 测试**

覆盖 base solid→explicit empty、base empty→solid、unload/reload、retry/menu：

```cpp
FakeBase.SetSolid(Macro, 4);
Overlay.Apply(MakeBreakTransaction(Macro));
TestEqual(TEXT("tombstone 覆盖 base"), Overlay.Resolve(FakeBase, Macro).Kind, EVoxiaResolvedMacroSpaceKind::Empty);

Overlay.EvictResidentMaterialization(Macro);
TestEqual(TEXT("重载后仍为空"), Overlay.Resolve(FakeBase, Macro).Kind, EVoxiaResolvedMacroSpaceKind::Empty);

Overlay.ResetPresentationAttempt();
TestEqual(TEXT("presentation retry 保留 truth"), Overlay.Resolve(FakeBase, Macro).Kind, EVoxiaResolvedMacroSpaceKind::Empty);

Overlay.EndSession();
TestEqual(TEXT("结束会话清理"), Overlay.EntryCount(), 0);
```

- [x] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.WorldModel.SessionOverlay`

Expected: FAIL，overlay 与 base query 尚未定义。

- [x] **Step 3: 实现三种存储态**

```cpp
enum class EVoxiaMacroOverlayKind : uint8
{
	InheritBase,
	ExplicitEmptyTombstone,
	SolidMacroOverride
};

FVoxiaMacroSpaceLookup FVoxiaSessionSparseOverlay::Resolve(
	const IVoxiaFrozenWorldBaseQuery& Base,
	const FVoxiaWorldMacroKey& Macro) const
{
	if (const FVoxiaMacroOverlayEntry* Entry = Entries.Find(Macro))
	{
		return Entry->Resolve();
	}
	return Base.LookupMacro(Macro);
}
```

WorldGen materializer 只实现 immutable base query；不能回读 overlay。Session flow 的 retry 只新建 presentation generation，`ReturnToMainMenu/StartNewGame` 才销毁/新建 overlay。

- [x] **Step 4: 运行 overlay 与 session tests**

Run: `Automation RunTests Voxia.WorldModel.SessionOverlay; Automation RunTests Voxia.Gameplay.ClientWorldSession`

Expected: PASS；`FeatureGate("voxel_edit")` 尚保持旧拒绝，直到 Task 6。

- [x] **Step 5: 提交 overlay**

```powershell
git -C clients/Voxia add Source/Voxia/Voxel/WorldModel Source/Voxia/Voxel/VoxiaWorldGenCanonicalPageMaterializer.* Source/Voxia/Gameplay/VoxiaClientWorldSession.*
git -C clients/Voxia commit -m "feat(world): add session sparse overlay"
```

## Task 5：Intent ledger、adapter 端口与确定性 Mock authority

**Files:**
- Create: `clients/Voxia/Source/Voxia/Authority/VoxiaWorldAuthorityAdapter.h`
- Create: `clients/Voxia/Source/Voxia/Authority/VoxiaIntentLedger.h`
- Create: `clients/Voxia/Source/Voxia/Authority/VoxiaIntentLedger.cpp`
- Create: `clients/Voxia/Source/Voxia/Authority/VoxiaMockWorldAuthorityAdapter.h`
- Create: `clients/Voxia/Source/Voxia/Authority/VoxiaMockWorldAuthorityAdapter.cpp`
- Create: `clients/Voxia/Source/Voxia/Authority/VoxiaWorldIntentSubsystem.h`
- Create: `clients/Voxia/Source/Voxia/Authority/VoxiaWorldIntentSubsystem.cpp`
- Create: `clients/Voxia/Source/Voxia/Authority/VoxiaIntentLedgerAutomationTest.cpp`
- Create: `clients/Voxia/Source/Voxia/Authority/VoxiaMockWorldAuthorityAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientRuntimeConfig.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientRuntimeConfig.cpp`

**Interfaces:**
- Consumes: Task 2 intents/conflicts、Task 3 confirmed query、Task 4 base/overlay。
- Produces: `IVoxiaWorldAuthorityAdapter::Submit/Pump`、`IVoxiaWorldInteractionGateway`、`FVoxiaIntentLedger`、Mock scenarios。

- [x] **Step 1: 写 ledger/Mock RED 测试**

```cpp
const uint64 First = Ledger.Enqueue(MakePlace(MacroA, 5, 1));
const uint64 Second = Ledger.Enqueue(MakeBreak(MacroA, 2));
const uint64 Independent = Ledger.Enqueue(MakePlace(MacroB, 6, 3));
TestEqual(TEXT("同资源后续排队"), Ledger.State(Second), EVoxiaIntentState::Queued);
TestEqual(TEXT("不相交可提交"), Ledger.State(Independent), EVoxiaIntentState::Submitted);

Mock.AdvanceBy(0.005);
TestEqual(TEXT("非零延迟前未确认"), Confirmed.Snapshot().ConfirmedWorldRevision, 0ULL);
Mock.AdvanceBy(0.045);
TestEqual(TEXT("accepted 仍未写 mirror"), Ledger.State(First), EVoxiaIntentState::Accepted);
Mock.AdvanceBy(0.050);
TestEqual(TEXT("confirmed 后 revision 前进"), Confirmed.Snapshot().ConfirmedWorldRevision, 1ULL);
```

- [x] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.Authority.IntentLedger; Automation RunTests Voxia.Authority.Mock`

Expected: FAIL，端口与调度器尚不存在。

- [x] **Step 3: 实现稳定端口和固定延迟场景**

```cpp
class IVoxiaWorldAuthorityAdapter
{
public:
	virtual ~IVoxiaWorldAuthorityAdapter() = default;
	virtual EVoxiaSubmitResult Submit(const FVoxiaWorldIntent& Intent) = 0;
	virtual void Pump(double NowSeconds, TFunctionRef<void(FVoxiaAuthorityEvent&&)> Emit) = 0;
};

class IVoxiaWorldInteractionGateway
{
public:
	virtual ~IVoxiaWorldInteractionGateway() = default;
	virtual FVoxiaIntentHandle SubmitMacroPlace(const FVoxiaMacroPlaceRequest& Request) = 0;
	virtual FVoxiaIntentHandle SubmitMacroBreak(const FVoxiaMacroBreakRequest& Request) = 0;
};
```

默认 Mock 延迟固定为 accepted 50ms、confirmed 100ms；scenario/seed/bootstrap 一次冻结。实现 `accept`、`reject_occupied`、`duplicate_event`、`disjoint_reordered`、`stale_event`，禁止随机延迟。

- [x] **Step 4: 运行 ledger/Mock tests**

Run: `Automation RunTests Voxia.Authority`

Expected: PASS；accepted 不改 mirror，前序 rejected 取消重叠后续，不相交 intent 可乱序。

- [x] **Step 5: 提交 authority runtime**

```powershell
git -C clients/Voxia add Source/Voxia/Authority Source/Voxia/Gameplay/VoxiaClientRuntimeConfig.*
git -C clients/Voxia commit -m "feat(authority): add deterministic mock intent runtime"
```

## Task 6：Build controller 切换到 query/gateway 并启用阶段 2

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPawn.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPawn.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSession.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPhase2InteractionAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Voxel/VoxiaVoxelRaycast.h`
- Modify: `clients/Voxia/Source/Voxia/Voxel/VoxiaVoxelRaycast.cpp`

**Interfaces:**
- Consumes: `IVoxiaConfirmedWorldQuery` 与 `IVoxiaWorldInteractionGateway`。
- Produces: 真实鼠标/Automation/CLI 共用的 macro selection/place/break；阶段 2 热栏只启用 material。

- [x] **Step 1: 扩展真实交互 RED 测试**

```cpp
Controller.Initialize();
FakeQuery.SetPresentedSolid(Target, 4);
Controller.UpdateSelection(PawnHost, FakeQuery, CoverageQuery);
Controller.Break(PawnHost, FakeQuery, Gateway, FlowState);
TestEqual(TEXT("只提交一个 macro break"), Gateway.Submissions.Num(), 1);
TestEqual(TEXT("目标是完整宏格"), Gateway.Submissions[0].Macro, Target);
TestEqual(TEXT("点击后 truth 未变"), FakeQuery.Query(Target).MaterialId, 4);

TestEqual(
	TEXT("micro feature 明确拒绝"),
	FlowMachine.FeatureGate(TEXT("micro_edit")),
	FString(TEXT("micro_edit_not_supported")));

const FString ControllerPath = FPaths::ProjectDir() / TEXT("Source/Voxia/Gameplay/VoxiaBuildInteractionController.cpp");
FString ControllerSource;
if (!TestTrue(TEXT("读取 build controller 实现"), FFileHelper::LoadFileToString(ControllerSource, *ControllerPath)))
{
	return false;
}
TestFalse(TEXT("生产交互不得直接发送 block wire"), ControllerSource.Contains(TEXT("SendBlockEdit(")));
TestFalse(TEXT("阶段 2 不得发送 micro edit"), ControllerSource.Contains(TEXT("TargetGranularity = 1")));
TestTrue(TEXT("生产交互必须使用 gateway"), ControllerSource.Contains(TEXT("IVoxiaWorldInteractionGateway")));
```

- [x] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.Phase2.Contract; Automation RunTests Voxia.Phase2.Interaction`

Expected: FAIL，controller 仍直连 Transport，阶段 2 gate 仍拒绝。

- [x] **Step 3: 改为显式依赖并启用 macro feature**

将签名改为：

```cpp
bool UpdateSelection(
	AVoxiaPawn& Pawn,
	const IVoxiaConfirmedWorldQuery& World,
	const IVoxiaInteractiveCoverageQuery& Coverage);

void Break(
	AVoxiaPawn& Pawn,
	const IVoxiaConfirmedWorldQuery& World,
	IVoxiaWorldInteractionGateway& Gateway,
	const FVoxiaClientFlowState& Flow);
```

Pawn 在组合根初始化时显式解析两个 subsystem 并传入；controller 内不调用 `GetSubsystem`。阶段 2 material slots 解锁，prefab slots 保持 `feature_not_available_phase3`。`FeatureGate("voxel_edit")` 在 active Mock session 返回空，`FeatureGate("prefab")` 返回 phase3 拒绝。

- [x] **Step 4: 运行 contract/interaction tests**

Run: `Automation RunTests Voxia.Phase2`

Expected: PASS；Task 1 的 `SendBlockEdit` 禁止门禁转绿，真实点击只产生 intent。

- [x] **Step 5: 提交 controller cutover**

```powershell
git -C clients/Voxia add Source/Voxia/Gameplay Source/Voxia/Voxel/VoxiaVoxelRaycast.*
git -C clients/Voxia commit -m "feat(gameplay): route macro edits through authority gateway"
```

## Task 7：Near/Far change set 与 presentation receipt

**Files:**
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPhase2PresentationAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeSnapshot.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenter.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenter.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaNearActivePresentation.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaNearActivePresentation.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelSource.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelSource.cpp`
- Modify: `clients/Voxia/Source/Voxia/Authority/VoxiaIntentLedger.h`
- Modify: `clients/Voxia/Source/Voxia/Authority/VoxiaIntentLedger.cpp`

**Interfaces:**
- Consumes: reducer `FVoxiaWorldChangeSet` 与 confirmed snapshot。
- Produces: `FVoxiaWorldPresentationReceipt`、affected-set obligation、near/far consumed/presented revision。

- [x] **Step 1: 写 presentation RED 测试**

```cpp
const auto Confirmed = Harness.PlaceMacro(Macro, 8);
TestEqual(TEXT("确认后等待呈现"), Ledger.State(Confirmed.IntentId), EVoxiaIntentState::ConfirmedAwaitingPresentation);
TestTrue(TEXT("旧 live 在 fence 前保留"), Harness.IsOldOwnerLive(Macro));

Harness.CompleteNearFence(Confirmed.MutationGroupId);
TestEqual(TEXT("far 未完成仍等待"), Ledger.State(Confirmed.IntentId), EVoxiaIntentState::ConfirmedAwaitingPresentation);

Harness.CompleteFarFence(Confirmed.MutationGroupId);
TestEqual(TEXT("完整 obligation 后 presented"), Ledger.State(Confirmed.IntentId), EVoxiaIntentState::Presented);
```

另测 affected set 非驻留时 `deferred_nonresident_count` 不阻塞 presented，后续 reload 从最新 snapshot 构建。

- [x] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.Phase2.Presentation`

Expected: FAIL，root 尚未消费 change set/receipt。

- [x] **Step 3: 接入 revisioned snapshot 与 receipt**

```cpp
struct FVoxiaWorldPresentationReceipt
{
	uint64 IntentId = 0;
	uint64 ConfirmedWorldRevision = 0;
	FGuid MutationGroupId;
	int32 ObligatedRepresentationCount = 0;
	int32 PresentedRepresentationCount = 0;
	int32 DeferredNonResidentCount = 0;

	bool IsComplete() const
	{
		return PresentedRepresentationCount == ObligatedRepresentationCount;
	}
};
```

root 在一帧开头冻结 `FVoxiaConfirmedWorldSnapshot`，near/far 对 changed coverage hidden-stage；旧 owner 保留至对应 fence。只对当前 committed live ownership 计算 obligation。受影响范围在 presented 前 `InteractiveCoverageQuery` 返回 `presentation_pending`。

- [x] **Step 4: 运行 presentation/streaming tests**

Run: `Automation RunTests Voxia.Phase2.Presentation; Automation RunTests Voxia.Presentation`

Expected: PASS；无半更新、accepted 成功提示或 residency revision 冒充 world revision。

- [x] **Step 5: 提交 presentation 集成**

```powershell
git -C clients/Voxia add Source/Voxia/Gameplay Source/Voxia/Authority
git -C clients/Voxia commit -m "feat(presentation): present confirmed macro transactions"
```

## Task 8：CLI、HUD、observe 与 smoke runner

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCommandCatalog.cpp`
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCommandHandlers.h`
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCommandHandlers.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeSnapshot.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenter.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.cpp`
- Create: `clients/Voxia/scripts/run_phase2_macro_interaction_smoke.js`
- Create: `clients/Voxia/scripts/run_phase2_macro_interaction_smoke.test.js`

**Interfaces:**
- Consumes: confirmed/query、ledger、presentation snapshot。
- Produces: additive CLI handlers、JSONL observe 和 deterministic stage 2 smoke。

- [x] **Step 1: 写 Node RED 测试**

```javascript
test('phase2 smoke requires pending, confirmed, presented and reload proof', () => {
  const result = validatePhase2Trace(fixtureTrace);
  assert.equal(result.ok, true);
  assert.deepEqual(result.states, ['submitted', 'accepted', 'confirmed', 'presented']);
  assert.equal(result.reloaded_material_id, 8);
  assert.equal(result.micro_edit_reason, 'micro_edit_not_supported');
});
```

- [x] **Step 2: 运行测试证明 RED**

Run: `node --test clients/Voxia/scripts/run_phase2_macro_interaction_smoke.test.js`

Expected: FAIL，runner/validator 尚不存在。

- [x] **Step 3: 增加稳定命令和 snapshot 字段**

命令：

```text
world intent-status <intent-id>
world macro-inspect <x> <y> <z>
world transaction-inspect <revision>
world parity-check
```

runner 通过现有 `voxia_stdio_cli.js` 依次执行：等待 root ready、选中宏格、place、读取 pending、等待 confirmed、等待 presented、跨 X/Y/Z tile 卸载/返回、break、查询 `micro_edit` feature gate 得到明确拒绝、返回主菜单。JSON 必须断言 authority/session/intent/conflict/revision/overlay/near/far/fence/reason 字段。

- [x] **Step 4: 运行 Node 与 focused UE tests**

Run:

```powershell
node --test clients/Voxia/scripts/run_phase2_macro_interaction_smoke.test.js
node clients/Voxia/scripts/run_phase2_macro_interaction_smoke.js --nullrhi --resolution 1280x720
```

Expected: 单元 validator PASS；Null-RHI runner `passed=true`，产物写入 `.demo/observe/voxia_phase2_<run-id>/`。

- [x] **Step 5: 提交可观测面**

```powershell
git -C clients/Voxia add Source/Voxia/Debug Source/Voxia/Gameplay scripts/run_phase2_macro_interaction_smoke.js scripts/run_phase2_macro_interaction_smoke.test.js
git -C clients/Voxia commit -m "feat(debug): expose phase2 macro interaction evidence"
```

## Task 9：唯一根 closeout、全量验证与文档同步

**Files:**
- Modify: `clients/Voxia/README.md`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/README.md`
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/README.md`
- Modify: `clients/Voxia/Source/Voxia/Authority/README.md`
- Modify: `docs/00-current-truth/README.md`
- Modify: `docs/00-current-truth/design/client/streaming-lod.md`
- Modify: `docs/00-current-truth/impl/README.md`
- Modify: `docs/00-current-truth/impl/known_gaps.md`
- Modify: `docs/10-active/cross-cutting/_session-handoff.md`
- Modify: `docs/10-active/cross-cutting/2026-07-21-voxia-phase2-phase3-world-occupancy-and-prefab-runtime-design.md`

**Interfaces:**
- Consumes: Tasks 1–8 全部成果。
- Produces: 阶段 2 closeout 证据、current-truth、阶段 3 解锁门禁。

- [x] **Step 1: fresh Development build**

Run:

```powershell
& "C:\Program Files\Epic Games\UE_5.8\Engine\Build\BatchFiles\Build.bat" `
  VoxiaEditor Win64 Development `
  -Project="$PWD\clients\Voxia\Voxia.uproject" -WaitMutex
```

Expected: UnrealBuildTool exit 0，无新增 warning/error。

- [x] **Step 2: focused 与全量 Automation**

Run:

```powershell
& "C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" `
  ".\clients\Voxia\Voxia.uproject" -unattended -nullrhi -nosound -nop4 -nosplash `
  '-ExecCmds=Automation RunTests Voxia.Phase2; Automation RunTests Voxia.WorldModel; Automation RunTests Voxia.Authority; Quit' `
  '-TestExit=Automation Test Queue Empty'
```

Expected: focused 全 PASS。随后 fresh 运行 `Automation RunTests Voxia`，通过数不少于基线 92 且 0 failed/not-run。

- [x] **Step 3: 三入口与完整 XYZ smoke**

Run:

```powershell
node --test clients/Voxia/scripts/*.test.js
node clients/Voxia/scripts/run_phase2_macro_interaction_smoke.js --nullrhi --resolution 1280x720
node clients/Voxia/scripts/run_xyz_near_window_smoke.js
```

Expected: Node 不少于基线 37 tests 且新增测试全 PASS；阶段 2 runner 覆盖鼠标等价输入、CLI、Automation、X/Y/Z unload/reload，`passed=true`。

- [x] **Step 4: Real-RHI 与资源/呈现预算**

Run: 使用阶段 2 runner 的 `--visible-rhi --resolution 1920x1080 --soak-minutes 30`。

Expected: 唯一根 ready；宏格 place/break/pending/confirmed/presented 路线通过；无 gap/overlap、overlay 回退、资源单调增长或 `LogVoxia: Error`。性能与阶段 1 RG6 基线并列报告，不过滤 D3D12/DXGI raw stall。

- [x] **Step 5: 更新事实并分别提交两个仓库**

客户端提交：

```powershell
git -C clients/Voxia add README.md Source/Voxia
git -C clients/Voxia commit -m "docs(world): close phase2 macro interaction"
```

主仓文档提交：

```powershell
git add docs/00-current-truth docs/10-active/cross-cutting
git commit -m "docs(voxia): record phase2 macro interaction closeout"
```

文档只有在 fresh 证据全部完成后才能把阶段 2 写成 implemented；否则保留 `implementation_in_progress` 和精确未通过门禁。阶段 3 只在该 closeout 后进入执行。

## Self-Review

- [x] 逐节对照设计稿 §2、§4–§9、§11–§12、§15–§16，确认每个阶段 2 不变量至少有一个 task/test。
- [x] 扫描本计划和实现 diff，消除空白步骤、模糊错误处理、未定义类型和“参照前文”式省略。
- [x] 核对 `FVoxiaWorldMacroKey`、`FVoxiaConfirmedWorldTransaction`、`FVoxiaConfirmedWorldSnapshot`、`IVoxiaWorldAuthorityAdapter`、`IVoxiaWorldInteractionGateway`、`FVoxiaWorldPresentationReceipt` 在所有 task 中签名一致。
- [x] 静态确认 production controller/root 不含 `SendBlockEdit`、micro intent 或 Mock store direct mutation。
- [x] 确认 Stage 2 完成前 prefab 热栏仍锁定，Stage 3 没有被隐式实现。
