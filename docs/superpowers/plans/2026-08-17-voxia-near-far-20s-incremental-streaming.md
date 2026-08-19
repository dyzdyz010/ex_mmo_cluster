# Voxia Near/Far 20 秒全增量流送 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让唯一 Voxia 生产组合根在 1280×720 Real-RHI 冷启动中每次 Near `<=10s`，并在 Playable 后 `<=10s` 完成全部 `33725 pages / 6859 Far patches`，同时保持相机感知排序与跨 Tile 全增量。

**Architecture:** 保留现有 TargetKey、PatchVersion、SceneHost ledger 与 renderer receipt，把 Far 待办改为“距离绝对优先、视角次优先”的可重排索引；把 Near/Far 的逐 Patch 双 fence 改为同 TargetKey 连续前缀共享 fence 的有界 presentation group；让 Full Far 数据准备与 Patch 发布形成连续流水线，并按硬件并发度使用 spare capacity。Root 独占 Near/Far deadline 和 Tile target 生命周期。

**Tech Stack:** Unreal Engine 5.8 C++、DynamicMesh、RHI render command fences、UE Automation Tests、Node.js smoke runner、结构化 JSONL observe。

**Status (2026-08-17):** 已在唯一 `L_VoxiaProductionWorld` / `RuntimeMock` 生产根完成实施并通过
1280×720 Real-RHI 连续 10 次独立冷启动门禁。下方步骤保留为实施过程清单；最终实现与证据见文末。

## Global Constraints

- 唯一现役客户端是 `clients/Voxia`，唯一生产地图是 `L_VoxiaProductionWorld`。
- 完整 Near 固定为 `27 tiles / 216 patches / 9261 chunks`，只由 Near 决定 Playable。
- Full Far 固定为 `33725 pages / 6859 patches`；视角只改变顺序，不裁剪目标。
- Near 从 Root start 起 `<=10000ms`；Far 从 Playable 起 `<=10000ms`；任一超时显式失败。
- 相机旋转只重排 pending；不得取消 in-flight/ready/presentation，不得重置 deadline。
- 同 Tile 不建立新完整目标；跨 Tile 只处理完整 XYZ retained/entered/exited 差集。
- 每个 Patch 的 TargetKey、版本、after-image、read-set、commit serial、coverage receipt 保持独立。
- baseline/H/manifest/diff-chain、coverage、fence 或账本错误必须 Fatal，禁止静默降级。
- 所有新增 C++ 注释使用中文；CLI、observe、自动化与 Real-RHI smoke 同步完成。
- `clients/Voxia` 当前存在用户未提交修改；不得用 reset/checkout 覆盖，也不得把整文件用户改动误提交。

---

### Task 1: 相机感知的确定性 Far 优先级

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Presentation/VoxiaStreamingPriority.h`
- Modify: `clients/Voxia/Source/Voxia/Presentation/VoxiaStreamingPriority.cpp`
- Modify: `clients/Voxia/Source/Voxia/Presentation/VoxiaStreamingPriorityAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarPatchBuildIndex.h`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarPatchBuildIndex.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarPatchBuildIndexAutomationTest.cpp`

**Interfaces:**
- Consumes: existing `FVoxiaStreamingPriorityAnchor`, `FVoxiaFarPatchBuildIndex::SetTarget` and pending sets.
- Produces: `CameraForwardQ15`, `CameraPriorityRevision`, angular fields on `FVoxiaStreamingPriorityKey`, and `ReprioritizePending`.

- [ ] **Step 1: Write failing priority tests**

Add fixtures that use one distance shell with patches at `0° / 30° / 60°`, assert center-first ordering, assert distance shell always beats angle, and assert negative XYZ tie-breaking remains stable:

```cpp
FVoxiaStreamingPriorityAnchor Anchor;
Anchor.TargetGeneration = 7;
Anchor.PlayerChunk = FIntVector::ZeroValue;
Anchor.CameraForwardQ15 = FIntVector(32767, 0, 0);
Anchor.CameraPriorityRevision = 3;
TestTrue(TEXT("距离层绝对优先"), FVoxiaStreamingPriority::Less(NearerWide, FartherCenter));
TestTrue(TEXT("同层视野中心优先"), FVoxiaStreamingPriority::Less(Center, Edge));
```

- [ ] **Step 2: Run the narrow tests and confirm RED**

Run:

```powershell
cd clients/Voxia
./scripts/run_automation_test.ps1 -TestFilter "Voxia.Presentation.StreamingPriority+Voxia.FarField.FarPatchBuildIndex"
```

Expected: compile/test failure because camera priority fields and `ReprioritizePending` do not exist.

- [ ] **Step 3: Implement fixed-point angular ordering**

Extend the anchor/key without floating-point comparator instability:

```cpp
struct FVoxiaStreamingPriorityAnchor
{
    uint64 TargetGeneration = 0;
    FIntVector PlayerChunk = FIntVector::ZeroValue;
    FIntVector CameraForwardQ15 = FIntVector(32767, 0, 0);
    uint64 CameraPriorityRevision = 0;
};

struct FVoxiaStreamingPriorityKey
{
    // existing fields remain first
    int32 AngularBucket = 0;
    int64 NegatedForwardDot = 0;
    uint64 CameraPriorityRevision = 0;
};
```

Compute the Patch AABB-center direction with saturating integer math. `Less` compares `DistanceShell` and `MinDistanceSquared` before `AngularBucket/NegatedForwardDot`, then `VerticalDistance/XYZ`.

- [ ] **Step 4: Implement pending-only reprioritization**

Add:

```cpp
FVoxiaPatchWorkResult ReprioritizePending(
    const FVoxiaStreamingPriorityAnchor& PriorityAnchor,
    int32& OutReprioritizedCount);
```

Only recompute keys for `PendingRequired` and `PendingSpeculative`. Reject target-generation mismatch; leave `WaitingDependencies`, `InFlight`, `Ready`, fatal and live versions untouched. Publish revision/count in the snapshot.

- [ ] **Step 5: Run tests and record GREEN**

Run the same filter and then `Automation RunTests Voxia.Presentation; Quit` through the existing unattended editor entry.

---

### Task 2: Root-owned Tile target and Near/Far deadline state

**Files:**
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaStreamingDeadline.h`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaStreamingDeadline.cpp`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaStreamingDeadlineAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeSnapshot.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenter.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenterAutomationTest.cpp`

**Interfaces:**
- Produces: `FVoxiaStreamingDeadline`, `FVoxiaStreamingDeadlineSnapshot`, Root `NearDeadline` and `FarDeadline`.
- Consumes: Root start time, `NearCompleteElapsedMs`, `PlayableElapsedMs`, patch-streaming settled state.

- [ ] **Step 1: Write deadline state-machine tests**

Cover not-started, active, complete-at-boundary, timeout, no-reset and new-Tile restart:

```cpp
FVoxiaStreamingDeadline Deadline(10000);
TestTrue(TEXT("首次开始"), Deadline.Start(12.0, 41));
TestFalse(TEXT("同 target 不重置"), Deadline.Start(15.0, 41));
TestFalse(TEXT("9999ms 未超时"), Deadline.Observe(21.999).bExceeded);
TestTrue(TEXT("10001ms 超时"), Deadline.Observe(22.001).bExceeded);
```

- [ ] **Step 2: Run test and confirm RED**

Run filter `Voxia.Gameplay.StreamingDeadline`; expect missing type failure.

- [ ] **Step 3: Implement the pure deadline owner**

Use monotonic seconds supplied by caller; store `TargetGeneration`, `StartedAtSeconds`, `CompletedAtSeconds`, `BudgetMs=10000`, and a terminal enum. `Start` is idempotent for the same generation and rejects older generations. `Complete` cannot turn an exceeded deadline into success.

- [ ] **Step 4: Wire Root milestones**

Start Near when the production Root begins; complete it only when existing Near readiness is true. Start Far exactly when `NotifyRootReady`/Playable is committed. Complete Far only when Full target is `6859`, exact retained count matches, mailbox/ready/in-flight/fatal are zero, renderer audit is clean and resources are quiescent.

On timeout call the existing explicit session/root failure path with `near_deadline_exceeded` or `far_deadline_exceeded`; never set settled.

- [ ] **Step 5: Expose snapshots and test JSON**

Add `near_deadline` and `far_deadline` objects with `elapsed_ms`, `budget_ms`, `remaining_ms`, `state`, `target_generation`, and `reason`. Assert exact values in presenter tests.

- [ ] **Step 6: Run focused tests and confirm GREEN**

Run `Voxia.Gameplay.StreamingDeadline+Voxia.Gameplay.UnifiedWorldRuntimePresenter`.

---

### Task 3: 同 Tile 抑制、跨 Tile 完整 XYZ 差集与相机重排入口

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageSchedulerAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.cpp`

**Interfaces:**
- Consumes: existing coverage plan, `RequestCenter`, `FarPatchBuildIndex::ReprioritizePending`.
- Produces: `ObserveCameraPriority`, `SameTileTargetSuppressedCount`, camera hysteresis and exact diff counters.

- [ ] **Step 1: Add failing scheduler tests**

Assert all movement positions that floor-divide to the current Tile produce no new full target; adjacent X/Y/Z and combined-axis crossings produce a new target with nonzero retained/entered/exited; camera-only updates do not change TargetKey/generation.

- [ ] **Step 2: Run scheduler tests and confirm RED**

Run `Voxia.Gameplay.WorldCoverageScheduler`.

- [ ] **Step 3: Implement explicit anchor ownership**

Store the committed `AnchorTile` in Root. Compare complete XYZ tile identity before calling `Force/Observe`. Same-Tile requests increment `SameTileTargetSuppressedCount` and return without touching target generation.

- [ ] **Step 4: Add bounded camera reprioritization**

Add:

```cpp
bool ObserveCameraPriority(
    const FVector& CameraForward,
    double NowSeconds,
    FString& OutError);
```

Quantize to Q15. Reprioritize only when angle delta is at least `5°` and at least `100ms` passed. Forward the new anchor to Pure3D; do not cancel or reset deadline.

- [ ] **Step 5: Prove cross-Tile reuse**

Extend state/tests so the committed target reports exact retained/entered/exited counts from the existing manifest and live ledger. Assert no full generation reset and no cleared live versions.

- [ ] **Step 6: Run focused tests and confirm GREEN**

Run scheduler, FarPatchBuildIndex and UnifiedWorld transaction tests.

---

### Task 4: Shared-fence presentation group lifecycle

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationResourceSet.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationResourceSet.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationResourceSetAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHostTransactionAutomationTest.cpp`

**Interfaces:**
- Produces: `FVoxiaPatchPresentationGroupTicket`, group runtime snapshot, `BeginPatchPresentationGroup`, `PollPatchPresentationGroup`, `CancelPatchPresentationGroup`.
- Preserves: per-Patch `FVoxiaPatchPresentationTicket` and existing single-plan wrappers.

- [ ] **Step 1: Write failing pure group lifecycle tests**

Build a group containing two renderer mutations and one command-free plan. Assert one staging fence, one post fence, three independent terminal receipts, ordered serials, and no fence for an all-command-free group. Test stale target rejection and pre-visibility atomic cancellation.

- [ ] **Step 2: Run ResourceSet/SceneHost transaction tests and confirm RED**

Run `Voxia.Gameplay.VoxelPresentationResourceSet+Voxia.Gameplay.VoxelPresentationSceneHostTransaction`.

- [ ] **Step 3: Add group tickets and lifecycle**

```cpp
struct FVoxiaPatchPresentationGroupTicket
{
    uint64 Value = 0;
    bool IsValid() const { return Value != 0; }
};

FVoxiaPatchWorkResult BeginPatchPresentationGroup(
    TArray<FVoxiaValidatedPatchPresentationPlan>&& Plans,
    FVoxiaPatchPresentationGroupTicket& OutGroup,
    TArray<FVoxiaPatchPresentationTicket>& OutPatchTickets);
```

Validate same TargetKey/coherence epoch, strict order, static group cap `64` renderer mutations, and presentation budget before creating hidden UObjects.

- [ ] **Step 4: Refactor SceneHost to one active group**

Replace the single optional transaction with one group containing ordered child transactions. Reuse existing child staging helpers, but arm the staging fence once after every renderer-mutating child is hidden-ready. Prevalidate all read-sets before the first visible commit.

- [ ] **Step 5: Commit per-Patch ledger under shared fences**

After the shared staging fence, execute child visibility/ledger commits in input order with the existing `2ms` GameThread slice. Arm one post-visibility fence after the final child. Only after that fence publish each child terminal snapshot and queue retirement. All-command-free groups complete without RHI commands.

- [ ] **Step 6: Keep single-plan API compatible**

Implement existing `BeginPatchPresentation` as a one-element group wrapper so Near/edit callers remain functional during migration. Snapshot APIs must resolve both group and child tickets.

- [ ] **Step 7: Run focused tests and confirm GREEN**

Run the ResourceSet, SceneHost ledger, SceneHost transaction, Near confirmed presentation and Far confirmed presentation filters.

---

### Task 5: Near/Far consumers submit bounded groups

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaNearPatchBuildIndex.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaNearPatchBuildIndex.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaNearPatchBuildIndexAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldActor.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.cpp`

**Interfaces:**
- Consumes: group SceneHost API and priority indexes.
- Produces: contiguous candidate groups, group statistics, per-Patch completion mapping.

- [ ] **Step 1: Add failing batch assembly tests**

Near and Far tests must prove: only a continuous priority prefix is grouped; TargetKey/epoch mismatch stops the group; a mailbox gap stops without scanning past it; ready/in-flight work is never cancelled by camera reprioritization; group cap is `64` renderer mutations.

- [ ] **Step 2: Run Near/Far index tests and confirm RED**

Run NearPatchBuildIndex, FarPatchBuildIndex and SceneHost transaction filters.

- [ ] **Step 3: Split prepare from presentation begin**

Refactor existing `BeginPendingFarPatchPresentation` so planner/boundary work produces `FVoxiaValidatedPatchPresentationPlan` without immediately claiming SceneHost. Keep all existing failure reporting and version checks.

- [ ] **Step 4: Assemble and submit Far groups**

Replace `TOptional<FPendingFarPatchPresentation>` with a bounded ordered group. Demand-consume mailbox items only for the queue head, prepare plans within the `2ms` slice, submit the group, then map child terminal snapshots back through existing `MarkPublished` calls.

- [ ] **Step 5: Migrate Near publication to the same group path**

Collect complete Near patch candidates in shell order. Preserve full-Near gate and atomic ownership rules; group fences reduce GPU round trips but cannot make partial Near count as playable.

- [ ] **Step 6: Expose group counters**

Record group count, renderer mutations, command-free children, average/max group size, shared staging/post fence count and per-stage elapsed time.

- [ ] **Step 7: Run focused tests and confirm GREEN**

Run all `Voxia.Gameplay.*Patch*`, SceneHost and UnifiedWorld runtime tests.

---

### Task 6: Full Far continuous build and hardware-derived parallelism

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldGenVoxelShellBuilder.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldGenVoxelShellBuilder.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldGenVoxelShellBuilderAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelShellResolvedSurfaceStager.h`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelShellResolvedSurfaceStager.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelShellResolvedSurfaceStagerAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler.cpp`
- Test: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageSchedulerAutomationTest.cpp`

**Interfaces:**
- Produces: hardware-derived `FVoxiaFarBuildParallelism`, one continuous Full build, no duplicate startup/full artifact work.
- Consumes: Near reserve/dispatch permission and existing demand-driven FarPatchBuildStream.

- [ ] **Step 1: Write failing parallelism policy tests**

Add a pure resolver:

```cpp
struct FVoxiaFarBuildParallelism
{
    int32 ProviderWorkers;
    int32 SurfaceWorkers;
};

static FVoxiaFarBuildParallelism Resolve(
    int32 LogicalWorkers,
    EVoxiaFarDispatchPermission Permission);
```

For `32` logical workers expect Normal `16/16`, OneSpareWorker `1/1`, Blocked `0/0`; clamp every count to `1..32` when dispatchable.

- [ ] **Step 2: Run builder/stager tests and confirm RED**

Run WorldGenVoxelShellBuilder, ResolvedSurfaceStager and WorldCoverageScheduler filters.

- [ ] **Step 3: Replace fixed `8/4` production limits**

Resolve worker caps once from frozen runtime hardware/config. Pass them through provider and surface stager; retain explicit OneSpareWorker pacing before Near completion.

- [ ] **Step 4: Remove duplicate StartupRequired → Full rebuild**

Prepare the full immutable target once. Mark the Required protection subset in the same manifest and allow its nearest candidates to reach the mailbox first. Before Near is complete, publication stays Held/RequiredOnly and build workers obey spare capacity; after Playable, release Normal parallelism and Full publication without creating a second plan, page batch, artifact cache or target generation.

- [ ] **Step 5: Preserve continuous producer handoff**

Ensure each finished Patch item enters the demand-driven stream immediately. The consumer must not wait for full `BuildFuture`; final future handoff only archives residency/artifact/coverage.

- [ ] **Step 6: Run focused tests and confirm GREEN**

Assert one Full generation, exact Required subset, no duplicate provider pages, no duplicate material/surface artifacts, and unchanged `6859` final target.

---

### Task 7: Hard 10 秒 smoke gate and structured diagnostics

**Files:**
- Modify: `clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.js`
- Modify: `clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.test.js`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/Net/VoxiaObserve.cpp`
- Modify: `clients/Voxia/Source/Voxia/Net/README.md`

**Interfaces:**
- Produces: `validateStreamingDeadlines`, deadline/group/progress index fields and bounded observe file rotation.

- [ ] **Step 1: Add failing Node tests**

Assert `10000ms` passes and `10001ms` fails independently for startup and Far. Assert missing deadline snapshots, reset Far start, target count other than `6859`, nonzero queue/fatal/audit fields and same-Tile generation changes fail with exact codes.

- [ ] **Step 2: Run Node tests and confirm RED**

Run:

```powershell
node --test clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.test.js
```

- [ ] **Step 3: Implement hard gates**

Set Full Far wait timeout to a small diagnostic margin above the hard deadline, but reject based on Root-reported monotonic elapsed time, not Node polling delay. Record both client and runner clocks.

- [ ] **Step 4: Add deadline/group progress fields**

Write Near/Far stage elapsed, remaining time, target/diff counts, priority revision, group counters, shared fence counts and the slowest stage to `index.json` and `events.jsonl`.

- [ ] **Step 5: Bound the accumulated observe file**

At writer start, rotate `voxia-transport.jsonl` when it exceeds `256MiB`, retaining at most four explicitly named previous files. Resolve and verify every path stays inside `.demo/observe/`; rotation failure is logged diagnostically but cannot corrupt the active stream.

- [ ] **Step 6: Run Node tests and focused C++ observe tests**

Expected: all pass and no unbounded log growth in a smoke run.

---

### Task 8: Performance convergence and Real-RHI acceptance

**Files:**
- Modify only the bottleneck-owning files identified by the structured run from Tasks 4–7.
- Modify: `docs/00-current-truth/design/client/streaming-lod.md`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/README.md`
- Modify: `clients/Voxia/README.md`
- Modify: `docs/10-active/voxel-far-field/2026-08-16-full-far-sparse-residual-convergence-optimization.md`

**Interfaces:**
- Consumes: smoke index stage metrics.
- Produces: ten-run Real-RHI evidence and current-truth documentation.

- [x] **Step 1: Compile and run the complete automation suite**

Run the existing Unreal build command from `clients/Voxia/README.md`, then `Automation RunTests Voxia; Quit`. Fix only observed regressions in the owning boundary.

- [x] **Step 2: Run one 1280×720 Real-RHI Full Far smoke**

```powershell
node clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.js --full-far-only --res 1280x720
```

Expected hard gate: Near `<=10000ms`, Far `<=10000ms`, exact `33725/6859`, clean coverage/parity/resources.

- [x] **Step 3: Use stage evidence for bounded tuning**

If the hard gate fails, change only the measured owner:

- build over budget: adjust hardware-derived provider/surface parallelism or remove a demonstrated duplicate build/cache miss;
- presentation over budget: adjust group cap within `1..256` or publication slice within `0.25..16ms` while preserving frame and fence tests;
- GameThread hitch over budget: reduce per-frame child visibility commits without restoring per-Patch fences.

After every change rerun the focused unit test and one Real-RHI smoke. Do not lower target counts, skip audits or enlarge the 10-second contract.

Measured owner on 2026-08-17: Near completed in `5.637s`; Far manifest arrived at `+8.132s`, then the
singleton boundary future and same-live-snapshot boundary conflicts limited groups to `1–2` children
(`105/6859` committed at the deadline). Implement the documented ordered projected-ledger group and bounded
boundary-build window before changing any deadline or target count. Add RED tests for a forward-dependent Far
pair, shared-batch final after-image, continuous-prefix-only harvesting, and more than two children per group.

- [x] **Step 4: Run ten independent cold starts**

Run the smoke ten times in fresh processes. Save every run directory and create an aggregate JSON containing min/p50/p95/max; acceptance requires every Near and every Far value `<=10000ms`.

- [x] **Step 5: Verify full incremental routes**

Run fixed camera, continuous camera rotation, same-Tile movement, X/Y/Z adjacent crossings, combined-axis crossing, negative coordinates and rapid reversal. Assert same-Tile target generation remains stable and crossings report only retained/entered/exited diff work within `10s`.

- [x] **Step 6: Update current truth and README files**

Document only measured results and exact `.demo/observe/<run-id>/` evidence. Explicitly retain the distinction that RuntimeMock success does not prove Online provider/server completion.

- [x] **Step 7: Run final verification**

Run Node tests, complete `Automation RunTests Voxia`, one final Real-RHI smoke, `git diff --check` in both repositories, and inspect `git status --short` to ensure unrelated user changes remain intact.

## Implementation result (2026-08-18)

本计划的八项任务已经落地。最终生产路径没有减少目标、放宽 10 秒合同或增加第二生产根：

- Near 的完整目标仍为 `27 tiles / 216 patches / 9261 chunks`。Root 只在同一 TargetKey 的
  patch coverage、CPU mesh 异步队列和 settled revalidation 都完成后锁存
  `near_entry_gate_satisfied`，随后才开放玩家输入并启动 Far deadline；
- Full Far 从启动起只建立一个 `33725 pages / 6859 patches` 目标。Near 阶段可以利用空闲容量
  预构建，但 Near 入场门未锁存前不能可见发布；入场后继续消费同一代结果，不重建第二份计划；
- pending 按距离绝对优先、相机夹角次优先、XYZ 稳定兜底排序。相机变化只重排 pending，
  不取消 in-flight/ready/presentation，也不重置 deadline；
- SceneHost 使用有序投影 ledger，把连续前缀聚合为最多 `256` 个 child 的 group，并共享一对
  staging/post fence；每个 child 的 TargetKey、PatchVersion、read-set、commit serial 和 receipt
  仍独立。发布软预算最终取 `16ms`，这是结构化计时证明后的实现值；
- Far pending 队列改为排序数组加游标，终态检查改为 O(1) required-work 计数，删除了原先每弹出
  一项重扫剩余队列、每个候选重建完整快照的 O(n²) 热路径；
- 同 Tile 不创建新完整目标；跨 Tile 继续使用完整 XYZ retained/entered/exited 差集。
- Far planner 按上一层实际 coverage 而非名义边界剔除 coarse pages，并用固定 overlap guard
  维持平移不变量；默认五层始终为 `702/4184/15113/7677/6049 = 33725 pages`。

1280×720 Real-RHI 十次独立冷启动全部通过：

| 阶段 | min | p50 | p95 / max | 平均 |
|---|---:|---:|---:|---:|
| Near | `7487ms` | `7871.5ms` | `8240ms` | `7846.1ms` |
| Far（从入场起） | `8630ms` | `8750ms` | `9373ms` | `8805.4ms` |
| 总计 | `16219ms` | `16560ms` | `17319ms` | `16651.5ms` |

每轮终态均为 `33725 pages / 6859 patches / 28 groups`，mailbox、ready、in-flight、fatal 与
producer queue 全部为 `0`，coverage clean、resources quiescent、settled 均为真。十轮原始
产物与汇总位于 `.demo/observe/voxia_near_far_10run_2026-08-18_final/`。相邻 +Y 的独立
Real-RHI 路线另在 `.demo/observe/voxia_phase1_2026-08-17T16-44-12-884Z_real_rhi_1280x720/`
证明 Near `3087/3087/6174` 与 Far `6618/241/241` 的精确差分分别于 `2962/7648ms` 收敛，
移动后的 Full Far 仍为 `33725/6859`。

最终验证：Development build 成功；Node `184/184`；完整 `Automation RunTests Voxia`
`224/224`，失败、未运行和进行中均为 `0`。这些证据证明的是本机 Real-RHI + RuntimeMock
生产根，不替代 Online authority/provider、服务端 page 传输或更多硬件矩阵的后续验收。
