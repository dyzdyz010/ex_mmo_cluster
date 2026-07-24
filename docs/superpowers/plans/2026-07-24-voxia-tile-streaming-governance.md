# Voxia 按 Tile 渐进流送实施计划

> **执行要求：** 在 `.worktrees/voxia-phase2-macro-interaction` 的
> `codex/voxia-phase2-macro-interaction` 分支实施；每项先写失败测试，再写最小实现。

**目标：** 玩家进入新 Tile 时立即启动 required near 更新；Chunk 作为最小后台调度单位；
每个 Tile 就绪后独立、单帧完成 far/near ownership 与六面 seam 替换；预测预取不能占用
required 保留容量；玩家相对实际 live near coverage 超出 3 chunks 时才停止移动并显示加载中。

**架构边界：** 沿用唯一 `AVoxiaUnifiedVoxelWorldActor` 生产组合根、现有 near mesh worker、
Tile ownership atlas、SceneHost 与客户端 flow。27 Tile barrier 只表示整窗 settled，不再作为
首个 Tile 可见提交的前置条件。每帧最多一次 Tile 可见 mutation，post-visibility fence
异步回收旧资源，不阻塞下一 Tile。

**技术栈：** UE 5.8、C++、Unreal Automation Test、Voxia stdio CLI、Node smoke runners。

---

## Task 1：required 优先与 Chunk 边界让路

**文件：**

- 修改：`Source/Voxia/Voxel/VoxiaNearWindowLifecycle.h`
- 修改：`Source/Voxia/Voxel/VoxiaNearWindowLifecycle.cpp`
- 测试：`Source/Voxia/Voxel/VoxiaNearWindowLifecycleAutomationTest.cpp`
- 修改：`Source/Voxia/Net/VoxiaTransportSubsystem.cpp`
- 修改：`Source/Voxia/Gameplay/VoxiaPlayerSessionController.cpp`

1. 在 `VoxiaNearWindowLifecycleAutomationTest.cpp` 增加红测：
   - speculative 最多使用 `WorkerLimit - 1` 个 physical slots；
   - speculative 占用或被标记 abandoned 时，required 仍能立即取得保留槽；
   - snapshot 分别报告 required/speculative in-flight；
   - speculative worldgen 单批只处理一个 Chunk，promotion 后恢复 required 批量。
2. 构建并运行 `Voxia.Voxel.NearWindowLifecycle`，确认测试因缺少意图感知 admission 失败。
3. 给 physical worker tracker 的 entry 保存 `EVoxiaNearWindowPrepareIntent`，提供意图感知
   `TryStart`；保留旧 required 默认重载，避免无关调用点扩散。
4. speculative 只允许占用未保留容量；required 可使用全部容量。abandoned worker 在真正
   完成前仍计入各自 in-flight，但不能侵占 required 保留槽。
5. 增加纯函数解析 worldgen batch：speculative 为 1 Chunk，required 使用配置批量。
6. Transport 的 pack/worldgen worker 传入当前 prepare intent；speculative 无容量时延后，
   不把 prepare 标记为确定性失败。
7. `MaintainRuntime` 先 `MaybeRefreshSubscription`，后 `MaybePrefetchNearWindow`。
8. 重新构建并运行目标测试，确认绿色。
9. 提交：`fix(streaming): reserve near workers for required tiles`

## Task 2：解除 near/far 后台准备的互相阻塞

**文件：**

- 修改：`Source/Voxia/Gameplay/VoxiaWorldCoverageScheduler.cpp`
- 测试：`Source/Voxia/Gameplay/VoxiaWorldCoverageSchedulerAutomationTest.cpp`
- 修改：`Source/Voxia/Gameplay/VoxiaNearActivePresentation.cpp`
- 测试：`Source/Voxia/Gameplay/VoxiaNearActivePresentationAutomationTest.cpp`

1. 先修改测试，要求 near required loading 时仍允许 far hidden build dispatch，并要求 far
   launch/build 不延迟 near required presentation。
2. 运行两个目标测试，确认旧 defer 策略导致失败。
3. 删除普通流送路径上的双向 defer；可见 ownership 仍由既有事务门禁控制，因此后台并行
   不扩大可见提交权限。
4. 运行目标测试并提交：
   `fix(streaming): prepare required near and far work concurrently`

## Task 3：按 Tile 就绪，不等 27 Tile 整窗

**文件：**

- 修改：`Source/Voxia/Gameplay/VoxiaNearActivePresentation.h`
- 修改：`Source/Voxia/Gameplay/VoxiaNearActivePresentation.cpp`
- 测试：`Source/Voxia/Gameplay/VoxiaNearActivePresentationAutomationTest.cpp`
- 修改：`Source/Voxia/Gameplay/VoxiaWorldActor.h`
- 修改：`Source/Voxia/Gameplay/VoxiaWorldActor.cpp`

1. 先增加纯状态红测：
   - Tile 未完成 343 个 Chunk 时不能 ready；
   - 第一个 Tile 完成后立即出现在 `ReadyStagedTiles`，不等待其余 26 个；
   - 27 Tile 全部完成时才产生整窗 `bAllTilesReady`；
   - `±X/±Y/±Z` 六面 boundary 全部存在才允许 Tile ready。
2. 运行 `Voxia.Gameplay.NearActivePresentation`，确认失败。
3. 候选窗口在新 desired window/activation serial 建立时就创建，不等全 near mesh settled。
4. 候选保存每 Tile 的 343 Chunk 完成状态；near CPU mesh store 每发布一个 Chunk 后更新所属
   Tile，Tile 完整后才建立 hidden components、材质与六面 boundary。
5. 将单一候选 fence 改为每 Tile staging fence；snapshot 暴露已完成 fence 的
   `ReadyStagedTiles`。`bAllTilesReady` 继续只由 27 Tile barrier 提供最终 settled 证明。
6. 保留 latest-wins identity/source/generation 校验；旧 generation 只能留在有界 cache，
   不可获得可见提交权。
7. 构建并运行 near presentation、near chunk work queue、world actor 测试。
8. 提交：`feat(streaming): stage near presentation per ready tile`

## Task 4：post fence 与下一 Tile 解耦

**文件：**

- 修改：`Source/Voxia/Gameplay/VoxiaVoxelPresentationOwnership.h`
- 修改：`Source/Voxia/Gameplay/VoxiaVoxelPresentationOwnership.cpp`
- 测试：`Source/Voxia/Gameplay/VoxiaVoxelPresentationOwnershipAutomationTest.cpp`
- 修改：`Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.h`
- 修改：`Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.cpp`
- 修改：`Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h`
- 修改：`Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp`
- 测试：`Source/Voxia/Gameplay/VoxiaUnifiedWorldTransactionPresentationAutomationTest.cpp`

1. 增加红测：Tile A activate 并 arm post fence 后可以释放 active staging ticket，Tile B
   在 A 的 post fence 未完成时仍可 stage；live atlas 必须累计保留 A 的最终 ownership。
2. 增加根策略红测：每帧最多提交一个可见 Tile，但 pending post fences 不阻塞下一帧 Tile。
3. 运行 ownership 与 transaction root 目标测试，确认失败。
4. Ownership 状态增加“已激活 ticket 交给异步回收”的显式转换，清理 staging transaction
   而不回滚 live atlas。
5. SceneHost 为每个已激活 ticket 保存待回收的旧 texture、seam components 与独立 fence；
   poll 完成后释放对应资源。
6. 根 actor 分离 `ActiveRendererTileTicket` 与 pending post-fence tickets；activate 当帧完成
   near/far/seam 可见 mutation，随后立即把 ticket 交给异步回收。
7. 根 actor 改为逐帧 tick；保持每帧只做一次可见 ownership mutation。
8. snapshot/proof 增加 pending post fence 数；最终 settled 要求 active/pending 均为空。
9. 构建并运行 ownership、transaction、near/far handoff 与 presentation generation 测试。
10. 提交：`fix(streaming): retire tile ownership fences asynchronously`

## Task 5：根按 ready Tile 渐进交接

**文件：**

- 修改：`Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.h`
- 修改：`Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp`
- 测试：`Source/Voxia/Presentation/VoxiaNearFarTileHandoffAutomationTest.cpp`
- 测试：`Source/Voxia/Presentation/VoxiaNearFarHandoffCoordinatorAutomationTest.cpp`

1. 增加红测：9 个 entering Tile 中任一 ready 即可提交；第二个 ready Tile 可在下一帧提交；
   entering 不等整窗 far target；exiting 仍必须等同位置 far counterpart ready。
2. 运行 handoff/coordinator 测试，确认旧 `Candidate.IsReadyForRootCommit()` 门槛失败。
3. 根 latch 接受尚未整窗完成的候选，只消费 `ReadyStagedTiles`；每帧按玩家距离/方向选择一个
   Tile transaction。
4. entering 使用当前位置已有 live far counterpart 完成 `FarOwns -> NearOwns`；目标 far
   generation 后台并行。exiting 仅在目标 far counterpart 已就绪后反向替换。
5. 27 Tile、所有 exiting、far target 与 pending fences 完成后再调用最终 window finalize。
6. 保留首窗/传送/无交集 jump 的显式 recovery 整窗路径。
7. 构建并运行两个 handoff 测试及 unified transaction 测试。
8. 提交：`feat(streaming): hand off each ready tile immediately`

## Task 6：实际 live coverage 与 depth-3 移动门禁

**文件：**

- 修改：`Source/Voxia/Gameplay/VoxiaAuthorityCoverage.h`
- 修改：`Source/Voxia/Gameplay/VoxiaAuthorityCoverage.cpp`
- 测试：`Source/Voxia/Gameplay/VoxiaAuthorityCoverageAutomationTest.cpp`
- 修改：`Source/Voxia/Gameplay/VoxiaSafeViewGuard.cpp`
- 测试：`Source/Voxia/Gameplay/VoxiaSafeViewGuardAutomationTest.cpp`
- 修改：`Source/Voxia/Gameplay/VoxiaPawn.cpp`
- 修改：`Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.cpp`

1. 增加红测：对实际 live Tile 并集按完整 XYZ/L∞ 计算 outside depth，覆盖负坐标、非规则
   渐进 live set 和 `0/1/2/3` chunks。
2. 增加红测：depth 1–2 保持 playable 且不显示 overlay；depth >= 3 且 required pending
   时进入 recovery loading、拒绝非零用户移动；覆盖恢复后自动解锁。
3. 运行 authority coverage 与 safe view guard 测试，确认失败。
4. 从 near registry 的真实 live Tile set 构建 coverage，不再用尚未 settled 的旧整窗 AABB
   判断安全边界。
5. depth 1–2 返回正常 playable；depth >= 3 + required pending 才切到
   `StreamingRecoveryLoading/UIOnly`。
6. Pawn 在门禁生效时清空方向、跳跃、升降和 sprint，并向服务端显式发送零移动意图；
   不回滚 confirmed position，不吞掉加载失败。
7. snapshot/CLI 暴露 `live_tile_count`、`outside_depth_chunks`、
   `movement_blocked` 与原因。
8. 构建并运行目标测试、movement 测试与 CLI contract 测试。
9. 提交：`feat(streaming): gate movement at live coverage depth three`

## Task 7：文档、观测与端到端验收

**文件：**

- 修改：`Source/Voxia/Gameplay/README.md`
- 修改：`Source/Voxia/Voxel/README.md`
- 修改：`Source/Voxia/Net/README.md`
- 修改：`scripts/voxia_stdio_cli.js`
- 修改：`scripts/run_phase1_world_lifecycle_smoke.js`
- 测试：对应 Node `*.test.js`
- 修改：外层 `docs/00-current-truth/design/client/streaming-lod.md`
- 修改：外层 `docs/10-active/voxel-far-field/2026-07-24-voxia-tile-streaming-governance.md`

1. 先给 Node 解析/门禁增加红测，要求输出 required/speculative、逐 Tile ready/visible/fence、
   first/all/settled 延迟、live depth 与 movement gate。
2. 运行 Node 测试确认失败，补齐 CLI/smoke 解析和门禁。
3. 同步三处客户端 README；将 current-truth 改为“逐 Tile visible，27 Tile 仅 settled proof”。
4. 构建 VoxiaEditor。
5. 运行：
   - `Automation RunTests Voxia`
   - 全部相关 Node tests
   - fresh NullRHI 单轴与 XYZ lifecycle
   - fresh Real-RHI 单轴与 XYZ lifecycle
   - stdio CLI 状态/门禁命令
6. 检查 `.demo/observe/` 产物：普通路线不触发 depth-3 门禁、首个 Tile 早于整窗 settled、
   连续 ready Tile 不被上一 Tile post fence 阻塞、frame budget 通过。
7. 更新决策稿状态、测试矩阵、证据路径和残余风险。
8. 运行 `git diff --check`、检查中文注释、确认唯一生产根未变化。
9. 提交客户端与外层文档；推送 Voxia 分支和外层 master。

