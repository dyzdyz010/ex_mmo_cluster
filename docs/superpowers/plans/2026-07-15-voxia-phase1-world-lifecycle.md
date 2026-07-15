# Voxia Phase 1 World Rendering and Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成 Voxia 阶段 1 的唯一 Mock 世界入口、共享世界快照、完整 XYZ near/far 生命周期、safe-view、加载/恢复 UI、材质族、CLI/日志与 Real-RHI 验收。

**Architecture:** `UVoxiaClientFlowSubsystem` 拥有跨 world 的 session 与流程状态，`AVoxiaUnifiedVoxelWorldActor` 是唯一 world-scoped 协调根；near/far 保留现有 renderer，但必须绑定同一 `FVoxiaClientWorldSnapshot`，并由根级 coverage generation、presentation proof 与 safe-view 门禁联合提交。流程 UI 是 viewport Slate overlay；相机只在最终 POV 发布点保持 last-safe view。

**Tech Stack:** Unreal Engine 5.8 C++、Slate/UMG、`UGameInstanceSubsystem`、`APlayerCameraManager`、Automation Framework、Node.js stdio CLI、PowerShell/Node Real-RHI harness。

## Global Constraints

- 只修改 `clients/Voxia` 与本阶段文档；不修改 `apps/**`、wire、HTTP、Web/Bevy。
- 唯一生产组合根是 `AVoxiaUnifiedVoxelWorldActor`；probe 不得成为验收入口。
- 完整 XYZ：near `3×3×3=27 tiles=9261 chunks`；单轴跨 tile 时 entered/exited=`3087`、retained=`6174`。
- Stage 1 snapshot 只读，`confirmed_revision=0` 仅是接口占位；编辑返回 `feature_not_available_phase2`。
- WorldGen/local disk 都必须冻结 source identity；local disk 在入场前通过 manifest/H gate；禁止 provider fallback。
- 新功能必须先有失败 automation，再写 production code；代码注释使用中文。
- 每个切片必须同时有 automation、CLI/结构化日志和独立 commit。
- 最终验收只认唯一 near+far 根的 Real-RHI；`-VoxiaNearWindowOnly` 仅诊断。

---

### Task 1: P1-A Session, flow state, and observe contract

**Files:**
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSession.h`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSession.cpp`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSessionAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelWorldSourceIdentity.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelWorldSourceIdentity.cpp`

**Interfaces:**
- Produces: `FVoxiaClientWorldSnapshot`, `FVoxiaClientWorldSessionState`, `EVoxiaClientFlowPhase`, `FVoxiaClientFlowMachine`。
- Snapshot fields: `SessionId`, `RuntimeProfile`, `SourceIdentity`, `WorldSnapshotId`, `ConfirmedRevision=0`, `AuthorityKind`。

- [ ] **Step 1: Write the failing session automation**

```cpp
FVoxiaClientFlowMachine Flow;
const FVoxiaClientWorldSnapshot Snapshot = MakeWorldGenSnapshot(TEXT("session-a"));
TestTrue(TEXT("new game binds one immutable snapshot"), Flow.StartSession(Snapshot, Error));
TestFalse(TEXT("second session is rejected while active"), Flow.StartSession(Snapshot, Error));
TestTrue(TEXT("explicit hard error fails immediately"), Flow.Fail(TEXT("provider_invalid"), 1.0));
TestTrue(TEXT("retry is single flight"), Flow.BeginRetry(2.0, Error));
TestFalse(TEXT("parallel retry is rejected"), Flow.BeginRetry(2.1, Error));
TestEqual(TEXT("editing is deferred"), Flow.FeatureGate(TEXT("voxel_edit")), FString(TEXT("feature_not_available_phase2")));
```

- [ ] **Step 2: Run RED**

Run from `clients/Voxia`:

```powershell
& 'D:\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' .\Voxia.uproject -unattended -nop4 -nosplash -NullRHI -ExecCmds='Automation RunTests Voxia.Gameplay.ClientWorldSession;Quit' -TestExit='Automation Test Queue Empty'
```

Expected: compile/test failure because `VoxiaClientWorldSession` does not exist.

- [ ] **Step 3: Implement the pure model**

```cpp
enum class EVoxiaClientFlowPhase : uint8
{
    Bootstrapping, InitialLoading, Playable, Streaming, SafeViewHold,
    StreamingRecoveryLoading, Retrying, Leaving, MenuIdle, Failed
};

struct FVoxiaClientWorldSnapshot
{
    FString SessionId;
    FString RuntimeProfile = TEXT("mock");
    FVoxiaVoxelWorldSourceIdentity SourceIdentity;
    FString WorldSnapshotId;
    uint64 ConfirmedRevision = 0;
    FString AuthorityKind;
    bool Validate(FString& OutError) const;
    FString SnapshotJson() const;
};

class FVoxiaClientFlowMachine
{
public:
    bool StartSession(const FVoxiaClientWorldSnapshot& Snapshot, FString& OutError);
    bool MarkRootLoading(uint64 Generation, double NowSeconds, FString& OutError);
    bool MarkPlayable(uint64 Generation, double NowSeconds, FString& OutError);
    bool BeginRetry(double NowSeconds, FString& OutError);
    bool MarkRetryProgress(uint64 ProgressEpoch, double NowSeconds);
    bool BeginLeaving(double NowSeconds, FString& OutError);
    bool CompleteLeaving(bool bClean, double NowSeconds, FString& OutError);
    bool Fail(const FString& Reason, double NowSeconds);
    FString FeatureGate(const FString& Feature) const;
    FVoxiaClientWorldSessionState Snapshot() const;
};
```

WorldGen identity includes frozen algorithm/version/seed/config fingerprint; local disk keeps expected identity and H. `Validate` rejects unresolved identity and revision other than zero.

- [ ] **Step 4: Run GREEN and focused regression**

Run the Task 1 command, then run `Voxia.Gameplay.VoxelWorldComposition` and `Voxia.Voxel.CanonicalVoxelPageProvider` separately. Expected: all selected tests succeed.

- [ ] **Step 5: Commit nested repo**

```powershell
git add Source/Voxia/Gameplay/VoxiaClientWorldSession* Source/Voxia/Gameplay/VoxiaVoxelWorldSourceIdentity.*
git commit -m 'feat(flow): add immutable mock world session state'
```

### Task 2: P1-B GameInstance flow and shared root snapshot binding

**Files:**
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientFlowSubsystem.h`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientFlowSubsystem.cpp`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientFlowSubsystemAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientGameMode.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h/.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldActor.h/.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.h/.cpp`

**Interfaces:**
- Consumes: Task 1 `FVoxiaClientWorldSnapshot` and `FVoxiaClientFlowMachine`。
- Produces: `StartNewGame`, `Retry`, `ReturnToMenu`, `RegisterRoot`, `SnapshotJson` and root `BindWorldSnapshot`。

- [ ] **Step 1: Write failing binding tests**

```cpp
TestTrue(TEXT("flow creates exactly one active session"), Harness.StartNewGame(Error));
TestTrue(TEXT("root receives snapshot before child BeginPlay"), Harness.RootSnapshotBound());
TestTrue(TEXT("near and far report the same snapshot id"), Harness.ChildSnapshotIdsMatch());
TestFalse(TEXT("unresolved local disk H cannot spawn root"), RejectedHarness.StartNewGame(Error));
TestEqual(TEXT("rejection is diagnostic"), Error, FString(TEXT("world_snapshot_source_not_authorized")));
```

The UObject harness uses a transient `UGameInstance`/`UWorld` only where unavoidable; source binding rules remain in a pure helper so the test does not mock renderer behavior.

- [ ] **Step 2: Run RED**

Run `Automation RunTests Voxia.Gameplay.ClientFlowSubsystem`. Expected: missing subsystem/binding symbols.

- [ ] **Step 3: Implement flow ownership and deferred child spawn**

```cpp
UCLASS()
class VOXIA_API UVoxiaClientFlowSubsystem final : public UGameInstanceSubsystem
{
    GENERATED_BODY()
public:
    bool StartNewGame(UWorld* World, FString& OutError);
    bool Retry(UWorld* World, FString& OutError);
    bool ReturnToMenu(UWorld* World, FString& OutError);
    void RegisterRoot(AVoxiaUnifiedVoxelWorldActor* Root);
    void UnregisterRoot(const AVoxiaUnifiedVoxelWorldActor* Root);
    const FVoxiaClientWorldSnapshot* GetWorldSnapshot() const;
    FString SnapshotJson() const;
};
```

`VoxiaClientGameMode` calls `StartNewGame` only for `UnifiedProduction`; probe/online compatibility keep their explicit old routes. Root uses `SpawnActorDeferred` for near/far, calls `BindWorldSnapshot` before `FinishSpawning`, and rejects any child whose snapshot/source fingerprint differs. For WorldGen, near verifies the frozen seed/config fingerprint before transport prepare; for local disk, Stage 1 refuses playable until the same verified source identity is reported by both adapters. No fallback is allowed.

- [ ] **Step 4: Run GREEN, build, and smoke root JSON**

Run the focused automation, build `VoxiaEditor Win64 Development -NoLiveCoding`, then launch Null-RHI CLI and assert:

```json
{"contract":"voxia_unified_voxel_world_root_v4","session_id":"...","world_snapshot_id":"...","confirmed_revision":0,"source_consumption":{"near":"root_world_snapshot","far":"root_world_snapshot"}}
```

- [ ] **Step 5: Commit nested repo**

```powershell
git add Source/Voxia/Gameplay/VoxiaClientFlowSubsystem* Source/Voxia/Gameplay/VoxiaClientGameMode.cpp Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.* Source/Voxia/Gameplay/VoxiaWorldActor.* Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.*
git commit -m 'feat(flow): bind the unified root to one world snapshot'
```

### Task 3: P1-C XYZ scheduler, root presentation proof, and safe-view

**Files:**
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler.h/.cpp`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageSchedulerAutomationTest.cpp`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldPresentationProof.h/.cpp`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldPresentationProofAutomationTest.cpp`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaSafeViewGuard.h/.cpp`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaSafeViewGuardAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h/.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCameraManager.h/.cpp`

**Interfaces:**
- Scheduler returns `FVoxiaWorldCoveragePlan { Generation, DesiredCenter, Bands, bImmediate }`。
- Root proof exposes `IsCommittedForTile`, `GapCount`, `OverlapCount`, `StaleCommitCount`, `ProgressEpoch`。
- Safe-view returns `Safe`, `Hold`, `SoftNotify`, `HardFail`, or `Recovered`。

- [ ] **Step 1: Write three failing pure automations**

```cpp
TestEqual(TEXT("single X tile retains 18 near tiles"), Plan.Near.RetainedTiles, 18);
TestEqual(TEXT("single Y tile enters 9 near tiles"), Plan.Near.EnteredTiles, 9);
TestEqual(TEXT("single Z tile exits 9 near tiles"), Plan.Near.ExitedTiles, 9);
TestFalse(TEXT("near-only readiness cannot commit"), Proof.TryCommit(NearOnly, Error));
TestTrue(TEXT("matching near/far/fence commits"), Proof.TryCommit(Complete, Error));
TestEqual(TEXT("250ms emits soft notify"), Guard.Evaluate(false, 0.250).Action, EVoxiaSafeViewAction::SoftNotify);
TestEqual(TEXT("2s becomes hard recovery"), Guard.Evaluate(false, 2.000).Action, EVoxiaSafeViewAction::HardFail);
```

- [ ] **Step 2: Run RED**

Run the three new automation names separately. Expected: missing pure units.

- [ ] **Step 3: Implement planner/profile and proof**

Freeze bands as near radius 1/0ms, far L0 4/0ms, L1 8/50ms, L2 24/150ms, L3 40/300ms, L4 72/600ms. Ordinary movement requires 3 stable frames; initial, teleport, retry, and source change are immediate. Each band holds one in-flight plus one latest pending.

Root commits a generation only when snapshot/revision/center match, near settled, far live, ownership ready and fence observed. Every visible proof enforces `gap=0`, `overlap=0`, `stale=0`; violations fail explicitly and retain the previous committed proof.

- [ ] **Step 4: Integrate final camera publication**

Override `AVoxiaCameraManager::DoUpdateCamera(float DeltaTime)`: call `Super`, read `GetCameraCacheView()` as the candidate, ask the unified root to evaluate it, then either `SetCameraCachePOV(LastSafeView)` or replace `LastSafeView` with the candidate. Candidate location uses the scheduler's canonical XYZ tile quantization. The guard never changes pawn transform, velocity, control rotation, or world geometry.

- [ ] **Step 5: Run GREEN and regression**

Run the three focused tests plus `Voxia.Voxel.NearVoxelWindow`, `Voxia.Gameplay.VoxelPresentationResourceSet`, and root-ready CLI smoke. Expected: all pass and root snapshot reports committed proof counters at zero.

- [ ] **Step 6: Commit nested repo**

```powershell
git add Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler* Source/Voxia/Gameplay/VoxiaWorldPresentationProof* Source/Voxia/Gameplay/VoxiaSafeViewGuard* Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.* Source/Voxia/Gameplay/VoxiaCameraManager.*
git commit -m 'feat(streaming): add root coverage proof and safe view'
```

### Task 4: P1-E viewport flow overlay, retry, menu, and CLI

**Files:**
- Create: `clients/Voxia/Source/Voxia/Gameplay/SVoxiaClientFlowOverlay.h/.cpp`
- Create: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientFlowViewModelAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientFlowSubsystem.h/.cpp`
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp`
- Modify: `clients/Voxia/scripts/voxia_stdio_cli.js`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPawn.cpp`

**Interfaces:**
- Overlay consumes an immutable `FVoxiaClientFlowViewModel` and emits only `OnRetry`, `OnReturnToMenu`, `OnStartNewGame`, `OnExit` delegates。
- CLI commands: `client_flow_state`, `client_flow_retry`, `client_flow_return_to_menu`, `client_flow_start_new_game`, `until_client_playable`, `safe_view_state`, `voxel_streaming_profile`。

- [ ] **Step 1: Write failing view-model/command tests**

```cpp
TestEqual(TEXT("loading is UI-only"), Loading.InputMode, EVoxiaClientInputMode::UiOnly);
TestEqual(TEXT("playable is game-only"), Playable.InputMode, EVoxiaClientInputMode::GameOnly);
TestTrue(TEXT("recovery exposes two actions"), Recovery.bShowRetry && Recovery.bShowReturnToMenu);
TestFalse(TEXT("retrying disables retry"), Retrying.bRetryEnabled);
TestFalse(TEXT("stage one hides edit affordance"), Playable.bShowVoxelEdit);
```

- [ ] **Step 2: Run RED**

Run `Automation RunTests Voxia.Gameplay.ClientFlowViewModel`. Expected: missing view model.

- [ ] **Step 3: Implement overlay and input projection**

Create one `SWeakWidget` wrapper through `UGameViewportClient::AddViewportWidgetContent`; update visibility/text/button state from the pure view model. Remove the widget during subsystem deinitialization. Use `SetInputMode(FInputModeUIOnly)` for loading/recovery/menu and `SetInputMode(FInputModeGameOnly)` only for playable/streaming.

Initial loading shows phase/progress/error; soft safe-view shows a non-blocking sync label; hard recovery shows Retry/Return; menu shows New Game/Exit. `VoxiaPawn` edit actions consult `FeatureGate` and emit `feature_not_available_phase2` without changing voxel data.

- [ ] **Step 4: Wire CLI and stdio waiter**

`client_flow_state` returns session/snapshot/root phase/progress/error/retry/safe-view. Actions return `ok=false` with `retry_in_flight`, `no_active_session`, or the exact hard error. JS caches `client_flow_state` and resolves `until_client_playable` only when phase is `playable|streaming`, root proof is committed, centers align, and error is empty.

- [ ] **Step 5: Run GREEN and action smoke**

Run the focused automation; then CLI sequence: `until_client_playable 300000; client_flow_state; client_flow_return_to_menu; client_flow_state; client_flow_start_new_game; until_client_playable 300000`. Expected phases: playable, menu_idle, playable; exactly one root after new game.

- [ ] **Step 6: Commit nested repo**

```powershell
git add Source/Voxia/Gameplay/SVoxiaClientFlowOverlay.* Source/Voxia/Gameplay/VoxiaClientFlowSubsystem.* Source/Voxia/Gameplay/VoxiaClientFlowViewModelAutomationTest.cpp Source/Voxia/Gameplay/VoxiaPawn.cpp Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp scripts/voxia_stdio_cli.js
git commit -m 'feat(ui): add phase one loading recovery and menu flow'
```

### Task 5: P1-D material families, patch budgets, and full oracle

**Files:**
- Create: `clients/Voxia/Source/Voxia/Voxel/VoxiaVoxelMaterialFamily.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/VoxiaVoxelMaterialFamilyAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarFieldDynamicMesh.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.h/.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.h/.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.h/.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilderAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationResourceSetAutomationTest.cpp`

**Interfaces:**
- `VoxelMaterialFamily(uint16)` maps 4/8/9 to translucent, 6/7/13/14/15/19/21 to emissive, remaining solid IDs to opaque。
- DynamicMesh triangle material slots are 0 opaque, 1 translucent, 2 emissive。
- Scene host accepts three `UMaterialInterface*` values and reports material histograms plus budget decisions。

- [ ] **Step 1: Write failing family, mesh, and budget tests**

```cpp
TestEqual(TEXT("water is translucent"), VoxelMaterialFamily(8), EVoxiaVoxelMaterialFamily::Translucent);
TestEqual(TEXT("lava is emissive"), VoxelMaterialFamily(15), EVoxiaVoxelMaterialFamily::Emissive);
TestEqual(TEXT("stone is opaque"), VoxelMaterialFamily(2), EVoxiaVoxelMaterialFamily::Opaque);
TestTrue(TEXT("dynamic mesh enables material IDs"), Mesh.Attributes()->HasMaterialID());
TestFalse(TEXT("over-budget patch is rejected before stage"), Host.ValidatePatchBudget(TooLarge, Error));
```

- [ ] **Step 2: Run RED**

Run `Voxia.Voxel.VoxelMaterialFamily`, the canonical scene-builder test, and resource-set test. Expected failures identify missing family slots and budget rejection.

- [ ] **Step 3: Implement three material slots**

`FVoxiaFarFieldDynamicMeshBuilder` enables `MaterialID` and assigns each two-triangle quad from `QuadMaterial`. Pure3D loads `M_VoxelWorldAligned`, `M_VoxelTranslucent`, and `M_VoxelEmissive`; scene host sets all three on every component. Patch fingerprint and stage JSON include material histogram, family policy version, and algorithm version so retained components cannot cross an incompatible material policy.

- [ ] **Step 4: Add frozen budgets and exact oracle**

Expose patch component/quad/vertex/bytes ceilings, live/hidden/retiring counts, queue depth, cancellation quantum, GT stage/commit/retire timings. Reject before hidden publish. The automation full oracle compares coverage owner, surface fingerprint, quad/vertex counts, material histogram, patch keys, gap and overlap for clean-full versus incremental output.

- [ ] **Step 5: Run GREEN and Real-RHI material audit**

Run focused automations, capture 1280×720 and 1600×900 screenshots from the production root, and query root JSON. Expected: all three family counts are present in the generated fixture, `gap=overlap=stale=0`, and no budget rejection in the default profile.

- [ ] **Step 6: Commit nested repo**

```powershell
git add Source/Voxia/Voxel/VoxiaVoxelMaterialFamily* Source/Voxia/FarField/VoxiaFarFieldDynamicMesh.cpp Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.* Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.* Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder* Source/Voxia/Gameplay/VoxiaVoxelPresentationResourceSetAutomationTest.cpp
git commit -m 'feat(rendering): preserve voxel material families in far LOD'
```

### Task 6: P1-F deterministic route harness and production-root acceptance

**Files:**
- Create: `clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.js`
- Modify: `clients/Voxia/scripts/voxia_stdio_cli.js`
- Modify: `clients/Voxia/Source/Voxia/Debug/README.md`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/README.md`

**Interfaces:**
- Harness writes `.demo/observe/voxia_phase1_<timestamp>/index.json`, engine log, event JSONL, screenshots, frame summaries and resource-soak samples。
- Routes: birth, positive/negative X/Y/Z, diagonal, multi-tile, A-B-A, ground-high-ground, teleport, retry, return-menu-new-game。

- [ ] **Step 1: Write the failing harness assertions**

```javascript
assert.equal(root.single_composition_root, true);
assert.equal(root.presentation_proof.gap_count, 0);
assert.equal(root.presentation_proof.overlap_count, 0);
assert.equal(root.presentation_proof.stale_commit_count, 0);
assert.ok(frame.frame_ms.p95 <= 8.33);
assert.equal(frame.over_16_67ms, 0);
assert.ok(!soak.monotonic_growth_detected);
```

- [ ] **Step 2: Run RED against the current executable**

Run `node scripts/run_phase1_world_lifecycle_smoke.js --null-rhi --short`. Expected: missing flow/root proof/material/budget fields or waiter commands.

- [ ] **Step 3: Implement route driver and machine summary**

Use stdio commands only; do not infer success from screenshots. For each route step, wait for `until_client_playable`, record desired/live centers, generation, queue, lease, retiring, safe-view and frame data. A-B-A must compare snapshot/source/material fingerprints. The 30-minute mode samples resource counters every 10 seconds and rejects monotonic growth.

- [ ] **Step 4: Run full automation and build**

```powershell
& 'D:\Epic Games\UE_5.8\Engine\Build\BatchFiles\Build.bat' VoxiaEditor Win64 Development .\Voxia.uproject -WaitMutex -FromMsBuild -NoLiveCoding
& 'D:\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' .\Voxia.uproject -unattended -nop4 -nosplash -NullRHI -ExecCmds='Automation RunTests Voxia;Quit' -TestExit='Automation Test Queue Empty'
```

Expected: build exit 0; active Voxia suite has zero failures. Archived test namespaces must not contain `Voxia`.

- [ ] **Step 5: Run CLI/Null-RHI and Real-RHI matrices**

```powershell
node scripts/run_phase1_world_lifecycle_smoke.js --null-rhi
node scripts/run_phase1_world_lifecycle_smoke.js --real-rhi --res 1280x720
node scripts/run_phase1_world_lifecycle_smoke.js --real-rhi --res 1600x900 --soak-minutes 30
```

Expected: all route assertions pass; p95 at or below 8.33ms; no streaming-caused frame above 16.67ms; per-band queue at most 1; no monotonic resource leak. If performance misses, use `superpowers:systematic-debugging`, fix the cause with a failing regression, and repeat.

- [ ] **Step 6: Commit nested repo**

```powershell
git add scripts/run_phase1_world_lifecycle_smoke.js scripts/voxia_stdio_cli.js Source/Voxia/Debug/README.md Source/Voxia/Gameplay/README.md
git commit -m 'test(voxia): add phase one production-root acceptance'
```

### Task 7: Documentation closeout and manual launch

**Files:**
- Modify: `docs/00-current-truth/design/client/streaming-lod.md`
- Modify: `docs/10-active/cross-cutting/2026-07-15-voxia-phase1-world-rendering-lifecycle-prd.md`
- Modify: `docs/10-active/cross-cutting/_session-handoff.md`
- Create: `docs/20-archive/client/2026-07-15-voxia-phase1-world-lifecycle-closeout.md`
- Modify: `clients/Voxia/scripts/launch_worldgen_preview.js` only if the verified production launch arguments changed。

- [ ] **Step 1: Record exact evidence**

Write commit IDs, build/automation counts, CLI route results, Real-RHI resolutions, p50/p95/p99/max, safe-view/retry/menu outcomes, artifact paths and residual risks. Do not promote Stage 2 editing or Stage 3 prefab.

- [ ] **Step 2: Update PRD status and current truth**

Change PRD from `review` to `complete` only after every Task 6 gate passes. Current-truth must describe user-visible capability first, then implementation evidence. Move the closed phase log to archive while keeping current-truth links.

- [ ] **Step 3: Verify both repositories and commit outer docs**

```powershell
git -C clients/Voxia status --short --branch
git diff --check
git add docs/00-current-truth/design/client/streaming-lod.md docs/10-active/cross-cutting/2026-07-15-voxia-phase1-world-rendering-lifecycle-prd.md docs/10-active/cross-cutting/_session-handoff.md docs/20-archive/client/2026-07-15-voxia-phase1-world-lifecycle-closeout.md
git commit -m 'docs(voxia): close phase one world lifecycle'
```

Expected: nested implementation branch clean; outer repo contains only the planned documentation changes.

- [ ] **Step 4: Final fresh verification**

Re-run the build, focused phase suite, production CLI short route, and a 1280×720 Real-RHI smoke after all commits. Read the fresh outputs before claiming completion.

- [ ] **Step 5: Launch for user confirmation**

Run `node scripts/launch_worldgen_preview.js` from the verified Voxia checkout with a visible window. Confirm the process is alive and the log reaches `playable`; leave the program open for manual user review.

---

## Plan Self-Review

- Spec coverage: Tasks 1–7 cover PRD sections 2–14; no server/wire/archive-client work is introduced.
- Type consistency: session snapshot is created by flow, bound before child BeginPlay, consumed by root/scheduler/proof/UI/CLI。
- TDD order: every production unit has a named RED command before implementation and a GREEN/regression command after。
- Evidence: automation, CLI/log, Null-RHI, two Real-RHI resolutions, 30-minute soak, docs and manual launch are all explicit。
- Scope: Stage 2 edit/overlay and Stage 3 prefab remain deferred; edit input only returns the phase gate error。

## Execution Mode

The user explicitly selected autonomous inline execution. Use `superpowers:executing-plans` task-by-task in an isolated Voxia worktree; stop only for an actual external blocker or a critical plan contradiction.

## File Map

### New focused units

- `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSession.h/.cpp`：只读 session/snapshot、flow phase 与 retry single-flight 纯状态机。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientWorldSessionAutomationTest.cpp`：session、硬失败、重试和 leaving 语义。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientFlowSubsystem.h/.cpp`：GameInstance 生命周期、root spawn/destroy、流程 overlay 与命令。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler.h/.cpp`：完整 XYZ band profile、稳定帧/coalesce、latest-pending 纯规划。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageSchedulerAutomationTest.cpp`：正负 XYZ、斜向、teleport、各 band cadence。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldPresentationProof.h/.cpp`：根级 near/far generation、ownership/fence、gap/overlap/stale proof。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldPresentationProofAutomationTest.cpp`：全有或全无与 stale reject。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaSafeViewGuard.h/.cpp`：250ms/2s 的纯状态机。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaSafeViewGuardAutomationTest.cpp`：安全、soft、hard、恢复路径。
- `clients/Voxia/Source/Voxia/Gameplay/SVoxiaClientFlowOverlay.h/.cpp`：加载、恢复、重试、主菜单 Slate overlay。
- `clients/Voxia/Source/Voxia/Voxel/VoxiaVoxelMaterialFamily.h`：材质 ID 到 opaque/translucent/emissive 的唯一映射。
- `clients/Voxia/Source/Voxia/Voxel/VoxiaVoxelMaterialFamilyAutomationTest.cpp`：family 和 slot 映射。
- `clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.js`：唯一根的完整 XYZ CLI/Real-RHI 路线与机器汇总。

### Existing integration points

- `Gameplay/VoxiaClientGameMode.cpp`：统一生产模式改由 flow subsystem 创建 session/root。
- `Gameplay/VoxiaUnifiedVoxelWorldActor.h/.cpp`：绑定 snapshot、维护 root phase/proof/progress/error/retry/safe-view。
- `Gameplay/VoxiaWorldActor.h/.cpp`：显式绑定 root snapshot，验证 near WorldGen source identity。
- `Gameplay/VoxiaPure3DVoxelWorldActor.h/.cpp`：显式绑定 snapshot、上报 desired/in-flight/live/progress/error。
- `Gameplay/VoxiaVoxelWorldSourceIdentity.h/.cpp`：WorldGen seed/config/content identity 显式化。
- `Gameplay/VoxiaVoxelPresentationSceneHost.h/.cpp`：三 material slot、per-patch budget、gap/overlap/stale 统计。
- `FarField/VoxiaFarFieldDynamicMesh.cpp`：写 triangle material ID overlay。
- `Gameplay/VoxiaCameraManager.h/.cpp`：`DoUpdateCamera` 最终 safe-view guard。
- `Debug/VoxiaDebugCliSubsystem.cpp`：阶段 1 状态与动作命令。
- `scripts/voxia_stdio_cli.js`：`until_client_playable` 与 flow state 缓存。
- `Gameplay/README.md`、`Debug/README.md`：职责、命令、状态与失败语义。
- `docs/00-current-truth/design/client/streaming-lod.md`、阶段 PRD、handoff：完成证据与残余风险。

---
