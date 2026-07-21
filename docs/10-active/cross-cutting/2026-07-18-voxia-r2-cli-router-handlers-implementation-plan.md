# Voxia R2 CLI 目录路由与领域 handler 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans and superpowers:test-driven-development task-by-task.

**Goal:** 让 stdio CLI 的 help、可用性与领域分派只认 R0 不可变目录，把跨域长分支拆成五个显式 context handler，同时逐字段保持当前 envelope、payload、legacy observe 与 unknown 语义。

**Architecture:** `FVoxiaDebugCommandRouter` 只把 token/alias 分类为 production domain、archived legacy 或 unknown；`UVoxiaDebugCliSubsystem` 继续独占 stdin thread、队列、Tick/Pump、result id 与 envelope。Subsystem 每条命令只采集一次 `FCommandContext`，再交给 `flow/runtime`、`voxel/presentation`、`interest/action`、`player/input` 或 `engine/perf` handler；handler 不再自行查找 GameInstance 服务。

**Tech Stack:** Unreal Engine 5.8、C++20、Unreal Automation、R0 `FVoxiaDebugCommandContract`、Null-RHI stdio CLI smoke。

## 不变边界

- 不改变任何命令 token、alias、help syntax/order、顶层 `id/ok/cmd/result`、payload 字段或类型。
- 九个 archived legacy 命令继续 `ok=false`，继续发出 `voxia_legacy_far_cli_rejected`，不进入 handler。
- unknown command 继续保持顶层 `ok=true` 与 `result.unknown_command`；本阶段不重新设计这一既有语义。
- 不改变协议、Actor/Transport/Pawn 行为、流送阈值、可见效果、地图或唯一生产根。
- 触达代码的新注释与文档使用中文。

---

### Task 1：建立纯目录路由门禁

**Files:**
- Create: `Source/Voxia/Debug/VoxiaDebugCommandRouter.h`
- Create: `Source/Voxia/Debug/VoxiaDebugCommandRouter.cpp`
- Create: `Source/Voxia/Debug/VoxiaDebugCommandRouterAutomationTest.cpp`

- [x] **Step 1: 先写 catalog/alias/legacy/unknown 路由测试**

  遍历 R0 specs 与 aliases，断言 production 精确进入声明 domain、legacy 不进入 handler、unknown 稳定失败分类。

- [x] **Step 2: 编译并确认 RED**

  Expected: 缺少 `VoxiaDebugCommandRouter.h`。

- [x] **Step 3: 实现最小纯 router 并确认 GREEN**

  Router 不持有 UObject，不执行命令，不生成 envelope。

### Task 2：切换 catalog help/legacy/unknown 与单次 context

**Files:**
- Modify: `Source/Voxia/Debug/VoxiaDebugCliSubsystem.h`
- Modify: `Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp`

- [x] **Step 1: `ExecuteLine` 只从 router 判断 legacy envelope**

- [x] **Step 2: `ExecuteCommand` 构造一次 `FCommandContext` 并按 domain dispatch**

- [x] **Step 3: 删除重复 `HelpJson`、legacy token list 与 unknown JSON 拼接**

  保留 legacy observe side effect；payload 改为调用 R0 contract 的逐字节等价输出。

### Task 3：拆分五个领域 handler

**Files:**
- Modify: `Source/Voxia/Debug/VoxiaDebugCliSubsystem.h`
- Modify: `Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp`

- [x] **Step 1: 按 catalog domain 机械迁移现有分支**

  每个 handler 只读取显式 context；保持原分支内部语句、参数默认值、调用顺序和返回字符串不变。

- [x] **Step 2: 证明 `ExecuteCommand` 不再含业务 token 长分支**

  静态审计：入口只允许 route kind/domain switch；121 个 token/alias 全部由 catalog 覆盖。

- [x] **Step 3: Development build 与 focused Automation**

  Run: `Automation RunTests Voxia.Debug.CommandContract`

  Run: `Automation RunTests Voxia.Debug.CommandRouter`

### Task 4：生产 CLI 回归、文档与提交

**Files:**
- Modify: `README.md`
- Modify: `Source/Voxia/Debug/README.md`
- Modify: `docs/10-active/cross-cutting/2026-07-18-voxia-industrial-code-review-and-remediation-design.md`

- [x] **Step 1: 全量 Voxia Automation**

  Expected: 不少于 74 项，全部 Success，0 test warning/error。

- [x] **Step 2: Null-RHI 25 路生命周期 smoke**

- [x] **Step 3: 独立 CLI 合同 smoke**

  覆盖 `help`、代表性五域命令、alias、legacy、unknown；比较 R0 fixture 与既有 envelope。

- [x] **Step 4: 更新 README/进度并运行 `git diff --check`**

- [x] **Step 5: 分仓提交**

  Client commit: `refactor(governance): route CLI through domain handlers`

  Outer docs commit: `docs(voxia): record R2 CLI router`

  Actual client commit: `c98f67d`。

## 验证证据

- Router RED：缺少 `VoxiaDebugCommandRouter.h`；实现后 `Voxia.Debug.CommandRouter` GREEN。
- Focused：`Voxia.Debug.CommandContract` 与 `Voxia.Debug.CommandRouter` 均为 Success，证据位于
  `.demo/observe/voxia_governance_r2_debug_focused_20260718/`。
- Development build：固定 AutoSDK 与 MSVC 14.50 工具链下 `Result: Succeeded`。
- 全量 Automation：`74/74 Success`、0 failure、0 warning，证据位于
  `.demo/observe/voxia_governance_r2_automation_20260718/`。
- 提交前最终全量证据：`.demo/observe/voxia_governance_r2_final_20260718/`，仍为
  `74/74 Success`、0 failure、0 warning。
- Null-RHI 唯一生产根：25 条生命周期路线通过，证据位于
  `.demo/observe/voxia_phase1_2026-07-18T16-02-35-576Z_null_rhi_1280x720/`。
- 独立 stdio CLI：五域代表命令、`fps` alias、`lod` legacy、unknown 与 quit 全部返回既有 envelope；
  legacy 为 `ok=false`，unknown 继续为 `ok=true`。
- HEAD 逐块等价审计：96/96 production 块内容相同，Pawn 门禁精确复制到两个需要它的 handler，
  `ExecuteCommand` 业务 token 比较为 0，missing/changed/extra 均为 0。
