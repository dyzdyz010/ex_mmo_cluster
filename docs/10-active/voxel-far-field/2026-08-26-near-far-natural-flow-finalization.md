# Near/Far 自然数据流收口决策稿

- 日期：2026-08-26
- 状态：方案已由用户批准，待实现（Voxia 基线 `1c15eb9`）
- 前置证据：`.superpowers/sdd/implementation-plan/task-5-efficiency-root-cause.md`（Task 5 只读根因诊断）及其只读校核（Task 6）
- 范围：Voxia far patch 有序组的提交切片器；`ResolveInitialRuntimeScope` 供给侧判据
- 不改变：服务端权威、confirmed truth 来源、逐 far patch 原子交权、唯一生产组合根、既有 fence 与 ledger 所有权

本稿只把已批准的方案定稿，不重新发明方案，也不复述 Task 5/6 的完整证据链。

## 1. 问题与证据

两项未收口指标，各有唯一根因，都不是“节流不够”：

| 现象 | 根因（已逐行核对） |
| --- | --- |
| `EOFU` max `16.354 ms` / 26 帧 > 8 ms | `MergeOrderedProjectedFarPhysicalPlans` 把全组 seam 并入不可分割的**组尾 child**，而 `ShouldYieldAfterFarPatchGroupCommitSlice` 是**事后**谓词；尾片在真正驱动 `SendAllEndOfFrameUpdates` 的单位上无界（组尾片 toggles p50 `217` / max `581`，占全部 toggles `92.5 %`） |
| 单 tile `AdjacentStep` 后 Full Far `39.276 s` | `AdjacentStep` 仍被解析成冷启动专用的 `StartupRequired` 64-patch scope，把 live 19³ 壳整体拆掉重建（`8.0 s` 拆 + `10.3 s` 重建 + `19.4 s` 上屏），而该步真实几何增量 ≤ `5.3 %`；可见 far patch `744 → 32` 持续约 11 s |

Task 6 校核补充两条硬事实，是本稿与 Task 5 §A.5 / §D 的差异来源：

1. **中间片本就已破 32**（实测 max `159`）。由事后谓词语义可反推出存在 **≥ 128 toggle 的单个不可分割 child**。只给组尾加第二个游标给不出 hard 32。
2. 因此「`slice_component_toggles` hard max ≤ 32」与「逐 far patch 原子交权」在当前组件形态下**不可同时成立**。切开一个 far patch 的组件集等于把一个 chunk 的几何半换，直接破坏零重叠不变量。

## 2. 唯一方案

一处呈现侧、一处供给侧，都是把现有结构改回自然流，不新增子系统：

- **P（呈现侧）**：把「child 序列 + 事后预算 + 组尾特殊事务」换成「**冻结的提交单元序列 + 单游标 + 先判后加预算**」。
- **Q（供给侧）**：`AdjacentStep` 且已有 live Full 壳时，初始 scope 直接返回 `Full`，让既有 `SelectReusableFarPatchVersions` 的相邻步复用（19³ 重叠约 `94.7 %`）重新生效。

两处都不引入第二真值、第二队列、第二本 ledger、重试或降级路径。

## 3. 自然数据流

本节是 AGENTS §2.2-9「自然数据流」在本子系统的落地。

```mermaid
flowchart LR
  W["固定 worker pool<br/>准备 far patch / seam 批次"] --> Q["现有 ready queue<br/>只运输与排序"]
  Q --> H["SceneHost 单 owner<br/>构造边界冻结提交单元序列"]
  H --> C["单游标 NextCommitUnitIndex<br/>先判后加预算"]
  C --> U["一个单元：show new → hide old → apply ledger delta"]
  U -->|游标未走完| C
  U -->|游标走完| F["现有 fence → coverage / parity / proof 终结"]
```

### 3.1 单元是唯一自然粒度（构造边界一次冻结）

在**现有** staging 聚合点、`MergeOrderedProjectedFarPhysicalPlans` 之后、任何 mutation 之前，由 SceneHost 一次性冻结 `Group.CommitUnits`：

| 单元 | 组成 | 成本 |
| --- | --- | --- |
| `FarPatch` | 该 patch 的全部候选组件 + 该 patch 的退场组件（一次 show-before-hide 原子交权） | 冻结时算出，与现有切片计数同源 |
| `BoundaryBatch` | 该 BatchId 的 1 个候选组件 + 同 BatchId 的 live 退场组件 | ≤ 2 toggle |

顺序 = child 原序；尾 child 内先自身 `FarPatch` 单元、再 boundary 批次单元，批次序复用 Merge 中已有的排序规则，**不新增排序规则**。冻结即构造边界：单元写集是合并写集的一份不相交划分，冻结时做一次「不相交并集 == 合并写集」等式校验并具名失败（AGENTS §2.2-6），此后消费侧不再复核。

### 3.2 单游标 + 先判后加预算

`Group.NextCommitUnitIndex` 是**唯一**游标；`NextVisibleCommitChildIndex` 降级为派生只读量（`= CommitUnits[cursor].ChildIndex`），不是第二真值。让帧判据仍只有 `ShouldYieldAfterFarPatchGroupCommitSlice` 一个，语义由「事后判」改为「预判下一单元」：

```text
SliceEnd = SliceBegin; Toggles = 0;
while (SliceEnd < Units.Num()) {
  Next = Units[SliceEnd].ToggleCost;
  if (SliceEnd > SliceBegin && Toggles + Next > Budget) break;   // 先判后加
  Toggles += Next; ++SliceEnd;
}
```

`SliceEnd > SliceBegin` 是活锁逃逸：首单元无条件入片，即使它自身超预算。`PatchRendererEpoch` 与 commit serial 同步改为**每单元一次**，`CoverageRendererEpochAdvanceCount` 初值由 `Plans.Num()` 改为冻结单元数；`RecordVisibleCommit` 只在 child 尾单元触发，保持一票一收据。

### 3.3 batch 只运输，没有组尾特殊事务

组（batch）此后只承担运输与调度：决定哪些单元一起入队、按什么顺序到达。它不决定原子性、不决定可见性、不携带第二份 ledger 或队列。**组尾不再是一个被合并放大的特殊不可分割事务**——尾 child 的 seam 批次就是序列里普通的 `BoundaryBatch` 单元。片内顺序保持既有形状、只是粒度变细：逐单元 ledger delta → show 本片全部候选 → hide 本片全部退场 → `ApplyDelta`。每个单元的新组件必然先于它自己的旧组件被隐藏，逐 chunk / 逐 slot 的 show-before-hide 因此比现状更强。

### 3.4 deferred / coverage / proof 全部派生

`BuildOrderedFarBoundaryDeferral` 的非空条件由 `0 < NextVisibleCommitChildIndex < Children.Num()` 改为 `0 < NextCommitUnitIndex < CommitUnits.Num()`；`Deferral.Slots` 由「尾 child 全部 boundary slot」收窄为「**尚未被已提交单元覆盖的 slot**」，仍从同一份合并写集派生。`FinalizePatchPresentationCoverage` 与 post-visibility fence 仍只在游标走完时发生，因此任何 seam 仍旧时 `coverage_complete` / parity / proof 依旧被阻断。唯一 SceneHost owner、唯一活动组槽、既有 Busy 让帧状态全部不变——**没有新增可写状态**。

### 3.5 供给侧：AdjacentStep + live Full 直接走 Full

两个事实都已在原地，无需跨层穿线：`EnsureFarTargetRequested` 自己就构建了 `TransitionPlan`（把 `Kind` 作为参数传给 `RequestPatchTarget` 即可），live Full 壳是 `AVoxiaPure3DVoxelWorldActor` 自己的私有状态。判据变为：

```text
bLiveFullShellRetained = (StepKind == AdjacentStep)
                      && PublishedFarTargetManifest.IsValid()
                      && PublishedFarTargetManifestScope == Full;
InitialScope = (Default && !bSameTargetAlreadyFull && !bLiveFullShellRetained)
             ? StartupRequired : Full;
```

`StepKind` 那一项不可省：它是挡住 `Relocate`（即使此刻有 live Full 壳也必须回 `StartupRequired`）的唯一条件。禁止用 `TransitionNearTiles` 非空当代理——那是隐式假设（AGENTS §2.2-3）。`Bootstrap` / `Relocate` / 冷启动快路径不变，required Far 的来源不变。

## 4. 生产与验收的边界

**生产代码不内置任何验收门禁。** `8 ms`、`2.5 s`、`6 s`、`90 %`、零重叠都不是运行时可据以杀会话、降级或改道的常量，它们只由自动化测试与验收脚本判定——与 [`2026-08-20-deadline-observe-not-kill.md`](2026-08-20-deadline-observe-not-kill.md) 同一条纪律。生产侧只做两件事：按契约推进自然流；在真实信任边界（冻结等式校验、identity / fence 失败）显式返回可诊断失败。

新增观测量 `far_group_commit_max_atomic_unit_toggles`（组快照与切片事件各一份）只是**归因用的观测面**，不参与任何运行时分支。

## 5. 最小充分测试

只改既有 suite，不新建；不重复 planner / auditor / spatial contract 已有覆盖，不跑全量 Automation。

| # | 测试 | 抓什么破坏 |
| --- | --- | --- |
| R1 | 改现有超预算组 fixture，child 规格换成非整除（如 6 × 7 toggle）：断言任何含 ≥ 2 单元的片 `slice_component_toggles ≤ 32`（今日事后谓词给 35，红） | 预算退回事后判定 |
| R2 | 改现有 `{40, 8}` 单 child 用例：期望由「片 = 40」改为「该片恰含 1 个原子单元且 toggles == 该单元成本」，并断言 `far_group_commit_max_atomic_unit_toggles == 40` | 有人为凑 32 切开原子 far patch（会同时破坏逐 chunk 交权） |
| R3 | 同 suite 新增「合并尾片 boundary 超预算」fixture：尾片跨 ≥ 2 次轮询；每个含 ≥ 2 单元的轮询 ≤ 32；每个中间轮询 `deferred_boundary_count > 0` 且同刻 `coverage_complete=false`、不提交 proof，走完后恰为 0；中间轮询 gap / overlap / orphan / protected 全 0；serial 推进量 == 单元数 | 尾片退回不可分割；或切了尾片却没让延迟集合保持武装 |
| R4 | 改现有 `ResolveInitialRuntimeScope` 纯函数用例，随新 bool 追加 3 条：`AdjacentStep` + live Full → `Full`；`Bootstrap` 无 live 壳 → `StartupRequired`；`Relocate` + live Full → `StartupRequired` | 缺陷本体复发；或矫枉过正让冷启动丢掉 required Far 快路径 |
| R5 | 在既有 `voxel_near_far_target_prepare_requested` 事件补 `step_kind` / `live_full_retained` / `initial_scope` 三个字段，由验收脚本断言 | 纯函数改对了但调用点恒传 `false`（R4 抓不到这一层） |

## 6. 一次 D3D12 验收门槛

同一受控真实场景**复跑一次**判完全部门槛：`1280×720`、`t.MaxFPS 130`、`r.VSync 0`、同一 +Z 走廊与相机，复用未改的 `eofu_gate.py` / `slice_structure.py`，含无抓屏子窗口复核。

| # | 门槛 |
| --- | --- |
| 1 | `Exclusive/GameThread/EndOfFrameUpdates` hard max ≤ `8 ms`，`eofu_over_8ms_frames = 0` |
| 2a | 所有含 ≥ 2 个原子单元的片 `slice_component_toggles ≤ 32`（结构性，单测已证） |
| 2b | `far_group_commit_max_slice_component_toggles ≤ max(32, far_group_commit_max_atomic_unit_toggles)`：任何越过 32 都必须可归因到恰好一个原子单元 |
| 2c | `far_group_commit_max_atomic_unit_toggles ≤ 42`（推导：baseline 实测最差 `0.374 ms`/新增实例，按 add : remove ≈ 1 : 1 折 `0.187 ms`/toggle，`8 / 0.187 ≈ 42.8` 取 42） |
| 3 | `protected_overlap / gap / orphan_seam_frame_count = 0`、`delta_fallback_count = 0`、最大连续共存帧 = 0 |
| 4 | ≥ 1 条 `deferred_boundary_count > 0` 且同刻 `coverage_complete=false`、`coverage_parity_verified=false`、`observation_epoch` 冻结 |
| 5 | required Far pending→complete ≤ `2.5 s`（产品 tracker 与闩锁相减两种口径都要过） |
| 6 | 单 tile `AdjacentStep` 后 Full Far ≤ `6 s` |
| 7 | 跨 tile 全程 `far_geometry_visible_patches` 不低于跨越前的 `90 %` |
| 8 | 同轮报出 `far_group_commit_slice_count` 与 Full Far 收敛墙钟，相对既有基线回退 ≤ `10 %` |

## 7. 退出条件与残余风险

- **若复跑显示 `far_group_commit_max_atomic_unit_toggles > 42`，或 EOFU 因单个原子单元越过 8 ms**：修复点在 **producer 侧 far patch 的组件划分**（build / mesh 侧每 patch 组件数上限），作为独立任务另行取证。**禁止在消费侧（切片器）加兜底、二次扫描、备用路径，或把原子单元切开。**
- 首要残余风险：按本次 `30237` 总 toggle / 32 估算，切片数将由 `186` 增至 ≥ `945`（约 5.1×），每个中间片要在下一帧多付一次全量覆盖审计（19683 格），该成本不在 `slice_ms` 内、现有产物无法给出量级。它与门槛 6、门槛 8 是本方案最可能失败的地方，**不得预先声称通过**。
- 门槛 3 的零重叠是硬不变量：任何为压低单片成本而放宽逐 far patch 原子交权的改法，一律视为方案失败而非折中。

## 8. 进度日志

- 2026-08-26：Task 5 只读根因诊断完成，定位两项唯一根因。
- 2026-08-26：Task 6 只读校核推翻「hard max 32 可达」，给出单游标 + 先判后加的最小状态机与结构化替代门槛。
- 2026-08-26：用户批准本方案；本稿定稿。实现、测试与 D3D12 验收均未开始。
- 2026-08-26：Task 1 / 2 / 3 已实现并审查通过；Task 4 单次 D3D12 实测门槛 3/4/7/8/9 过，1/2c/5/6 未过。
- 2026-08-26：Task 5A（producer 侧 far patch 组件划分）已实现并收口，门槛 1 待复跑判定。
- 2026-08-26：Task 5B 只读根因证实门槛 5/6 的 owner 是**供给侧的宽度冻结**，不是「far 被 near-first 挂起」：
  `FVoxiaFarBuildParallelism::Resolve` 把 `OneSpareWorker` 折成宽度 1，provider 与 resolved-surface
  又各自在阶段入口把逐帧门快照成宽度 1，`ReleaseUnpaced()` 之后无人恢复——一次真实 run 里
  1128 页 provider 用单线程跑了 13.757 s，而 16 线程专用 far 池有 15 条空转。
- 2026-08-26：用户裁定采用根因报告 §9.2（**固定配置宽度 + 既有逐单元让权**），不采用 §9.1 的
  「入口快照后动态加宽」。Task 5B 据此实现：许可只决定能否派工，宽度恒为配置值；near 优先只由
  `TPri_Lowest` / `EQueuedWorkPriority::Lowest` / `BackgroundPriority` 叠加 `FVoxiaVoxelShellBackgroundFramePacer`
  在**每个自然页 / 表面单元边界**的让权表达；provider 通过一个微型稳定契约 `PaceWorkUnit(uint64&)`
  取得同一让权语义，游标由各 drain worker 局部持有。未新增线程池、队列、调度抽象或产品埋点。
- 2026-08-26：门槛 5（`2.5 s`）与门槛 6（`6 s`）在新语义下的实测值由 Task 5A + Task 5B 收口后的
  **一次合并 D3D12 复跑**判定，本稿不预先声称通过；根因报告 §10-1 指出的「门槛 5 是否仍然可达 /
  仍然合理」在拿到该实测前保持未决。
- 2026-08-26（**更正**，Task 5B 审查 M-3）：上一条把 `FVoxiaFarBuildParallelism::Resolve` 的
  `OneSpareWorker → {1,1}` 折叠列进 13.757 s 的因果链并不准确。真正下发给 build 的宽度是
  `BeginPlay` 时以 **`Normal`** 解析并冻结的 `FrozenFarBuildParallelism`，与许可无关；那次
  1128 页单线程**只**由 provider 与 resolved-surface 两处阶段入口快照造成。`Resolve` 的折叠是
  **第三处同义的宽度耦合**，影响的是可派工校验与 `far_launch_effective_*` 观测口径，
  删除它仍然正确，但它不是那次单线程的原因。
- 2026-08-26：Task 5B 修复 1（nested `f38ce98`）收口审查的 Important/Minor。最实质的一条：
  宽度恢复后两处 drain 走的是 `ParallelFor`，而 UE 的 `ParallelFor` 使用全局 `LowLevelTasks`
  调度器而不是调用方的 `FQueuedThreadPool`——让权阻塞因此落在**共享 TaskGraph 后台 worker**
  上（违反引擎「不要用长时间运行或会阻塞的任务堵塞 task graph」的显式契约），
  16 线程专用 far 池仍然空转，上一条里「叠加 `BackgroundPriority` 表达 near 优先」的说法
  也随之失真。现改为：两处 drain 都在既有 `FarBuildThreadPool` 上执行——调用方（build 任务
  本身就是该池线程）认领第一份份额，其余份额以 `EQueuedWorkPriority::Lowest` 投回同一个池，
  投递数以 `GetNumThreads() - 1` 为上界保证不自锁。未新增池、队列、调度抽象或第二条路径。
  同轮还把 provider 让权点移到「认领到下一个自然页单元」之后（最后一页之后不再多等一次授予），
  并在既有 `provider.parallel` 对象内增加 `pacing_wait_ms`，使复跑能把让权等待从
  `work_ms` 的墙钟里拆出来对账。
- 2026-08-26：**用户裁定**：本轮不新增、不运行自动化测试，也不把测试当门禁；唯一验收是
  实际连续跨多个 tile 流送顺畅、Near/Far 无重叠/空洞/空气墙、无明显卡顿或挂起，
  由协调器统一安排的**唯一一次真实 D3D12 长流程**判定。
- 2026-08-26（用户实跑反馈 → 第四轮根因）：`b25c068` / `f38ce98` / 同日三份 engineering note
  收口后，跨 tile 仍有「新 Near 逐个上屏、旧 Far 再等 3–4 秒随大 Far 组整批消失」。
  取证（`clients/Voxia/Saved/Logs/run_voxia_3d_world.log`，14:40 UTC 的 `8,0,-54` 换区）
  指向**门槛 5/6 的最后一个串行点**：`ResolveFarDispatchPermission` 在 Near fence 未完成时
  返回 `OneSpareWorker` → `GrantOneFrame` 逐帧门，far 吞吐退化为「worker 数 × 帧率」
  （`far_background_frame_grants=4882`，16 条专用 far 线程大部分时间在等帧）；
  Near 入场门又要等整窗 near mesh（`2824.7 ms`）才闭合，逐帧门解除后剩余 far 工作只需
  `2.12 s`。manifest 发布前 publication mode 恒 `Held`，`required_far_patches=4` 的必需
  补丁同样发不出去，因此新 Near 全可见（`34.0`）到旧 Far 首次被替换（`38.31`）共存 `4.3 s`。
  修复：`ResolveFarDispatchPermission` 新增 `bFarTargetHandoffPending`（调用点供给
  `RequestedPatchTargetKey.IsSet()`，其生命周期恰为「far manifest 已请求、尚未发布」），
  与 `bSharedSourceBootstrapRequired` 同类返回 `Normal`；逐帧门保留其真正定义域
  （无待交接目标的同目标后台扩展）。这不改 §3.5 的供给侧 scope 判据，也不改呈现侧切片器。
  同轮修掉 ownership atlas 换对象时 `MarkLiveFarOwnershipRenderStateDirty` /
  `BindRendererOwnershipMaterialsToAllFarComponents` 漏刷 `LiveBoundaryBatches` 的缺口。
  细节与实跑判据见 [`clients/Voxia/docs/engineering-notes/2026-08-26-far-target-handoff-frame-gated.md`](../../../clients/Voxia/docs/engineering-notes/2026-08-26-far-target-handoff-frame-gated.md)。
  门槛 5/6 与门槛 1（EOFU）仍由**同一次真实 D3D12 复跑**判定，本条不预先声称通过。
- 2026-08-26（残余，未做）：相邻步实际只有 ~10 个 far patch 需要重建
  （`voxia_layer_interface_build_timing … patches=10`），但 `voxia_far_patch_build_stage_timing`
  仍是 `total_ms=1612 … patch_count=6859`。far target manifest 因此是一个成本与增量不成比例的
  不可分割单元，按 AGENTS §2.2-9「修复点在上游划分」应单独立项取证，不在本稿范围内。
- 2026-08-26（第四轮实施 + 实跑）：按上一条实施后**第一次复跑毫无变化**，日志证明修复被
  自身抵消：判据窗口只覆盖到 `voxia_patch_target_published`，而 far 几何全在关窗之后产生；
  关窗当帧许可掉档，`ShouldRestartUnpacedFarBuild` 在 3 ms 后把一个已跑到 `patch_mesh`
  的 Full 构建整份作废重跑并重新挂门。最终收敛为三处修复（缺一不可）：
  (1) 许可窗口扩为 `RequestedPatchTargetKey.IsSet() || 当前目标 handoff 未完成`；
  (2) 删除 `ShouldRestartUnpacedFarBuild` 及其调用点——pacer 不可逆，降档只能靠丢弃工作；
  (3) far 发布门由入场闩锁（含 `!bNearMeshBuilding`，换 tile 时要等整窗 9261 chunk 重过指纹）
  改读 SceneHost 的完整 Near 覆盖证明 `GetLastCompleteNearWindow`。
  实测：`pacing` 全程 `unpaced`、`restart=0`、`paused=0`、发布门贴着覆盖证明触发（`+14/15 ms`）、
  玩家换区期间 `gap_count` 与 `boundary_orphan_count` 全 `0`、`LogVoxia: Error=0`。
- 2026-08-26（用户裁定 + 实施）：删除 `bHasCompleteDependencyDirtyProof`。它是 planner
  已精确表达的脏集合的第二份粗副本，且粗的覆盖精的（拿不到证明就把 33725 页全标脏）。
  核实三点后确认冗余：`IsIncremental()` 只有这一个消费者；生产路径从不填 legacy 复用图，
  唯一复用源 `ReusableArtifactCache` 已有 source fingerprint 硬校验（显式失败而非静默降级）；
  planner 在 `cold_start` / `source_identity_changed` 两种全量情况下脏集合本身就是全量。
  同轮补两条观测：`voxia_far_incremental_plan`（含 `full_rebuild_reason` 与六项 counts）、
  `voxia_far_surface_reuse`（脏页规模与快/慢路命中）。实测页级增量健康：
  `dirty_pages=1336 / planned=33725`，`fast_reused=31529`（`93 %`）。
- 2026-08-26（**更正**）：一次量到的 `67–78 ms` 共存是 `StartupRequired` scope
  （`required=6598`）下的非典型样本；Full 壳 live 后的相邻步走 `required=33752`，
  manifest 落在 `+1.1 ~ +5.7 s`，玩家实测共存仍达 `4–5 s`。上述修复解决的是「far 被限速 /
  被取消重跑 / 被 CPU mesher 挡住发布」，不触及 far 每步的**工作量**；稳定态下工作量是主导项。
- 2026-08-26（下一步，已与用户对齐）：剩余根因是**整目标 after-image 屏障**——
  `MergeOrderedProjectedFarPhysicalPlans` 之前那道「主线程必须先拥有全量 after-image」的
  metadata 遍历（`ParallelFor` 全部 `6859` patch，`670–1393 ms`）与层间面 `candidate_scan`
  （每步扫 `59610` candidates / `33752` owner_tiles，产出仅 `~920` patch）。它是屏障不是
  并行度问题：已跑在 16 线程上，加线程只能除常数。修法为「上一代表 + 脏 delta = 这一代完整表」，
  屏障、原子交权契约与 `gap=0` 不变量全部保持不变，构造成本由 `O(target)` 降为 `O(dirty)`。
  明确不采用「先提交、不一致先露着」：省不下同样的几秒，只把重影换成破洞，且会拆掉
  `gap_count=0` 这个唯一能证伪发布门改动的仪器。
