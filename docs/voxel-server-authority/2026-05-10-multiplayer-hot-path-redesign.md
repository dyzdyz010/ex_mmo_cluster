# 多人热路径架构重设计 — 决策稿

**起草日期**:2026-05-10
**状态**:决策稿,等用户拍板方向后实施
**触发**:用户实测两个长期症状无法靠"打补丁"消除 ——
1. 远端角色频繁跳变 / 抖动
2. 摆放 prefab 始终 ~3 秒卡顿(即便 A1-1b 把某个 O(N²) 优化掉之后)

本稿不修单点 bug,**做整体架构归因 + 提出系统性改造方案**。

---

## 1. 问题陈述

### 1.1 用户实测症状

| 症状 | 期望 | 实测 | 之前打的补丁 |
|---|---|---|---|
| 远端移动 | 流畅(<33ms 跳变) | 频繁跳变 | extrapolation clamp 0.25 → 0.6s(减轻 low priority,未根治) |
| Prefab 摆放 | <100ms | ~3 秒 | A1-1b batch API(server normalize 1.5s→46ms) — 但用户说仍 3 秒 |

### 1.2 为啥打补丁没用

每个补丁修了**一个**瓶颈,但路径上**还有另外 4-5 个相似量级的瓶颈**。性能问题是**架构性叠加** —— 改一个,下一个浮上来。需要重新看整条链路,**冷/热路径分离 + 数据传输形态升级**。

---

## 2. 链路时间预算审计

### 2.1 远端移动(本端输入 → 远端渲染)

```
[本端 client]
  input event → KeyboardController → MovementInput frame
  → ws.send (~1ms 本地序列化)

[网络 ~50-150ms]

[gate ws_connection]
  收 0x66 → GenServer.call PlayerCharacter (~2ms)

[scene PlayerCharacter, 单 GenServer mailbox 串行]
  ⚠️ mailbox 跟 :movement_tick / :chat / :cast_skill / :apply_damage / damage routing 共享
  ⚠️ 任何慢消息(技能 5-20ms)阻塞下一 tick
  
  handle_call({:movement_input, frame}) 入队 (~2ms)
  
  handle_info(:movement_tick, 100ms 一次) 触发:
    Engine.step + replay (8 frames)
    update_character_movement_with_retry (3 次 NIF + 5ms sleep) — 最坏 15ms 阻塞
    cast {:self_move, snapshot} → aoi_ref

[scene aoi_item, per-cid GenServer]
  收 :self_move → broadcast_action_player_move
  ⚠️ priority 节流:
     - high(<35% radius): 每 tick = 100ms 间隔
     - medium(<75%): 每 2 tick = 200ms
     - low(<100%): 每 5 tick = 500ms
  cast {:player_move, snapshot} 给每 subscriber 的 aoi_item

[scene aoi_item per subscriber]
  收 :player_move → cast 给 connection_pid

[gate ws_connection]
  收 :player_move → Codec encode (~1ms) → send_encoded → ws.send

[网络 ~50-150ms]

[远端 client transport]
  decodeServerMessage → push 到 remoteSnapshots[]

[远端 client onFrame, 16ms 周期]
  RemotePlayerController.sampleMotion:
    INTERPOLATION_DELAY 150ms 后才回放
    hermite interpolate prev → next snapshot
    ⚠️ tickDurationSecs 默认 0.1,只在收到 ack 时更新 — 远端 ack 永远不来,
       依赖 server 隐式 100ms 节奏假设
    ⚠️ MAX_EXTRAPOLATION 600ms — 低优先级 500ms 间隔卡边界
```

**时间预算总结**:
- 不可省 = ~250ms(net RTT 100 + server tick 100 + interp delay 150 减去重叠)
- **架构开销** = ~250ms+(mailbox 阻塞 15-30ms + priority 节流 0-400ms + N 跳 cast 5-10ms)

### 2.2 Prefab 摆放(点击 → 远端看到方块)

```
[本端 client]
  click → worldEditController → onlineVoxelWorldAdapter.placePrefab
  → transport.sendVoxelPrefabPlaceIntent → ws.send 0x67

[网络 ~50-150ms]

[gate ws_connection]
  收 0x67 → PrefabRaster.rasterize (sphere 280 cells, ~2ms)
  → GenServer.call GateServer (~3ms)
  → coordinator_begin_transaction → World

[world TransactionCoordinator, 单 GenServer]
  ⚠️ persist 整 transaction 到 voxel_transaction_coordinator_snapshots — Postgres INSERT (~10-20ms)
  → executor.execute (per-participant Task.async_stream)

[scene per-chunk ChunkProcess(GenServer.call)] × N participant chunks
  Phase 1 prepare:
    fence + 持久化 voxel_chunk_pending_transactions — Postgres INSERT (~5-15ms 每 chunk)
  
  Phase 2 commit_decision (coordinator 端):
    Postgres UPDATE (~5-15ms)
  
  Phase 3 commit (per chunk):
    apply_normalized_intents → A1-1b batch put_micro_blocks (~46ms)
    encode_chunk_snapshot_payload — full chunk binary 50-150KB (~3ms)
    ⚠️ persist_snapshot — Postgres FOR UPDATE lock + UPDATE big binary (~10-50ms 锁竞争)
    ⚠️ push_snapshot_fallbacks — **每 subscriber 重新 encode 一遍**(O(N) 而不是 O(1))
       — 全 chunk snapshot 而不是 delta!10 subscriber × 100KB encode = 1MB 工作

[gate × N subscriber]
  ws_connection 收 :voxel_chunk_snapshot_payload → ws.send (~150KB binary)

[网络 ~50-150ms × big binary]

[client transport]
  decodeVoxelServerMessage → push 到 voxelSnapshots[]

[client OnlineVoxelWorldAdapter onFrame]
  drainVoxelSnapshots → store update → markDirty
  
[client RenderOrchestrator onFrame]
  ⚠️ chunkRenderer.syncDirtyChunks — **主线程同步 mesh rebuild**
     — 全 chunk re-mesh 而不是 incremental
     — 100-200ms WebGL 阻塞,卡帧
```

**时间预算总结**:
- 最快 ~300ms(net RTT 100 + 几次 call 40 + persist 50 + render 50 + 回程 60)
- **最坏 ~2-3 秒**(net + lock 争用 150 + per-subscriber encode 200 + mesh rebuild 200 + 回程 + 多 chunk 协调)

A1-1b 修了 normalize O(N²),从 1.5s 摁到 46ms ✓ — 但**3 秒里 normalize 只占 46ms,真瓶颈在别处**。

---

## 3. 根因总结(架构层)

| # | 根因 | 影响 | 在哪 |
|---|---|---|---|
| **R1** | PlayerCharacter 单 mailbox 把 input + 物理 tick + 技能 + 聊天 + 伤害路由 全串行 | 远端跳变(任何慢消息阻塞 tick → snapshot 间隔抖动) | `apps/scene_server/lib/scene_server/worker/player_character.ex` |
| **R2** | `update_character_movement_with_retry` 三次 NIF + 5ms sleep | tick 内阻塞最坏 15ms | `player_character.ex` line 1326+ |
| **R3** | Voxel 更新走**全 chunk snapshot**,且 per-subscriber 重新 encode | prefab 体感慢 + 带宽浪费 | `apps/scene_server/lib/scene_server/voxel/chunk_process.ex` `push_snapshot_fallbacks` |
| **R4** | Chunk persist 在 commit 路径上**同步阻塞**(Postgres FOR UPDATE + 大 binary) | prefab 多 50-150ms,subscribers 也要等 | `apps/data_service/lib/data_service/voxel/chunk_snapshot_store.ex` `put_snapshot` |
| **R5** | Transaction coordinator 4-6 跳 GenServer.call 串行链 | 每跳累积 1-3ms,跨多 participant 累积更多 | `world_server/voxel/{coordinator,executor}` + `scene_server/voxel/build_transaction_applier` |
| **R6** | 客户端 mesh rebuild 在主线程同步 | 卡帧 100-200ms | `clients/web_client/src/render/chunkRenderer.ts` |
| **R7** | 客户端 interpolation 不知道 server `delivery_interval` | low priority 远端 stutter(500ms 节流 vs 600ms clamp 边界) | `clients/web_client/src/domain/movement/remotePlayer.ts` |

---

## 4. 设计原则(架构方向)

整套思路两条主线:

### 4.1 **冷热路径分离**(Hot/Cold Path Separation)

任何"用户看得见"的操作必须**只走热路径**(纯内存 + 单次 encode + 单次 fan-out),**永远不等冷路径**(Postgres 持久化 / 大 binary 序列化 / 多 hop GenServer 协调)。

冷路径在背景跑,出问题最多回放 / 重试,不阻塞用户体验。

**当前违反**:
- ❌ Prefab commit 等 Postgres FOR UPDATE 完成才回 ack(R4)
- ❌ Snapshot fan-out 每 subscriber 重新 encode 阻塞 commit(R3)
- ❌ Transaction coordinator 5-6 hop sync call(R5)

### 4.2 **协议 = 状态变化(delta),不是状态快照(snapshot)**

游戏协议的常识:**hot 路径只发 delta,snapshot 仅做"我刚加入,给我全图"的初始化**。

**当前违反**:
- ❌ Voxel 编辑后给所有 subscribers 发**全 chunk snapshot**(50-150KB)而不是 delta(几十 bytes)
- ❌ 0x6C ChunkDelta 协议**已经存在**(per docs 给 object_state_delta 用),但 prefab / break / place 路径仍走 snapshot(代码注释:`Temporary ChunkDelta fallback: push the full authoritative snapshot until the scene/gate delta wire contract is available.`)

### 4.3 **单进程不串多职责**

OTP 文化是"一个 GenServer 一件事"。把性能敏感的 movement/physics tick 跟 RPC 处理 / 业务逻辑(技能 / 聊天)分开。

**当前违反**:
- ❌ PlayerCharacter 一个 mailbox 跑 input + tick + 技能 + 聊天 + 伤害(R1)

### 4.4 **客户端渲染:决不阻塞 frame loop**

Mesh rebuild、大 binary decode 都不能跑在 RAF callback 同步链里。

**当前违反**:
- ❌ ChunkRenderer.syncDirtyChunks 同步 rebuild(R6)

---

## 5. 改造方案(分 Tier,按 ROI)

### Tier 1 — 立刻可做、ROI 极高(总工 1-2 天)

> 改完应**立刻看到 prefab <500ms,远端基本不抖**。这一 tier 不动数据结构,只改流程。

#### **T1-A. ChunkSnapshot 单次 encode + send fan-out**(对应 R3 的一半)

**改动**:`ChunkProcess.push_snapshot_fallbacks` 的 per-subscriber 循环里**先 encode 一次成 binary**,然后 `Enum.each(subscribers, &send(&1, {:voxel_chunk_snapshot_payload, binary}))`。

**收益**:N subscribers 时 commit 路径节省 (N-1) × 编码时间(50-100ms × N)。

**风险**:零 — 同样的 binary 内容。

**估时**:30 分钟。

#### **T1-B. Chunk persist 异步化**(对应 R4)

**改动**:`apply_normalized_intents` 里把 `persist_snapshot` 从同步 GenServer.call 改为 `Task.start_link`(fire-and-forget)。失败 emit observe + 后台重试。Snapshot fan-out 立刻执行,不等 PG。

**收益**:Commit 路径少 10-50ms(Postgres lock + binary write)。Subscriber 立刻看到方块。

**风险**:中等。Server crash 时**最近未持久化的 snapshot 丢失**。但:
- 已经有 `voxel_chunk_pending_transactions` fence + recovery watcher,fence 持久化 ≠ snapshot 持久化
- 真正的影响:server 重启后那条 snapshot 必须从 PG 加载(走的是 task #26 chunk_process hydrate from PG)
- 协议层面 client 已经能 reconcile(下次 chunk_subscribe 给客户端发当前权威 snapshot)
- **生产可接受 trade-off**(MMORPG 业界惯例:玩家位置/世界状态延迟持久化 1-5 秒)

**估时**:2-3 小时(含错误处理 + observe)。

#### **T1-C. 客户端 priority-aware interpolation delay**(对应 R7)

**改动**:`RemotePlayerController` 收到 snapshot 后,根据 snapshot.deliveryInterval 动态调 `INTERPOLATION_DELAY`:
- high(interval=1) → 150ms
- medium(interval=2) → 250ms
- low(interval=5) → 600ms

**收益**:低优先级远端不再 stutter(因为 buffer 永远有数据可插值,不进 extrapolation)。

**风险**:零 — 客户端单边改动,server 不知道。

**估时**:1 小时。

### Tier 2 — 中等成本、高 ROI(总工 3-5 天)

> 涉及协议形态升级,需要双端测试,但能根治 prefab 卡顿。

#### **T2-A. ChunkDelta 替代 ChunkSnapshot fan-out**(对应 R3 的另一半)

**改动**:Voxel commit 时不发全 snapshot,发 ChunkDelta(只列出改动的 cells)。0x6C ChunkDelta 协议已存在(给 object_state_delta 用),复用其 schema 给一般 voxel edit。

**收益**:
- Wire 数据 50-150KB → 几十 bytes(N×1000 倍)
- 客户端 mesh rebuild **只 dirty 改动的 quads**,不全 chunk(配合 T2-B)
- 网络好的局域网都能感觉,跨地理也大幅降延迟

**风险**:协议层改动,需要双端 schema 对齐 + 测试覆盖。**ChunkSnapshot 路径仍保留给 chunk_subscribe 初始 sync**(冷启动 / 新 client join)。

**估时**:1-2 天。

#### **T2-B. 客户端增量 mesh rebuild + Web Worker**(对应 R6)

**改动**:
- ChunkRenderer 改 incremental:只 rebuild 改动 cell 周围 6 邻接
- Mesh 计算迁到 Web Worker(OffscreenCanvas / WorkerGeometry),主线程只接 mesh data + upload GPU

**收益**:卡帧 100-200ms → 几乎不可感(主线程不阻塞)。

**风险**:中等。Three.js + WebWorker 协作有踩坑空间(BufferGeometry transfer)。需要测多 player + 大量 dirty chunk 场景。

**估时**:1-2 天。

#### **T2-C. Transaction coordinator 路径压平**(对应 R5)

**改动**:把 4-6 跳 sync GenServer.call 链路压成 2-3 跳。具体:
- Coordinator 直接给 ChunkProcess 发 prepare/commit cast,用 Process.monitor + receive 等结果
- 跳过中间 BuildTransactionApplier 模块的 GenServer 边界
- Per-participant prepare 仍并行(Task.async_stream)

**收益**:Prefab 路径节省 5-15ms(每跳 1-3ms × 多 participant)。

**风险**:中等。Recovery watcher / replay 路径也要跟着改。

**估时**:1-2 天。

### Tier 3 — 高成本、深架构(总工 1-2 周)

> 长期治理,改对体感非常显著但工程量大。

#### **T3-A. PlayerCharacter mailbox 拆分**(对应 R1)

**改动**:从 PlayerCharacter 抽出独立 process `MovementWorker`:
- MovementWorker 单职责:input 入队 + tick 物理 + self_move broadcast
- PlayerCharacter 保留:技能 / 聊天 / 伤害 / RPC interface
- 两者通过 message 通信,各自 mailbox 独立

**收益**:**远端跳变根治**。任何慢业务消息再不阻塞 tick。

**风险**:大。物理状态在 MovementWorker,combat / damage 在 PlayerCharacter,跨 process 拿状态需要小 RPC + cache。要改 ~500 LOC + 全套测试。

**估时**:3-5 天。

#### **T3-B. Server tick 频率提到 50ms 或 33ms**

**改动**:`MovementProfile.fixed_dt_ms 100 → 50`(20Hz → 30Hz)或 33(30Hz)。

**收益**:远端动作平滑度本质提升(从 100ms 一份 snapshot 到 33-50ms 一份)。

**风险**:负载倍增。2-3x snapshot 流量 + 2-3x server tick CPU。需要 T1-A / T2-A 先做,否则 wire 流量爆。**T3-A 之前不能做**(否则 mailbox 串行化更糟)。

**估时**:0.5 天本身,但前置依赖 ~5 天。

#### **T3-C. update_character_movement_with_retry 改非阻塞**(对应 R2)

**改动**:把 5ms sleep 重试改 backoff Task,或干脆 NIF 改 lock-free。

**收益**:tick 最坏阻塞 15ms → 0ms。

**风险**:低,但需要 Rust NIF 改动。

**估时**:1 天。

---

## 6. 不在范围

明确**这次不做**的事(避免 scope creep):

- A4-bis-cluster 段 2 的 audit + release 配置(等性能问题搞定再回去)
- 完整的 client mesh rebuild → GPU compute shader 路径
- Server 跨地理 region 的 latency 优化(WAN tuning,生产事)
- PlayerCharacter / NPC / 伤害的整个 actor 模型重构(远超本稿)

---

## 7. 风险

1. **T1-B(persist 异步)的 server crash 数据丢失**:已说明 trade-off。如果 user 不接受,T1-B 改成"persist 仍同步,但不阻塞 fan-out"(即 fan-out 跑在另一 task)。
2. **T2-A(ChunkDelta 协议)的双端 schema drift**:需要 wire 协议规范文档同步更新 `docs/2026-04-10-线协议规范.md`。
3. **T2-B(Worker mesh)的 WebGL 上下文跨 worker**:Three.js BufferGeometry.transferable 支持的边界,要先 PoC 验证。
4. **T3-A(mailbox 分离)的状态一致性**:input → MovementWorker tick → snapshot,中间 PlayerCharacter 的技能可能改了 movement_profile。需要明确"谁是 movement profile 的 source of truth"。

---

## 8. 决策项(请你拍板)

### D1. **走哪个 tier 组合**?

候选:

- **方案 A(快速止血)**:T1-A + T1-B + T1-C。**1-2 天**,prefab 应该 < 500ms,远端低优先级抖动消除。**适合**:不想停下 A4-bis-cluster 太久,先把体感拉到能玩。
- **方案 B(根治)**:Tier 1 全部 + T2-A + T2-B。**1 周**,prefab < 100ms,客户端 mesh 不卡帧,远端基本流畅。**推荐**。
- **方案 C(架构重写)**:Tier 1+2+3 全部。**2-3 周**,远端动作完全等同电竞水平,server 可以支撑 5x 并发。**适合**:你确认这是 MVP 必须线,愿意暂停其他 phase。

我**推荐方案 B**,理由:
- T3 改动深,值得做但不是现在(用户能玩起来就该回去推 A4-bis-cluster)
- 方案 A 留 mesh rebuild + 全 snapshot 协议,是体感天花板
- 方案 B 把"用户能感知到的"全修干净,工程量可控

### D2. **T1-B(persist 异步)的 trade-off 接不接**?

接:server crash 时丢最近 ~1 秒的 voxel 改动(玩家重新摆即可)。
不接:T1-B 改弱版"fan-out 不等 persist 但 commit 仍等",收益减半。

### D3. **T2-A 的 ChunkDelta 协议需要不需要保留 ChunkSnapshot 路径**?

我建议**保留**:ChunkSnapshot 用于 chunk_subscribe 初始全量 sync(新 client / 长时间断线重连),ChunkDelta 用于 commit 增量。这是行业惯例。

### D4. **远端 server tick 33ms 还是 50ms**?

如果走方案 C,tick 频率定:
- 33ms (30Hz):接近 console FPS 游戏标准,流畅度更好,负载 3x
- 50ms (20Hz):比当前 100ms 更流畅,负载 2x,稳妥

### D5. **改的过程中是否暂停 A4-bis-cluster**?

我**强烈建议**暂停 — 性能问题不修,A4-bis-cluster 的多 scene_node 部署只会让幽灵 / 卡顿症状放大。先把单 scene_node 跑稳,再分布式化。

---

## 9. 建议落地顺序(假设方案 B)

| Day | 任务 | 验收 |
|---|---|---|
| Day 1 上午 | T1-A(单次 encode fan-out) | scene 测试 + 实测 prefab 无明显加速但 N=2 时 commit 路径少 50ms |
| Day 1 下午 | T1-B(persist 异步) | 实测 prefab 落地 <500ms,server crash 测试 |
| Day 1 晚上 | T1-C(priority-aware delay) | 远端低优先级 stutter 消除 |
| Day 2-3 | T2-A(ChunkDelta 协议)server 端 | 双端 schema + scene 测试 |
| Day 4 | T2-A 客户端 + 联调 | 实测 prefab < 200ms,wire 流量降 N×1000 倍 |
| Day 5-6 | T2-B(Worker mesh + incremental rebuild) | 实测帧率不掉,大量 dirty chunk 不卡 |
| Day 7 | 端到端回归 + 文档收尾 | 用户实测验收 |

---

## 10. 进度日志

### 2026-05-10 — 方案 B 第一批落地

- `ChunkProcess.apply_intents/2` / `commit_transaction/2`：prefab / batch commit 热路径改为
  `ChunkDelta` fan-out。按最终受影响 macro 合并 ops，sphere prefab 从完整 `ChunkSnapshot`
  推送改成单条 `CellRefined` delta。
- `ChunkProcess`：batch snapshot PG 持久化后台化，热路径只等待 write-token 校验；新增
  `voxel_chunk_async_persist_*` observe 事件和 `flush_persistence/2` CLI / 测试同步点。
- 客户端远端插值：按 server `deliveryInterval` 动态提高 interpolation delay，low priority
  远端保留 600ms buffer，避免 500ms AOI 节流打到 extrapolation clamp。
- Web render：chunk mesh rebuild 移入 module worker，主线程只替换 `BufferGeometry`；observe
  日志可直接看到 schedule / rebuilt / failure。
- 测试验收：gate prefab e2e 已改为断言 `0x63 ChunkDelta`，并在 flush 后验证 PG snapshot；
  跨 region prefab 用唯一 logical scene 隔离旧 `region_bounds_overlap`。

2026-05-10 follow-up：实测右键 prefab 仍慢的根因不是 delta fan-out，而是常见单 chunk
prefab 仍走 World two-phase transaction，`prepare` 阶段同步写
`voxel_chunk_pending_transactions` fence 会产生约 1s 以上等待。已增加 single-chunk fast
path：Gate 仍先通过 MapLedger 获取 lease，但若 prefab 只命中一个 chunk，则直接调用
`ChunkDirectory.apply_intents/2`，并在 intent opts 带 `reject_occupied: true` 保留
chunk-local all-or-reject 语义；只有 multi-chunk / multi-lease prefab 继续走
`TransactionCoordinator` + `TransactionExecutor`。

2026-05-10 follow-up 2: real browser right-click boundary-snap prefabs can touch
several macro cells inside the same chunk. The first single-chunk fast path only
optimized the one-macro batch case, so the common right-click sphere still fell
back to 280 per-slot storage normalizations. `ChunkProcess.apply_intents/2` now
groups micro writes by macro and calls `Storage.put_micro_blocks/4` once per
touched macro; observed Gate fast-path latency for the same right-click case
dropped from 1379ms to 38ms, with `ChunkDelta` still delivered and snapshot
persistence deferred behind the write-token check.
