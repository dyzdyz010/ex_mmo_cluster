# Voxia R3 统一 JSON 与冻结运行时配置实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans and superpowers:test-driven-development task-by-task.

**Goal:** 建立单一 JSON 转义基础设施，并把现役模块对 `FCommandLine::Get()` 的散读替换为进程内一次冻结的不可变运行时配置，同时保持所有参数语义、JSON schema、协议和可见效果不变。

**Architecture:** `FVoxiaJson` 提供纯 escape/string/bool/vector writer；先迁移 Debug、统一根 presenter 与 Interest。`FVoxiaClientRuntimeConfig` 首次访问时冻结完整 command line，解析 startup/network/near/far/input-debug 安全摘要并提供无凭据 snapshot；现有 `FParse` 调用继续读取同一冻结字符串，避免一次性重写参数语义。GameMode 在启动门禁前触发冻结并发出结构化 observe。`bUseUnity=false` 只在冲突家族清零后才能单独翻转，本阶段保留。

## 不变边界

- 不改变 command-line token、默认值、clamp、热调 tuner、协议字段、CLI token/envelope 或 JSON schema。
- 配置 snapshot 不包含 username、token、cookie、authorization、完整 command line 或 URL 查询凭据。
- 不翻转 unity build，不借 R3 调优预算、线程数、阈值或渲染参数。
- 新增/修改注释使用中文。

### Task 1：统一 JSON 基础设施

- [x] 先写控制字符、引号、反斜杠、bool、XYZ 的 RED Automation。
- [x] 实现 `Source/Voxia/Core/VoxiaJson.h/.cpp` 并确认 GREEN。
- [x] 逐域迁移 Debug contract/CLI、root presenter、Interest wire/subsystem；逐字节门禁保持通过。
- [x] 盘点剩余 helper 与 `WriteU8` 冲突家族，记录不翻转 unity 的理由。

### Task 2：冻结运行时配置

- [x] 先写 synthetic command line 解析、默认值、clamp 与凭据红线测试并确认 RED。
- [x] 实现 `FVoxiaClientRuntimeConfig` 的 startup/network/near/far/input-debug 子结构、冻结字符串与安全 snapshot。
- [x] 将 13 个现役源文件的 `FCommandLine::Get()` 机械替换为同一冻结 config 字符串；保持原 `FParse` 语句不变。
- [x] GameMode 在启动门禁前冻结并发出 `client_runtime_config_frozen` observe；不得输出凭据。
- [x] 静态断言除 config 实现外现役模块不再调用 `FCommandLine::Get()`。

### Task 3：验证、文档与提交

- [x] Development build 与 focused Automation。
- [x] 全量 Automation 不少于 76 项、0 failure/warning。
- [x] Null-RHI 25 路生命周期 smoke 与独立 CLI 合同 smoke。
- [x] 更新 README/进度，运行 `git diff --check`。
- [x] 分仓提交：client `c89eadd`（`refactor(governance): freeze runtime config and unify JSON`）；
  outer `docs(voxia): record R3 config freeze`。

## 验证证据与剩余库存

- Development build 使用 VS 14.50 / UE 5.8，结果 `Succeeded`。
- focused RED/GREEN：`Voxia.Core.Json` 与 `Voxia.Gameplay.ClientRuntimeConfig` 均先因实现缺失失败，
  再分别通过；全量证据 `.demo/observe/voxia_governance_r3_full_retry_20260718/` 为
  `76/76 Success`、0 failure、0 warning。
- Null-RHI 根级证据 `.demo/observe/voxia_phase1_2026-07-18T16-22-17-750Z_null_rhi_1280x720/`
  为 25 条路线通过、clean exit、far release=`11/11/0`；独立 CLI 证据为
  `.demo/observe/voxia_governance_r3_cli_smoke_20260718.log`。
- `client_runtime_config_frozen` 实跑事件只含分类安全摘要，并明确
  `credentials_redacted=true`；synthetic 测试同时覆盖 username、token、URL 查询凭据和完整命令行红线。
- 静态库存仍有 33 个待逐域迁移的局部 JSON helper 声明/定义和 7 个 `WriteU8` 定义；这些匿名
  namespace 同名家族在 unity TU 中仍可能冲突，因此 `bUseUnity=false` 本阶段按设计保留。
- 生产调用点对 `FCommandLine::Get()` 为 0；仅 `FVoxiaClientRuntimeConfig.cpp` 的首次冻结和
  `WITH_DEV_AUTOMATION_TESTS` 显式夹具刷新边界仍读取进程命令行。
