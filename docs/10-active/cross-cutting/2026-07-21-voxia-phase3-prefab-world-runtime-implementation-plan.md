# Voxia 阶段 3 Prefab 世界运行时实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在已验收的阶段 2 authority/reducer/presentation 骨架上，实现 immutable prefab catalog、24 向变换、跨宏格精确 footprint、instance directory、微格级命中/碰撞、层级选择、原子放置/移除/替换和 near/far 一致呈现。

**Architecture:** 阶段 3 只扩展 `WorldModel` 的 entity/transaction variants 和新增 `PrefabRuntime` 纯领域模块，不重建阶段 2 的 adapter、ledger、reducer 或 presentation 状态机。Prefab instance 是实体；每个 projected micro 只保存 material + leaf instance id；完整 ancestry 由 directory 恢复，inclusive coverage 由可重建索引维护。Mock authority 重新展开 definition、检查完整 conflict set 并一次确认；客户端 preview 永远不成为 truth。

**Tech Stack:** Unreal Engine 5.8、C++20/UE Core、UE Automation、DynamicMesh/Pure3D presentation、Node.js stdio CLI smoke。

> **当前执行门禁（2026-07-23）：** 阶段 1/A8-A10 的
> [`Far LOD 外露表面材质语义修复`](../voxel-far-field/2026-07-23-far-lod-surface-material-semantic-repair.md)
> 已通过完整自动化、Null-RHI 与 Real-RHI closeout，修复后的 VXP5 canonical material/surface
> contract 可作为阶段 3 基线。本计划设计不变，本轮没有开始阶段 3。

## Global Constraints

- 本计划只有在阶段 2 closeout 全部门禁通过后执行；基线必须包含阶段 2 的 `WorldModel`、`Authority`、single reducer、Mock adapter 和 presentation receipt。
- 当前仍是客户端 Mock 阶段；不修改 `apps/*`、wire、opcode、DataService 或 Online provider。
- 微格只用于 prefab footprint、材质、命中、碰撞和渲染；没有 micro place/break intent。
- 普通 SolidMacro 使用 `All512` 空间 claim，并与任何 prefab micro 互斥；同一宏格多个 prefab 只要 masks 不交即可共存。
- prefab place/remove/replace 是单个 authority transaction，不能按 macro/chunk 拆分或失败补偿。
- 每个 projected micro 只有一个 material 和一个 confirmed leaf instance id；完整 path 从 directory parent 链恢复。
- directory、MacroSpace projection 和 coverage/path indices 由阶段 2 同一 reducer 在同一 world revision 原子更新。
- 完整 XYZ、signed 64-bit、负坐标 floor-div/floor-mod 和 24 向整数变换是硬合同。
- near/far/collision/raycast 都消费同一 confirmed/presented snapshot；pending preview 不参与 hit-test 或碰撞。
- `AVoxiaUnifiedVoxelWorldActor` 仍是唯一生产根；旧 `AnyOwner`、resident scan 和逐宏格删除不能进入正式 readiness。
- 真实输入、Automation、stdio CLI/结构化日志三入口必须调用同一 controller/gateway。
- 新增/修改代码注释统一使用中文；Prefab Designer、draft/outbox 和 expression editor 留在阶段 4。

---

## 文件结构

新增：

```text
clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/
  README.md
  VoxiaPrefabDefinition.h
  VoxiaPrefabOrientation.h
  VoxiaPrefabOrientation.cpp
  VoxiaPrefabFootprint.h
  VoxiaPrefabFootprint.cpp
  VoxiaPrefabInstanceDirectory.h
  VoxiaPrefabInstanceDirectory.cpp
  VoxiaPrefabCoverageIndex.h
  VoxiaPrefabCoverageIndex.cpp
  VoxiaPrefabPlacementPlanner.h
  VoxiaPrefabPlacementPlanner.cpp
  VoxiaPrefabSelectionModel.h
  VoxiaPrefabSelectionModel.cpp
  VoxiaPrefabSurfaceQuery.h
  VoxiaPrefabSurfaceQuery.cpp
```

新增测试：

```text
Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabOrientationAutomationTest.cpp
Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabInstanceDirectoryAutomationTest.cpp
Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabPlacementPlannerAutomationTest.cpp
Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabSelectionAutomationTest.cpp
Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabSurfaceQueryAutomationTest.cpp
Source/Voxia/Authority/VoxiaMockPrefabAuthorityAutomationTest.cpp
Source/Voxia/Gameplay/VoxiaPhase3PrefabInteractionAutomationTest.cpp
Source/Voxia/Gameplay/VoxiaPhase3PrefabPresentationAutomationTest.cpp
scripts/run_phase3_prefab_runtime_smoke.js
scripts/run_phase3_prefab_runtime_smoke.test.js
```

主要修改：

```text
Source/Voxia/Voxel/WorldModel/VoxiaWorldDomainTypes.h
Source/Voxia/Voxel/WorldModel/VoxiaWorldIntent.h
Source/Voxia/Voxel/WorldModel/VoxiaWorldConflictSet.h/.cpp
Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldState.h
Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldReducer.h/.cpp
Source/Voxia/Authority/VoxiaWorldAuthorityAdapter.h
Source/Voxia/Authority/VoxiaMockWorldAuthorityAdapter.h/.cpp
Source/Voxia/Authority/VoxiaWorldIntentSubsystem.h/.cpp
Source/Voxia/Gameplay/VoxiaBuildInteractionController.h/.cpp
Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h/.cpp
Source/Voxia/Gameplay/VoxiaNearActivePresentation.h/.cpp
Source/Voxia/Gameplay/VoxiaCanonicalVoxelSource.h/.cpp
Source/Voxia/Gameplay/VoxiaWorldActor.h/.cpp
Source/Voxia/Voxel/VoxiaVoxelRaycast.h/.cpp
Source/Voxia/Voxel/VoxiaVoxelStore.h/.cpp
Source/Voxia/Net/VoxiaProtocol.h/.cpp
Source/Voxia/Debug/VoxiaDebugCommandCatalog.cpp
Source/Voxia/Debug/VoxiaDebugCommandHandlers.h/.cpp
```

## Task 1：PrefabDefinition 与 Orientation24

**Files:**
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/README.md`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabDefinition.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabOrientation.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabOrientation.cpp`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabOrientationAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Voxel/VoxiaPrefabCatalog.h`
- Modify: `clients/Voxia/Source/Voxia/Voxel/VoxiaPrefabCatalog.cpp`

**Interfaces:**
- Consumes: stage 2 world-micro/macro types、existing 7 builtin fixtures。
- Produces: `FVoxiaPrefabDefinition`、`FVoxiaPrefabDefinitionIdentity`、`FVoxiaPrefabOrientation24`、immutable fixture catalog。

- [ ] **Step 1: 写 Orientation/definition RED 测试**

```cpp
const TArray<FVoxiaPrefabOrientation24> All = FVoxiaPrefabOrientation24::All();
TestEqual(TEXT("恰好 24 个方向"), All.Num(), 24);

TSet<FString> Bases;
for (const auto& Orientation : All)
{
	TestEqual(TEXT("保持手性"), Orientation.Determinant(), 1);
	Bases.Add(Orientation.Fingerprint());
	const auto Identity = Orientation.Compose(Orientation.Inverse());
	TestTrue(TEXT("组合逆为单位方向"), Identity.IsIdentity());
}
TestEqual(TEXT("方向 basis 唯一"), Bases.Num(), 24);

const auto A = MakeFixtureDefinition(1, TEXT("hash-a"));
const auto B = MakeFixtureDefinition(1, TEXT("hash-b"));
TestFalse(TEXT("同 id 不同内容非法"), FVoxiaPrefabDefinition::CanCoexist(A, B));
```

- [ ] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.Prefab.Orientation`

Expected: FAIL，orientation/definition 类型尚不存在。

- [ ] **Step 3: 实现整数 basis 与 immutable fixture catalog**

```cpp
struct FVoxiaPrefabOrientation24
{
	uint8 Id = 0;
	FIntVector AxisX;
	FIntVector AxisY;
	FIntVector AxisZ;

	FInt64Vector Transform(const FInt64Vector& Local) const
	{
		return FInt64Vector(
			Local.X * AxisX.X + Local.Y * AxisY.X + Local.Z * AxisZ.X,
			Local.X * AxisX.Y + Local.Y * AxisY.Y + Local.Z * AxisZ.Y,
			Local.X * AxisX.Z + Local.Y * AxisY.Z + Local.Z * AxisZ.Z);
	}
};

struct FVoxiaPrefabDefinitionIdentity
{
	uint64 PrefabId = 0;
	uint32 DefinitionSchemaVersion = 1;
	FSHAHash ContentHash;
	uint32 CompilerAlgorithmVersion = 1;
};
```

将七个 builtin 转换为 immutable compiled fixtures；不再称作“与归档 Web 公式同步”。每个 fixture 明确 allowed orientation set 和 content hash。

- [ ] **Step 4: 运行 orientation/catalog tests**

Run: `Automation RunTests Voxia.Prefab.Orientation; Automation RunTests Voxia.Voxel.PrefabCatalog`

Expected: PASS；24 个方向唯一、组合/逆正确，旧 0..3 yaw fixture 映射保持显式 compatibility 测试但不成为新 runtime 限制。

- [ ] **Step 5: 提交 definition/orientation**

```powershell
git -C clients/Voxia add Source/Voxia/Voxel/PrefabRuntime Source/Voxia/Voxel/VoxiaPrefabCatalog.*
git -C clients/Voxia commit -m "feat(prefab): add immutable definitions and orientation24"
```

## Task 2：Instance directory、runtime tree 与 coverage index

**Files:**
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabInstanceDirectory.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabInstanceDirectory.cpp`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabCoverageIndex.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabCoverageIndex.cpp`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabInstanceDirectoryAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldState.h`

**Interfaces:**
- Consumes: immutable definitions、stage 2 snapshot/revision。
- Produces: `FVoxiaPrefabInstanceRecord`、`FVoxiaPrefabInstanceDirectory`、`FVoxiaPrefabCoverageIndex::Rebuild/QueryInclusive`。

- [ ] **Step 1: 写 directory/index RED 测试**

```cpp
Directory.Add(MakeRoot(100, PrefabHouse));
Directory.Add(MakeChild(101, 100, 100, SlotWall));
Directory.Add(MakeChild(102, 100, 100, SlotWindow));

TestEqual(TEXT("leaf path"), Directory.ResolvePath(102), TArray<uint64>({100, 102}));
TestFalse(TEXT("重复 slot child id"), Directory.Add(MakeChild(103, 100, 100, SlotWindow)).IsValid());
TestFalse(TEXT("循环 parent"), Directory.ReparentForTest(100, 102).IsValid());

Coverage.Rebuild(Directory);
TestEqual(TEXT("root inclusive mask"), Coverage.QueryInclusive(100), UnionMasks(100, 101, 102));
TestEqual(TEXT("leaf direct mask"), Coverage.QueryInclusive(102), DirectMask(102));
```

- [ ] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.Prefab.InstanceDirectory`

Expected: FAIL，directory/index 尚不存在。

- [ ] **Step 3: 实现 occurrence tree 和压缩 coverage**

```cpp
struct FVoxiaPrefabInstanceRecord
{
	FVoxiaPrefabInstanceKey InstanceKey;
	uint64 PrefabId = 0;
	uint64 RootInstanceId = 0;
	TOptional<uint64> ParentInstanceId;
	TOptional<uint32> ComponentSlotId;
	FInt64Vector AnchorWorldMicro;
	uint8 OrientationId = 0;
	uint64 InstanceVersion = 0;
	TMap<FVoxiaWorldMacroKey, FVoxiaDirectFootprintSlice> DirectFootprintByMacro;
};

using FVoxiaCoverageSlice = TPair<FVoxiaWorldMacroKey, TVoxiaMicroMask512>;
```

index 物理表示为 sorted `{macro, mask}`，不保存 512 个 world coordinate。directory/index 无 public mutator；只有 reducer candidate builder 可写。

- [ ] **Step 4: 运行 directory/index tests**

Run: `Automation RunTests Voxia.Prefab.InstanceDirectory`

Expected: PASS，覆盖重复 PrefabRef、空 direct parent、cycle、missing parent、不同 root、index rebuild parity。

- [ ] **Step 5: 提交 identity/index**

```powershell
git -C clients/Voxia add Source/Voxia/Voxel/PrefabRuntime Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldState.h
git -C clients/Voxia commit -m "feat(prefab): add instance directory and coverage index"
```

## Task 3：Footprint 展开、placement planner 与精确 conflict set

**Files:**
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabFootprint.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabFootprint.cpp`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabPlacementPlanner.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabPlacementPlanner.cpp`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabPlacementPlannerAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaWorldConflictSet.h`
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaWorldConflictSet.cpp`
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaWorldIntent.h`

**Interfaces:**
- Consumes: definition catalog、Orientation24、confirmed query。
- Produces: `FVoxiaCompiledPrefabFootprint`、`FVoxiaPrefabPlacementPlan`、place/remove/replace conflict claims。

- [ ] **Step 1: 写跨边界与冲突 RED 测试**

```cpp
const auto Plan = Planner.PlanPlace(Definition, {-1, -8, -9}, Orientation17, Snapshot);
TestTrue(TEXT("计划有效"), Plan.IsValid());
TestTrue(TEXT("跨多个宏格"), Plan.AffectedMacros.Num() > 1);
TestTrue(TEXT("负坐标 slot 正确"), Plan.ContainsWorldMicro({-1, -8, -9}));

Snapshot.PutPrefabMicro(Macro, Slot0, 200, 4);
TestTrue(TEXT("一个微格重叠整体拒绝"), Planner.PlanPlace(OverlapDefinition, Anchor, O0, Snapshot).IsRejected());
TestTrue(TEXT("同宏格不重叠接受"), Planner.PlanPlace(DisjointDefinition, Anchor, O0, Snapshot).IsValid());

Snapshot.PutSolidMacro(Macro, 7);
TestEqual(TEXT("Solid 拒绝 prefab"), Planner.PlanPlace(Definition, Anchor, O0, Snapshot).Reason, TEXT("occupied_by_solid_macro"));
```

- [ ] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.Prefab.PlacementPlanner`

Expected: FAIL，planner/footprint 尚不存在。

- [ ] **Step 3: 实现纯整数展开和 limits**

```cpp
FVoxiaPrefabPlacementPlan FVoxiaPrefabPlacementPlanner::PlanPlace(
	const FVoxiaPrefabDefinition& Definition,
	const FInt64Vector& Anchor,
	const FVoxiaPrefabOrientation24& Orientation,
	const IVoxiaConfirmedWorldQuery& World) const
{
	FVoxiaPrefabPlacementPlan Plan;
	ExpandRuntimeTree(Definition, Anchor, Orientation, Plan);
	if (!Plan.CheckLimits(16, 1024, 65536, 4096, 256))
	{
		return Plan.Reject(TEXT("prefab_runtime_limit_exceeded"));
	}
	Plan.ConflictSet = BuildExactClaims(Plan);
	return ValidateAgainstWorld(World, MoveTemp(Plan));
}
```

用 checked integer addition；overflow、cycle、invalid orientation、empty footprint、owner/material mismatch 全部显式拒绝。no-floating 邻域进入 validation-read claim，不建立持续支撑依赖。

- [ ] **Step 4: 运行 planner tests**

Run: `Automation RunTests Voxia.Prefab.PlacementPlanner`

Expected: PASS，覆盖 24 orientation、三轴负坐标、跨 macro/chunk、limit、Solid/prefab、prefab/prefab、validation read。

- [ ] **Step 5: 提交 footprint/planner**

```powershell
git -C clients/Voxia add Source/Voxia/Voxel/PrefabRuntime Source/Voxia/Voxel/WorldModel
git -C clients/Voxia commit -m "feat(prefab): plan exact cross-macro footprints"
```

## Task 4：Reducer 扩展与 Mock 原子 place

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaWorldDomainTypes.h`
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldState.h`
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldReducer.h`
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldReducer.cpp`
- Modify: `clients/Voxia/Source/Voxia/Authority/VoxiaWorldAuthorityAdapter.h`
- Modify: `clients/Voxia/Source/Voxia/Authority/VoxiaMockWorldAuthorityAdapter.h`
- Modify: `clients/Voxia/Source/Voxia/Authority/VoxiaMockWorldAuthorityAdapter.cpp`
- Create: `clients/Voxia/Source/Voxia/Authority/VoxiaMockPrefabAuthorityAutomationTest.cpp`

**Interfaces:**
- Consumes: placement plan、instance directory/index。
- Produces: `RefinedProjection` material+leaf slots、prefab instance mutations、provisional→confirmed mapping。

- [ ] **Step 1: 写原子 place RED 测试**

```cpp
const auto Handle = Gateway.SubmitPrefabPlace(MakePlaceRequest(PrefabId, Anchor, Orientation));
Mock.AdvanceToAccepted(Handle);
TestEqual(TEXT("accepted 不写 mirror"), Confirmed.Snapshot().PrefabDirectory.Num(), 0);

Mock.AdvanceToConfirmed(Handle);
const auto Snapshot = Confirmed.Snapshot();
TestEqual(TEXT("一次 revision"), Snapshot.ConfirmedWorldRevision, 1ULL);
TestTrue(TEXT("root 已存在"), Snapshot.PrefabDirectory.Contains(ConfirmedRootId));
TestTrue(TEXT("projection parity"), Snapshot.ValidateEntityProjectionIndexParity());

Mock.InjectCandidateFailureAfterMacro(1);
const auto Failed = Gateway.SubmitPrefabPlace(CrossChunkRequest);
Mock.Drain(Failed);
TestEqual(TEXT("故障不发布半个 prefab"), Confirmed.Snapshot().ConfirmedWorldRevision, 1ULL);
```

- [ ] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.Authority.MockPrefab`

Expected: FAIL，reducer 尚未支持 prefab mutations。

- [ ] **Step 3: 扩展 candidate builder**

```cpp
struct FVoxiaProjectedMicro
{
	uint16 MaterialId = 0;
	uint64 LeafInstanceId = 0;
};

bool FVoxiaConfirmedWorldReducer::ApplyPrefabAdds(
	FVoxiaConfirmedWorldCandidate& Candidate,
	const TArray<FVoxiaPrefabInstanceRecord>& Adds) const
{
	for (const FVoxiaPrefabInstanceRecord& Instance : Adds)
	{
		if (!Candidate.PrefabDirectory.Add(Instance))
		{
			return false;
		}
		if (!Candidate.ProjectDirectFootprint(Instance))
		{
			return false;
		}
	}
	return Candidate.RebuildAffectedCoverage() && Candidate.ValidateParity();
}
```

Mock authority 独立分配 confirmed ids，client provisional ids 只存在 ledger/preview。一次事件携带全部 instance adds、macro patches、mapping 和 exact affected set。

- [ ] **Step 4: 运行 Mock/reducer tests**

Run: `Automation RunTests Voxia.Authority.MockPrefab; Automation RunTests Voxia.WorldModel.Reducer`

Expected: PASS；同宏格两个不重叠 prefab 保留各自 material/leaf；fault injection 不发布 candidate。

- [ ] **Step 5: 提交原子 place**

```powershell
git -C clients/Voxia add Source/Voxia/Voxel/WorldModel Source/Voxia/Authority
git -C clients/Voxia commit -m "feat(prefab): confirm atomic prefab placement"
```

## Task 5：精确 micro raycast、collision 与 surface query

**Files:**
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabSurfaceQuery.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabSurfaceQuery.cpp`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabSurfaceQueryAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Voxel/VoxiaVoxelRaycast.h`
- Modify: `clients/Voxia/Source/Voxia/Voxel/VoxiaVoxelRaycast.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCharacterMovement.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldActor.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaNearActivePresentation.cpp`

**Interfaces:**
- Consumes: presented world query、MacroSpace tri-state。
- Produces: exact `FVoxiaWorldHit`、`FVoxiaPrefabSurfaceQuery::IsOccupied`、micro-accurate collision/surface。

- [ ] **Step 1: 写空隙/边界 RED 测试**

```cpp
World.PutPrefabMicro(Macro0, SlotFarCorner, 100, 4);
World.PutPrefabMicro(Macro1, SlotFront, 200, 5);
const FVoxiaWorldHit Hit = RaycastVoxels(World, RayThroughEmptyPartOfMacro0);
TestEqual(TEXT("穿过前一 refined 空隙"), Hit.LeafInstanceId, 200ULL);
TestEqual(TEXT("命中精确 world micro"), Hit.WorldMicro, ExpectedMicro);

TestFalse(TEXT("稀疏 prefab 空隙可通过"), Collision.Overlaps(PlayerBoxInEmptySlots));
TestTrue(TEXT("occupied micro 阻挡"), Collision.Overlaps(PlayerBoxAtOccupiedSlot));

TestFalse(TEXT("solid-refined 接缝无内面"), Surface.EmitsInteriorFace(SolidSide, RefinedFilledBoundary));
```

- [ ] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.Prefab.SurfaceQuery`

Expected: FAIL，旧 raycast/collision 仍把 refined macro 当整块。

- [ ] **Step 3: 实现统一三态 surface query**

```cpp
enum class EVoxiaOccupancyQueryResult : uint8
{
	Unavailable,
	Air,
	Occupied
};

FVoxiaWorldHit RaycastVoxels(
	const IVoxiaPresentedWorldQuery& World,
	const FVector& OriginCm,
	const FVector& DirectionCm,
	double MaxDistanceCm)
{
	return FVoxiaHierarchicalVoxelRaycaster(World).Trace(OriginCm, DirectionCm, MaxDistanceCm);
}
```

宏格 DDA 进入 Refined 后执行 12.5cm micro DDA；未命中继续外层 DDA。surface query 跨 macro/chunk 查询六邻；Solid 查询时等价全 512 occupied，不持久展开。Unavailable 返回不可编辑/等待依赖，禁止当 air。

- [ ] **Step 4: 运行 ray/collision/surface tests**

Run: `Automation RunTests Voxia.Prefab.SurfaceQuery; Automation RunTests Voxia.Gameplay.CharacterMovement`

Expected: PASS，覆盖 solid↔refined、refined↔refined、不同 prefab 同宏格、chunk seam、Unavailable。

- [ ] **Step 5: 提交精确空间查询**

```powershell
git -C clients/Voxia add Source/Voxia/Voxel/PrefabRuntime Source/Voxia/Voxel/VoxiaVoxelRaycast.* Source/Voxia/Gameplay/VoxiaCharacterMovement.cpp Source/Voxia/Gameplay/VoxiaWorldActor.* Source/Voxia/Gameplay/VoxiaNearActivePresentation.cpp
git -C clients/Voxia commit -m "feat(prefab): add exact micro spatial queries"
```

## Task 6：Prefab preview、输入上下文与 place 交互

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPawn.cpp`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPhase3PrefabInteractionAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSession.cpp`

**Interfaces:**
- Consumes: placement planner、exact hit、interaction gateway。
- Produces: face-aligned preview、contextual `R` orientation cycle、single prefab place intent。

- [ ] **Step 1: 写 preview/input RED 测试**

```cpp
Controller.SelectPrefab(PrefabId);
Controller.UpdateSelection(PawnHost, PresentedWorld, Coverage);
Controller.RotatePreview();
TestEqual(TEXT("预览方向循环"), Controller.Preview().OrientationId, ExpectedNextOrientation);
TestEqual(TEXT("remote action 未触发"), RemoteAction.Count, 0);

Controller.Place(PawnHost, PresentedWorld, Gateway, Flow);
TestEqual(TEXT("只提交一个 prefab intent"), Gateway.PrefabPlaces.Num(), 1);
TestEqual(TEXT("preview 不写 confirmed"), Confirmed.PrefabDirectory.Num(), 0);
```

- [ ] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.Phase3.PrefabInteraction`

Expected: FAIL，prefab feature 仍锁定且 controller 使用旧 preview。

- [ ] **Step 3: 接入 planner 与 context priority**

controller 保存：

```cpp
struct FVoxiaPrefabPreviewState
{
	uint64 PrefabId = 0;
	FInt64Vector AnchorWorldMicro;
	uint8 OrientationId = 0;
	FVoxiaPrefabPlacementPlan Plan;
	uint64 ObservedWorldRevision = 0;
	bool bValid = false;
	FString InvalidReason;
};
```

有效 preview context 中 `R` 旋转，其他上下文继续 remote action；Alt+滚轮由 Task 7 selection 消费，普通滚轮仍切热栏。`FeatureGate("prefab")` 在阶段 3 Mock session 解锁。

- [ ] **Step 4: 运行 interaction tests**

Run: `Automation RunTests Voxia.Phase3.PrefabInteraction; Automation RunTests Voxia.Gameplay.PawnControllerOwnership`

Expected: PASS；controller 只调用 planner/query/gateway，不读取 Mock/codec/Transport。

- [ ] **Step 5: 提交 place 交互**

```powershell
git -C clients/Voxia add Source/Voxia/Gameplay
git -C clients/Voxia commit -m "feat(gameplay): add prefab preview and placement input"
```

## Task 7：层级选择与原子 subtree remove

**Files:**
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabSelectionModel.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabSelectionModel.cpp`
- Create: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabSelectionAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaWorldIntent.h`
- Modify: `clients/Voxia/Source/Voxia/Authority/VoxiaMockWorldAuthorityAdapter.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.cpp`

**Interfaces:**
- Consumes: exact hit path、directory、coverage index。
- Produces: `FVoxiaPrefabSelectionModel`、Alt+wheel layer change、`PrefabRemoveIntent`、hold/feedback states。

- [ ] **Step 1: 写 selection/remove RED 测试**

```cpp
Selection.UpdateHit(Path100_104, Revision7);
TestEqual(TEXT("默认 leaf"), Selection.SelectedInstanceId(), 104ULL);
Selection.SelectParent();
TestEqual(TEXT("切到 parent"), Selection.SelectedInstanceId(), 100ULL);
Selection.UpdateHit(Path100_105, Revision7);
TestEqual(TEXT("同 subtree 保持 parent"), Selection.SelectedInstanceId(), 100ULL);
Selection.UpdateHit(Path200, Revision7);
TestEqual(TEXT("新 subtree 重置 leaf"), Selection.SelectedInstanceId(), 200ULL);

const auto Remove = Gateway.SubmitPrefabRemove(Selection.MakeRemoveRequest());
TestEqual(TEXT("一次 remove intent"), Gateway.RemoveCount(), 1);
Mock.Confirm(Remove);
TestFalse(TEXT("A subtree 已删除"), Confirmed.Directory.Contains(200));
TestTrue(TEXT("同宏格 B 保留"), Confirmed.Directory.Contains(300));
```

- [ ] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.Prefab.Selection`

Expected: FAIL，selection model/remove intent 尚不存在。

- [ ] **Step 3: 实现 path 选择、hold 与一次性 remove**

```cpp
struct FVoxiaPrefabRemoveRequest
{
	uint64 SelectedInstanceId = 0;
	uint64 ObservedWorldRevision = 0;
	uint64 InputSequence = 0;
	FGuid IdempotencyKey;
};
```

leaf 直接提交；non-leaf 使用设计稿冻结的 0.6s hold token，绑定 selected id、selection fingerprint 和 revision。authority 从 directory 重算 subtree/inclusive coverage；reducer 同 transaction 删除 records、projection、index。parent 在 child 删除后保留为部分 realization并递增 instance version。

- [ ] **Step 4: 运行 selection/remove tests**

Run: `Automation RunTests Voxia.Prefab.Selection; Automation RunTests Voxia.Authority.MockPrefab`

Expected: PASS，覆盖 leaf/parent/root、同宏格 B 保留、跨 chunk 非 resident coverage、hold cancel/reject/presented feedback。

- [ ] **Step 5: 提交 selection/remove**

```powershell
git -C clients/Voxia add Source/Voxia/Voxel/PrefabRuntime Source/Voxia/Voxel/WorldModel/VoxiaWorldIntent.h Source/Voxia/Authority/VoxiaMockWorldAuthorityAdapter.cpp Source/Voxia/Gameplay/VoxiaBuildInteractionController.*
git -C clients/Voxia commit -m "feat(prefab): select and remove prefab subtrees atomically"
```

## Task 8：原子 root/child replace

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabPlacementPlanner.h`
- Modify: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabPlacementPlanner.cpp`
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaWorldIntent.h`
- Modify: `clients/Voxia/Source/Voxia/Authority/VoxiaMockWorldAuthorityAdapter.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.cpp`
- Modify: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/VoxiaPrefabPlacementPlannerAutomationTest.cpp`

**Interfaces:**
- Consumes: selected subtree、target definition、old/new planner。
- Produces: retained/added/removed preview、`PrefabReplaceIntent`、old→new selection mapping。

- [ ] **Step 1: 写 replace RED 测试**

```cpp
const auto Preview = Planner.PlanReplace(SourceChildId, TargetPrefabId, Snapshot);
TestEqual(TEXT("保留 anchor"), Preview.Anchor, Snapshot.Directory.Get(SourceChildId).AnchorWorldMicro);
TestEqual(TEXT("保留 orientation"), Preview.OrientationId, Snapshot.Directory.Get(SourceChildId).OrientationId);
TestEqual(TEXT("冲突集是并集"), Preview.ConflictSet.SpaceClaims, Union(Preview.OldClaims, Preview.NewClaims));

const auto Handle = Gateway.SubmitPrefabReplace(Preview.MakeRequest());
Mock.Confirm(Handle);
TestFalse(TEXT("旧 subtree id tombstone"), Confirmed.Directory.Contains(SourceChildId));
TestTrue(TEXT("新 root 挂同 slot"), Confirmed.Directory.Get(NewChildId).ComponentSlotId == OldSlot);
TestTrue(TEXT("无半状态"), Confirmed.ValidateEntityProjectionIndexParity());
```

- [ ] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.Prefab.Replace`

Expected: FAIL，replace intent/plan 尚不存在。

- [ ] **Step 3: 实现 state-old+new candidate**

```cpp
FVoxiaPrefabReplacePlan FVoxiaPrefabPlacementPlanner::PlanReplace(
	uint64 SelectedInstanceId,
	uint64 TargetPrefabId,
	const FVoxiaConfirmedWorldSnapshot& State) const
{
	const FVoxiaCoverageSet Old = State.Coverage.QueryInclusive(SelectedInstanceId);
	FVoxiaPrefabReplacePlan Plan = BuildTargetAtExistingTransform(SelectedInstanceId, TargetPrefabId, State);
	Plan.ConflictSet = BuildUnionClaims(Old, Plan.NewCoverage);
	return ValidateAgainstStateMinusOld(State, Old, MoveTemp(Plan));
}
```

不自动平移/换向/缩放。old ids 永不复用；target root/new descendants 全部由 authority 分配。child replace 保留外层 parent 和 attachment slot；root replace 产生新 root id。reducer 一次 swap。

- [ ] **Step 4: 运行 replace/fault tests**

Run: `Automation RunTests Voxia.Prefab.Replace; Automation RunTests Voxia.WorldModel.Reducer`

Expected: PASS，覆盖 child/root、invalid orientation、target conflict、same-macro unrelated prefab、candidate 中点故障与 duplicate request。

- [ ] **Step 5: 提交 replace**

```powershell
git -C clients/Voxia add Source/Voxia/Voxel/PrefabRuntime Source/Voxia/Voxel/WorldModel/VoxiaWorldIntent.h Source/Voxia/Authority/VoxiaMockWorldAuthorityAdapter.cpp Source/Voxia/Gameplay/VoxiaBuildInteractionController.*
git -C clients/Voxia commit -m "feat(prefab): replace prefab subtrees atomically"
```

## Task 9：Near/Far refined presentation 与 group receipt

**Files:**
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPhase3PrefabPresentationAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaNearActivePresentation.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaNearActivePresentation.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelSource.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelSource.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarFieldRenderArtifact.h`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarFieldRenderArtifact.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.cpp`

**Interfaces:**
- Consumes: refined surface query、mutation group、confirmed snapshot。
- Produces: exact near micro surface、versioned far histogram/footprint identity、atomic group receipt。

- [ ] **Step 1: 写 near/far RED 测试**

```cpp
const auto Transaction = Harness.PlaceCrossChunkPrefab(PrefabId);
TestTrue(TEXT("fence 前旧 owner 保留"), Harness.AllOldOwnersVisible(Transaction.AffectedSet));
Harness.CompleteFirstChunkOnly();
TestFalse(TEXT("首 chunk 不得 presented"), Harness.IsPresented(Transaction.IntentId));
Harness.CompleteMutationGroup();
TestTrue(TEXT("整组 presented"), Harness.IsPresented(Transaction.IntentId));

const auto Far = BuildFarArtifact(MixedMaterialRefinedMacro);
TestTrue(TEXT("far 保留 mixed identity"), Far.MaterialHistogram.Num() > 1);
TestFalse(TEXT("不使用首材质实心退化"), Far.PolicyId == TEXT("first_non_zero_material"));
```

- [ ] **Step 2: 运行测试证明 RED**

Run: `Automation RunTests Voxia.Phase3.PrefabPresentation`

Expected: FAIL，far 仍可能把 refined 归约为首材质实心，group receipt 尚未覆盖 prefab。

- [ ] **Step 3: 实现版本化 refined LOD 与原子 group**

```cpp
struct FVoxiaRefinedFarIdentity
{
	uint32 ProjectionAlgorithmVersion = 1;
	FSHAHash FootprintHash;
	TMap<uint16, uint32> MaterialHistogram;
	uint32 OccupiedMicroCount = 0;
};
```

near 使用 Task 5 surface query；far 从同一 snapshot 构建 histogram/footprint hash，进入 artifact key。place/remove/replace 的当前 live affected representations 作为一个 mutation group hidden-stage/reveal；非 resident 计数延后加载但不阻塞当前 obligation。

- [ ] **Step 4: 运行 presentation tests**

Run: `Automation RunTests Voxia.Phase3.PrefabPresentation; Automation RunTests Voxia.Presentation; Automation RunTests Voxia.Rendering`

Expected: PASS，跨 chunk prefab 不半显、solid/refined seam 无裂缝、far 不膨胀为首材质宏格、旧 owner 在 fence 前保留。

- [ ] **Step 5: 提交 refined presentation**

```powershell
git -C clients/Voxia add Source/Voxia/Gameplay Source/Voxia/FarField
git -C clients/Voxia commit -m "feat(rendering): present refined prefab transactions"
```

## Task 10：CLI/observe、兼容退役、全量验收与文档

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCommandCatalog.cpp`
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCommandHandlers.h`
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCommandHandlers.cpp`
- Modify: `clients/Voxia/Source/Voxia/Voxel/VoxiaVoxelStore.h`
- Modify: `clients/Voxia/Source/Voxia/Voxel/VoxiaVoxelStore.cpp`
- Create: `clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.js`
- Create: `clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.test.js`
- Modify: `clients/Voxia/README.md`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/README.md`
- Modify: `clients/Voxia/Source/Voxia/Voxel/PrefabRuntime/README.md`
- Modify: `docs/00-current-truth/README.md`
- Modify: `docs/00-current-truth/design/client/streaming-lod.md`
- Modify: `docs/00-current-truth/impl/README.md`
- Modify: `docs/00-current-truth/impl/known_gaps.md`
- Modify: `docs/10-active/cross-cutting/_session-handoff.md`
- Modify: `docs/10-active/cross-cutting/2026-07-21-voxia-phase2-phase3-world-occupancy-and-prefab-runtime-design.md`

**Interfaces:**
- Consumes: Tasks 1–9。
- Produces: instance/micro/coverage CLI、parity observe、compatibility isolation、阶段 3 closeout。

- [ ] **Step 1: 写 CLI runner RED 测试**

```javascript
test('phase3 trace proves shared macro, ancestry, atomic remove and replace', () => {
  const result = validatePhase3Trace(fixtureTrace);
  assert.equal(result.same_macro_non_overlap, true);
  assert.deepEqual(result.hit_path, [100, 104]);
  assert.equal(result.unrelated_prefab_preserved_after_remove, true);
  assert.equal(result.replace_atomic, true);
  assert.equal(result.entity_projection_index_parity, true);
});
```

- [ ] **Step 2: 运行测试证明 RED**

Run: `node --test clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.test.js`

Expected: FAIL，runner/commands 尚不存在。

- [ ] **Step 3: 增加命令并隔离旧 compatibility**

命令：

```text
prefab instance-inspect <instance-id>
prefab micro-trace <x> <y> <z>
prefab coverage-inspect <instance-id>
prefab select-parent
prefab select-child
prefab remove-selected
prefab replace-selected <prefab-id>
world parity-check
```

`FVoxiaRefinedMicro` 及其 decoder 字节布局在本阶段保持原 compatibility 状态，不接入新 aggregate，也不借阶段 3 猜测未来 ancestry wire。删除 production 对 `AnyOwner()` 和 `GatherPrefabInstanceCells()` 的引用；若兼容测试仍需保留函数，命名空间/contract 明确为 probe，唯一根静态门禁禁止调用。未来 Online adapter 对 owner part、mask parity 和 instance closure 的处理必须另立 append-only 协议计划。

runner 覆盖：两个 prefab 同宏格不重叠、overlap rejection、Solid 双向冲突、24 orientation、负坐标跨 chunk、完整 path、parent selection、leaf/root remove、child/root replace、unload/reload、near/far group presented、parity check、micro edit rejection。

- [ ] **Step 4: fresh build 与全矩阵验证**

Run:

```powershell
& "C:\Program Files\Epic Games\UE_5.8\Engine\Build\BatchFiles\Build.bat" `
  VoxiaEditor Win64 Development `
  -Project="$PWD\clients\Voxia\Voxia.uproject" -WaitMutex

& "C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" `
  ".\clients\Voxia\Voxia.uproject" -unattended -nullrhi -nosound -nop4 -nosplash `
  '-ExecCmds=Automation RunTests Voxia.Prefab; Automation RunTests Voxia.Phase3; Quit' `
  '-TestExit=Automation Test Queue Empty'

node --test clients/Voxia/scripts/*.test.js
node clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.js --null-rhi
```

Expected: build exit 0；focused、全量 `Automation RunTests Voxia`、Node 与 Null-RHI runner 全 PASS；通过数不少于阶段 2 closeout 基线，0 failed/not-run。

随后运行 1920×1080 Real-RHI 短路线和 30 分钟 soak。必须报告 exact micro ray/collision CPU、directory/coverage/overlay high-water、near/far artifact/presentation、frame/GT/GPU 分位数；在完整 9,261 chunk XYZ 窗口下无资源单调增长、半 prefab、seam、旧 WorldGen 回退或 `LogVoxia: Error`。

- [ ] **Step 5: 更新事实并分别提交**

客户端：

```powershell
git -C clients/Voxia add README.md Source/Voxia scripts/run_phase3_prefab_runtime_smoke.js scripts/run_phase3_prefab_runtime_smoke.test.js
git -C clients/Voxia commit -m "docs(prefab): close phase3 world runtime"
```

主仓：

```powershell
git add docs/00-current-truth docs/10-active/cross-cutting
git commit -m "docs(voxia): record phase3 prefab runtime closeout"
```

只有 fresh 三入口、唯一根、Real-RHI 与资源门禁完成后才能把阶段 3 写成 implemented。该 closeout 不代表
Prefab Designer 或 Online authority 已开始。

## Self-Review

- [ ] 对照设计稿 §2、§4–§8、§10–§16，确认每个阶段 3 不变量都有具体 task/test。
- [ ] 清除所有占位式步骤，保证每个代码动作都有精确文件、签名、测试命令和 expected result。
- [ ] 核对 `FVoxiaPrefabDefinition`、`FVoxiaPrefabOrientation24`、`FVoxiaPrefabInstanceRecord`、`FVoxiaPrefabPlacementPlan`、`FVoxiaProjectedMicro`、remove/replace request 在各 task 中名称一致。
- [ ] 静态确认 production root/controller 不调用 `AnyOwner()`、`GatherPrefabInstanceCells()`、`SendPrefabPlace()` 或 N 次 block break。
- [ ] 确认 Online wire、服务端事务和 Designer 均未被隐式实现或宣称完成。
