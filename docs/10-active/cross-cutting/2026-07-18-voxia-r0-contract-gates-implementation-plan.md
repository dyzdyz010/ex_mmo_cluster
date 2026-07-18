# Voxia R0 特征测试与结构门禁实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不切换任何生产调用路径的前提下，冻结统一根状态投影、CLI 合同和唯一 near/far owner 结构，为 R1～R6 提供稳定回归门禁。

**Architecture:** R0 只增加纯值 contract、可解析 JSON fixture 和 Automation 测试。运行中的 `AVoxiaUnifiedVoxelWorldActor`、`UVoxiaDebugCliSubsystem`、协议、渲染、阈值和唯一生产根均不改；R1/R2 再把现有调用点接到这些已验证 seam。

**Tech Stack:** Unreal Engine 5.8、C++20、Unreal Automation、`FJsonSerializer`、UObject reflection。

## Global Constraints

- 不改 wire codec、CLI token、顶层 `ok` 语义、JSON 合同字段或 observe event 名称。
- 不改 safe-view/overdue 阈值、readiness、spawn、Tick、commit、worker 或渲染行为。
- 不新增 GameMode、地图或第二生产根；probe/compatibility 继续与 `production_all_features` 隔离。
- 新增和修改的代码注释统一使用中文。
- 每个测试提交后运行定向 Automation；R0 退出前运行 Development build、全量 Voxia Automation 和 `git diff --check`。

---

### Task 1: 冻结统一根 phase 与 schema 合同

**Files:**
- Create: `Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeContract.h`
- Create: `Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeContract.cpp`
- Create: `Source/Voxia/Gameplay/VoxiaUnifiedWorldRuntimeContractAutomationTest.cpp`
- Create: `Source/Voxia/Tests/Fixtures/voxia_cli_contract_v1.json`

**Interfaces:**
- Produces: `EVoxiaUnifiedWorldStreamingPhase`，包含 `InitialLoading`、`Preparing`、`SafeViewHold`、`Overdue`、`Ready`、`Failed`。
- Produces: `FVoxiaUnifiedWorldPhaseInput`，只含 `bHasError`、`bProofCommitted`、`bHasAuthorityStreamingAction`、`AuthorityStreamingAction`、`bStagingPending`。
- Produces: `FVoxiaUnifiedWorldRuntimeContract::DeriveStreamingPhase(const FVoxiaUnifiedWorldPhaseInput&)` 与 `StreamingPhaseLabel(...)`。
- Produces: fixture 顶层 `contract/help/samples`；samples 冻结 root probe、root snapshot、authority observe、legacy reject 和 unknown command 的合同字段。

- [x] **Step 1: 写 phase 六态和 fixture schema Automation 测试**

  测试逐一断言旧实现嵌套判断对应的六个 label，并通过 `FJsonSerializer` 读取 fixture；只检查合同字段、类型和命令 token 唯一性，不检查 JSON 字段顺序、动态 id 或时间。

- [x] **Step 2: 运行定向测试并确认 RED**

  Run: `Automation RunTests Voxia.Gameplay.UnifiedWorldRuntimeContract`

  Expected: 新 test/header 尚不存在，编译或 test discovery 失败。

- [x] **Step 3: 实现最小纯值 phase contract 与 fixture**

  `DeriveStreamingPhase` 必须按当前优先级实现：error → failed；未提交 proof → initial_loading；recovery action → overdue；safe-view action → safe_view_hold；staging → preparing；否则 ready。

- [x] **Step 4: 运行定向测试并确认 GREEN**

  Run: `Automation RunTests Voxia.Gameplay.UnifiedWorldRuntimeContract`

  Expected: `Result={Success}`。

### Task 2: 冻结 CLI command catalog 合同

**Files:**
- Create: `Source/Voxia/Debug/VoxiaDebugCommandContract.h`
- Create: `Source/Voxia/Debug/VoxiaDebugCommandContract.cpp`
- Create: `Source/Voxia/Debug/VoxiaDebugCommandContractAutomationTest.cpp`
- Read: `Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp:1700`
- Read: `Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp:2129`
- Read: `Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp:3091`

**Interfaces:**
- Produces: `EVoxiaDebugCommandDomain`（`FlowRuntime`、`VoxelPresentation`、`InterestAction`、`PlayerInput`、`EnginePerf`）。
- Produces: `EVoxiaDebugCommandAvailability`（`Production`、`ArchivedLegacy`）。
- Produces: immutable `FVoxiaDebugCommandSpec { Token, Syntax, Domain, Availability, Aliases }`。
- Produces: `FVoxiaDebugCommandContract::Specs()`、`Find(Token)`、`HelpJson()`、`ArchivedLegacyRejectionJson(Token)`、`UnknownCommandJson(Token)`。

- [x] **Step 1: 写 token/help/legacy/unknown Automation 测试**

  测试断言 primary token 与 aliases 全局唯一、fixture 中每个 help token 都有 spec、九个 legacy token 均解析为 `ArchivedLegacy`、help/legacy/unknown JSON 可解析且合同字段与 fixture 一致。

- [x] **Step 2: 运行定向测试并确认 RED**

  Run: `Automation RunTests Voxia.Debug.CommandContract`

  Expected: contract 类型不存在或 test discovery 失败。

- [x] **Step 3: 从现有 HelpJson/ExecuteCommand 提取不可变 spec**

  只复制当前 token、syntax、aliases、legacy policy 和输出字段，不修改 `UVoxiaDebugCliSubsystem`；因此 R0 不改变实时 CLI 路由。

- [x] **Step 4: 运行定向测试并确认 GREEN**

  Run: `Automation RunTests Voxia.Debug.CommandContract`

  Expected: `Result={Success}`。

### Task 3: 冻结唯一生产根 owner 结构

**Files:**
- Modify: `Source/Voxia/Gameplay/VoxiaVoxelWorldCompositionAutomationTest.cpp`
- Read: `Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h`

**Interfaces:**
- Consumes: `AVoxiaUnifiedVoxelWorldActor::StaticClass()` 的 UObject reflection metadata。
- Produces: 结构断言——root 恰有一个 `AVoxiaWorldActor` owner property 和一个 `AVoxiaPure3DVoxelWorldActor` owner property；两者均由 root 类声明，且没有同类型第二槽。

- [x] **Step 1: 增加反射结构断言**

  使用 `TFieldIterator<FObjectPropertyBase>` 统计 property class；不访问对象实例、不 spawn 第二条路径。

- [x] **Step 2: 运行现有 composition test**

  Run: `Automation RunTests Voxia.Gameplay.VoxelWorldComposition`

  Expected: `Result={Success}`，现有 selector/conflict/missing-provider 断言保持不变。

### Task 4: R0 完整验证与提交

**Files:**
- Modify: `Source/Voxia/Gameplay/README.md`
- Modify: `Source/Voxia/Debug/README.md`
- Modify: `docs/10-active/cross-cutting/2026-07-18-voxia-industrial-code-review-and-remediation-design.md`

- [x] **Step 1: 更新最近 README 与进度日志**

  只记录 R0 contract/test ownership，不宣称 R1/R2 已切换生产路径。

- [x] **Step 2: 运行静态、编译和全量门禁**

  Run: `git diff --check`

  Run: `Build.bat VoxiaEditor Win64 Development -Project=<R0 worktree>/Voxia.uproject -WaitMutex`

  Run: `Automation RunTests Voxia`

  Expected: Development build exit 0；全量测试数不少于基线 70，全部 `Success`，0 test warning/error。

- [x] **Step 3: 审阅合同差异**

  对照 baseline fixture 检查 CLI token、root schema、authority observe fields 和 owner slot；确认没有 Actor/Subsystem 生产调用点变化。

- [ ] **Step 4: 分仓提交**

  Client commit: `test(governance): freeze Voxia runtime contracts`

  Outer docs commit: `docs(voxia): start approved R0 governance`
