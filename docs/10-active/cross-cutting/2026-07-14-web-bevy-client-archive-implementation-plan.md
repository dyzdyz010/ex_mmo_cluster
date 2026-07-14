# Web / Bevy 客户端逻辑归档实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **状态：已执行。** 2026-07-14 已完成根治理、active/current 文档、CI、手动发布、通用启动/E2E/doctor、日常部署显式开关与归档 README 收口；实施改动按工作树所有权约束保持未提交。

**Goal:** 保留 `clients/web_client` 与 `clients/bevy_client` 的代码和历史证据，同时把它们从默认架构、开发、验证、CI、发布和进度判断中移除，使 Voxia 成为唯一现役客户端。

**Architecture:** 服务端 wire contract 继续由 `GateServer.Codec` 持有，Voxia decoder 自动化与实跑承担现役客户端消费验证。归档客户端保持原目录和可复现工具，但只有显式点名或显式归档入口才允许使用；默认入口、CI 和发布均不再触发它们。

**Tech Stack:** Markdown、GitHub Actions YAML、PowerShell、Bash、Unreal Engine 5.8 / Voxia 验收入口

## Global Constraints

- `clients/Voxia` 是唯一现役客户端；`clients/web_client` 与 `clients/bevy_client` 是逻辑归档客户端。
- 当前仍在扩展后的 Milestone A / A10，本地完善 Voxia 模块边界、统一 near/far 运行时和渲染效果；Milestone B 的 CS projection/protocol contract 与 Milestone C 的在线接入均未开始。
- 不移动或删除归档客户端目录，不批量改写历史证据。
- 只有用户显式点名时，归档客户端才进入任务范围；读取旧代码、保留 decoder 或运行历史回归不能隐式解冻。
- wire codec 真值仍是 `apps/gate_server/lib/gate_server/codec.ex`；默认协议门禁改为服务端 codec / golden fixture + Voxia decoder / 实跑。
- 保留当前工作树中用户已有的 staged 完整 XYZ 改动；不得覆盖、回退或把它们混入本任务的独立提交。
- 本任务不提交实施改动，除非用户另行要求；当前 index 已含多个同路径用户改动，路径级提交无法安全分离所有权。
- 新增或修改的脚本说明使用中文；失败必须给出可诊断原因和 Voxia 入口。

---

### Task 1: 切换根治理与 current-truth 客户端口径

**Files:**
- Modify: `AGENTS.md:13-18,27-29,76-78,96`
- Modify: `CLAUDE.md:9`
- Modify: `README.md:90-96`
- Modify: `docs/00-current-truth/README.md:43-53`
- Modify: `docs/00-current-truth/impl/README.md:26-32,56-62`

**Interfaces:**
- Consumes: `docs/10-active/cross-cutting/2026-07-14-web-bevy-client-archive-policy.md`
- Produces: 仓库级唯一客户端状态、默认协议验收口径和默认验证入口

- [x] **Step 1: 运行现役口径扫描并确认它会失败**

Run:

```powershell
rg -n "默认 parity|参考实现|默认端到端验证/parity 主线|Web client 验证|Web client：" AGENTS.md CLAUDE.md README.md docs/00-current-truth
```

Expected: 至少命中 `AGENTS.md` 的 Web parity、`docs/00-current-truth/README.md` 的 Web parity / Bevy 参考实现，以及 `docs/00-current-truth/impl/README.md` 的 Web 默认验证条目。

- [x] **Step 2: 修改根准则与工具入口索引**

在 `AGENTS.md` 的客户端口径中明确写入：

```markdown
- `clients/Voxia`（UE5.8）是**唯一现役客户端与真实联调焦点**——新功能、模块设计、渲染效果、近场交互、远景 LOD、debug overlay、stdio CLI 和客户端实跑验收均在此推进。
- `clients/web_client` 与 `clients/bevy_client` 是**逻辑归档客户端**——代码和历史证据保留原位，默认不读取、不开发、不验证、不进入 CI / 发布 / 进度判断；只有用户显式点名时才临时纳入任务。
```

把协议追加规则改为：

```markdown
7. **协议层只追加不破坏**：新增 wire 字段必须保持旧字段字节序和含义稳定；wire codec 真值以 `apps/gate_server/lib/gate_server/codec.ex` 为准，默认通过服务端 codec / golden fixture 与 Voxia decoder 自动化、实跑验证。归档 Web / Bevy parity 不再是默认门禁。
```

删除 Web 默认验证命令，并在验证入口末尾增加：

```markdown
- 归档客户端：Web / Bevy 不进入默认验证；只有用户显式点名时才按各自 README 运行历史测试或工具。
```

把客户端关键路径改为 Voxia 现役入口加归档决策：

```markdown
- 现役客户端：[`clients/Voxia/README.md`](clients/Voxia/README.md)
- 归档客户端策略：[`docs/10-active/cross-cutting/2026-07-14-web-bevy-client-archive-policy.md`](docs/10-active/cross-cutting/2026-07-14-web-bevy-client-archive-policy.md)
```

把 `CLAUDE.md:9` 改为：

```markdown
> - 客户端口径（Voxia 唯一现役 / Web 与 Bevy 逻辑归档）— AGENTS.md §1
```

- [x] **Step 3: 修改根 README 与 current-truth**

在根 README 的客户端表中保留三个目录，但把状态写清：

```markdown
| **[Voxia](clients/Voxia)** | Unreal Engine 5.8 | 唯一现役产品客户端；当前在 Milestone A / A10 完善本地模块与渲染 |
| [`clients/web_client`](clients/web_client) | TypeScript · Three.js | 归档；仅显式点名时使用 |
| [`clients/bevy_client`](clients/bevy_client) | Rust · Bevy | 归档；仅显式点名时使用 |
```

把 `docs/00-current-truth/README.md` 的客户端事实改为：

```markdown
7. **Voxia 是唯一现役客户端，Web / Bevy 已逻辑归档**：默认客户端设计、实现、协议消费验证、联调、CI 与进度判断只看 Voxia；归档目录只保留历史证据，只有用户显式点名时才临时纳入。当前仍在 Milestone A / A10 本地完善模块设计、统一 near/far 与渲染效果，B/C 均未开始。
```

把 `docs/00-current-truth/impl/README.md` 客户端表改为：

```markdown
| Voxia UE | `clients/Voxia/README.md` | 唯一现役 UE5.8 product client；Milestone A / A10 本地完善中 |
| Web | `clients/web_client/README.md` | 归档；仅显式点名时使用 |
| Bevy | `clients/bevy_client/README.md` | 归档；仅显式点名时使用 |
```

删除 Web 与 WS browser smoke 的默认验证条目，在验证入口增加：

```markdown
- 归档 Web / Bevy：不进入默认验证；显式点名后按各自 README 选择历史测试入口
```

- [x] **Step 4: 验证根口径一致**

Run:

```powershell
rg -n "唯一现役|逻辑归档|Milestone A|B/C 均未开始|归档 Web / Bevy" AGENTS.md CLAUDE.md README.md docs/00-current-truth
rg -n "默认 parity|默认端到端验证/parity 主线|Web client 验证|Web client：" AGENTS.md CLAUDE.md README.md docs/00-current-truth
git diff --check -- AGENTS.md CLAUDE.md README.md docs/00-current-truth/README.md docs/00-current-truth/impl/README.md
```

Expected: 第一条在五个治理入口中命中新的现役 / 归档口径；第二条无匹配并返回 1；`git diff --check` 返回 0。

---

### Task 2: 给归档客户端自身增加不可误读的状态入口

**Files:**
- Modify: `clients/web_client/README.md:1-3`
- Modify: `clients/bevy_client/README.md:1-3`

**Interfaces:**
- Consumes: Task 1 的仓库级客户端分类
- Produces: 进入归档目录时可直接看见的状态、限制和重新启用条件

- [x] **Step 1: 确认两个 README 目前没有归档警告**

Run:

```powershell
rg -n "归档客户端|仅在用户显式点名" clients/web_client/README.md clients/bevy_client/README.md
```

Expected: 无匹配并返回 1。

- [x] **Step 2: 在两个 README 标题后加入相同归档警告**

在各自一级标题后加入：

```markdown
> [!WARNING]
> **归档客户端。** 本目录保留历史实现与可复现工具，但不再参与默认架构、开发、协议 parity、测试、CI、发布或进度判断。仅在用户显式点名本客户端时，才读取、运行或修改这里的内容；当前唯一现役客户端是 [`clients/Voxia`](../Voxia/README.md)。
```

保留两个 README 中已有的完整 XYZ 与在线 authority 说明，不回退用户已暂存内容。

- [x] **Step 3: 验证归档警告与历史内容共存**

Run:

```powershell
rg -n "归档客户端|当前唯一现役客户端|完整 XYZ|server-authoritative|confirmed truth" clients/web_client/README.md clients/bevy_client/README.md
git diff --check -- clients/web_client/README.md clients/bevy_client/README.md
```

Expected: 两个 README 都命中归档警告；原有完整 XYZ / authority 内容仍可检索；`git diff --check` 返回 0。

---

### Task 3: 停止默认 CI、Web 自动发布、通用旧客户端入口与隐式部署

**Files:**
- Modify: `.github/workflows/ci.yml:520-556`
- Modify: `.github/workflows/web-client-publish.yml:7-19`
- Modify: `scripts/start-client.ps1:1-61`
- Modify: `scripts/start-client.sh:1-63`
- Modify: `scripts/dev-client.ps1:1-87`
- Modify: `scripts/start-dual-scene-demo.ps1:4-18`
- Modify: `scripts/e2e-stdio.ps1`
- Modify: `scripts/e2e-live-movement.ps1`
- Modify: `scripts/e2e-stdio-movement.ps1`
- Modify: `scripts/e2e-stdio-movement.sh`
- Modify: `scripts/dev-doctor.sh`
- Modify: `deploy/.env.example`
- Modify: `deploy/upgrade.sh`
- Modify: `deploy/README.md`

**Interfaces:**
- Consumes: Task 1 的默认工作流口径
- Produces: 不会自动运行、发布或部署归档客户端的 CI / 脚本 / 部署边界

- [x] **Step 1: 证明当前自动化仍会触发归档客户端**

Run:

```powershell
rg -n "test-bevy-client|cargo test --locked|push:|clients/web_client|Launching bevy_client|Launching web_client" .github/workflows/ci.yml .github/workflows/web-client-publish.yml scripts/start-client.ps1 scripts/start-client.sh scripts/dev-client.ps1
```

Expected: 命中 Bevy CI job、Web publish 的 `push` trigger，以及三个通用脚本的归档客户端启动代码。

- [x] **Step 2: 移除默认 Bevy CI 并把 Web publish 改为纯手动**

从 `.github/workflows/ci.yml` 删除完整 `test-bevy-client` job。该 job 没有被其它 `needs` 引用，不需要替代依赖。

把 `.github/workflows/web-client-publish.yml` 的 trigger 改为：

```yaml
on:
  workflow_dispatch:
    inputs:
      tag_override:
        description: "Extra tag to publish (optional)"
        required: false
        default: ""
```

保留手动 workflow 的构建、登录和发布步骤；显式手动触发即视为显式使用归档 Web 客户端。

- [x] **Step 3: 让三个通用启动脚本显式拒绝归档客户端**

保留 PowerShell 参数声明以便旧调用得到统一诊断，在 `scripts/start-client.ps1` 与 `scripts/dev-client.ps1` 的参数块后立即终止：

```powershell
$ErrorActionPreference = "Stop"
throw "archived_client_default_disabled: Web / Bevy 已逻辑归档，通用客户端入口不再启动它们。现役 Voxia 入口：node clients/Voxia/scripts/voxia_stdio_cli.js --cmd `"...`"。如用户显式要求归档客户端，请直接进入对应 clients 目录按 README 运行。"
```

删除这两个脚本中不可达的旧启动主体。

把 `scripts/start-client.sh` 改为：

```bash
#!/usr/bin/env bash
set -euo pipefail

cat >&2 <<'EOF'
archived_client_default_disabled: Web / Bevy 已逻辑归档，通用客户端入口不再启动它们。
现役 Voxia 入口：node clients/Voxia/scripts/voxia_stdio_cli.js --cmd "..."
如用户显式要求归档客户端，请直接进入对应 clients 目录按 README 运行。
EOF
exit 64
```

- [x] **Step 4: 给 Web 双 scene demo 增加显式归档开关**

在 `scripts/start-dual-scene-demo.ps1` 参数中增加：

```powershell
[switch]$AllowArchivedWebClient,
```

并在 `$ErrorActionPreference = "Stop"` 后增加：

```powershell
if (-not $AllowArchivedWebClient) {
    throw 'archived_web_client_explicit_opt_in_required: 本脚本驱动已归档 web_client；只有用户显式要求时才可传 -AllowArchivedWebClient 运行。当前 Voxia 入口：node clients/Voxia/scripts/voxia_stdio_cli.js --cmd "..."'
}
```

保留当前 staged 的 `VITE_VOXEL_DIAGNOSTIC_PARTIAL_WINDOW=1` 专项诊断逻辑。

- [x] **Step 5: 验证 CI、workflow 与脚本语法**

Run:

```powershell
rg -n "test-bevy-client|cargo test --locked" .github/workflows/ci.yml
rg -n "^[ ]+push:" .github/workflows/web-client-publish.yml
rg -n "workflow_dispatch|archived_client_default_disabled|archived_web_client_explicit_opt_in_required" .github/workflows/web-client-publish.yml scripts/start-client.ps1 scripts/start-client.sh scripts/dev-client.ps1 scripts/start-dual-scene-demo.ps1
@('scripts/start-client.ps1','scripts/dev-client.ps1','scripts/start-dual-scene-demo.ps1') | ForEach-Object {
  $tokens = $null; $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $_), [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -ne 0) { throw "$($_): $($errors -join '; ')" }
}
bash -n scripts/start-client.sh
git diff --check -- .github/workflows/ci.yml .github/workflows/web-client-publish.yml scripts/start-client.ps1 scripts/start-client.sh scripts/dev-client.ps1 scripts/start-dual-scene-demo.ps1
```

Expected: 前两条无匹配并返回 1；第三条命中手动 workflow 和四个显式诊断；三个 PowerShell 文件无 parser error；`bash -n` 与 `git diff --check` 返回 0。

- [x] **Step 6: 收口通用 E2E、doctor 与日常部署入口**

最终审查发现四个通用 E2E 入口仍会驱动 Bevy、通用 doctor 仍默认检查浏览器客户端，日常
`deploy/upgrade.sh` 仍可能按示例变量替换 Web 静态包。现已让这些通用入口在副作用前 fail-fast
并指向 Voxia；生产部署新增 `ALLOW_ARCHIVED_WEB_CLIENT_DEPLOY=false` 默认门禁，只有显式改为
`true` 且 `WEB_CLIENT_IMAGE_TAG` 非空时才进入归档 Web 部署分支。PowerShell 入口同时通过
PowerShell 7 与 Windows PowerShell 5.1 parser / fail-fast 实跑，Bash 入口返回 64。

---

### Task 4: 标注仍在 active 层中的归档客户端证据

**Files:**
- Modify: `docs/10-active/cross-cutting/2026-04-14-文档完善执行计划.md:1-3`
- Modify: `docs/10-active/cross-cutting/2026-04-15-游戏内容主流程框架化方案.md:1-3`
- Modify: `docs/10-active/cross-cutting/2026-06-26-genesis-initiative-direction.md:8-10`
- Modify: `docs/10-active/cross-cutting/voxel-server-authority-phase-overview.md:67-71`
- Modify: `docs/10-active/field-emergence/2026-05-14-phase7-field-kernel-architecture.md:7-10`
- Modify: `docs/10-active/movement-sync/2026-04-13-移动同步-vNext-后续缺口清单.md:1-4`
- Modify: `docs/10-active/movement-sync/2026-04-20-移动同步-路线C-实施计划.md:1-6`
- Modify: `docs/10-active/voxel-authority/2026-06-17-unit-morphology-and-surface-element-layer.md:50-54`

**Interfaces:**
- Consumes: Task 1 的现役 / 归档分类
- Produces: 不会被误读为 Web / Bevy 后续任务的 active 文档

- [x] **Step 1: 给旧计划增加统一覆盖说明**

在仍以 Web / Bevy 为实施对象的旧计划开头加入：

```markdown
> **2026-07-14 客户端归档覆盖**：本文中的 `web_client` / `bevy_client` 内容只保留为历史实现与证据，不再是默认后续任务或验收门禁。客户端新增工作只进入 Voxia；除非用户显式点名归档客户端。服务端结论是否仍有效需按当前 truth 单独核对。
```

适用文件为两份旧 cross-cutting 计划、FieldKernel 架构稿和两份 movement-sync 计划。

- [x] **Step 2: 修正仍像当前任务的零散引用**

- `2026-06-26-genesis-initiative-direction.md`：把 Web 写为“归档历史参考”，不再写成当前品牌客户端组成。
- `voxel-server-authority-phase-overview.md`：把 Web FieldDebugOverlay 描述标为归档证据，并明确 Voxia 等价入口未落地时属于 Milestone A 客户端缺口，不以 Web 完成替代。
- `2026-06-17-unit-morphology-and-surface-element-layer.md`：把 Web 数据模型和 Bevy 无渲染写为归档实现证据，不作为当前客户端状态。
- A10 作战文档中 `CI Test bevy_client` 的单次历史事件保持原文，因为其上下文已经明确为历史日志，不能改写事件事实。

- [x] **Step 3: 扫描 active/current 层并分类剩余引用**

Run:

```powershell
rg -n -i "\bweb\b|\bbevy\b|\bbrowser\b|web_client|bevy_client|web cli|web client|浏览器|网页|fielddebugoverlay" AGENTS.md CLAUDE.md README.md docs/00-current-truth docs/10-active
```

Expected: 扩展后的大小写不敏感扫描覆盖独立词 `Web` / `Bevy` / `Browser`、`web_client`、`bevy_client`、`Web CLI`、`web client`、通用“浏览器”/“网页”与 `FieldDebugOverlay`。剩余命中只属于归档政策 / 全文覆盖说明、逐条限定的历史实现证据，或 A10 中明确记录过去 CI 事件的进度日志；不得再出现未限定的 Web parity、Bevy 参考实现或 Web / Bevy active 后续任务。

---

### Task 5: 最终验证并保持工作树所有权边界

**Files:**
- Verify: 本计划涉及的全部文件
- Verify: `clients/Voxia/**` 未被本归档任务修改

**Interfaces:**
- Consumes: Tasks 1-4 的文档、CI 与脚本结果
- Produces: 可复核的归档完成证据和未触碰 Voxia 实现的边界证明

- [x] **Step 1: 运行归档契约扫描**

Run:

```powershell
rg -n "唯一现役客户端|逻辑归档|归档客户端|workflow_dispatch|archived_client_default_disabled|archived_web_client_explicit_opt_in_required|ALLOW_ARCHIVED_WEB_CLIENT_DEPLOY" AGENTS.md CLAUDE.md README.md docs/00-current-truth docs/10-active clients/web_client/README.md clients/bevy_client/README.md .github/workflows scripts deploy
```

Expected: 根治理、current-truth、两个客户端 README、CI/workflow 与脚本均有对应归档证据。

- [x] **Step 2: 确认默认触发已经消失**

Run:

```powershell
rg -n "test-bevy-client|cargo test --locked" .github/workflows/ci.yml
rg -n "^[ ]+push:" .github/workflows/web-client-publish.yml
rg -n "默认 parity|默认端到端验证/parity 主线|Web client 验证|Web client：" AGENTS.md CLAUDE.md README.md docs/00-current-truth
```

Expected: 前两条分域负向命令各自无匹配并返回 1；这只要求移除 Bevy CI job 与 Web 自动发布，不要求删除主 `.github/workflows/ci.yml` 的正常 `push` trigger。第三条同样无匹配并返回 1。

- [x] **Step 3: 检查补丁质量与 Voxia 边界**

Run:

```powershell
git diff --check
git status --short
git diff --name-only HEAD -- clients/Voxia
git -C clients/Voxia status --short --branch
```

Expected: `git diff --check` 返回 0；umbrella 仍显示用户已有 staged 改动与本任务叠加内容；第一条 Voxia diff 无输出；nested Voxia 保持本任务开始前的 clean / ahead 状态。

- [x] **Step 4: 记录实施结果，不提交或推送**

在最终说明中分别列出：归档实施内容、验证命令、用户既有 staged 改动仍被保留、当前 Milestone A / A10 进度判断，以及 Milestone B/C 未开始。不得把 Web / Bevy 测试结果纳入默认完成证明。
