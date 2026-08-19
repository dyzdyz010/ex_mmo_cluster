# Full Far 稀疏残差收敛实现计划

> 对应设计：`docs/10-active/voxel-far-field/2026-08-16-full-far-sparse-residual-convergence-optimization.md`

目标：在不改变完整 27-tile Near 用户放行门、完整 XYZ 契约与近到远顺序的前提下，消除
无渲染差异 Far Patch 的边界重建与两道 RHI fence，并在 Near 已稳定后恢复 Full 构建并行度。

## Task 1：planner 精确边界残差与渲染效果分类

文件：

- 修改 `clients/Voxia/Source/Voxia/Presentation/VoxiaPatchCommitPlanner.h`
- 修改 `clients/Voxia/Source/Voxia/Presentation/VoxiaPatchCommitPlanner.cpp`
- 修改 `clients/Voxia/Source/Voxia/Presentation/VoxiaPatchCommitPlannerAutomationTest.cpp`

步骤：

1. 先在 automation 中增加失败断言：全 absent 空 patch 的边界写集为零且无需渲染命令；
   单槽身份变化只写一个 slot/batch；旧几何被空 patch 替换仍需渲染命令；几何 payload 仍需
   渲染命令。
2. 运行 Development build，确认测试先因新期望或缺少分类 API 失败。
3. 为计划增加只读的 `RequiresRenderCommands()`；它只从冻结 read-set、完整 after-image、
   geometry payload 与 ownership 写集计算，不读取 UObject。
4. 将 `AddFarWriteSet` 改为逐槽比较 live ledger 与 after-image，仅把真实变化写入
   `BoundarySlots/BoundaryBatches`；Far Patch 本身仍始终进入写集。
5. 更新 `IsValidInternal`：重算期望残差并拒绝伪造的稀疏写集。
6. 重跑 focused automation，确认 RED 变 GREEN。

### Task 1b：语义身份与物理 mesh effect 残差解耦

实跑若证明 renderer mutation 仍被临时边界语义放大，则继续在同一 planner / SceneHost 事务中
完成第二层精确化，不另建旁路：

1. 先增加 RED：相同 mesh 仅改变 provisional/final kind 或 incident/version 时，artifact
   version 必须变化，但 geometry identity 与物理 batch identity 必须稳定。
2. 给计划同时维护完整语义 boundary write-set 与物理 renderer write-set；后者只在几何
   出现、消失或 geometry identity 改变时写入。
3. SceneHost 对仅语义变化的 slot 原位更新 payload/binding/coverage receipt，复用原组件与
   handle，不创建、隐藏、退役组件，也不 arm fence。
4. 增加 planner、batch builder、SceneHost transaction 回归，再重新实跑 Full Far；所有
   ledger、manifest、coverage、顺序与无洞门禁保持不变。

## Task 2：无渲染命令的 SceneHost 原子提交

文件：

- 修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationResourceSet.h`
- 修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationResourceSet.cpp`
- 修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationResourceSetAutomationTest.cpp`
- 修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.h`
- 修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.cpp`
- 修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHostTransactionAutomationTest.cpp`

步骤：

1. 先增加 lifecycle 失败测试：无渲染命令时可从 hidden staging 直接得到 ready-to-commit，
   ledger commit 后直接得到 committed，且 staging/post epoch 相等、没有 pending fence。
2. 增加 SceneHost 失败测试：初次提交精确空 Far Patch 时 ticket 在一次 poll 内完成、组件数不变、
   ledger/renderer receipt/manifest 均前进；有边界或旧几何变化时仍等待真实 fence。
3. 实现显式的 no-render-command lifecycle 转换；禁止复用或伪装 `FRenderCommandFence` 完成。
4. SceneHost 在 `RequiresRenderCommands() == false` 时跳过边界构建、RHI fence 与资源退休；
   仍执行 read-set 二次复核、ledger delta、manifest、renderer coverage delta 和审计。
5. 在事务快照加入渲染效果字段，供 actor 调度与 CLI/observe 使用。
6. 重跑 ResourceSet、Transaction、SceneHostLedger、RendererCoverage focused automation。

## Task 3：连续前缀批处理与 mailbox 分流

文件：

- 修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler.h`
- 修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler.cpp`
- 修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageSchedulerAutomationTest.cpp`
- 修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.h`
- 修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.cpp`
- 修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaFarConfirmedPresentationAutomationTest.cpp`

步骤：

1. 先写失败测试：无命令 commit 可在 `1.0ms` / `32` 条双预算内继续；渲染事务只有在
   post fence 完成后才可衔接下一有序事务；只有携带几何 shard 的 mailbox 移交才强制让帧。
2. 将 begin 成功后的第一次 poll 合并到同一次推进，允许无命令事务同步完成。
3. 只批处理现有 BuildIndex 有序队列的连续队首；保留 Held、RequiredOnly、Speculative、
   Near priority 和 supersede 判断位置。
4. 增加稀疏 batch、最大 batch、render-command-free、renderer-mutation 与 boundary slot
   skipped/written 计数，并写入 snapshot 与 Full 完成 observe。
5. 跑 scheduler 与 FarConfirmedPresentation focused automation。

## Task 4：Full 构建自适应并行

文件：

- 修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler.cpp`
- 修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldCoverageSchedulerAutomationTest.cpp`
- 按测试需要修改 `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.cpp`
- 按测试需要修改 `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelShellResolvedSurfaceStagerAutomationTest.cpp`

步骤：

1. 先把旧“Full + Normal 仍 GrantOneFrame”断言改为失败的新期望：Normal 必须
   `ReleaseUnpaced`，OneSpareWorker 仍 `GrantOneFrame`，Blocked 仍 `Paused`。
2. 实现许可驱动 pacing，删除 Full 标签对 Normal 的永久单工覆盖。
3. 保持目标变化 cancellation；验证 Near 重新进入关键期时可暂停或显式取消旧 Full，不允许
   无维护地继续占用。
4. 验证 provider/surface 在 unpaced 下恢复配置 worker 数，paced 下仍为单 worker。

### Task 4b：物理 boundary batch 的有界同帧排空

第一轮 Full 证据若显示渲染事务的真实工作很轻、但被逐 batch 分帧放大，则在 SceneHost 内部
优化同一个事务，不改变 patch 粒度和 fence：

1. 先增加失败测试，锁定 `2.0ms` 软时间预算与 `8 batch/poll` 硬数量上限；无效计数必须
   保守让出。
2. `CompleteCandidateBoundaryBatches` 在一次 poll 中连续消费有序物理 batch 前缀，任一预算
   到达即返回 Busy；全部隐藏组件完成后才进入 staging fence。
3. timing 日志增加 `polls`、`yields`、`max_batches_per_poll`、预算与硬上限；不得把多个 patch
   合成新事务，也不得弱化 staging/post-visibility fence。
4. 重跑 ResourceSet、SceneHostLedger、Transaction automation，再进行 Real-RHI Full 对比。

### Task 4c：消除 post-fence 完成后的事务间空泡

1. 先把“renderer mutation 完成后无条件让帧”改成失败的新期望：只有完整 post fence 已确认的
   事务才会进入该策略，此时允许在本 Tick 预算内领取下一有序队首。
2. 保留 `1.0ms` 软预算、`32 commits/tick` 硬上限、几何 mailbox 让帧和每个新事务自己的两道
   fence；不允许在 fence pending 时提前发布 receipt。
3. 重跑 WorldCoverageScheduler 与 FarConfirmedPresentation，再跑 Real-RHI Full 对比。

## Task 5：文档、CLI 与 smoke 门禁

文件：

- 修改 `clients/Voxia/Source/Voxia/Presentation/README.md`
- 谨慎合并修改 `clients/Voxia/Source/Voxia/Gameplay/README.md`
- 谨慎合并修改 `clients/Voxia/README.md`
- 谨慎合并修改 `docs/00-current-truth/design/client/streaming-lod.md`
- 修改 `clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.js`
- 修改 `clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.test.js`
- 更新对应 active 设计文档的进度与证据

步骤：

1. 先给 Node validator 增加失败测试，要求 Full 证明包含残差/worker/顺序统计，同时继续要求
   `27/9261` Near 门、`6859` Far、clean audit 与完整终态。
2. 实现 JSON/observe 字段解析和验收；保留已有兼容错误的显式诊断。
3. 更新最近 README 与 current truth，说明这是同一事务的物理残差优化，不是空气专用路径。
4. 运行 `node --test scripts/*.test.js`。

## Task 6：编译、自动化与真实 Full Far 对比

工作目录：`clients/Voxia`

1. Development build：

   ```powershell
   & 'C:\Program Files\Epic Games\UE_5.8\Engine\Build\BatchFiles\Build.bat' `
     VoxiaEditor Win64 Development `
     -Project="$PWD\Voxia.uproject" -WaitMutex
   ```

2. focused automation：

   ```powershell
   & 'C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe' `
     "$PWD\Voxia.uproject" -unattended -nop4 -NullRHI `
     -ExecCmds='Automation RunTests Voxia.Presentation.PatchCommitPlanner+Voxia.Gameplay.VoxelPresentationResourceSet+Voxia.Gameplay.VoxelPresentation.Transaction+Voxia.Gameplay.VoxelPresentation.SceneHostLedger+Voxia.Gameplay.WorldCoverageScheduler+Voxia.Gameplay.FarConfirmedPresentation;Quit' `
     -TestExit='Automation Test Queue Empty' -log
   ```

3. 完整 `Automation RunTests Voxia` 与 Node 全量测试。
4. 运行生产组合根 mock cold-start：确认用户放行前 Near 恰为 27 tiles / 9261 chunks，排序
   近到远，放行时间不回退超过 10%。
5. 运行 Real-RHI `fullfar` 到完整收敛，保存 `.demo/observe/`，比较：
   - build complete；
   - presentation drain；
   - total full convergence；
   - render-command-free / renderer-mutation 数；
   - provider/surface worker 数与 foreground rest；
   - p95 frame、final 6859、clean audit、manifest/order/ownership/fence 错误数。
6. 若仍高于 `240s`，只按新增分层证据处理最大剩余瓶颈并重新走 RED/GREEN；不得用固定 sleep、
   跳过证明或扩大无界帧预算掩盖问题。
