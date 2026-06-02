# 移动同步重构 · 支柱 1 设计 spec：协议契约 + 统一时间基准（2026-05-28）

> 上游：`docs/2026-05-28-移动同步现状调研与重构方向.md`（现状调研 + 四支柱总纲 + codex 评审）。
> 本 spec 是四支柱分阶段重构的**第一阶段（地基）**的可实现设计。方向：CONSOLIDATE+COMPLETE——保留客户端预测栈（CSP/reconciliation/interpolation），重构服务端 authority substrate。
>
> 2026-06-01 状态：1.1 wire 升级已落地；1.2 server-owned tick 已用伪造 `client_tick` 测试保护；1.3 web client 已周期性发送 TimeSync，offset 已 EWMA 平滑，远端插值已消费 `server_state_ms + serverClockOffsetMs`，本地 `authorityRender` 改为 `server_tick + ack received-time` 的原始 ACK 调试标记，`server_send_ms` 退为发送链路诊断；画面里可见的本地服务端方块改用 reconcile 后的当前帧权威投影再叠加同一显示平滑；G5 jitter estimator 已修复；debug/observe 已暴露 offset jitter、offset jump、tick discontinuity、playback regression 和 `serverStateTimelineHealthy`。浏览器 smoke 已内置可配置 clock soak verdict，并支持 WebSocket network-emulation proxy 注入双向延迟/抖动/限速；本轮 40ms + 0..40ms jitter + 32768 B/s、5 轮 WS 闪断与 60s clock soak 已通过，clock soak 覆盖远端 `server_state_ms` 样本、0 playback regression，long movement verdict 另以逐帧位移差分别约束可视 display、未平滑权威投影和原始 ACK 调试流。32KB/s 压测暴露的单 WebSocket 体素/movement 队头阻塞已通过服务端发送分流缓解：movement ack / remote move 走 bounded-FIFO realtime lane，field overlay 走 latest-only visual lane，chunk snapshot/delta 走 bulk pacing lane。Web client 已支持 transient socket close 自动重连，browser smoke 默认通过 WebSocket drop proxy 执行两轮已建连接闪断并验证双方重新 ready、远端玩家继续可见；远端跳跃 smoke 现在也断言首个 airborne 样本不超过当前网络条件下的延迟预算，并要求远端 server tick 推进、近距离样本保持 high priority 且 `deliveryInterval=1`。同日补充的 server->client `PlayerMove(0x83)` frame-loss smoke 使用 20% seeded 丢帧、40ms + 0..40ms jitter、32768 B/s、两轮 reconnect 与 15s clock soak，本地样本实际丢弃约 19% 的移动帧（7/36 到 7/37），远端首个 airborne 仍低于当前 1620ms 延迟预算；远端客户端也已在快照长时间缺失时把 stale airborne 外推钳制到已知地面，避免其他玩家在画面里穿地。随后补上服务端 queued replay 逐帧体素碰撞：3 帧 burst 现在触发 3 次 `VoxelCollision.resolve`，不会把网络抖动合成一段长扫掠。server-authoritative web runtime 现在会在本地预测中读取带权威 metadata 的 voxel mirror；缺失权威 chunk 时 fail-open 并暴露 `authority_unavailable`，同时立即请求缺失 strict chunk；strict 区满足后按 400cm 水平边界余量预取邻近 chunk。startup / 手动订阅 / movement prewarm 共享 in-flight chunk subscription 去重，半径订阅覆盖的邻居 chunk 不再重复请求，snapshot / invalidate 会清理 pending，未返回数据的 pending 10s 后才允许重试；启动订阅不再硬编码邻居 chunk，而是中心 chunk + `VITE_VOXEL_SUBSCRIBE_RADIUS`。最新 smoke 的本地 collision 诊断为 `clear` 而不是旧的 `disabled`。更底层真实网络包丢失、scene 级统一 tick、完整碰撞 truth 统一、AOI / handoff 级 chunk 预取策略与 lag compensation 仍是后续更高保真验收。

---

## 1. 定位与范围

### 1.1 在四支柱中的位置
| 支柱 | 内容 | 本 spec |
|---|---|---|
| **1（本 spec）** | 协议契约 + 统一时间基准 | ✅ |
| 2 | 场景权威仿真 + 进程/tick 模型 | 后续 spec |
| 3 | 碰撞权威融合 | 后续 spec |
| 4 | AOI / lag compensation / cluster handoff | 后续 spec |

支柱 1 是地基：后续 scene tick、AOI throttling、lag compensation 都需要先有**统一时间基准**与**健壮协议契约**。codex 评审明确建议时间/协议先行。

### 1.2 目标（G1–G5）
- **G1 协议契约健壮化**：消除"固定 offset 靠注释解码"的脆弱性，加协议版本守卫。
- **G2 state-time 时间基**：`PlayerMove(0x83)` / `MovementAck(0x8b)` 携带"服务器权威状态时间"，发送时间仅用于链路诊断。
- **G3 server authoritative tick**：统一单帧/replay 两路径让 `movement_state.tick` server-owned 单调递增；`client_tick` 降为只读元数据。
- **G4 客户端时间轴对齐**：把已算出却闲置的 `serverClockOffsetMs` 接入远端插值时间轴。
- **G5 jitter estimator 修复**：改用 `|rtt − smoothedRtt|` 的 EWMA。

### 1.3 非目标（明确不做，留给后续支柱）
- ❌ 不引入 scene 级统一 tick / sim barrier（支柱 2）。本阶段 tick 仍是 per-player server-owned。
- ❌ 不拆 `PlayerCharacter` mailbox、不改进程模型（支柱 2）。
- ❌ 不提升 tick rate（支柱 2 后半）。
- ❌ 不动碰撞路径（支柱 3）；"整段位移一次碰撞"的穿透问题留支柱 3。
- ❌ 不改 AOI 频率/形状（支柱 4）。
- ❌ 不改客户端预测/和解/插值**算法本身**，只改其**时间轴输入**与 jitter 公式。

### 1.4 贯穿原则：无迁移债（第一版心态）
支柱 1 当作**第一版**开发：目标态直接替换旧实现，**不保留兼容层、灰度回退、新旧并存**。具体地——旧的 `serverTick × dt` 插值时间轴、单帧路径的 `client_tick` 泄漏、靠注释对齐的固定 offset 解码、闲置的 clock offset 断路，全部**删除并替换**为目标设计，不留过渡开关。原则一句话：**"要改就彻底改"**。

---

## 2. 现状精确画像（本地工作区核实）

> 以下行号基于本地工作区核实（非 GitHub 提交版）。

### 2.1 协议（固定 offset，无版本）
- 分帧：4 字节大端长度前缀（TCP `{packet,4}`）；消息 `<<msg_type::8, payload::binary>>`。
- 解码全靠固定 offset + 注释（`clients/web_client/src/infrastructure/net/gateProtocol.ts:197-244`），无 magic / version / schema 守卫；追加字段易静默错位。
- 关键消息现状布局：
  - `Movement(0x01)` 上行 25B：`seq(u32)/client_tick(u32)/dt_ms(u16)/input_dir_x(f32)/input_dir_y(f32)/speed_scale(f32)/movement_flags(u16)`（`gate_server/lib/gate_server/codec.ex:138-153`）。
  - `PlayerMove(0x83)` 下行：`cid(u64)/server_tick(u32)/pos(f64×3)/vel(f64×3)/accel(f64×3)/movement_mode(u8)` + 可选优先级元数据。**无 wall-clock 时间戳、无朝向**。
  - `MovementAck(0x8b)` 下行 104B：`ackSeq/authTick/cid/pos/vel/accel/mode/correctionFlags(u32)/serverFixedDtMs(u16)/groundY`（`gateProtocol.ts:232-263`）。
  - `time_sync(0x85)`：请求-回复，回复含 `clientSendTs/serverRecvTs/serverSendTs`（`gateProtocol.ts:69-75,285-286`）。

### 2.2 时钟同步：已算出却闲置（断路）
- 客户端用标准 NTP 半差算出 `serverClockOffsetMs`（`remotePlayerController.ts:124-130`），**但仅暴露给 debug snapshot（190-195），从未用于插值时间轴**。
- 远端插值时间轴用 `snapshotTimeSecs = serverTick × tickDurationSecs`（`remotePlayer.ts:156`）——把计数器当时间，tick 不规律时跳变。

### 2.3 server authoritative tick：两路径不一致（本地核实，纠正 codex/probe）
- **replay 路径**（`input_queue` 有积压）：`renumber_input_frames(queued, movement_state.tick, fixed_dt_ms)` 用服务端 tick 重编号 + 钳制 dt_ms（`player_character.ex:720, 949-955`）——**已权威**。
- **单帧路径**（无积压、走 `latched_input`）：`step_and_broadcast` 直接把 `effective_input`（含客户端 `client_tick`）喂进 `Engine.step`（`player_character.ex:685`）——**`client_tick` 泄漏进 `movement_state.tick`**。
- integrator `grounded_step` 输出 `tick: input.client_tick`（`movement_core/src/integrator.rs:121`）：replay 路径下是服务端值，单帧路径下是客户端值。
- ⇒ "tick 来自 client_tick" 的 authority 漏洞**仅在单帧路径成立**；`movement_state.tick` 基础设施已在，改动可控。

### 2.4 jitter estimator：基准错误
- `observeRtt` 用 `|rtt − smoothedJitterMs|`（拿 RTT 与"jitter 估计"作差）而非 `|rtt − smoothedRtt|`（`localPlayer.ts:147-153`）；网络稳定时 jitter 被估成 0，导致 `softPositionError` 长期贴底（2cm）。

---

## 3. 已定设计决策

| 决策 | 选择 | 理由 |
|---|---|---|
| **A 时间基** | **混合：`server_tick`（权威序号）+ `server_state_ms`（权威状态时间锚点）+ `server_send_ms`（发送链路诊断）** | 序号用于和解/去重/碰撞顺序；state-time 解决"计数器当时间"并避免发送排队污染仿真时间；send-time 只用于观测链路延迟。 |
| **B 协议契约** | **握手协商版本 + 热点帧 1 字节 schema version + decode 长度自校验** | 热路径开销最小（+1B），兼顾运行时错位保护。 |
| **C server tick 归属** | **per-player server-owned 单调递增**（scene 级统一 tick 留支柱 2） | 符合分阶段；最小改动堵泄漏、统一两路径。 |

---

## 4. 详细设计

### G1 协议契约健壮化
1. **握手版本协商**：在客户端接入握手（enter-scene / auth 完成后的首个 server→client 帧）增加 `protocol_version`（u16）。双方记录协商版本；不匹配则按既定降级/拒绝策略处理（具体策略 plan 阶段定）。
2. **热点帧 schema version**：`Movement(0x01)`、`PlayerMove(0x83)`、`MovementAck(0x8b)` 在 `msg_type` 之后插入 1 字节 `schema_version`。这是 **wire layout 变更**（非纯追加），需双端同步升级 + 版本协商兜底。
3. **decode 长度自校验**：每条消息 decode 前按 `(schema_version → 期望长度区间)` 校验 payload 长度，不符则结构化报错（不静默错位）。
4. **codec 契约集中化**：把"msg_type → schema_version → 字段布局"收敛为单一可读的 schema 描述（Elixir 与 TS 各一份，但以线协议规范文档为单一真相源），减少"靠注释对齐 offset"。

> **第一版收口（无迁移债）**：热点帧直接定为目标布局（含 `schema_version`），**不保留旧 layout、不实现新旧 schema 并存的过渡窗口**。`protocol_version` 的作用是握手时**双端版本一致性断言**（不一致即 fail-fast 拒绝连接，杜绝静默错位）与为支柱 2/3/4 演进留的 version 锚点——**不是兼容层**。靠注释对齐 offset 的旧解码路径一并删除替换。后续支柱再加字段才走"追加 + version bump"。

### G2 state-time 时间基
1. `PlayerMove(0x83)` 与 `MovementAck(0x8b)` **追加** `server_state_ms`（u64，毫秒）与 `server_send_ms`（u64，毫秒）字段。
2. 时间源：Scene 以 `movement_epoch_ms + movement_state.tick * fixed_dt_ms` 生成 `server_state_ms`，确保状态时间随仿真 tick 等距递增；Gate 在 TCP/UDP/WS 发送边缘生成 `server_send_ms`，仅用于延迟、排队和 QoS 诊断。（monotonic 仅用于本地间隔测量，不上线。）
3. `time_sync(0x85)` 维持现有请求-回复三时间戳；本阶段强化：客户端周期探测（频率 plan 定，建议 1–2s）+ offset 用 EWMA 平滑。

### G3 server authoritative tick
1. **统一两路径**：单帧路径（`step_and_broadcast`）在 `Engine.step` 前，对 `effective_input` 施加与 replay 路径一致的 server 重编号（`movement_state.tick + 1`），使 `client_tick` 不再进入仿真状态。
2. **`client_tick` 降级**：客户端上报的 `client_tick` 仅保留为**只读元数据**（用于 RTT/采样诊断、observe），永不写入 `movement_state.tick`。
3. **tick 语义固定**：`movement_state.tick` 为 server-owned 单调递增计数器，递增步长 = 本 tick 处理的固定步数（单帧 +1；replay +N）。`MovementAck.authTick` 与 `PlayerMove.server_tick` 均取自它。
4. integrator 层：保持 `grounded_step` 接口，但确保其 `tick` 输入恒为 server 分配值（通过上层 renumber 保证；不改 NIF 算法）。

### G4 客户端时间轴对齐
1. 远端插值：`RemotePlayerState` 的时间轴从 `serverTick × tickDuration` 改为**优先基于 `server_state_ms`**——客户端用 `localArrival + clockOffset` 将快照锚定到统一 server 状态时间轴，`server_tick` 退为序号（去重/排序，保留 `pushSnapshot:70` 的单调过滤）。当本地测试/旧离线快照缺失状态时间，或相邻 `server_state_ms` 间隔不再匹配 tick 间隔时，运行时会显式标记 `serverStateTimelineHealthy=false` 并用 `server_tick` 维持可视化单调性；这是诊断可见的安全降级，不是旧协议兼容层。
2. `serverClockOffsetMs` 从共享 `ServerClockEstimator` 接入远端实体的 `RemotePlayerState.sampleMotion` 时间换算（消除 2.2 的断路）。本地 authority render 不走 wall-clock TimeSync：它是调试"服务器是否已确认我的移动"的本地标记，按 `server_tick + ack received-time` 采样 ack 原始权威态，避免 TimeSync 偏差把灰色服务端方块稳定拖到旧快照。
3. 本地和解：reconcile 的权威态仍以 `auth_tick` / `ack_seq` 作为顺序真相；可视化 authority render 保留 RemotePlayerState 的 Hermite 插值和 0.6s 限幅外推，但时间轴与远端玩家分离，replay 算法本身保持不变。
4. interpolation delay 与 `deliveryInterval` 自适应（`remotePlayer.ts:160-173`）保留；其上限与 `server_state_ms` 抖动联动（plan 调参）。

### G5 jitter estimator 修复
- `localPlayer.ts:147-153`：引入 `smoothedRtt`（EWMA），`jitter = EWMA(|rtt − smoothedRtt|)`；`softPositionError` 据此自适应（保留 `governance.ts` 上限 8cm）。

---

## 5. 协议变更清单（wire 层）

| 消息 | 变更 | 说明 |
|---|---|---|
| 握手帧 | 新增 `protocol_version(u16)` | enter-scene/auth 完成后 |
| `Movement(0x01)` | `msg_type` 后插 `schema_version(u8)` | layout 变更，双端同步 |
| `PlayerMove(0x83)` | 插 `schema_version(u8)` + 追加 `server_state_ms(u64)` / `server_send_ms(u64)` | layout 变更 + 追加 |
| `MovementAck(0x8b)` | 插 `schema_version(u8)` + 追加 `server_state_ms(u64)` / `server_send_ms(u64)` | layout 变更 + 追加 |
| `time_sync(0x85)` | 不变（强化使用频率/平滑，非 wire 变更） | |

> 精确字节偏移在 plan 阶段连同 codec 实现钉死，并同步更新 `docs/2026-04-10-线协议规范.md`（线协议单一真相源）。

---

## 6. 实现影响面（锚点，plan 阶段细化）

**服务端（Elixir）**：
- `apps/gate_server/lib/gate_server/codec.ex`（编解码 + schema_version + 长度校验）
- `apps/scene_server/lib/scene_server/worker/player_character.ex`（单帧路径 renumber 统一、ack/snapshot 盖 `server_state_ms`）
- `apps/scene_server/lib/scene_server/movement/{engine.ex,ack.ex,remote_snapshot.ex,state.ex}`（tick 语义、ack/snapshot 字段）
- 握手/接入路径（`gate_server` 连接建立、enter-scene）+ `time_sync` 处理点

**服务端（Rust）**：
- `apps/scene_server/native/movement_core/src/integrator.rs`（确保 tick 输入为 server 值；不改算法）

**客户端（TS, `clients/web_client/src`）**：
- `infrastructure/net/gateProtocol.ts`（schema_version + 长度校验 + 解析 `server_state_ms` / `server_send_ms`）
- `infrastructure/net/serverMovementTransport.ts`（time_sync 频率/平滑、offset 暴露）
- `domain/movement/remotePlayer.ts`（时间轴改 wall-clock）、`domain/movement/serverClock.ts`（TimeSync offset 平滑）、`localPlayer.ts`（jitter 修复）
- `app/controllers/remotePlayerController.ts` 与 `app/controllers/localPlayerController.ts`（offset 接入远端插值；本地 authority render 按 ack received-time 采样）

**参考实现（滞后跟进，非 parity 目标）**：`clients/bevy_client`、`movement_core` 共享算法保持 bit-exact。

---

## 7. 验证方案（遵 AGENTS.md：CLI observe + 结构化日志优先）

**新增 observe 指标**：
- `clock_offset_ms` 估计值与稳定性（方差/EWMA 收敛）。
- 远端插值时间轴连续性：相邻采样 `playbackServerTime` 单调、无跳变计数。
- tick 一致性：单帧路径与 replay 路径产出的 `authoritative_tick` 严格连续（断点计数 = 0）。
- `client_tick` 不再影响 `movement_state.tick` 的断言（注入异常 client_tick 不改变权威 tick 序列）。
- jitter 估计：稳定网络下非零且合理；高抖动下随 RTT 方差上升。

**门槛（沿用 + 新增）**：
- 沿用既有：`total_hard_snaps = 0`、`drift ≤ 8u`。
- 新增：插值时间轴跳变计数受限；tick 序列断点可观测；伪造 `client_tick` 注入测试下权威 tick 不受影响；clock soak verdict 要求 remote entity 使用 `server_state_ms` 时间轴，或在 `serverStateTimelineHealthy=false` 时使用显式 `server_tick` 降级；正常 `server_state_ms` 样本仍要求 TimeSync 样本持续增长。原始本地 `authorityRender` 预期使用 `server_tick + ack received-time`；可见服务端方块使用当前帧权威投影加显示平滑；long movement verdict 用逐帧 `local / authority / authorityRender / authorityProjected / authorityDisplay` 位移差分别约束原始 ACK 调试流、未平滑投影和玩家实际显示距离。

**验证入口**（复用现有 + 扩展）：
- `powershell scripts\e2e-stdio-movement.ps1`、`scripts\e2e-live-movement.ps1`（drift/reconcile）。
- `node scripts/run_browser_movement_smoke_supervised.js`（浏览器双客户端 + 多轮断线重连 + 远端 airborne 延迟预算 + realtime lane 质量 + clock soak；默认通过 WS drop proxy 断开已建连接两轮，`BROWSER_MOVEMENT_RECONNECT_SMOKE=0` 可关闭，`BROWSER_MOVEMENT_RECONNECT_CYCLES=1..5` 可调轮数；`BROWSER_MOVEMENT_REMOTE_JUMP_MAX_AIRBORNE_MS` 可覆盖远端跳跃延迟预算；`BROWSER_MOVEMENT_CLOCK_SOAK_MS` 可拉长到 60s；`BROWSER_MOVEMENT_NET_DELAY_MS` / `BROWSER_MOVEMENT_NET_JITTER_MS` / `BROWSER_MOVEMENT_NET_BYTES_PER_SEC` 启用 WS network-emulation proxy）。
- 服务端 stdio：`player_state <cid>` 扩展时间/tick 字段；observe 写 `.demo/observe/`。

---

## 8. 风险与回退

| 风险 | 缓解 |
|---|---|
| 热点帧 layout 变更（第一版无兼容层） | web_client 与服务端同步发布；`protocol_version` 握手做版本一致性断言（不一致 fail-fast）；bevy_client 作为参考实现滞后跟进 |
| `server_state_ms` 新时间轴质量需验证 | observe/CLI 暴露 `serverStateTimelineHealthy`、active time axis 和 playback regression；正常流量优先用状态时间，缺失状态时间或状态时间间隔异常时显式降级到 tick timeline，避免播放时间倒退 |
| time_sync 频率提升带来额外流量 | 频率可配；仅 RTT 探测，载荷极小 |
| 与体素权威化主线（Phase 7）并行的协议冲突 | 协议变更集中在 movement 消息，避开 voxel snapshot/delta；变更前在线协议规范文档登记 |

---

## 9. 真相源回写（遵 Genesis CLAUDE.md §6 与 ex_mmo_cluster 文档纪律）
- 协议字节布局变更 → 更新 `docs/2026-04-10-线协议规范.md`。
- 时间模型/tick 语义变更 → 更新 `apps/scene_server/lib/scene_server/movement/README.md`。
- 完成后在 `docs/2026-05-28-移动同步现状调研与重构方向.md` §6 标注支柱 1"已实现"并指向本 spec。

---

## 10. 交付定义（Definition of Done）
1. 协议握手版本协商 + 热点帧 schema_version + decode 长度自校验落地，双端通过。
2. `PlayerMove`/`Ack` 携带 `server_state_ms` / `server_send_ms`；客户端插值时间轴改用状态时间 + clock offset。
3. 单帧/replay 两路径 tick 统一为 server-owned，`client_tick` 注入测试不污染权威 tick。
4. jitter estimator 修正，softError 自适应在稳定/抖动网络下表现合理。
5. 全部门槛通过（§7），observe 产物可复现；线协议规范 + README 已回写。
6. **无迁移债**：旧 `serverTick × dt` 时间轴、单帧 `client_tick` 泄漏路径、靠注释的固定 offset 解码均已删除，代码中不残留兼容/回退/双 schema 开关。
