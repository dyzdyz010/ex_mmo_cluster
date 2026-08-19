# 流式 deadline 运行时降级为观测决策稿

- 日期：2026-08-20
- 状态：已收口（Voxia `be3c734`）
- 前置：[`2026-08-19-far-deadline-required-scope.md`](2026-08-19-far-deadline-required-scope.md)
- 触发：用户手玩生产根（`run_voxia_3d_world.ps1`,GUI 首启）"过了一会儿提示加载失败"。

## 1. 现场定性

同一晚两次失败,同一形态——**流水线在推进,只是慢于 12s 预算,deadline 直接杀会话**：

| | 失败 1（首启） | 失败 2（重试） |
| --- | --- | --- |
| 原因 | `near_deadline_exceeded` | `far_deadline_exceeded` |
| 实况 | baseline worldgen 窗口 26s 才 ready（冒烟同步骤 3s;GUI 首启引擎初始化即 51s,环境性慢） | near 4.2s 正常,far 12s 内发布 578/6859 后被杀 |
| 排除 | 帧率 150–200fps 正常;shader 编译为零;非死锁（事件持续推进） | 同左 |

`FailPatchStreaming` → flow recovery → UI"加载失败"。玩家看到的是:世界正在加载,
然后被自己的验收计时器杀掉。

## 2. 契约判断（AGENTS.md 第 7 条）

10s 目标 / 12s 硬线是**验收契约**（streaming-lod current-truth）,其归属是冒烟门禁。
把它编译进正常流程作为会话击杀,即"把门禁放入正常流程"——在验收机器上它恰好从不
触发,在玩家的冷启动/慢环境上它把"慢但正在成功"变成"失败"。

真死锁不靠 deadline 兜底：liveness/stall 监控独立存在（本次失败 1 里 liveness 正确
报告了 stall 并在恢复后清除）。

## 3. 修复

- **运行时**：`UpdateStreamingDeadlines` 里 near/far `bExceeded` 不再调
  `FailPatchStreaming`;首次进入 exceeded 时发一条 `voxia_streaming_deadline_exceeded`
  观测（near/far 各自最多一次/代）。deadline 状态机原样保留——`state=exceeded`
  仍写入 readiness JSON,遥测与验收照读。加载继续推进,ready 即入场。
- **验收（强度不降反升）**：冒烟已消费 `readiness.deadlines.{near,far}.state`,
  `exceeded` 仍使 full-far / startup 门禁硬失败（脚本侧断言,不依赖运行时击杀）。
  长程路由逐段快照补充 deadline 状态,任何段 exceeded 即失败。
- 其余 `FailPatchStreaming` 调用（start/prepare 失败等真错误）不动。

## 4. 验收

1. Automation 221 全绿
2. `--full-far-only` / `--long-haul-only 12`：通过,deadline 断言仍在脚本侧生效
3. 手玩复现路径：GUI 冷启动即使 baseline 慢,不再弹"加载失败",最终进入世界

## 5. 进度日志

- 2026-08-20：定性 + 立稿。
- 2026-08-20：实现——`UpdateStreamingDeadlines` 超时改发一次性
  `voxia_streaming_deadline_exceeded`(near/far 各自每代最多一次,状态机 exceeded
  终态保留,新代自动复位);长程逐段快照携带 `deadlines.{near,far}.state` 并硬断言
  非 exceeded;单测 196/196、Automation 221/221。双冒烟验证进行中。

## 6. 终验

- `--full-far-only`：PASS
- `--long-haul-only 12`：**PASS,24/24 段零失败**——长程路由建立以来首次完整全绿
  （帧门禁、逐段 deadline 断言、劣化趋势 4.64→4.67ms/限 7.95 全部通过）
- Automation 221/221;脚本套件 196/196
- 途中一次误报排除:双批冒烟并发撞车导致 CLI 超时,与本改动无关

## 7. 进度日志（续）

- 2026-08-20：实现提交 `be3c734`,双冒烟终验通过,收口。手玩复现路径留待用户重跑确认。
