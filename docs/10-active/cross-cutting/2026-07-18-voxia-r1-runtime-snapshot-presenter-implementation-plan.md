# Voxia R1 统一根运行时快照与 Presenter 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让唯一生产根每次观察只采集一次 live 状态，再由纯 presenter 生成 probe、full snapshot 与 observe fields，同时保持现有 JSON/事件合同逐字段等价。

**Architecture:** `AVoxiaUnifiedVoxelWorldActor` 继续独占 spawn、bind、Tick、commit 和 flow notification，只新增一个私有采样边界。`FVoxiaUnifiedWorldRuntimeSnapshot` 保存本次观察的纯值；`FVoxiaUnifiedWorldRuntimePresenter` 不依赖 Actor/Subsystem，只读取快照并生成字符串或字段 map。

**Tech Stack:** Unreal Engine 5.8、C++20、Unreal Automation、`FString`、`TMap`、现有 Gameplay/Observe 合同。

## Global Constraints

- 不改 root contract `voxia_unified_voxel_world_root_v4`、authority observe contract `voxia_authority_stream_v1`、字段名、类型、phase label 或 event 名。
- 不改 safe-view、overdue、readiness、coverage、generation、source authorization、near/far renderer 或 worker 行为。
- 不改变 `AVoxiaUnifiedVoxelWorldActor` 的 UCLASS 名、唯一 owner 槽、GameMode/flow 入口或任何地图/资产。
- probe 继续是轻量路径，不得展开 near/far 大快照；full snapshot 才采集模块 JSON。
- 新增/修改注释使用中文；每个实现步骤遵循 RED→GREEN。

---

### Task 1: 定义冻结快照与 presenter 输出合同

**Files:**
- Create: `Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeSnapshot.h`
- Create: `Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenter.h`
- Create: `Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenter.cpp`
- Create: `Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimePresenterAutomationTest.cpp`
- Consume: `Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeContract.h`

**Interfaces:**
- Produces: `FVoxiaUnifiedWorldRuntimeSnapshot`，包含 ready/session、composition/source authorization、proof/coverage、player、near/far center、staging、authority action、readiness、source/session identity、nested JSON 与 state/root error。
- Produces: `FVoxiaUnifiedWorldRuntimePresenter::Phase`、`AuthorityCoverageJson`、`ProbeJson`、`SnapshotJson`、`RootObserveFields`、`AuthorityObserveFields`。

- [x] **Step 1: 写 presenter 精确输出 Automation 测试**

  构造固定 snapshot，逐字节断言 phase label 与 probe/full JSON；逐字段断言 root/authority observe maps。测试必须覆盖 initial/loading、preparing、safe-view、overdue、ready、failed 的既有 R0 门禁。

- [x] **Step 2: 编译并确认 RED**

  Expected: snapshot/presenter 头文件不存在。

- [x] **Step 3: 实现最小纯 presenter**

  复用 R0 `FVoxiaUnifiedWorldRuntimeContract::DeriveStreamingPhase`；JSON helper 暂时只服务本 presenter，R3 才统一模块 JSON 基础设施。

- [x] **Step 4: 运行 `Voxia.Gameplay.UnifiedWorldRuntimePresenter` 并确认 GREEN**

### Task 2: 将根接入单次采样边界

**Files:**
- Modify: `Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h`
- Modify: `Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp`

**Interfaces:**
- Produces: private `CaptureRuntimeSnapshot(bool bIncludeModuleJson) const`。
- Produces: private `ResolveStreamingPending(...) const`，只消费本次已采集 proof/player/near/far 值；不重复查 live actor。
- Consumes: presenter 的 probe/full/observe 投影。

- [x] **Step 1: 增加 actor 接入特征断言并确认 RED**

  扩展 presenter/root contract test，要求 probe/full/observe 全部来自同一 snapshot 字段组合，并保留 module-json 轻重路径。

- [x] **Step 2: 实现一次采样**

  proof、player、near/far center、staging、source/session、readiness、error 各采集一次；`IsReady` 改为读取同一快照派生值，避免递归。

- [x] **Step 3: 替换重复投影**

  `ProbeJson`、`SnapshotJson`、`EmitState`、`EmitAuthorityStreamState` 只调用采样器与 presenter；删除 Actor 内重复 phase 三元、`AuthorityCoverageJson` 和重复 JSON 拼接。

- [x] **Step 4: 编译并运行 focused tests**

  Run: `Automation RunTests Voxia.Gameplay.UnifiedWorldRuntimePresenter`

  Run: `Automation RunTests Voxia.Gameplay.UnifiedWorldRuntimeContract`

  Run: `Automation RunTests Voxia.Gameplay.VoxelWorldComposition`

  Expected: 全部 `Success`。

### Task 3: 合同与生产根 smoke 验证

**Files:**
- Modify: `README.md`
- Modify: `Source/Voxia/Gameplay/README.md`
- Modify: `Source/Voxia/Debug/README.md`
- Modify: `docs/10-active/cross-cutting/2026-07-18-voxia-industrial-code-review-and-remediation-design.md`

- [x] **Step 1: 运行 Development build 与全量 Automation**

  Expected: build exit 0；测试数不少于 73；全部 Success、0 test warning/error。

- [x] **Step 2: 运行 Null-RHI phase1 全路线**

  Run: `node scripts/run_phase1_world_lifecycle_smoke.js --null-rhi --res 1280x720`

  Expected: 25 条路线通过；唯一根、staging/safe-view/recovery、clean exit 和 release drain 语义不变。

- [x] **Step 3: 对照 R0 fixture 审计 CLI/observe**

  比较 `help`、unknown、`client_flow_probe`、`voxel_world_root_state`、authority stream events；只允许字段顺序差异，不允许 token、顶层语义、字段或类型差异。

- [x] **Step 4: 更新 README/进度并运行 `git diff --check`**

- [x] **Step 5: 分仓提交**

  Client commit: `refactor(governance): project root state from one snapshot`

  Outer docs commit: `docs(voxia): record R1 snapshot presenter`

  Actual client commit: `1875183`。

## 验证证据

- Presenter RED：缺少 `VoxiaUnifiedWorldRuntimePresenter.h`，证明新测试先于实现失败。
- Presenter GREEN：`Voxia.Gameplay.UnifiedWorldRuntimePresenter` Success，证据位于
  `.demo/observe/voxia_governance_r1_presenter_green_20260718/`。
- Development build：固定 AutoSDK 与 MSVC 14.50 工具链下 `Result: Succeeded`。
- 全量 Automation：`73/73 Success`、0 failure、0 warning，证据位于
  `.demo/observe/voxia_governance_r1_automation_20260718/`。
- Null-RHI 唯一生产根：25 条生命周期路线通过，证据位于
  `.demo/observe/voxia_phase1_2026-07-18T15-43-14-725Z_null_rhi_1280x720/`。
