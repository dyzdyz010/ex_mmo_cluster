# 长程加载流水线与流畅性决策稿

- 日期：2026-08-19
- 状态：进行中
- 范围：`clients/Voxia` Near/Far 流式呈现的**持续移动**场景
- 目标：建立长程（多 tile 连续穿越）加载流水线验收，判据是**流畅性**而不是收敛时延。

## 1. 为什么现有验收不够

| 路由 | 覆盖 | 缺口 |
| --- | --- | --- |
| `--full-far-only` | 静止收敛（33725 pages / 6859 patches） | 不移动，不触发 Near 窗口滑动 |
| `--performance-only` | **1 个 tile 出 + 1 个 tile 回**（各 120m） | 距离太短；只有 2 段样本 |
| `--soak-minutes N` | ±1 tile 往复 | **完全不做帧门禁**，只断言队列/释放计数 |
| `--cross-tile-far-only` | 单次跨 tile 的 Far 换区 | 单次事件，不看持续性 |

即：**没有任何路由检验"持续长距离移动下帧是否稳定"**。

## 2. 已测得的现状（2026-08-19，`--performance-only`，1280x720 Real-RHI）

帧门禁失败：`GameThread p99 8.485 exceeds 8.33ms`、`hitch ratio 0.003211 exceeds 0.001`。

但稳态其实很好：

| 段 | samples | frame p50 | frame p95 | GT p50 | GT p95 | GT p99 | >16.67ms 帧 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 2083 | 7.692 | 7.692 | 2.303 | 3.309 | 4.589 | 2 |
| 1 | 1557 | 7.692 | 7.692 | 2.523 | 3.443 | 8.485 | 5 |

`frame p50 = 7.692ms` 正是 `t.MaxFPS 130` 的上限，GT 稳态 2.3–2.5ms。
**问题是少数孤立尖峰，不是整体掉帧。**

## 3. 尖峰归因（已完成）

排除了两个错误假设：

1. **不是 CLI 测量工具的观察者效应**。16 个最慢帧只有 2 个落在 CLI 命令帧上，
   而 CLI 占用 131/1000 个帧槽，随机命中率就是 13.1%——2/16 = 12.5% 即噪声水平。
   （`FVoxiaDebugFramePerfSamplingPolicy::ShouldExcludeSample` 只排除 `CliCommandFrame + 1`
   一帧，机制本身偏弱，但本次不是主因。）
2. **不是 Near 缺少每帧预算**。`MaxNearPatchGroupChildren = 64` 确实存在；
   日志里 `max_commit_batch_size: 256` 属于 Far actor（`VoxiaPure3DVoxelWorldActor`）的同名字段，
   Far 的渲染变更另有 `MaxLiveFarPatchGroupRendererMutations = 128` 上限。

真实归因：`voxia_near_world_tick_timing`（仅在 tick > 2ms 时输出）本次共 10 条，
**每一条都由 `near_patch_ms` 主导**，即 `ContinueNearActivePresentation` → `ContinueNearPatchPresentation`：

```
frame=2452 total=20.48ms  near_patch_ms=20.48
frame=7368 total=16.63ms  near_patch_ms=16.50
frame=6051 total=16.13ms  near_patch_ms=16.13
frame=3976 total=15.66ms  near_patch_ms=15.66
```

与最慢帧一一对应（慢 tick 在帧 N，帧时间记在 N+1）。

量化：本次 12 个 Near 提交组、624 个子项、平均 52、最大 64，
`group_prepare_ms` 合计 154.947ms → **每组约 12.9ms**，且 624 个子项**全部**是渲染变更
（`command_free_children = 0`）。

**结论：每组 64 子项的上限约束了批大小，但没有约束单帧 GameThread 时间。**
Far 用"渲染变更计数"作预算且 command-free child 不占额度；Near 用的是"子项个数"，
在全部子项都产生渲染变更时，这个上限起不到帧预算的作用。

## 4. 本次要做的事

### 4.1 新增长程路由 `--long-haul-only`

- 前置：与 `--performance-only` 一致（Full Far 收敛 + `performance_runtime_barrier`）
- 主体：地面高度直线穿越 **N 个 tile**，每 1 tile 为一个测量段
  （fly 1400cm/s，1 tile = 12000cm ≈ 8.6s ≈ 1100 帧 @130fps，
  安全落在 `FramePerfSampleCapacity = 7200` 的环形缓冲内）
- 往返：出程 + 回程，覆盖前进方向与反向的窗口滑动
- 每段：`frame_perf reset` → `move_continuous` → `frame_perf snapshot` + Near/Far 状态采样

### 4.2 流畅性判据（每段 + 跨段）

1. **逐段帧门禁**：沿用 `validateStreamingFrameWindow` 现有阈值
2. **不劣化**：后半程各段的 GT p99 / hitch 比例不得显著高于前半程（检测累积性退化）
3. **流水线跟得上**：每段结束时 `far_release_pending` 归零、队列深度有界、无目标饥饿
4. **尖峰归因**：逐段记录最慢 8 帧，并与 `voxia_near_world_tick_timing` 关联输出，
   使失败信息直接指向阶段而不是只报一个比值

### 4.3 不做的事

- 本稿**不改** `MaxNearPatchGroupChildren` 或引入 Near 帧预算。
  先让长程路由把问题量化出来（尖峰频率是否随距离线性增长、是否累积），
  再据此决定预算形态。避免在没有长程证据时凭一次短程测量调参数。

## 5. 实现记录

- `--long-haul-only` / `--long-haul-tiles N`（默认 12，范围 [2,64]，与其他专项模式互斥、禁 soak）
- `buildLongHaulRoutePlan`：N 段出程 + N 段回程，每段 1 tile（12000cm），命名
  `long_haul_out_XX` / `long_haul_back_XX`，段号与 leg 随段携带
- `measureMove` 增加 `deferFrameGate`：长程模式逐段只采样不断言，最后统一判定，
  失败信息携带段名与跨段趋势
- `evaluateLongHaulSmoothness`（已导出，单测覆盖）：
  1. 逐段 `validateStreamingFrameWindow`（与 performance 路由同阈值）
  2. 段末 `far_release_pending == 0`、`queue_depth <= 1`
  3. 后半程 GT p99 均值 ≤ 前半程均值 × 1.5 + 1ms
  4. 逐段保留 `slowest_game_thread_frames`，可与 `voxia_near_world_tick_timing` 对账
- 前置与 `--performance-only` 完全一致：Full Far 收敛 → `performance_runtime_barrier` →
  升空至 near 全空验证高度；跳过全量交互路线
- 单测 6 项新增，脚本套件 193/193 通过；文档更新 `Source/Voxia/Debug/README.md`

## 6. 长程首跑结果与第二凶手（2026-08-19，4 tile 往返试跑）

路由一次跑通，8/8 段全部执行并逐段判定。结果：**8 段全部超 hitch 门限**
（ratio 0.0011–0.0022，限 0.001），但**无累积劣化**（后半程 GT p99 均值 5.28ms，
限度 7.73ms；`far_release_pending` 段末全零）。即流水线健康，问题是每 tile
固定出现 1–3 个 17–30ms 的 GameThread 尖峰。

归因（两个来源，各自独立成立）：

1. **`near_patch_ms` 15–16ms**：`voxia_near_world_tick_timing` 18 条记录全部由
   `ContinueNearActivePresentation` 主导，与各段最慢帧一一对应。单独不过
   16.67ms hitch 线，与同帧其他工作叠加后过线。
2. **`readiness_ms` ≈20ms（每段最大尖峰，每 tile 恰一次）**：
   `voxia_unified_root_tick_timing` 显示 readiness 段恒定 ~20ms，
   来源是 `EnsureRendererCoverageFinalParity` —— readiness 每次换区收敛后在
   GameThread 上做"增量快照 vs 独立全量重建"的深比较。**这正是把门禁放进
   正常流程的教科书案例**（AGENTS.md 第 7 条的反面）。

### 修复 1：全量 parity 移出正常流程

- readiness 的 `coverage_complete` 只吃增量审计（gap/overlap/seam 计数），
  不再依赖 `bRendererCoverageFinalParityVerified`；等待原因改名
  `coverage_audit_pending`
- 新 CLI `renderer_coverage_parity`：显式触发同一校验；冒烟脚本在
  Full Far 收敛后与长程每段末尾（测量窗口之外）显式调用并断言 verified
  —— 验收强度不降，成本移到验收时刻

### 修复 2：audit 与 continuity 的自维护（parity 移除暴露的隐式耦合）

首次复测暴露：`LastRendererCoverageAudit` 只在全量重建路径更新，此前一直靠
readiness 里的 parity 强制重建来"顺带保鲜"；parity 移走后 audit 停在启动瞬态的
全 gap（19683），且 `Arm` 守卫要求 `audit.IsClean()` → 保护永远立不起来（死锁）。

- delta 提交路径本就逐次做 `AuditDelta` 且不干净不应用；现在**应用成功即把
  `LastRendererCoverageAudit` 同步为刚算出的干净 DeltaAudit**（"最近一次真实
  审计"的语义落实为自维护，不靠验收工具副作用）
- `RendererCoverageContinuity.Arm()` 以 **complete near window 达成/续签**这一
  证明本身为据，不再被陈旧 audit 挡死

### 修复 2 的两轮补充（复测逐层暴露的焊死点）

parity 之前不只是"校验",它以副作用维系着三个运行时判定,逐一解耦：

| 焊死点 | 症状 | 解法 |
| --- | --- | --- |
| `Arm` 守卫 `audit.IsClean()` 吃到启动瞬态全 gap | `protection_armed=false` / `protected_audited_frame_count=0` | Arm 移到 delta 应用尾部,与 audit 刷新同点(窗口证明 + 新审计干净同时成立) |
| Arm 过早于 audit 刷新 | `protected_gap_frame_count > 0` | 同上(6687/6719 恢复原守卫,不再死锁) |
| `IsPatchStreamingSettled` 要求 `IsRendererCoverageFinalParityCurrent` | Far 实际 6859/6859 收敛但 settled 恒 false → `far_deadline_exceeded`(前两次复测被更早失败掩盖) | settled 与 readiness 同口径:只吃增量审计 |
| CLI 命令未注册进 `VoxiaDebugCommandContract` 路由表 | `unknown_command: renderer_coverage_parity` | 在契约表补 `VoxelPresentation/Production` 条目 |
| （修正）我曾把 `LastRendererCoverageAudit = DeltaAudit` 当自维护 | `AuditedChunkCount`/`InvalidChunks` 是全量契约,增量审计冒充后 `IsRendererChunkCommittedCovered` 恒 false → 移动 `block_uncovered` 11.7 万次,`--vertical-only` 也回归 | **回退**该替换。audit 保持"最近一次全量审计"语义;保鲜由验收脚本在断言点显式 `renderer_coverage_parity`(waitPlayable/startup-proof/full-far gate/长程段末),运行时零成本 |

## 7. 修复后复测（4 tile，2026-08-19）

| | 修复前 | 修复后 |
| --- | --- | --- |
| 超 hitch 门限的段 | 8/8 | 4/8 |
| GT max | 26–30ms | 17–21ms（一段 25.5） |
| hitch ratio 区间 | 0.0011–0.0022 | 0.0005–0.0013 |
| 趋势（后半程 GT p99 均值 / 限度） | 5.28 / 7.73 | 5.55 / 7.97（通过） |

readiness parity 的每 tile ~20ms 尖峰确认消灭。剩余尖峰全部归于 **Near 组提交**：
每次换区一组（≤64 子项、全渲染变更），`PlanNearMove`×N + `RebaseNearMoveGroupOwnership` +
`BeginPatchPresentationGroup` 在一个 GameThread tick 内同步完成，实测 13–16ms/组。
段门限 0.001×~1100 帧 ≈ 每段只容 1 个 >16.67ms 帧，该尖峰叠加日常工作时过线。

## 8. 下一决策项（未动手）：Near 组提交分帧

方向：像 Far 侧一样把"渲染变更预算"与"组大小"分离——组的组装(Take/Plan)分帧摊开，
提交(fence arm)保持单帧原子。涉及 `FPendingNearPatchPresentationGroup` 的生命周期与
mailbox 语义，属实质架构改动，需先在此稿补充设计与测试矩阵再动手。

## 9. 进度日志

- 2026-08-19：完成现状测量与尖峰归因，产出本稿。
- 2026-08-19：实现 `--long-haul-only` 路由与流畅性判定，单测 193/193。
- 2026-08-19：4 tile 试跑 8/8 段执行、8/8 段超 hitch 门限；归因出 readiness 全量 parity
  （~20ms/换区）与 near_patch（15–16ms）两个来源；完成修复 1 + 修复 2，
  Build Succeeded、Automation 221/221。
- 2026-08-19：修复过程中回退了一次错误的"DeltaAudit 冒充全量审计"（曾使移动
  `block_uncovered` 冻结、`--vertical-only` 回归）；最终形态=运行时只吃增量审计、
  验收点显式 parity。4 tile 复测 8/8→4/8，GT max −9ms；Voxia 提交 `96ca17d`。
- 2026-08-19：12 tile 完整长程启动。
