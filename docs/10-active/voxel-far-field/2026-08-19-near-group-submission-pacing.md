# Near 组提交分帧决策稿

- 日期：2026-08-19
- 状态：已收口（Voxia `7737bb8`）
- 前置：[`2026-08-19-long-haul-streaming-smoothness-plan.md`](2026-08-19-streaming-deadline-tolerance-plan.md) §8
- 目标：消除长程移动中每 tile 一次的 GameThread 尖峰（13–16ms 的 Near 组提交），
  使 `--long-haul-only` 的 hitch 门禁（每段 >16.67ms 帧 ≤1）转绿。

## 1. 现状（代码事实）

每次换区,`AVoxiaWorldActor::ContinueNearPatchPresentation`（每帧推进）走：

```
StageNextReadyNearPatchMove
  ├─ CollectReadyMovePrefix(≤64)            // 有序前缀收集
  ├─ Take ×N                                 // mailbox payload 移入组(MoveTemp)
  └─ SubmitPendingNearPatchPresentationGroup // ↓ 同一帧全部完成
       ├─ PlanNearMove ×N                    // 构建 plan + read-set + after-image 校验
       ├─ CountContinuousPrefix / Rebase     // 组前缀与 ownership 重建
       └─ BeginPatchPresentationGroup        // SceneHost:含 ValidateReadSet ×N、
                                             //   fence/staging 组装、账本 AdvanceGroup
```

实测（12 组统计）`group_prepare_ms ≈ 12.9ms/组`,叠加当帧日常工作后产生
每 tile 1–2 帧 >16.67ms。组大小上限 `MaxNearPatchGroupChildren = 64`
约束的是**组的规模**,不是**单帧 GameThread 时间**。

## 2. 工程约束的落点（用户指定）

| 约束 | 本稿的落点 |
| --- | --- |
| 最小化 | 先细分计时归因,只分帧真正的热点段;不预防性重构无关结构 |
| DRY | 若 Plan 与 Begin 存在重复校验（read-set 构建后整组重校验）,合并为一次,而不是把重复的两遍各自分帧 |
| 唯一事实源 | 组的跨帧状态只存在 `PendingNearPatchPresentationGroup` 一处,不新增平行状态容器 |
| 高内聚低耦合 | 分帧策略进 `FVoxiaWorldRootStreamingSchedulingPolicy`（组预算已在此）,WorldActor 只执行 |
| 模块正交 | 提交的**原子性语义不变**：账本 AdvanceGroup、fence arm、渲染变更仍单帧发生;分帧只作用于其前的纯 CPU 组装段 |

## 3. 待归因（先测后改）

在 `SubmitPendingNearPatchPresentationGroup` 加常驻细分计时
（与 `voxia_near_world_tick_timing` 同模式：超阈值才打）：
`take_ms / plan_ms / rebase_ms / begin_ms`,其中 begin 内部再分
`begin_validate_ms / begin_stage_ms / begin_ledger_ms`。

跑 `--long-haul-only --long-haul-tiles 4` 取数据,按占比决定：

- **若 Plan 主导** → Plan 分帧：每帧最多 plan K 个（K 由帧预算常量导出）,
  组保持在 `PendingNearPatchPresentationGroup` 中带进度游标;全部 plan 完成的那一帧
  才进入 Begin（原子段不动）
- **若 Begin.ValidateReadSet 主导** → 先查 DRY：Plan 刚构建过 read-set,Begin 是否
  必须整组重校验;若必须（跨帧后账本可能已变）,则校验只对"账本 serial 自 plan 后变化"
  的场景全量执行,serial 未变时走凭证短路（唯一事实源：账本 serial）
- **若 stage/fence 主导** → 涉及渲染资源,单独评估,不并入本稿

## 4. 验收矩阵

1. 单测：调度策略的分帧预算函数（纯函数）
2. `Automation RunTests Voxia` 221 全绿
3. `--long-haul-only --long-haul-tiles 4`：per-tile 尖峰消失
   （期望每段 >16.67ms GT 帧 = 0,`near_patch_ms` 峰值 < 8ms）
4. `--long-haul-only --long-haul-tiles 12`：hitch 门禁全绿、趋势门禁保持通过
5. `--full-far-only`：Near/Far 收敛时延不回归（对照 2026-08-19 基线）

## 5. 归因结果（实测,4-tile,18 组样本）

`voxia_near_patch_group_submit_timing`：

| 阶段 | 实测 | 占比 |
| --- | --- | --- |
| **plan_ms**（PlanNearMove ×N） | **9.3–17.1ms** | **~80%** |
| rebase_ms | 0.7–1.0ms | ~6% |
| begin_ms（含 ValidateReadSet ×N） | 1.3–2.7ms | ~14% |

Begin 内的 read-set 校验从未超过 2ms 阈值——凭证机制（`bLedgerInvariantAlreadyValidated`）
工作正常,不是热点。

**热点定位**：`PlanNearMoveInternal` 每个 child 内联调用 `ProjectNearOwnership`,
后者**两次遍历 `Ledger.ExactNearOwnedChunks`（9261 chunk）**构建全窗口 ownership mask。
64 child × 2 × 9261 ≈ **每组 120 万次集合迭代**。

而代码事实是这些 mask 在组路径下**全部是死工作**：

- 非尾 child：`bDefersOwnershipToGroupTail` → 消费 live texture,自己的 mask 无人读
- 尾 child：`RebaseNearMoveGroupOwnership` 用**全组 after-image 一次投影**并
  **覆盖**尾 plan 的 mask
- 且 Rebase 被调了**两次**（`SubmitPendingNearPatchPresentationGroup` 一次、
  `BeginPatchPresentationGroupInternal` 的 `bCumulativeNearOwnership` 分支又一次）

## 6. 方案（修订：不做分帧,删死工作）

原计划的"分帧"不再需要——热点不是必要工作太多,是**无人消费的工作在被重复做**。

按约束逐条：

- **唯一事实源**：组的 ownership 唯一由组尾 mask 承载。现状类型上不表达这一点,
  导致每个 child"先造一个假的再被丢弃"。给 `FVoxiaPatchPresentationPlan` 增加
  `bOwnershipDeferredToGroupTail` 一个 bool,把既有的 defer 语义显式化。
- **DRY**：组路径 per-child 投影删除（新组入口 `PlanNearMoveForGroup`,内部跳过
  `ProjectNearOwnership`）;双 Rebase 合一（删 Submit 里那次,保留 Begin 内
  `bCumulativeNearOwnership` 的必经一次）。
- **最小化**：单 child 流（move/edit/trim/removal）完全不动,默认路径零变化;
  不引入分帧状态机、不加新容器。
- **正交**：提交原子性（账本 AdvanceGroup、fence、渲染变更单帧）不动。

一致性强化：`IsValid` 对 deferred plan 放行 mask 要求,但 Begin 组循环交叉校验
"非尾必须 deferred、尾在 Rebase 后必须已承载 mask"——不变量比现状更强而不是更松。

预期：plan_ms 10–12ms → 1–2ms,组提交总耗 13–16ms → ~4–5ms,低于 8.33ms 帧预算,
每 tile 尖峰消失。

## 7. 进度日志

- 2026-08-19：立稿;加 `voxia_near_patch_group_submit_timing` / 
  `voxia_patch_group_begin_read_validate_timing` 常驻细分计时（超阈值才输出）。
- 2026-08-19：4-tile 实测归因完成,方案由"分帧"修订为"删除组内死投影 + 双 Rebase 合一"。
- 2026-08-19：实现完成——`bOwnershipDeferredToGroupTail` 字段 + `PlanNearMoveForGroup`
  组入口(冻结快照/live 凭证双重载) + `IsValid` 对移交计划要求"必须未配置 mask"
  (半配置即非法,不变量不松反紧) + Rebase 组尾承载后清标志 + Submit 删除重复 Rebase
  (Begin 内 `bCumulativeNearOwnership` 为唯一执行点)、单成员组保持完整计划。
  RED(`GroupDeferredOwnership`)→GREEN;Automation 221/221。

## 8. 终验（12-tile / 24 段 / 40,304 帧）

| 指标 | 修复前 | 修复后 |
| --- | --- | --- |
| 组提交耗时（移动段） | 13–16ms | **< 2ms**（低于计时阈值,整轮无输出） |
| 超 hitch 门限的段 | 12/24 | **2/24**（0.00112/0.00124,擦线偶发,不再每 tile 固定） |
| GT max | 17–28ms | 11–25ms |
| 趋势（后半程 GT p99 均值 / 限度） | 5.24/8.41 | 5.20/8.50（通过） |
| 挂段总计 | 15/24 | 7/24 |

剩余 7 个挂段的构成：
- 4 段 GT p95 3.54–3.85ms（限 3.5）——即长程稳态标定问题（前稿 §9.2,选项 B,待用户拍板）
- 2 段 hitch 擦线 + 1 段单帧 >33ms + 1 段 p99 8.44（限 8.33）——偶发残余,
  与组提交无关（GT max 20–25ms 的零星帧另有来源,未随距离累积）

**本稿目标达成**：每 tile 固定的 Near 组提交尖峰消灭。hitch 门禁要全绿还差
偶发残余的归因,与 p95 标定同属后续独立事项。

## 9. 进度日志（续）

- 2026-08-19：实现提交 `7737bb8`;12-tile 终验完成,收口。
