# Bevy Client 审计修复 Sweep 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal**：根据 5 路审计 agent 输出的 47 + 3 条 punch list，在 `feat/bevy-client-restructure` 分支上完成 Bevy client 全部 confirmed 问题的修复，配套必要的 server 端最小改动（`EnterSceneResult.expected_seq` 字段）。

**Architecture**：三阶段流水线 × 5 切片并行。阶段 0 由 validator agent 评审每条发现产出 `confirmed | false_positive | needs_more_context` verdict；阶段 1 由 implementer agent 按 verdict 做 TDD 修复（先 reproducer test 后 fix）；阶段 2 由独立 reviewer agent 二次审核。切片间依赖：A → B → C；D、E 与 A 并行。

**Tech Stack**：Rust (cargo / clippy / cargo test) for `clients/bevy_client`；Elixir/OTP (mix / ExUnit) for `apps/{gate,scene}_server`；Bevy 0.x ECS、自定义二进制协议（packet:4 分帧、大端 u32）、`rapier3d-f64` (server-side NIF)。

---

## 输入文件

- `docs/2026-04-26-bevy-client-audit-sweep-design.md` — 设计文档
- `docs/2026-04-26-bevy-client-audit-findings.md` — 47 + 3 条 punch list（validator 输入）
- `docs/2026-04-10-线协议规范.md` — 线协议规范（B-SRV3 同步更新）

## 输出文件（本计划产出）

- `docs/2026-04-26-bevy-client-audit-sweep-verdicts.md` — Phase 0 全部 verdict 汇总
- `docs/2026-04-26-bevy-client-audit-sweep-changelog.md` — Phase 1/2 完成项勾销表

## 执行约定

- 每个阶段的 agent dispatch 任务 = 1 步 = 1 个 subagent invocation
- Implementer agent 必须遵循 per-item TDD 模板（见下文 §Phase 1 Per-Item Template）
- Reviewer agent 不写代码，只跑 verification + 给 `pass | needs_rework` 决议
- 任何 reviewer `needs_rework` → 回到 implementer 重做该 item，verify-loop 直到 pass
- 全部修复完后单一 commit 收尾（Phase 3 自动完成）

---

# Phase 0: Validation（5 路并行 + 1 路 synthesis）

**目标**：把 47 条 client + 3 条 server findings 全部过 validator，产出 verdicts.md。

**约束**：validator 只读不写。allowed tools: Read, Grep, Glob, Bash (read-only)。**严禁**调用 Edit/Write/git apply。

## Task 0.1: Validator A（Net + Protocol）

**Files**:
- Read: `docs/2026-04-26-bevy-client-audit-findings.md` 切片 A 全部 11 条
- Read: `clients/bevy_client/src/{net/*,protocol.rs,protocol_v2.rs}`
- Read: `apps/gate_server/lib/gate_server/codec.ex`
- Read: `docs/2026-04-10-线协议规范.md`

- [ ] **Step 1: Dispatch validator agent A**

```
Agent({
  description: "Validate slice A audit findings",
  subagent_type: "Explore",
  prompt: """
你是 audit findings 的 validator。只做研究，不写代码。

任务：对 docs/2026-04-26-bevy-client-audit-findings.md 切片 A 的 11 条
（A-S1, A-S2, A-S3, A-M1, A-M2, A-M3, A-M4, A-L1, A-L2, A-L3, A-L4）逐条核验。

每条产出 verdict 之一：
- confirmed: 必须给出 文件:行号 + 复现路径（描述触发条件 / 提供反例代码片段）
- false_positive: 必须给出反证（贴出当前代码片段 + 解释为什么 audit 误读）
- needs_more_context: 缺什么，建议追加什么调研

不接受"可能"、"也许"、"应该"等模糊词。每条至少 50 字论证。

输出格式（Markdown）：
## A-S1
**Verdict**: confirmed | false_positive | needs_more_context
**Evidence**: ...
**Repro/Refute**: ...
**Suggested fix scope**: ...

最后给出 slice 总结：confirmed N / false_positive M / needs_more_context K。

返回完整 markdown，控制在 1500 词以内。
"""
})
```

- [ ] **Step 2: 保存 agent 返回内容到临时文件**

将 agent 输出写入 `docs/_tmp/verdicts-slice-a.md`（最后会合并）。

## Task 0.2: Validator B（Sim + Movement + Server seq 握手）

类似 0.1，prompt 末尾加：

```
切片 B 共 9 条 client + 3 条 server findings：
- Client: B-S1, B-S2, B-S3, B-M1, B-M2, B-M3, B-L1, B-L2, B-L3
- Server: B-SRV1, B-SRV2, B-SRV3

额外读：
- clients/bevy_client/src/{sim/*,movement/*,world/local_player.rs}
- apps/scene_server/lib/scene_server/**/*.ex（聚焦 session/movement/enter_scene 路径）
- apps/gate_server/lib/gate_server/codec.ex 中 EnterSceneResult encode/decode

特别核验：
- B-S1 client `next_seq` 重置逻辑现状是什么？server 端目前如何分配 / 期待 input seq？是否已经有任何 sequence tracking？
- B-M2 client 与 server 的 `fixed_dt_ms` 取值是否真的耦合且无校验？grep 两侧的 dt 常量定义。

- [ ] **Step 1: Dispatch validator agent B**
- [ ] **Step 2: 保存到 docs/_tmp/verdicts-slice-b.md**
```

## Task 0.3: Validator C（Camera + Input）

切片 C 共 8 条：C-S1, C-S2, C-M1, C-M2, C-M3, C-L1, C-L2, C-L3

读：`clients/bevy_client/src/{camera/*,input/*,movement/plugin.rs}`、`clients/web_client/src/presentation`（仅看默认值对照）

- [ ] **Step 1: Dispatch validator agent C**
- [ ] **Step 2: 保存到 docs/_tmp/verdicts-slice-c.md**

## Task 0.4: Validator D（Voxel + World + Presentation）

切片 D 共 8 条：D-S1, D-S2, D-S3, D-M1, D-M2, D-M3, D-L1, D-L2

读：`clients/bevy_client/src/{voxel,world,presentation}/**`、`clients/bevy_client/tests/voxel*`

- [ ] **Step 1: Dispatch validator agent D**
- [ ] **Step 2: 保存到 docs/_tmp/verdicts-slice-d.md**

## Task 0.5: Validator E（App + UI + Stdio）

切片 E 共 11 条：E-S1, E-S2, E-S3, E-M1, E-M2, E-M3, E-M4, E-L1, E-L2, E-L3, E-L4

读：`clients/bevy_client/src/{app,headless,stdio,hud,chat,skill,effects}/**`、`{observe,login,auth_client,config,main,lib}.rs`

- [ ] **Step 1: Dispatch validator agent E**
- [ ] **Step 2: 保存到 docs/_tmp/verdicts-slice-e.md**

## Task 0.6: 合并 verdicts → verdicts.md

- [ ] **Step 1**：合并 5 个临时文件成 `docs/2026-04-26-bevy-client-audit-sweep-verdicts.md`，按切片排序
- [ ] **Step 2**：在文件顶部写汇总表格（每切片 confirmed/false_positive/needs_more_context 数量）
- [ ] **Step 3**：删除 `docs/_tmp/`
- [ ] **Step 4**：commit

```bash
git add docs/2026-04-26-bevy-client-audit-sweep-verdicts.md
git commit -m "docs(audit): phase 0 verdicts from 5 validator agents

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

## Task 0.7: needs_more_context 单独追研

如果有 verdict 为 `needs_more_context`，**逐条**单开 validator agent 专攻，直到全部转化为 confirmed 或 false_positive。

- [ ] **Step 1**：grep verdicts.md 找出所有 needs_more_context
- [ ] **Step 2**：对每一条单开 Agent (Explore)，prompt 列出该条信息缺口和具体调研要求
- [ ] **Step 3**：合并新 verdict 回 verdicts.md，commit

---

# Phase 1: Implementation（按依赖图分波）

## Per-Item TDD 模板（implementer agent 必须遵循）

每个 confirmed item 的修复 = 一个完整 TDD 循环：

````
1. Read 当前代码 + 找到/确定测试文件路径
2. 写 reproducer test（Rust: #[test] in 模块测试 或 tests/*.rs；Elixir: ExUnit test/*_test.exs）
   测试必须能在未修复时失败、修复后通过
3. 跑 test 验证 fail：
   - Rust: `cd clients/bevy_client && cargo test <test_name> -- --exact`
   - Elixir: `cd apps/<app> && mix test <path> --no-start`
   预期：FAIL（看到具体的 assertion error 或 panic）
4. 写最小 fix
5. 跑 test 验证 pass（同命令）
6. 跑该模块/应用全套：
   - Rust: `cd clients/bevy_client && cargo test`
   - Elixir: `cd apps/<app> && mix test --no-start`
7. 跑 lint：
   - Rust: `cd clients/bevy_client && cargo clippy -- -D warnings`
   - Elixir: `mix format --check-formatted`
8. 在 changelog.md 勾选该 item，commit

提交消息格式：
"<scope>: <one-line summary> [<ITEM-ID>]"
正文给一句"为什么这么改"
````

**reviewer 跳过的情况**（implementer 必须显式声明）：
- 纯渲染抖动 / 视觉抖动类（D 切片）：可声明 "no automated test, manual verification only"，但必须配合 observer log 或 metric assertion
- 协议字段重排：assert codec round-trip identity

不允许 implementer 自审。每个 commit 之后排队等 reviewer。

---

## Wave 1（Phase 1）：A、D、E 并行启动

### Task 1.A: Slice A Implementer（Net + Protocol）

**Files in scope**:
- `clients/bevy_client/src/net/*.rs`
- `clients/bevy_client/src/protocol.rs`
- `clients/bevy_client/src/protocol_v2.rs`
- `apps/gate_server/lib/gate_server/codec.ex`（仅 protocol 对齐项）

**Blocked by**: Phase 0 全部完成

- [ ] **Step 1: Dispatch implementer agent A**

```
Agent({
  description: "Implement slice A confirmed audit fixes",
  subagent_type: "general-purpose",
  prompt: """
你是 slice A 的 implementer。

输入：
- docs/2026-04-26-bevy-client-audit-sweep-verdicts.md（只看切片 A 的 confirmed 项）
- docs/2026-04-26-bevy-client-audit-findings.md（切片 A 详情）
- docs/2026-04-10-线协议规范.md（协议事实源）

工作循环（对每个 confirmed item）：
（粘贴 Per-Item TDD 模板）

约束：
- 不修非 net/ + protocol*.rs 的文件
- 不动 server 端代码（gate codec 改动除外，但 slice A 没有 server 改动）
- 每条 commit 一次，commit message 含 [item-id]
- false_positive 项跳过，needs_more_context 项必须先升级为 confirmed 才修
- 全部完成后 cargo fmt + clippy + test 必须 clean
- 末尾在 docs/2026-04-26-bevy-client-audit-sweep-changelog.md 勾选 + commit

返回：完成项列表 + 跳过项原因 + 最后一个 commit hash。
"""
})
```

- [ ] **Step 2: Dispatch reviewer agent A**

```
Agent({
  description: "Review slice A implementation",
  subagent_type: "superpowers:code-reviewer",
  prompt: """
你是 slice A 的独立 reviewer。原 implementer 不得自审。

输入：
- docs/2026-04-26-bevy-client-audit-sweep-verdicts.md（切片 A confirmed 项）
- 当前分支自上一个 reviewer pass 以来的 commits

逐条核验：
1. 代码改动是否真的落在 verdict 描述的位置 + 修复方向
2. 是否引入新 bug（unwrap/expect、panic、race）
3. 测试是否真能复现原问题（git stash 改动后重跑应失败）
4. cargo fmt / clippy -D warnings / cargo test 是否全绿
5. commit message 是否带 [item-id]

返回 verdict per item: pass | needs_rework，并给修订建议。
最末给整体 verdict：merge_ready | rework_required。
"""
})
```

- [ ] **Step 3**：若 reviewer 给 `rework_required`，循环回 Step 1 让 implementer 修。注意每次都新派 agent，避免上下文污染。
- [ ] **Step 4**：reviewer pass 后，更新 changelog.md（implementer 已勾选，这里仅核对）。

### Task 1.D: Slice D Implementer（Voxel + World + Presentation）

**Files in scope**:
- `clients/bevy_client/src/voxel/**`
- `clients/bevy_client/src/world/**`
- `clients/bevy_client/src/presentation/**`
- `clients/bevy_client/tests/voxel*.rs`

**Blocked by**: Phase 0 全部完成。**与 Task 1.A 并行**。

- [ ] **Step 1: Dispatch implementer agent D**（prompt 同 1.A 模板，scope 换成 D 切片 + 文件范围）
- [ ] **Step 2: Dispatch reviewer agent D**
- [ ] **Step 3**：rework loop
- [ ] **Step 4**：勾选 changelog

### Task 1.E: Slice E Implementer（App + UI + Stdio）

**Files in scope**:
- `clients/bevy_client/src/{app,headless,stdio,hud,chat,skill,effects}/**`
- `clients/bevy_client/src/{observe,login,auth_client,config,main,lib}.rs`

**Blocked by**: Phase 0 全部完成。**与 Task 1.A、1.D 并行**。

- [ ] **Step 1: Dispatch implementer agent E**
- [ ] **Step 2: Dispatch reviewer agent E**
- [ ] **Step 3**：rework loop
- [ ] **Step 4**：勾选 changelog

---

## Wave 2（Phase 1）：B 启动

### Task 1.B: Slice B Implementer（Sim + Movement + Server seq 握手）

**Files in scope**:
- `clients/bevy_client/src/sim/**`
- `clients/bevy_client/src/movement/**`
- `clients/bevy_client/src/world/local_player.rs`
- `clients/bevy_client/src/protocol.rs`（仅 EnterSceneResult decode 加 expected_seq 字段）
- `apps/gate_server/lib/gate_server/codec.ex`（EnterSceneResult encode/decode）
- `apps/scene_server/lib/scene_server/**`（session 维护 next_input_seq）
- `docs/2026-04-10-线协议规范.md`（同步字段表）

**Blocked by**: Task 1.A 完成（reviewer pass）

**特殊约束**：B 切片含线协议变更，**第一个 commit 必须是协议变更（client + server + 文档同改）**，其它 fix 在协议落地后再做。

- [ ] **Step 1: Dispatch implementer agent B-1（仅协议变更）**

```
Agent({
  description: "Implement slice B step 1: EnterSceneResult.expected_seq protocol change",
  subagent_type: "general-purpose",
  prompt: """
单独这一步：仅落地协议变更（B-S1 + B-SRV1/2/3），不做其他 sim 修复。

变更内容（设计文档已定）：
1. apps/gate_server/lib/gate_server/codec.ex: EnterSceneResult encode/decode 末尾追加 expected_seq: u32 BE
2. apps/scene_server: session 内 next_input_seq 状态；进场/重连写入 EnterSceneResult.expected_seq
3. clients/bevy_client/src/protocol.rs: EnterSceneResult decode 读末尾 expected_seq；struct 加字段
4. clients/bevy_client/src/world/local_player.rs: reset_to_seq(N: u32) 接口；进场时 LocalPlayer 用 expected_seq 初始化 next_seq
5. docs/2026-04-10-线协议规范.md: EnterSceneResult 字段表追加

测试：
- ExUnit codec round-trip test（apps/gate_server）
- cargo test protocol round-trip
- ExUnit session next_input_seq 单测
- cargo test local_player.reset_to_seq

约束：
- 单一 commit（client + server + 文档原子）
- 不实现兼容/fallback——v1 协议
- 不做其他 B 切片 fix（在后续步骤）

返回：commit hash + 全套测试通过证据。
"""
})
```

- [ ] **Step 2: Dispatch reviewer agent B-1（协议变更专审）**

reviewer 必须额外验证：
- gate codec encode/decode 字节对齐（手写 hex roundtrip）
- scene_server 进场流程 expected_seq 正确写入
- 客户端 reset_to_seq 调用点
- 文档同步

- [ ] **Step 3**：rework loop（协议层错误代价高，必要时人工介入）
- [ ] **Step 4: Dispatch implementer agent B-2（其余 sim/movement fix）**

prompt 与 Task 1.A 相同模板，但 scope 排除 B-S1/B-SRV1/2/3（已完成）。

- [ ] **Step 5: Dispatch reviewer agent B-2**
- [ ] **Step 6**：rework loop
- [ ] **Step 7**：勾选 changelog

---

## Wave 3（Phase 1）：C 启动

### Task 1.C: Slice C Implementer（Camera + Input）

**Files in scope**:
- `clients/bevy_client/src/camera/**`
- `clients/bevy_client/src/input/**`
- `clients/bevy_client/src/movement/plugin.rs`（C-S2 dead zone 触点）

**Blocked by**: Task 1.B 完成（reviewer pass）

- [ ] **Step 1: Dispatch implementer agent C**
- [ ] **Step 2: Dispatch reviewer agent C**
- [ ] **Step 3**：rework loop
- [ ] **Step 4**：勾选 changelog

---

# Phase 2: 跨切片集成审查

## Task 2.1: 跨切片冲突检查

**目标**：5 路 implementer 是否在共用文件（如 `Cargo.toml`、`lib.rs`、`movement/plugin.rs`）上引入冲突或风格分歧。

- [ ] **Step 1: Dispatch integration reviewer agent**

```
Agent({
  description: "Cross-slice integration review",
  subagent_type: "superpowers:code-reviewer",
  prompt: """
跨切片集成审查。输入：5 路 implementer 完成后的全部 commits。

检查：
1. 相同文件被多个切片改动是否一致（Cargo.toml、lib.rs、main.rs、movement/plugin.rs）
2. 接口变更是否在调用方同步（如 reset_to_seq、speed_scale 参数）
3. 新增依赖是否合理（设计文档说不引入新依赖）
4. 代码风格一致性
5. 测试是否互相覆盖（不重不漏）

返回：list of integration issues + 修订建议。
"""
})
```

- [ ] **Step 2**：对每个 integration issue 单开小 fix（implementer + reviewer mini-loop）

## Task 2.2: 全套验收测试

- [ ] **Step 1: Bevy client 测试**

```bash
cd clients/bevy_client
cargo fmt --check
cargo clippy -- -D warnings
cargo test
cargo test --release
```

预期全绿；任一不绿 → 单开小 fix loop。

- [ ] **Step 2: Server 测试**

```bash
cd /c/Users/dyz/Documents/dev/hemifuture/ex_mmo_cluster
mix format --check-formatted
mix compile --warnings-as-errors
cd apps/gate_server && mix test --no-start
cd ../scene_server && mix test --no-start
cd ../.. && mix test
```

预期全绿。

- [ ] **Step 3: voxel parity test 专项**

```bash
cd clients/bevy_client
cargo test --test voxel_parity
cargo test --test voxel_cli_parity
```

预期全绿，含 D-M3 新增的 refined cell / prefab overlap / batch import 三类测试。

---

# Phase 3: 收尾

## Task 3.1: 完成 changelog

- [ ] **Step 1**：核对 `docs/2026-04-26-bevy-client-audit-sweep-changelog.md` 47+3 条全部勾选
- [ ] **Step 2**：补"未修复项"小节列出 false_positive 的反证摘要（供未来参考）

## Task 3.2: 最终 commit

- [ ] **Step 1**：

```bash
git status   # 应该 clean
git log --oneline feat/bevy-client-restructure ^master | head -50
```

- [ ] **Step 2**：写一个汇总 commit（如有未提交改动）

```bash
git commit -m "$(cat <<'EOF'
docs(audit): close out bevy client audit sweep

47 client items + 3 server items processed.
- N confirmed → fixed
- M false_positive → documented
- 0 needs_more_context (all escalated to verdict)

Reviewers: independent per slice + integration pass.
All gates green: cargo fmt/clippy/test, mix format/test.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

## Task 3.3: 总结报告

- [ ] **Step 1**：写一段 150 字以内的中文总结（fix 数、test 增量、commit 数、剩余 TODO 列表）发给用户

---

# 自检清单（写完计划后扫一遍）

- [x] 所有 47 + 3 条 findings 都被某个 task 覆盖（Phase 0 全部，Phase 1 按 verdict）
- [x] 所有 task 都有具体文件路径和 agent prompt
- [x] Per-Item TDD 模板替代了"重复每条 fix 的 5 步"
- [x] 依赖关系清晰：A → B → C；D、E 与 A 并行
- [x] reviewer 与 implementer 独立（不同 agent）
- [x] 没有"TBD / TODO / fill in details"占位
- [x] 协议变更原子化（B-1 单 commit）
- [x] 验收门具体可执行（cargo / mix 命令）

# 不在本计划范围

- 重命名 `protocol_v2.rs`（改 TODO 注释由 A-L3 处理）
- web client 字节序对齐
- protocol_v2 重命名 / fastlane 整体重写
- 引入新依赖

---

# Execution Hand-Off

执行方式选择：

**1. Subagent-Driven（推荐）**：每个 task 独立 subagent，task 间 reviewer 把关，rework loop。
**2. Inline Execution**：当前 session 顺序跑 task，间隔 checkpoint。

**推荐 Subagent-Driven**，因为本 plan 有大量 agent dispatch + 跨阶段独立 reviewer 的要求，新鲜上下文对 reviewer 公正性至关重要。
