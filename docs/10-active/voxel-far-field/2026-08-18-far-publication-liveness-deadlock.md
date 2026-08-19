# 跨 Tile 后 Far 发布活性死锁设计稿

日期：2026-08-18
状态：根因已定位并修复；剩余项见第 7 节
范围：`clients/Voxia` 的呈现提交账本不变量、`FVoxiaPatchCommitPlanner` 读集校验与
`AVoxiaPure3DVoxelWorldActor` Far 发布循环可观测面；不涉及服务端

## 1. 触发现象

`node clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.js --real-rhi --performance-only`
在 `performance_clearance_to_verified_empty_near_1` 步骤确定性失败：`far_deadline_exceeded`。

产物：`.demo/observe/voxia_post_incremental_ledger_summary_performance_2026-08-18/`
`voxia_phase1_2026-08-18T08-06-40-269Z_real_rhi_1280x720/`。

第一代（冷启动，中心 `[11,0,-51]`）完全正常：Near `7860ms`、Far `9561ms`、
`33725 pages / 6859 patches` 全部收敛。失败发生在随后 `+Y` 相邻步进到 `[11,1,-51]`
产生的第二代目标上。

## 2. 时间线证据

| 时刻 | 事件 | Far deadline |
|---|---|---:|
| `08:07:18.645` | `voxel_near_far_target_prepare_requested` 第二代 | 未启动 |
| `08:07:18.646` | `voxel_pure3d_build_dispatch_deferred` | 未启动 |
| `08:07:20.535` | `voxel_near_entry_gate_satisfied` → **Far 时钟起点** | `0ms` |
| `08:07:20.561` | `voxel_pure3d_world_prepare_started`、dispatch resumed | `26ms` |
| `08:07:21.283` | `voxel_pure3d_world_build_started` | `748ms` |
| `08:07:25.634` | `voxel_liveness_stall`，`far_readiness_reason=far_target_not_current` | `5078ms` |
| `08:07:27.416` | `voxia_far_prepared_target_published` 第二代 Far 目标才存在 | `6881ms` |
| `08:07:27.633` | `voxel_pure3d_stream_committed` | `7098ms` |
| `08:07:32.566` | `voxel_patch_streaming_failed`：`far_deadline_exceeded` | `12006ms` |

因此 12 秒预算被切成两段，两段都有独立缺陷。

## 3. 缺陷 A：Far 时钟包含尚无 Far 目标的世界重建

Far deadline 在 `20.535` 锁存，但该 TargetKey 的 Far 目标直到 `27.416` 才发布。其间
`6881ms`（占预算 `57.3%`）的 `far_readiness_reason` 恒为 `far_target_not_current`：Far patch
streamer 根本没有可消费的目标，时钟却在走。

这段时间的实际持有者是 pure3d Far 世界重建，`voxia_far_patch_build_stage_timing` 记为
`total_ms=2027.724`（`metadata_ms=1217.712`、`layer_interfaces_ms=615.719`、
`priority_sort_ms=14.644`、`grouping_ms=21.656`），其余为 prepare/plan/publish 与
residency/artifact cache 归档。注意 `voxia_far_target_publish_timing` 只有 `3.673ms`，
即目标发布本身不是瓶颈。

同一 `+Y` 路线在 2026-08-17 的独立验收里 Far 差分耗时 `7648ms` 并通过，量级一致；因此
A 单独不足以造成硬失败，它只是把预算压缩到不足 `5.2s`。

## 4. 缺陷 B：LayerFace 精确计数失配导致的发布活锁（真正的失败原因）

Far 目标到位后，剩余预算内 Far 侧零进展。首轮静态推断曾指向
`patch_presentation_previous_transaction_not_retired`，**该推断是错的**；补上可观测面后实测
`presentation_availability_block` 全程为空串，呈现事务始终可用。

### 4.1 补上的可观测面

原先 Far 发布循环每 Tick 的 `Waiting`/`Busy` 结果既不写 `patch_streaming.error`，也不进任何
观测面，因此“发布侧无限重试”与“正在正常推进”不可区分。本次新增：

- `far.publication_wait_state` / `publication_wait_reason` / `publication_wait_repeat`：
  发布循环上一次非 Ready 结果与其连续重复次数；
- `far.presentation_availability_block`：SceneHost 阻塞新事务的具体条件（只读，不排空 cleanup）；
- `far.boundary_build_dispatched` / `boundary_build_consumed`：边界几何异步构建的派发与收割计数；
- `voxia_far_publication_wait_changed`：只在诊断变化的边界上落一条结构化记录，用于还原完整循环；
- 读集审计失败不再只报分类名，改为带出不洁分类与首条审计诊断。

### 4.2 实测循环

`.demo/observe/voxia_far_wait_cycle_probe_2026-08-18/` 显示一个周期约 `77ms` 的稳定环：

```
far_patch_candidate_mailbox_pending
far_patch_boundary_build_in_flight              ×5~7
[far_patch_group_prepare_slice_yield]
patch_presentation_exact_renderer_read_not_ready[gap=1,invalid_ledger=1
  |presentation_ledger_snapshot_layer_face_count_mismatch]      ← 拒绝并重排
```

`.demo/observe/voxia_far_boundary_dispatch_probe_2026-08-18/` 用计数确认这不是单次长构建：
第一代结束时 `dispatched = consumed = 6859`（每个 Far Patch 恰好一次）；第二代在
`2520ms → 12002ms` 之间 `dispatched` 由 `6879` 涨到 `7130`，即为同样的 **2** 个 required
patch 反复重建了约 `251` 次边界几何，`required_published` 始终为 `0`。

### 4.3 根因

`FVoxiaPresentationCommitLedgerSnapshot::LiveLayerFaceArtifactCount` 在上一阶段由“完整扫描
求值”改为“增量维护字段”，并在 `IsStructurallyValid` 中加了硬失败：canonical 表里
`LayerFace` 的实际条数必须等于该字段。

但 `VoxiaPatchCommitPlanner.cpp` 的 `AddCanonicalArtifact` 直接写
`Snapshot.LiveBoundaryArtifacts`，从不维护该计数，而它正是读集校验装配**过滤账本**的唯一入口。
于是只要读集含至少一个 LayerFace 边界工件：

```
过滤账本：CountedLayerFaceArtifacts >= 1，LiveLayerFaceArtifactCount == 0
→ presentation_ledger_snapshot_layer_face_count_mismatch
→ 审计 invalid_ledger=1 → patch_presentation_exact_renderer_read_not_ready
→ 该 child 被拒绝并 RequeueUnpublished → 重新 Pop、重建边界 → 无限重复
```

第一代不触发是因为其 required 集合的读集不含 LayerFace；跨 Tile 步进后的 `2` 个 required
Far Patch 位于移动边界上，读集必然包含层间面，因此必然触发。

同一缺陷已经把 `Voxia.Presentation.PatchCommitPlanner` 与 `Voxia.Presentation.RendererCoverage`
两个自动化测试留成红色（诊断字符串与线上完全一致），只是此前未被当作阻塞项处理。

### 4.4 修复

不变量交还给类型自身，调用方不再各自记账：

- `FVoxiaPresentationCommitLedgerSnapshot` 新增 `SetBoundaryArtifact` /
  `RemoveBoundaryArtifact`，写 canonical 表的同时维护 LayerFace 计数；
- `ApplyLayerFaceArtifacts`、Face/Edge/Corner 提交路径、`AddCanonicalArtifact` 与相关测试夹具
  全部改走该入口；生产代码中不再存在直写 `LiveBoundaryArtifacts` 的位置。

## 5. 缺陷 C：活性检测在真实冻结时报告未失速

`08:07:31.774` 的 liveness summary 为
`waiter_id=required_far_complete, wait_ms=11177, stall_ms=0, stalled_count=0`，而同一时刻
Far 已连续冻结数秒。进度指纹为
`RequiredFarWorkCount|RequiredFarPublishedCount|FarCommittedPatchCount|PendingRequiredCount|
InFlightCount|ReadyCount|RendererEpoch`；上述重排循环使 `PendingRequiredCount` 与 `ReadyCount`
在 `0/2` 之间来回翻转，指纹持续变化，失速计时被反复清零。

“反复搬运同一批候选”被记成进展，是活性合同的漏洞：指纹必须只由单调量构成。**本次未修复**，
留作独立项。

## 6. 修复后实测

`.demo/observe/voxia_layerface_count_fix_performance_2026-08-18/`
`voxia_phase1_2026-08-18T12-53-31-479Z_real_rhi_1280x720/`：

| 目标代 | Near | Far |
|---|---:|---:|
| gen1（冷启动） | `10674ms` completed | `11375ms` completed |
| gen2（跨 Tile） | `1747ms` completed | **`5009ms` completed** |
| gen3 | `1704ms` completed | `5293ms` completed |
| gen4 | `1719ms` completed | 进行中 `5466ms` |

跨 Tile Far 由“永不收敛（12s 硬失败）”变为约 `5s` 收敛。完整
`Automation RunTests Voxia` 为 `224/224` success、`0` fail（修复前 `PatchCommitPlanner` 与
`RendererCoverage` 为红）；Node `187/187`。

## 7. 仍未解决

1. **帧门禁**：同一路线现在推进到 `measureMove` 才失败——`GameThread p95 5.018ms`
   超 `3.5ms`、单帧 `39.255ms` 超 `33.33ms`。该门禁在本次修复之前的多次 probe 里同样失败
   （`voxia_clean_pre_soak_probe2..9`），是独立的既有问题。
2. ~~静止 Full Far 收敛回退~~ **已定位并修复，见第 9 节。**
3. **缺陷 A**：Far 时钟仍包含尚无 Far 目标的世界重建；本次实测该段最短约 `1.7s`、最长约
   `6.9s`，波动很大。是否把它移出 Far 时钟属于契约议题，另开决策稿。
4. **缺陷 C** 的进度指纹未改。

## 8. 进度日志

- 2026-08-18（续）：定位并修复缺陷 D。静止 Full Far 收敛超限的根因不是活性问题，而是
  `MaxLiveFarPatchGroupRendererMutations = 32` 把组数从 `34` 抬到 `120`，使按组固定的
  fence/投影/轮询成本被多付近四倍。改为 `128` 后 Full Far 由 `9844ms` 降到 `5045ms`，
  `--vertical-only` 由失败转为通过，GameThread p50/p95/p99 同步改善。
- 2026-08-18：从失败产物完成初步定位，提出的 `previous_transaction_not_retired` 假设经
  实测证伪；补齐 Far 发布等待原因与呈现事务阻塞项的可观测面后，确认真因是
  `LiveLayerFaceArtifactCount` 增量计数在 `AddCanonicalArtifact` 缺失维护。修复后
  跨 Tile Far 由活锁变为约 `5s` 收敛，`Automation RunTests Voxia` 由红转绿 `224/224`，
  Node `187/187`。剩余项见第 7 节。

## 9. 缺陷 D：入场后单组渲染变更上限 `32` 同时恶化吞吐与帧稳定

### 9.1 成本模型

对通过的 `--full-far-only` 路线（`6859` child）按组聚合
`voxia_far_patch_group_submitted`：

```
prepare_wall_ms   5100.6   每child 0.744    ← 其中 GameThread 实占仅 prepare_call 479ms
boundary_worker_ms 7333.5  每child 1.069    ← worker 线程，平均并发仅 7333/5100 ≈ 1.44
group_submit_to_commit_ms 4708.8           ← 按组固定的 fence 往返
commit_batch_count 120     组均 57.2 child
```

即 `Far ≈ 组数 × (每组 prepare 42.5ms + 每组 fence 39.2ms)`，`120 × 81.7ms ≈ 9.8s`。

组均只有 `57`，而 child 上限是 `256`；真正的约束是
`commit_batch_renderer_mutation_count / 组 = 3752/120 ≈ 31.3`，正好卡在本轮工作树新增的
`MaxLiveFarPatchGroupRendererMutations = 32`。

### 9.2 根因

该上限的意图是「玩家入场后限制单次可见切换的真实渲染变更峰值，保护帧稳定」。但每组还带有
一份**与 child 数无关的固定成本**：共享 staging/post fence 往返、投影账本重建、组快照与轮询。
把上限压到 `32` 使组数从 `34` 涨到 `120`，这份固定成本被多付了近四倍，而它恰恰落在
GameThread 上。因此该上限不但没有换来帧稳定，反而同时劣化了吞吐与帧稳定——它的前提被实测证伪。

### 9.3 实验

1280×720 Real-RHI，仅改该常量：

| 上限 | Full Far | 组数 | GT p50 | GT p95 | GT p99 | GT max |
|---:|---:|---:|---:|---:|---:|---:|
| `32` | `9844ms` | 120 | `3.851ms` | `5.018ms` | `7.774ms` | `39.255ms` |
| `128` | `5360ms` | 34 | `2.347ms` | `3.257ms` | `4.298ms` | `28.553ms` |
| `256` | — | 34 | `2.287ms` | `3.112ms` | `4.227ms` | `32.049ms` |

三档在 p50/p95/p99 上单调改善；`max` 与 hitch ratio 由个位数离群帧主导，噪声大，不随该常量单调
变化（属第 7 节第 1 项的独立问题）。

### 9.4 决定

取 `128`：拿到几乎全部收益，同时对单次可见切换的真实渲染变更仍保有峰值约束（`256` 等于 child
上限，等于取消该约束，收益相对 `128` 只有约 `0.15ms` 的 p95 差异，不足以放弃约束）。

### 9.5 修复后实测

- `--full-far-only`：Far `5045ms`（原 `9844ms`），`validation_code=ok`，`34` 组，
  `33725 pages / 6859 patches`，settled/coverage clean/quiescent 均为真。产物
  `.demo/observe/voxia_mutcap128_final_fullfar_2026-08-18/`；
- `--vertical-only`：**通过**（原为静止收敛门禁 `12007ms` 超限失败）。六代目标 Far 分别为
  `5364/4423/5560/4814/3748/4664ms`，Near 除首代 `7608ms` 外均约 `1.7s`；终态同样
  `34` 组、`33725/6859`、全部干净。产物
  `.demo/observe/voxia_mutcap128_final_vertical_2026-08-18/`；
- 完整 `Automation RunTests Voxia` `224/224`、`0` fail；Node `187/187`。
