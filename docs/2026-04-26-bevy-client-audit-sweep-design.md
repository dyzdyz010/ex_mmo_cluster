# Bevy Client 审计修复 sweep 设计

**日期**：2026-04-26
**分支**：`feat/bevy-client-restructure`
**输入**：5 路审计 agent 的 punch list（共约 35 条，分 严重/中等/轻微 三档）
**目标**：在一个 sweep 内修完全部 confirmed 问题，含必要的 server 端最小改动

## 范围

**In scope**
- `clients/bevy_client/**`：所有 confirmed 问题
- `apps/scene_server/**` 与 `apps/gate_server/**`：仅做对齐 client 修复必需的最小改动
  - 唯一已知改动：`EnterSceneResult` 增加 `expected_seq` 字段（用于重连 seq 握手，方案二）
  - 可能改动：MovementAck 携带 `fixed_dt_ms`（如验证确认 client 累积漂移真实存在）
- 必要的新增/修改 ExUnit 与 cargo test

**Out of scope**
- `clients/web_client/**`：字节序与 fastlane 缺口单独立项，本 sweep 不动
- 任何与审计无关的重构 / 风格调整 / 命名优化
- 删除遗留 `protocol.rs` vs `protocol_v2.rs` 的双轨命名（仅打 TODO，不在本轮做）

## 工作流：三阶段 × 5 切片

```
阶段 0: validator agent       阶段 1: implementer agent       阶段 2: reviewer agent
   ──────────────────              ──────────────────                ──────────────────
   每条 punch 读相关代码           只修 confirmed 项                  全套 cargo test + clippy
   + 现有测试 + git blame          先写 reproducer test               跨切片冲突检查
   + 必要时跑 cargo check          再改代码让 test pass               功能回归核对
   + 输出 verdict:                 不改无关代码                       审计原始条目逐条勾销
     confirmed | false_positive
     | needs_more_context
```

**严格性**：所有 35 条（含轻微）必须经 validator agent 评审。validator 只做研究、不写代码。validator 必须给出文件:行号 + 复现路径或反证。需要时可单开 validator 专攻某一条。

**时间窗**：单条 validator 控制在 15 分钟内；单切片 implementer 控制在 60 分钟内；reviewer agent 控制在 30 分钟内。超时即上报，由人决定是切小还是延后。

## 切片与依赖

| ID | 切片 | 文件范围 | 大致条目 | 依赖 |
|---|---|---|---|---|
| **A** | Net + Protocol + Server codec | `clients/bevy_client/src/{net,protocol*.rs}` + `apps/gate_server/lib/gate_server/codec.ex` | ~10 | 无 |
| **B** | Sim + Movement + Seq 握手 | `clients/bevy_client/src/{sim,movement}` + `apps/scene_server/lib/scene_server/{movement,session}` 的 `EnterSceneResult` 路径 | ~10 | A（协议字段） |
| **C** | Camera + Input | `clients/bevy_client/src/{camera,input}` | ~7 | B（dead zone 与 movement plugin 触点） |
| **D** | Voxel + World + Presentation | `clients/bevy_client/src/{voxel,world,presentation}` | ~6 | 无 |
| **E** | App glue + Stdio + UI | `clients/bevy_client/src/{app,headless,stdio,hud,chat,skill,effects,observe.rs,login.rs,auth_client.rs,config.rs,main.rs,lib.rs}` | ~10 | 无 |

并行度：阶段 0 全部 5 条并行；阶段 1 中 A/D/E 先并行，B 等 A，C 等 B；阶段 2 全部 5 条并行。

## 重连 seq 握手设计（方案二：复用 EnterSceneResult）

**问题**：client `next_seq` 在 `reset()` 时重置为 1，但 server 仍期待旧序列号；ack 全错配 → 无限回放或硬 snap。

**方案**：在现有 `EnterSceneResult` 消息里追加 `expected_seq: u32` 字段。

**协议变更（线协议规范同步更新）**

| 字段 | 类型 | 偏移 | 说明 |
|---|---|---|---|
| ...existing fields... | | | 不变 |
| `expected_seq` | `u32` BE | 末尾追加 | server 端期望的下一个 movement input seq |

**客户端流程**
1. 进场 → 收到 `EnterSceneResult { expected_seq: N }`
2. `local_player.reset_to(seq = N)`，预测/历史/输入缓冲全部以此为基准
3. 后续移动输入从 N 开始单调递增

**服务端流程**
1. session 内为每个 character 维护 `next_input_seq`（初始 1，进场时递增持久化或快照）
2. 进场 / 重连 → 在 `EnterSceneResult` 里塞当前 `next_input_seq`
3. 收到的 `Movement(seq)` 落后于 `next_input_seq` → 丢弃 + 日志；超前 → 缓存（可选）或丢弃 + 日志

**版本协商**：`EnterSceneResult` 长度可变，旧 client 收到带新字段的包按当前长度截断（已是大端 u32，最后追加不破坏前面 layout）。新 client 收到老 server 的包时检测长度不足 → fallback `expected_seq = 1`，并在 observer log warn。

**回滚**：拆 server 新字段写入逻辑（保持长度不变）；client 自动走 fallback 路径。

## 验收门

按顺序，全部通过才算 sweep 完成：

```bash
# Bevy client
cd clients/bevy_client
cargo fmt --check
cargo clippy -- -D warnings
cargo check
cargo test
cargo test --release   # 性能敏感的 sim 测试

# Server
cd ../..
mix format --check-formatted
mix compile --warnings-as-errors
cd apps/gate_server && mix test --no-start
cd ../scene_server && mix test --no-start
cd ../.. && mix test    # 全套，含 NIF
```

**额外门**：每个 implementer agent 必须为修复点新增至少 1 条 reproducer test（除非 reviewer agent 显式判定无法测试，例如纯渲染抖动）。

## 文件产出

- `docs/2026-04-26-bevy-client-audit-sweep-design.md`（本文）
- `docs/2026-04-26-bevy-client-audit-sweep-plan.md`（writing-plans 阶段产出，phase 化执行计划）
- `docs/2026-04-26-bevy-client-audit-sweep-verdicts.md`（阶段 0 validator agent 全部 verdict 汇总）
- `docs/2026-04-26-bevy-client-audit-sweep-changelog.md`（阶段 1/2 完成后逐条勾销表）

## 风险与回滚

| 风险 | 影响 | 缓解 |
|---|---|---|
| seq 握手 server 端实现引入新 bug | 全员断线 | 先在 ExUnit 加 contract test；上线前在本地双 client（bevy + 旧 web）冒烟 |
| 协议字段长度变化引发老 client 不兼容 | 仅影响未升级 web client | 已设计为末尾追加 + fallback；新增门：升级 server 前确认 web client 的 codec 不会因长度大于预期而 panic |
| 5 路 implementer 同时改文件冲突 | 编译失败 | 切片严格按文件范围划分；reviewer agent 跨切片做合并检查 |
| 某些"严重"项是 false positive | 改了无效代码 | 阶段 0 validator agent 强制评审；reviewer 阶段双重检查 |
| 单测覆盖不到位 | 修复回归无人发现 | implementer 必须先写 reproducer test |

## 不做的事

- 不重命名 `protocol_v2.rs`（标 TODO 即可）
- 不重写整个 fastlane 模块（仅修竞态点）
- 不修 web client 字节序
- 不替换 smoothing 算法（只在 dirty 时重建 + 文档化阈值）
- 不引入新依赖
