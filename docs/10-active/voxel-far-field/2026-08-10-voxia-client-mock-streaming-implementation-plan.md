# Voxia Client Mock Streaming Smoothness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Voxia 唯一生产组合根的 Mock 流程以玩家完整 XYZ 为锚点由近及远加载，只有完整 27-tile Near 与 Required Far 边界闭合后才允许操作，并通过连续 10 次 Real-RHI 冷启动 p95 `<=20s`、max `<=25s`、零失败门禁。

**Architecture:** 在现有 Patch-diff 架构上新增共享的纯值三维优先级和壳层 publication frontier；Near 独占关键提交预算，Far 仅在空闲容量预计算并在 Near fence 后发布。SceneHost 将 bootstrap expected gap 与结构损坏分离，Mock confirmed 链路改为 prepare/commit，Root 以统一 liveness registry 自维护所有等待。

**Tech Stack:** Unreal Engine 5.8、C++20/UE Automation、Node.js `node:test`、Voxia stdio CLI、JSONL observe、PowerShell。

## Global Constraints

- 只修改 `clients/Voxia` 客户端 Mock 生产流程与配套文档；不修改服务器、wire codec、Online provider、Web 或 Bevy。
- `Playable` 必须证明完整 `3×3×3 tiles = 27 tiles = 9261 chunks` Near、216 个 Near patch、post-visibility fence、Required Far 边界和最终 coverage audit。
- Near/Far 距离与 identity 一律使用完整 XYZ；禁止 XZ column、有限 Y 带或 Y=0 假设。
- confirmed truth 只从 Mock authority 的 confirmed transaction 进入；禁止客户端乐观体素编辑。
- 所有代码注释使用中文；公共类型/函数补 `///`，目录 README 与当前真相同步。
- 所有 Waiting/Busy/Deferred 必须有 waiter、wake key、owner、progress epoch 与期限。
- 现有工作区修改属于用户；禁止 reset、checkout 或覆盖无关修改。
- 每个任务遵循 RED → GREEN → REFACTOR；失败测试未出现前不写对应生产实现。
- 每次 commit 只 stage 当前任务列出的文件。

---

## File Structure

### 新文件

- `clients/Voxia/Source/Voxia/Presentation/VoxiaStreamingPriority.h`：共享的冻结玩家锚点、Near/Far patch AABB 距离与稳定 key。
- `clients/Voxia/Source/Voxia/Presentation/VoxiaStreamingPriority.cpp`：纯值距离、比较和壳层 frontier 实现。
- `clients/Voxia/Source/Voxia/Presentation/VoxiaStreamingPriorityAutomationTest.cpp`：正负 XYZ、边界、tie、壳层单调测试。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaStreamingLiveness.h`：waiter/wake key/owner/progress/deadline 纯值注册表。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaStreamingLiveness.cpp`：注册、推进、清理、stall/fatal 判定和 JSON 快照。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaStreamingLivenessAutomationTest.cpp`：活性注册表状态机测试。
- `clients/Voxia/scripts/run_mock_streaming_cold_start_gate.js`：顺序执行 10 次真实 RHI 冷启动并汇总 p95/max。
- `clients/Voxia/scripts/run_mock_streaming_cold_start_gate.test.js`：聚合器、失败归因和 uint64 安全测试。

### 主要修改文件

- `clients/Voxia/Source/Voxia/Gameplay/VoxiaNearPatchBuildIndex.{h,cpp}`：冻结 priority anchor、ready move 排序、publication shell frontier。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaNearPatchBuildIndexAutomationTest.cpp`：Near 壳层与完整窗口测试。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldActor.{h,cpp}`：Near assembly/mesh/publish 使用同一 key，并输出 shell 进度。
- `clients/Voxia/Source/Voxia/FarField/VoxiaFarPatchBuildIndex.{h,cpp}`：Far 使用玩家锚点而非 target center，并持有 precomputed/held 状态。
- `clients/Voxia/Source/Voxia/FarField/VoxiaFarPatchBuildIndexAutomationTest.cpp`：Far 距离、hold 与 stale generation 测试。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler.{h,cpp}`：Near critical/Far spare/publish gate 纯策略。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageSchedulerAutomationTest.cpp`：预算隔离测试。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.{h,cpp}`：Far precompute 与 visible publication 分离。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.{h,cpp}`：冻结锚点、完整 Near fence、Required Far gate、liveness owner。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.{h,cpp}`：coverage structural state、delta eligibility、一次性 rebase 和统计。
- `clients/Voxia/Source/Voxia/Presentation/VoxiaRendererCoverage.{h,cpp}`：结构错误与 expected incompleteness 的纯值判定。
- `clients/Voxia/Source/Voxia/Presentation/VoxiaRendererCoverageAutomationTest.cpp`：bootstrap delta parity 测试。
- `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldSubsystem.{h,cpp}`：prepared authority batch 与一次性 commit token。
- `clients/Voxia/Source/Voxia/Authority/VoxiaWorldIntentSubsystem.{h,cpp}`：confirmed/journal/ledger 协调提交。
- `clients/Voxia/Source/Voxia/Authority/VoxiaWorldIntentSubsystemAutomationTest.cpp`：部分提交、密闭坑位和重排测试。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedTransactionPresentationDriver.{h,cpp}`：resident obligation totality 与 non-resident wake key。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldTransactionPresentationAutomationTest.cpp`：零 obligation 和多 chunk 原子 receipt 测试。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeSnapshot.h`、`VoxiaUnifiedWorldRuntimePresenter.cpp`：priority/coverage/liveness/timing 字段。
- `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp`：`voxel_liveness_state` 命令。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSession.{h,cpp}`：60 秒 initial/recovery 正确性 deadline 与分层 stall。
- `clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.{js,test.js}`：startup-only 与 Near/Far/ratio/time gates。
- `clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.{js,test.js}`：真实跨 chunk 与密闭坑位 place。
- `clients/Voxia/README.md`、相关目录 README、外层 current truth/known gaps/阶段文档：收口证据。

---

### Task 1: 冻结三维流送优先级

**Files:**
- Create: `clients/Voxia/Source/Voxia/Presentation/VoxiaStreamingPriority.h`
- Create: `clients/Voxia/Source/Voxia/Presentation/VoxiaStreamingPriority.cpp`
- Create: `clients/Voxia/Source/Voxia/Presentation/VoxiaStreamingPriorityAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Presentation/README.md`

**Interfaces:**
- Consumes: `FVoxiaNearPatchId`、`FVoxiaFarPatchId`、`FVoxiaPatchStreamingSpatialContract`。
- Produces: `FVoxiaStreamingPriorityAnchor`、`FVoxiaStreamingPriorityKey`、`ForNearPatch`、`ForFarPatch`、`FVoxiaStreamingPriority::Less`。

- [ ] **Step 1: 写失败测试，钉死完整 XYZ 与稳定顺序**

```cpp
IMPLEMENT_SIMPLE_AUTOMATION_TEST(
    FVoxiaStreamingPriorityTest,
    "Voxia.Presentation.StreamingPriority",
    EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FVoxiaStreamingPriorityTest::RunTest(const FString& Parameters)
{
    using namespace Voxia::Presentation;
    const FVoxiaStreamingPriorityAnchor Anchor{41, FIntVector(-17, 9, 33)};
    const FVoxiaStreamingPriorityKey Center =
        FVoxiaStreamingPriority::ForNearPatch(Anchor, FVoxiaNearPatchId{{-5, 2, 8}});
    const FVoxiaStreamingPriorityKey VerticalFar =
        FVoxiaStreamingPriority::ForNearPatch(Anchor, FVoxiaNearPatchId{{-5, 9, 8}});
    TestTrue(TEXT("完整 XYZ 更近 Patch 优先"), FVoxiaStreamingPriority::Less(Center, VerticalFar));
    TestEqual(TEXT("冻结锚点保留目标世代"), Center.TargetGeneration, 41ULL);
    return true;
}
```

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Presentation.StreamingPriority; Quit'
```

Expected: compile fails because `VoxiaStreamingPriority.h` and the types do not exist.

- [ ] **Step 3: 实现最小纯值接口**

```cpp
struct VOXIA_API FVoxiaStreamingPriorityAnchor
{
    uint64 TargetGeneration = 0;
    FIntVector PlayerChunk = FIntVector::ZeroValue;
    bool IsValid() const { return TargetGeneration != 0; }
};

struct VOXIA_API FVoxiaStreamingPriorityKey
{
    uint64 TargetGeneration = 0;
    uint8 WorkClass = 0;
    int32 DistanceShell = 0;
    int64 MinDistanceSquared = 0;
    int32 VerticalDistance = 0;
    FIntVector Coord = FIntVector::ZeroValue;
};

class VOXIA_API FVoxiaStreamingPriority
{
public:
    static FVoxiaStreamingPriorityKey ForNearPatch(
        const FVoxiaStreamingPriorityAnchor& Anchor,
        const FVoxiaNearPatchId& PatchId);
    static FVoxiaStreamingPriorityKey ForFarPatch(
        const FVoxiaStreamingPriorityAnchor& Anchor,
        const FVoxiaFarPatchId& PatchId,
        uint8 WorkClass);
    static bool Less(
        const FVoxiaStreamingPriorityKey& Left,
        const FVoxiaStreamingPriorityKey& Right);
};
```

`DistanceShell` 必须由玩家 chunk 到 patch chunk AABB 的最小 Chebyshev 距离计算；同壳层依次比较平方距离、垂直距离、X、Y、Z。

- [ ] **Step 4: 补负坐标、AABB 内部、相同距离、不同世代严格弱序测试并跑绿**

Run: 与 Step 2 相同。

Expected: `Voxia.Presentation.StreamingPriority` PASS。

- [ ] **Step 5: 提交 Task 1**

```powershell
git add Source/Voxia/Presentation/VoxiaStreamingPriority.h Source/Voxia/Presentation/VoxiaStreamingPriority.cpp Source/Voxia/Presentation/VoxiaStreamingPriorityAutomationTest.cpp Source/Voxia/Presentation/README.md
git commit -m "feat(streaming): add stable xyz patch priority"
```

---

### Task 2: Near 壳层 dispatch 与 publication frontier

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaNearPatchBuildIndex.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaNearPatchBuildIndex.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaNearPatchBuildIndexAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldActor.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/README.md`

**Interfaces:**
- Consumes: `FVoxiaStreamingPriorityAnchor` 与 `FVoxiaStreamingPriority::ForNearPatch`。
- Produces: `SetWindowTarget(..., PriorityAnchor, ...)`、`CurrentPublicationShell()`、snapshot shell counters。

- [ ] **Step 1: 写 RED，证明字典序不能越过较近壳层**

在 `VoxiaNearPatchBuildIndexAutomationTest.cpp` 构造两个 artifact：先提交坐标更小但更远的 patch，再提交坐标更大但更近的 patch；断言 `PopReadyMove` 返回更近 patch。再只完成远 patch，断言 publication frontier 返回 `near_patch_waiting_for_closer_shell`。

```cpp
TestEqual(TEXT("较近壳层先发布"), Candidate.Artifact.PatchId, NearPatch);
TestEqual(
    TEXT("远壳层不得越过 frontier"),
    Blocked.Reason,
    FString(TEXT("near_patch_waiting_for_closer_shell")));
```

- [ ] **Step 2: 运行目标测试并确认 RED**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Gameplay.NearPatchBuildIndex; Quit'
```

Expected: existing `SetWindowTarget` has no anchor and `ReadyMoves` still uses `PatchIdLess`。

- [ ] **Step 3: 将 Near index 改为 priority-key 索引**

```cpp
FVoxiaPatchWorkResult SetWindowTarget(
    const FVoxiaPatchTargetKey& TargetKey,
    const FVoxiaStreamingPriorityAnchor& PriorityAnchor,
    const FVoxiaPresentationCommitLedgerSnapshot& LivePresentation);

int32 CurrentPublicationShell() const;
```

保存每个 target patch 的 key；`ReadyMoves` 以 key 排序。维护每壳层的 expected、terminal、ready、published 数；只有所有更近壳层 terminal 后才能弹出更远壳层。

- [ ] **Step 4: 让 Near assembly、chunk mesh 与 index 使用同一冻结锚点**

在 `AVoxiaWorldActor` target begin 时保存 `NearStreamingPriorityAnchor`。将 `PendingNearPatchAssemblies`、`NearMeshBuildChunks`、增量 added chunks 和 ready publication 全部改用同一 anchor；禁止从逐帧 Pawn 位置重新排序当前 target。

- [ ] **Step 5: 跑 Near 相关测试**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Gameplay.NearPatchBuildIndex; Quit'
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Voxel.TileWindow; Quit'
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Gameplay.NearActiveChunkMeshWorkQueue; Quit'
```

Expected: all selected tests PASS，新增断言证明 shell 单调且负 XYZ 不退化。

- [ ] **Step 6: 提交 Task 2**

```powershell
git add Source/Voxia/Gameplay/VoxiaNearPatchBuildIndex.h Source/Voxia/Gameplay/VoxiaNearPatchBuildIndex.cpp Source/Voxia/Gameplay/VoxiaNearPatchBuildIndexAutomationTest.cpp Source/Voxia/Gameplay/VoxiaWorldActor.h Source/Voxia/Gameplay/VoxiaWorldActor.cpp Source/Voxia/Gameplay/README.md
git commit -m "feat(streaming): publish near patches by distance shell"
```

---

### Task 3: Far 空闲预计算与 Near fence 后发布

**Files:**
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarPatchBuildIndex.h`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarPatchBuildIndex.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarPatchBuildIndexAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageSchedulerAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/README.md`

**Interfaces:**
- Consumes: Task 1 priority anchor、Task 2 Near shell snapshot。
- Produces: `EVoxiaFarDispatchPermission::{Blocked,OneSpareWorker,Normal}`、`EVoxiaFarPatchPublicationMode::{Held,RequiredOnly,Full}`、held artifact counts。

- [ ] **Step 1: 写 RED，证明 Near 未完成时 Far 不可发布**

```cpp
TestEqual(
    TEXT("Near 未完成时 Far publication held"),
    FVoxiaWorldRootStreamingSchedulingPolicy::ResolveFarPatchPublicationMode(
        EVoxiaPatchTargetKind::Bootstrap,
        false,
        false,
        true),
    EVoxiaFarPatchPublicationMode::Held);
```

另测：Near 有 pending/ready/in-flight 任一关键工作时 Far dispatch 为 Blocked；只有 Near 无可派发且 worker 有空位时返回 OneSpareWorker。

- [ ] **Step 2: 跑调度测试确认 RED**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Gameplay.WorldCoverageScheduler; Quit'
```

Expected: bootstrap 当前解析为 `Full`，测试失败。

- [ ] **Step 3: 实现纯策略与 Far anchor**

`FVoxiaFarPatchBuildIndex::SetTarget` 增加 `PriorityAnchor`；`ChooseNext` 用 Task 1 key，删除以 target center patch 为中心的距离。snapshot 增加 `PrecomputedHeldCount`、`RequiredPublishedCount`、`SpeculativePublishedCount`。

- [ ] **Step 4: 分离 build complete 与 visible publication**

`AVoxiaPure3DVoxelWorldActor` 允许 worker complete 后保存 held artifact，但仅当 Root 传入 publication mode 非 Held 时提交 SceneHost。Near 新工作出现时撤销未开始 speculative work；in-flight 保持 Lowest priority 并沿现有 cancellation token 退出。

- [ ] **Step 5: 跑 Far/Root 调度测试**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Voxel.FarPatchBuildIndex; Quit'
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Gameplay.WorldCoverageScheduler; Quit'
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Gameplay.UnifiedWorldTransactionPresentation; Quit'
```

Expected: all selected tests PASS；stale generation held artifact 明确 Cancelled。

- [ ] **Step 6: 提交 Task 3**

```powershell
git add Source/Voxia/FarField/VoxiaFarPatchBuildIndex.h Source/Voxia/FarField/VoxiaFarPatchBuildIndex.cpp Source/Voxia/FarField/VoxiaFarPatchBuildIndexAutomationTest.cpp Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler.h Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler.cpp Source/Voxia/Gameplay/VoxiaWorldCoverageSchedulerAutomationTest.cpp Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.h Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.cpp Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp Source/Voxia/FarField/README.md
git commit -m "feat(streaming): reserve critical path for complete near"
```

---

### Task 4: 完整 27-tile readiness 与阶段计时

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeSnapshot.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenter.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenterAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSession.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSession.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSessionAutomationTest.cpp`

**Interfaces:**
- Consumes: Near/Far snapshots from Tasks 2-3。
- Produces: `near_complete`、`required_far_complete`、`playable_elapsed_ms` 与严格 readiness reason。

- [ ] **Step 1: 写 RED，缺任一 Near 事实都不能 Playable**

在 runtime contract/presenter automation 中分别构造 `target_patches=215`、`exact_owned_chunks=9260`、`pending_move=1`、`post_visibility_fence` 落后、Required Far 未闭合，逐项断言 `ready=false` 和具体 reason。

- [ ] **Step 2: 跑 runtime contract 测试确认 RED**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Gameplay.UnifiedWorldRuntime; Quit'
```

- [ ] **Step 3: 实现唯一 readiness predicate**

将 Root 的 readiness 合取集中到一个纯函数，明确检查 `27/216/9261`、Near terminal、fence、Required Far 和 coverage；`CaptureRuntimeSnapshot`、HUD、CLI 与 `IsReady()` 共用，禁止复制不同版本的条件。

- [ ] **Step 4: 增加分段 monotonic timing**

首次满足 Near fence、Required Far fence 和 Playable 时记录 monotonic time；同一 generation 只写一次。输出字符串字段使用 uint64 decimal，Node 不经浮点转换。

- [ ] **Step 5: 统一 initial/recovery 正确性 deadline 为 60 秒**

扩展 `FVoxiaClientFlowMachine`，让 `CheckLoadingDeadline` 同时覆盖 InitialLoading 与 StreamingRecoveryLoading；性能 25 秒不在状态机内主动 Fail。

- [ ] **Step 6: 跑测试并提交**

Run: 与 Step 2 相同，Expected PASS。

```powershell
git add Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeSnapshot.h Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenter.cpp Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenterAutomationTest.cpp Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp Source/Voxia/Gameplay/VoxiaClientWorldSession.h Source/Voxia/Gameplay/VoxiaClientWorldSession.cpp Source/Voxia/Gameplay/VoxiaClientWorldSessionAutomationTest.cpp
git commit -m "feat(streaming): gate playability on complete near coverage"
```

---

### Task 5: Bootstrap 增量 coverage 结构状态

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Presentation/VoxiaRendererCoverage.h`
- Modify: `clients/Voxia/Source/Voxia/Presentation/VoxiaRendererCoverage.cpp`
- Modify: `clients/Voxia/Source/Voxia/Presentation/VoxiaRendererCoverageAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHostLedgerAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeSnapshot.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenter.cpp`

**Interfaces:**
- Consumes: existing renderer snapshot、delta scope、complete Near progress tracker。
- Produces: `FVoxiaRendererCoverageStructuralState` 与 delta eligibility/fallback reason counters。

- [ ] **Step 1: 写 RED，expected gap 仍允许 delta**

```cpp
FVoxiaRendererCoverageAudit BootstrapAudit;
BootstrapAudit.GapCount = 9000;
BootstrapAudit.InvalidLedgerCount = 0;
TestTrue(
    TEXT("预期 bootstrap gap 不等于结构损坏"),
    FVoxiaRendererCoverageStructuralState::FromAudit(BootstrapAudit).bStructurallyClean);
```

另测 overlap、invalid ledger、fence mismatch、unknown contributor 必须 dirty。

- [ ] **Step 2: 跑 coverage tests 确认 RED**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Presentation.RendererCoverage; Quit'
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Gameplay.VoxelPresentationSceneHostLedger; Quit'
```

- [ ] **Step 3: 实现 structural state 与 delta eligibility**

```cpp
struct VOXIA_API FVoxiaRendererCoverageStructuralState
{
    bool bStructurallyClean = false;
    int32 MissingExpectedCount = 0;
    FString Reason;
    static FVoxiaRendererCoverageStructuralState FromAudit(
        const FVoxiaRendererCoverageAudit& Audit);
};
```

`ApplyCommittedRendererCoverageDelta` 不再要求 `LastRendererCoverageAudit.IsClean()`，而要求 structural clean、serial/epoch/manifest 连续和 expectation cache 有效。gap 由 `FVoxiaCompleteNearWindowProgressTracker` 持续维护。

- [ ] **Step 4: 将 fallback 改为一次性显式 rebase**

每个 target/reason 只允许一次 full audit/rebase；同一 reason 重复 fallback 直接输出 `renderer_coverage_delta_rebase_loop` Fatal。加入 eligible/apply/fallback/full-audit/parity-failure 计数与 reason map。

- [ ] **Step 5: 最终 full audit parity**

Near + Required Far 就绪后强制独立 full audit；若与增量 snapshot 不一致则禁止 Playable，错误为 `renderer_coverage_incremental_parity_failed`。

- [ ] **Step 6: 跑 coverage tests 并提交**

Run: 与 Step 2 相同，Expected PASS。

```powershell
git add Source/Voxia/Presentation/VoxiaRendererCoverage.h Source/Voxia/Presentation/VoxiaRendererCoverage.cpp Source/Voxia/Presentation/VoxiaRendererCoverageAutomationTest.cpp Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.h Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.cpp Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHostLedgerAutomationTest.cpp Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeSnapshot.h Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenter.cpp
git commit -m "fix(streaming): keep bootstrap coverage deltas incremental"
```

---

### Task 6: Mock confirmed prepare/commit 原子泵

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldSubsystem.h`
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldSubsystem.cpp`
- Modify: `clients/Voxia/Source/Voxia/Authority/VoxiaWorldIntentSubsystem.h`
- Modify: `clients/Voxia/Source/Voxia/Authority/VoxiaWorldIntentSubsystem.cpp`
- Modify: `clients/Voxia/Source/Voxia/Authority/VoxiaWorldIntentSubsystemAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/README.md`
- Modify: `clients/Voxia/Source/Voxia/Authority/README.md`

**Interfaces:**
- Consumes: existing reducer、intent ledger、presentation journal。
- Produces: `FVoxiaPreparedAuthorityBatch`、`PrepareAuthorityEvent`、`CommitPreparedAuthorityEvent`。

- [ ] **Step 1: 写 RED，预校验失败不得推进 confirmed revision**

在 WorldIntent harness 注入一个 reducer 可接受、但 journal correlation 校验失败的 transaction。断言 Pump 后 confirmed revision、pending reorder map、journal 与 ledger 全部保持原值。

```cpp
TestEqual(TEXT("失败前 confirmed revision 不变"), Harness.Confirmed->Snapshot().ConfirmedWorldRevision, BeforeRevision);
TestEqual(TEXT("失败前 ledger state 不变"), KnownState(*Harness.Intents, Intent.IntentId), EVoxiaIntentState::Accepted);
```

- [ ] **Step 2: 跑 authority test 确认 RED**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Authority.WorldIntentSubsystem; Quit'
```

- [ ] **Step 3: 引入 prepared batch**

```cpp
struct FVoxiaPreparedAuthorityBatch
{
    uint64 SessionGeneration = 0;
    uint64 BaseRevision = 0;
    uint64 NewRevision = 0;
    uint64 EventHash = 0;
    FVoxiaConfirmedWorldSnapshot CandidateSnapshot;
    TMap<uint64, FVoxiaConfirmedWorldTransaction> CandidatePending;
    TArray<FVoxiaWorldChangeSet> ChangeSets;
    TArray<FVoxiaWorldPresentationFreezeFrame> PresentationFrames;
    bool IsValid() const;
};
```

`PrepareAuthorityEvent` 复用现有 reducer/drain 逻辑但不写 live storage。`CommitPreparedAuthorityEvent` 核对 session、当前 revision 和 token 后只做不可失败的 move/swap 与 metrics observe。

- [ ] **Step 4: WorldIntent 在副本完成所有校验后统一发布**

先准备 CandidateJournal/CandidateLedger，再 commit confirmed，最后 move/swap 已验证的 journal/ledger；commit 后不得再调用可能返回失败的 API。buffered/duplicate/resync 语义保持原合同。

- [ ] **Step 5: 补 reorder、duplicate、session drift 和 token replay 测试并跑绿**

Run: 与 Step 2 相同，Expected PASS。

- [ ] **Step 6: 提交 Task 6**

```powershell
git add Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldSubsystem.h Source/Voxia/Voxel/WorldModel/VoxiaConfirmedWorldSubsystem.cpp Source/Voxia/Authority/VoxiaWorldIntentSubsystem.h Source/Voxia/Authority/VoxiaWorldIntentSubsystem.cpp Source/Voxia/Authority/VoxiaWorldIntentSubsystemAutomationTest.cpp Source/Voxia/Voxel/WorldModel/README.md Source/Voxia/Authority/README.md
git commit -m "fix(authority): commit confirmed intent state atomically"
```

---

### Task 7: Obligation totality、密闭坑位与真实跨 chunk

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedTransactionPresentationDriver.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedTransactionPresentationDriver.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldTransactionPresentationAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Authority/VoxiaPresentationWorkJournal.h`
- Modify: `clients/Voxia/Source/Voxia/Authority/VoxiaPresentationWorkJournal.cpp`
- Modify: `clients/Voxia/Source/Voxia/Authority/VoxiaWorldIntentSubsystemAutomationTest.cpp`
- Modify: `clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.js`
- Modify: `clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.test.js`

**Interfaces:**
- Consumes: Task 6 atomic confirmed batches、Near target masks 与 resident coverage。
- Produces: `EVoxiaPresentationObligationState::{Present,Deferred,DeadLetter}` 与 `WakeKey`。

- [ ] **Step 1: 写 RED，resident confirmed mutation 不得 obligated=0**

构造完整 Near 内、无可见表面但 chunk confirmed/resident 的 prefab footprint；断言 obligation state 为 Present、patch 集非空。另构造 footprint 跨 `chunk_x=77/78` 边界，断言 patch 并集和统一 receipt。

- [ ] **Step 2: 跑 presentation tests 确认 RED**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Gameplay.UnifiedWorldTransactionPresentation; Quit'
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Authority.ApplicationBoundary; Quit'
```

- [ ] **Step 3: 实现义务三态与 wake key**

```cpp
enum class EVoxiaPresentationObligationState : uint8
{
    Present,
    Deferred,
    DeadLetter
};

struct FVoxiaPresentationWakeKey
{
    FString Owner;
    FString Key;
    bool IsValid() const { return !Owner.IsEmpty() && !Key.IsEmpty(); }
};
```

resident 判定基于 confirmed affected chunk 与当前完整 target ownership，不依赖 ray、表面可见性或几何是否为空。non-resident Deferred 必须携带 `chunk_residency:<x>,<y>,<z>`；无 key 的零义务直接 Fatal。

- [ ] **Step 4: residency owner 主动重扫 Deferred**

在 target/residency generation 前进时按 wake key 通知 journal，只重算命中的 Deferred；成功后注册固定 patch obligation，失败转 DeadLetter 并终结 intent，不能阻塞后继 mutation。

- [ ] **Step 5: 将 Phase 3 smoke 从 preview 升级为真实 place**

runner 先用 `world macro-inspect` 选取密闭坑位 anchor，再实际 `place` 并等待 accepted→confirmed→presented。跨 chunk case 必须验证 footprint 的 `affected_chunks` 至少含两个不同 chunk identity，不能用相邻 macro 冒充。

- [ ] **Step 6: 跑 C++ 与 Node 单测并提交**

Run:

```powershell
node --test scripts/run_phase3_prefab_runtime_smoke.test.js
```

Expected: Node tests PASS；C++ 使用 Step 2 命令 PASS。

```powershell
git add Source/Voxia/Gameplay/VoxiaUnifiedTransactionPresentationDriver.h Source/Voxia/Gameplay/VoxiaUnifiedTransactionPresentationDriver.cpp Source/Voxia/Gameplay/VoxiaUnifiedWorldTransactionPresentationAutomationTest.cpp Source/Voxia/Authority/VoxiaPresentationWorkJournal.h Source/Voxia/Authority/VoxiaPresentationWorkJournal.cpp Source/Voxia/Authority/VoxiaWorldIntentSubsystemAutomationTest.cpp scripts/run_phase3_prefab_runtime_smoke.js scripts/run_phase3_prefab_runtime_smoke.test.js
git commit -m "fix(streaming): make confirmed presentation obligations total"
```

---

### Task 8: Root liveness registry 与 CLI

**Files:**
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaStreamingLiveness.h`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaStreamingLiveness.cpp`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaStreamingLivenessAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeSnapshot.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenter.cpp`
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp`
- Modify: `clients/Voxia/Source/Voxia/Debug/README.md`

**Interfaces:**
- Consumes: Tasks 2-7 各 subsystem 的稳定 snapshot/progress epoch。
- Produces: `FVoxiaStreamingLivenessRegistry`、`voxel_liveness_state` JSON、5/15/60 秒分层诊断。

- [ ] **Step 1: 写 RED，所有等待必须有 owner/wake key**

```cpp
FVoxiaStreamingLivenessRegistry Registry;
FString Error;
TestFalse(TEXT("无 owner 等待被拒绝"), Registry.Upsert({TEXT("near"), TEXT(""), TEXT("target:1"), 1}, 0.0, Error));
TestEqual(TEXT("错误可诊断"), Error, FString(TEXT("streaming_wait_owner_missing")));
```

测试 5 秒 report、15 秒无在途工作 Fatal、持续 progress 不 stall、owner remove 清理 waiter、60 秒 initial/recovery deadline。

- [ ] **Step 2: 跑 liveness test 确认 RED**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Gameplay.StreamingLiveness; Quit'
```

- [ ] **Step 3: 实现纯值 registry**

```cpp
struct FVoxiaStreamingWaitState
{
    FString WaiterId;
    FString Owner;
    FString WakeKey;
    uint64 ProgressEpoch = 0;
    double FirstWaitAtSeconds = 0.0;
    double LastProgressAtSeconds = 0.0;
    bool bOwnerHasInFlightWork = false;
};
```

Registry 只存值，不持有 Actor/PID；Root 每帧从 subsystem snapshot 更新，owner subsystem 负责 progress epoch。JSON 按 waiter id 排序，确保测试稳定。

- [ ] **Step 4: 集成 Root 与 debug CLI**

`client_flow_probe` 嵌入有界摘要；`voxel_liveness_state` 输出完整 waiter 数组、最老 waiter、Near/Far shell、coverage ratio、阶段时间。5 秒只 emit 一次 stall report；15 秒满足 Fatal 条件时进入有期限 recovery。

- [ ] **Step 5: 跑 liveness/runtime/CLI tests 并提交**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Gameplay.StreamingLiveness; Quit'
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Gameplay.UnifiedWorldRuntimePresenter; Quit'
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia.Debug; Quit'
```

Expected: all selected tests PASS。

```powershell
git add Source/Voxia/Gameplay/VoxiaStreamingLiveness.h Source/Voxia/Gameplay/VoxiaStreamingLiveness.cpp Source/Voxia/Gameplay/VoxiaStreamingLivenessAutomationTest.cpp Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeSnapshot.h Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenter.cpp Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp Source/Voxia/Debug/README.md
git commit -m "feat(streaming): expose owned liveness waits"
```

---

### Task 9: Smoke 门禁与 10 次 Real-RHI 聚合器

**Files:**
- Modify: `clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.js`
- Modify: `clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.test.js`
- Create: `clients/Voxia/scripts/run_mock_streaming_cold_start_gate.js`
- Create: `clients/Voxia/scripts/run_mock_streaming_cold_start_gate.test.js`
- Modify: `clients/Voxia/scripts/run_phase2_macro_interaction_smoke.js`
- Modify: `clients/Voxia/scripts/run_phase2_macro_interaction_smoke.test.js`
- Modify: `clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.js`
- Modify: `clients/Voxia/scripts/run_phase3_prefab_runtime_smoke.test.js`

**Interfaces:**
- Consumes: `client_flow_probe`、`voxel_liveness_state`、Phase runner summary。
- Produces: `--startup-only`、`cold_start_gate_summary.json`、性能/顺序/ratio 硬门禁。

- [ ] **Step 1: 写 Node RED**

加入 fixtures：Near `215/216`、Far 在 Near complete 前 visible、shell 倒退、delta ratio 89.9%、25,001ms、pending intent。逐项断言 runner 以稳定 code 失败：

```js
assert.equal(validateStartupProof(fixture).code, "near_window_incomplete");
assert.equal(validateDeltaRatio(ratioFixture).code, "coverage_delta_ratio_below_gate");
assert.equal(validateTiming(slowFixture).code, "mock_cold_start_max_exceeded");
```

- [ ] **Step 2: 跑 Node tests 确认 RED**

Run:

```powershell
node --test scripts/run_phase1_world_lifecycle_smoke.test.js scripts/run_mock_streaming_cold_start_gate.test.js scripts/run_phase2_macro_interaction_smoke.test.js scripts/run_phase3_prefab_runtime_smoke.test.js
```

- [ ] **Step 3: 扩展 Phase 1 startup proof**

新增 `--startup-only`：Root ready 后采集一次 final proof 即退出。断言 `near tiles=27`、`patches=216`、`chunks=9261`、shell 单调、Far pre-Near visible=0、Required Far complete、coverage clean、delta ratio>=0.9、无 waiter/pending intent。

- [ ] **Step 4: 实现 10-run 聚合器**

```js
export function percentileNearestRank(values, percentile) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(percentile * sorted.length) - 1)];
}
```

聚合器顺序启动 10 次 Phase 1 `--real-rhi --startup-only`，每次独立 observe dir；任何子运行失败立即保留产物但继续收集剩余次数，最终以 p95<=20000、max<=25000、failed=0 判定。

- [ ] **Step 5: 跑 Node tests 并提交**

Run: 与 Step 2 相同，Expected PASS。

```powershell
git add scripts/run_phase1_world_lifecycle_smoke.js scripts/run_phase1_world_lifecycle_smoke.test.js scripts/run_mock_streaming_cold_start_gate.js scripts/run_mock_streaming_cold_start_gate.test.js scripts/run_phase2_macro_interaction_smoke.js scripts/run_phase2_macro_interaction_smoke.test.js scripts/run_phase3_prefab_runtime_smoke.js scripts/run_phase3_prefab_runtime_smoke.test.js
git commit -m "test(streaming): gate complete mock cold starts"
```

---

### Task 10: 构建、全量验证与真相同步

**Files:**
- Modify: `clients/Voxia/README.md`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/README.md`
- Modify: `clients/Voxia/Source/Voxia/FarField/README.md`
- Modify: `clients/Voxia/Source/Voxia/Authority/README.md`
- Modify: `clients/Voxia/Source/Voxia/Voxel/WorldModel/README.md`
- Modify: `docs/00-current-truth/design/client/streaming-lod.md`
- Modify: `docs/00-current-truth/impl/known_gaps.md`
- Modify: `docs/10-active/voxel-far-field/2026-08-10-voxia-client-mock-streaming-smoothness.md`
- Modify: `docs/10-active/cross-cutting/_session-handoff.md`

**Interfaces:**
- Consumes: Tasks 1-9 全部实现和 `.demo/observe/` 证据。
- Produces: 可复现的最终验收记录；只有证据通过才关闭 known gaps。

- [ ] **Step 1: 重新构建 VoxiaEditor**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Build\BatchFiles\Build.bat' VoxiaEditor Win64 Development 'C:\Users\DYZ\Documents\dev\hemifuture\ex_mmo_cluster\clients\Voxia\Voxia.uproject' -WaitMutex -NoHotReload
```

Expected: exit 0；记录 DLL timestamp 晚于全部修改源码。

- [ ] **Step 2: 跑全量 Unreal Automation**

Run:

```powershell
& 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' '.\Voxia.uproject' -unattended -nop4 -nosplash -nullrhi -ExecCmds='Automation RunTests Voxia; Quit'
```

Expected: started=completed=success、failed=0、进程 exit 0。

- [ ] **Step 3: 跑全量 Node tests**

Run:

```powershell
node --test scripts/*.test.js
```

Expected: fail=0。

- [ ] **Step 4: 跑 Null-RHI Phase 1/2/3**

```powershell
node scripts/run_phase1_world_lifecycle_smoke.js --null-rhi --startup-only --resolution 1280x720
node scripts/run_phase2_macro_interaction_smoke.js --null-rhi --resolution 1280x720
node scripts/run_phase3_prefab_runtime_smoke.js --null-rhi --resolution 1280x720
```

Expected: 三个 summary `passed=true`，Phase 3 密闭坑位和跨 chunk intent 为 presented。

- [ ] **Step 5: 跑 Real-RHI Phase 1/2/3**

```powershell
node scripts/run_phase1_world_lifecycle_smoke.js --real-rhi --startup-only --resolution 1280x720
node scripts/run_phase2_macro_interaction_smoke.js --real-rhi --resolution 1280x720
node scripts/run_phase3_prefab_runtime_smoke.js --real-rhi --resolution 1280x720
```

Expected: 三个 summary `passed=true`，无 `LogVoxia Error`。

- [ ] **Step 6: 跑连续 10 次 Real-RHI 冷启动硬门禁**

```powershell
node scripts/run_mock_streaming_cold_start_gate.js --runs 10 --p95-ms 20000 --max-ms 25000 --resolution 1280x720
```

Expected: `failed_runs=0`、`p95_ms<=20000`、`max_ms<=25000`、`passed=true`。

- [ ] **Step 7: 更新文档，只写实际证据**

将 build/automation/Node/Null/Real/10-run 命令、计数、时长和 observe 路径写入设计进度日志及 current truth。只有 Phase 3 两条 intent lifecycle 与 10-run 全绿后才关闭 known gaps #8/#9；否则保留 OPEN 并记录精确阻塞。

- [ ] **Step 8: 检查 diff 与工作区边界**

```powershell
git -C clients/Voxia diff --check
git diff --check
git -C clients/Voxia status --short
git status --short
```

Expected: 无 whitespace error；原有用户修改仍在，未被覆盖或意外 stage。

- [ ] **Step 9: 提交客户端文档与外层真相文档**

在 `clients/Voxia` 只 stage 本专项相关文件并提交；回到外层仓库只 stage current truth、known gaps、active design/handoff，禁止把无关 dirty 文件混入。

```powershell
git commit -m "docs(streaming): record complete mock flow closure"
```

---

## Plan Self-Review Result

- 设计 §3-5 的完整 Near、XYZ priority、Near/Far budget 分别由 Tasks 1-4 覆盖；
- 设计 §6 的 bootstrap delta 与 `>=90%` 门禁由 Tasks 5、9 覆盖；
- 设计 §7 的原子 confirmed 泵、密闭坑位和跨 chunk 由 Tasks 6-7、9 覆盖；
- 设计 §8-9 的 liveness/deadline/CLI 由 Tasks 4、8 覆盖；
- 设计 §10 的 build、automation、Node、Null/Real 与 10-run 由 Tasks 9-10 覆盖；
- 所有新增接口在首次使用前均已定义；没有未决占位或含糊的后置步骤。
