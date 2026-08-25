# Far deadline 只约束 required 层决策稿

- 日期：2026-08-19
- 状态：已收口（Voxia `2ed2c91`）
- 前置：[`2026-08-19-traversal-frame-gate-calibration.md`](2026-08-19-traversal-frame-gate-calibration.md) §4.1、
  [`2026-08-18-far-publication-liveness-deadlock.md`](2026-08-18-far-publication-liveness-deadlock.md) defect A
- 目标：消除移动中确定性复现的 `far_deadline_exceeded`（serial 8 类大 diff 换区代）。

## 1. 定性（三轮对照 + 超时时刻断面）

- 每换区代的 Far 收敛耗时与该代 **speculative 工作量**完全相关：
  普通代 diff 0–539 patch → 4–8s;gen 8 为 **1236 patch** → 三轮全部 11.1–11.7s,
  贴 12s 死线（gen 23 为 1150 → 9.8s,同型）
- 超时时刻断面（失败轮 serial 8）：`required_far_complete=true`、
  `coverage_complete=true`、`far_reason=complete`、`required_work=0`——
  **玩家承诺层早已全部达成**,收敛中的只剩 speculative 渐进发布
  （其存在状态的事件名就叫 `speculative_publication_continues`）
- `far_deadline_exceeded` 触发 `voxel_patch_streaming_failed`,整个 root 会话被打死

## 2. 契约缺陷

`AVoxiaUnifiedVoxelWorldActor::UpdateStreamingDeadlines` 里 Far deadline 的
`Complete` 条件绑定在 `IsPatchStreamingSettled`——settled 要求
`PendingSpeculativeCount == 0 && RetainedCount == TargetCount`,即**全部
speculative 后台工作清零**。

Far deadline 的语义（defect A 稿定义）是"玩家入场门锁存后,Far 必须限时收敛"
——这是**可玩性承诺**,对应 readiness 的 required 层。speculative 是架构上明确的
后台渐进发布,其完成时间随 diff 规模无界;把它纳入 12s 硬死线,意味着移动速度或
地形复杂度稍增即确定性失败——正是实测形态。

## 3. 修复（唯一事实源对齐）

`FarDeadline.Complete` 的条件从 `IsPatchStreamingSettled(...)` 改为消费
**readiness 的同源决策位**：`Decision.bRequiredFarComplete && Decision.bCoverageComplete`
（与 `far_reason == "complete"` 的判定一字不差,同一 `EvaluateReadiness` 产出,
不新建第二套"far 完成"判定）。

- `IsPatchStreamingSettled` 本身不动——它的其他消费者
  （runtime barrier 的 quiescence 等）语义正确
- speculative 渐进发布不再受 deadline 管辖;其活性由既有 liveness 监控负责
- 发布准备（act→pub 4.2s,defect A 的计时起点问题）不另行处理：
  required 在 pub 后 1–2s 即完成（本代 required_published 仅 2 个 patch）,
  修复后余量足够,不为它再动计时起点（最小化）

### 报告口径变化（如实记录）

`readiness.deadlines.far.elapsed_ms` 的完成时刻语义由"全量 settled"变为
"required + coverage 完成"。静止 Full Far 验收（`--full-far-only`）自身的
全量收敛判定（retained==target 等）由脚本独立检查,验收强度不变;
但基线文档里"Far 耗时"数字的语义随之改变,验证后需重校基线数字。

## 4. 验收

1. Automation 全绿（Presenter 决策位为既有纯函数,已有覆盖）
2. 12-tile 长程：serial 8 类大 diff 代不再触发 `far_deadline_exceeded`;
   帧门禁结果与离线重放一致（p95 类 0,偶发残余可见）
3. `--full-far-only`：验收通过;记录新口径下的 far elapsed 数字,
   若与基线显著偏离则更新 current-truth

## 5. 进度日志

- 2026-08-19：定性与断面证据完成,立稿。

## 6. 终验

- 12-tile 长程：`far_deadline_exceeded` **0/24 段**（此前确定性死于第 6 段）;
  GT hitch ratio 类失败 0（此前每轮 2 段擦线）;趋势通过（5.16→5.30,限 8.73）
- `--full-far-only`：PASS。`deadlines.far.elapsed_ms` 新口径 **977ms**
  （required+coverage 完成时刻,旧口径全量 settled ≈5.2s）;全量 33725 页收敛
  仍由脚本计数独立断言（published 6859 / 34 组）,验收强度不变
- Automation 221/221

## 7. 修复暴露的下一事项（已完全归因,本稿不处理）

speculative 不再被 deadline 打死后,其后台发布与移动共存,暴露出
**far 组账本提交的单帧峰值**：12-tile 剩余 6 个挂段中 5 个是孤立的
单帧 frame>33ms（GT 20–29ms + 渲染跟进）,逐帧对账全部命中 far 组活动;
`voxia_far_patch_group_poll_timing` 实测 `host_poll_ms` 9–13ms,穿透到
`CommitOrderedProjectedFarGroupVisibility` 内 **188–256 个 child 的
`CommitPatchPresentationLedgerDelta` 在 ReadyToCommit 帧一次性执行**
（staging 阶段已有切片让出,提交阶段没有）。另有 1 段 GT p95 5.2 超
traversal 门限,同源(后台发布抬稳态)。

修复方向：far 组账本提交按帧预算切片,需先论证 visible 切换与账本条目的
一致性窗口(组尾递延机制已在,可能可复用),属独立决策稿。

## 8. 进度日志（续）

- 2026-08-19：实现提交 `2ed2c91`;12-tile 与 full-far 终验完成,收口。

## 9. 2026-08-25 同目标分阶段范围与流送回归补充

本次 MockWorldGen 洞口可玩验收暴露的流送故障不改变本稿“deadline 只约束 required”的决策，
而是修复其 owner 边界与可观测面：

1. 默认新 TargetKey 先构建 `StartupRequired = 6598 pages`；该范围发布并收敛后，Far owner 才把
   **同一 TargetKey** 单调提升为 `Full = 33725 pages`。统一根只替换同目标 manifest，不重新激活
   Near，也不创建第二生产根。Full 后台扩展由独立 observer 观察，不能反向撤销 playable proof。
2. Near 调度围栏只读取 Near owner 自己的 dispatch、ready publication、critical transaction 与 worker
   状态；Far 使用共享 SceneHost 的事务不再让 `IsNearPresentationReady()` 变假并取消自己的构建。
3. `requested required Far pending` 与 active/exceeded deadline 下同 generation 的 required convergence
   都有调度保护；玩家移动只可暂停 speculative Far，不能饿死或反复 cancel required 工作。
4. `near_window.active_settled` 是当前窗口的规范完成证明；全局 `idle=false` 可能仅表示存在 speculative
   successor，脚本不得再把它误判成活动 Near 未收敛。
5. 跨窗口 Far retained/entered/exited 由 `FVoxiaFarTargetVersionDiff` 比较前后两份已验证 Full manifest
   一次冻结。`StartupRequired → Full` 的阶段内 build index 不是目标级移动差分。

终验：Null-RHI 唯一生产根从 `[11,0,-51]` 跨到 `[11,1,-51]`，Near
`entered/exited/retained=3087/3087/6174`；目标级 Far
`retained/entered/exited=6618/241/241`；Near/required Far 分别 `295/1739ms`，cancel count 为 `0`，
clean exit。证据：`.demo/observe/voxia_phase1_2026-08-25T01-21-18-032Z_null_rhi_1280x720/`；
策略与生命周期分层证据位于
`.demo/observe/voxia_worldgen_streaming_fix_20260825/{runtime_scope_lifecycle_green,near_owner_scheduling_fence_green,required_far_dispatch_protection_green,active_near_settled_green,far_target_version_diff_green}/`。
