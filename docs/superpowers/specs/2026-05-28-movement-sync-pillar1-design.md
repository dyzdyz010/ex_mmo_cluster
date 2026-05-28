# 移动同步重构 · 支柱 1 设计 spec：协议契约 + 统一时间基准（2026-05-28）

> 上游：`docs/2026-05-28-移动同步现状调研与重构方向.md`（现状调研 + 四支柱总纲 + codex 评审）。
> 本 spec 是四支柱分阶段重构的**第一阶段（地基）**的可实现设计。方向：CONSOLIDATE+COMPLETE——保留客户端预测栈（CSP/reconciliation/interpolation），重构服务端 authority substrate。

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
- **G2 wall-clock 时间基**：`PlayerMove(0x83)` / `MovementAck(0x8b)` 携带"服务器发送时间"。
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
| **A 时间基** | **混合：`server_tick`（权威序号）+ `server_send_ms`（wall-clock 锚点）** | 序号用于和解/去重/碰撞顺序；wall-clock 解决"计数器当时间"；与现架构最兼容（均为追加字段）。 |
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

### G2 wall-clock 时间基
1. `PlayerMove(0x83)` 与 `MovementAck(0x8b)` **追加** `server_send_ms`（u64，毫秒）字段于 payload 末尾。
2. 时间源：服务端统一用 `System.os_time(:millisecond)`（wall-clock）作为 `server_send_ms`；与 `server_tick` 一起发出。（monotonic 仅用于本地间隔测量，不上线。）
3. `time_sync(0x85)` 维持现有请求-回复三时间戳；本阶段强化：客户端周期探测（频率 plan 定，建议 1–2s）+ offset 用 EWMA 平滑。

### G3 server authoritative tick
1. **统一两路径**：单帧路径（`step_and_broadcast`）在 `Engine.step` 前，对 `effective_input` 施加与 replay 路径一致的 server 重编号（`movement_state.tick + 1`），使 `client_tick` 不再进入仿真状态。
2. **`client_tick` 降级**：客户端上报的 `client_tick` 仅保留为**只读元数据**（用于 RTT/采样诊断、observe），永不写入 `movement_state.tick`。
3. **tick 语义固定**：`movement_state.tick` 为 server-owned 单调递增计数器，递增步长 = 本 tick 处理的固定步数（单帧 +1；replay +N）。`MovementAck.authTick` 与 `PlayerMove.server_tick` 均取自它。
4. integrator 层：保持 `grounded_step` 接口，但确保其 `tick` 输入恒为 server 分配值（通过上层 renumber 保证；不改 NIF 算法）。

### G4 客户端时间轴对齐
1. 远端插值：`RemotePlayerState` 的时间轴从 `serverTick × tickDuration` 改为**基于 `server_send_ms`**——客户端用 `localArrival + clockOffset` 将快照锚定到统一 server 时间轴，`server_tick` 退为序号（去重/排序，保留 `pushSnapshot:70` 的单调过滤）。
2. `serverClockOffsetMs` 从 `remotePlayerController` 接入 `RemotePlayerState.sampleMotion` 的时间换算（消除 2.2 的断路）。
3. 本地和解：reconcile 的权威态时间锚定改用 `authTick` + `server_send_ms` 一致化（保持 `reconcile.ts` 现有 replay 算法不变，仅校正时间对齐）。
4. interpolation delay 与 `deliveryInterval` 自适应（`remotePlayer.ts:160-173`）保留；其上限与 `server_send_ms` 抖动联动（plan 调参）。

### G5 jitter estimator 修复
- `localPlayer.ts:147-153`：引入 `smoothedRtt`（EWMA），`jitter = EWMA(|rtt − smoothedRtt|)`；`softPositionError` 据此自适应（保留 `governance.ts` 上限 8cm）。

---

## 5. 协议变更清单（wire 层）

| 消息 | 变更 | 说明 |
|---|---|---|
| 握手帧 | 新增 `protocol_version(u16)` | enter-scene/auth 完成后 |
| `Movement(0x01)` | `msg_type` 后插 `schema_version(u8)` | layout 变更，双端同步 |
| `PlayerMove(0x83)` | 插 `schema_version(u8)` + 末尾追加 `server_send_ms(u64)` | layout 变更 + 追加 |
| `MovementAck(0x8b)` | 插 `schema_version(u8)` + 末尾追加 `server_send_ms(u64)` | layout 变更 + 追加 |
| `time_sync(0x85)` | 不变（强化使用频率/平滑，非 wire 变更） | |

> 精确字节偏移在 plan 阶段连同 codec 实现钉死，并同步更新 `docs/2026-04-10-线协议规范.md`（线协议单一真相源）。

---

## 6. 实现影响面（锚点，plan 阶段细化）

**服务端（Elixir）**：
- `apps/gate_server/lib/gate_server/codec.ex`（编解码 + schema_version + 长度校验）
- `apps/scene_server/lib/scene_server/worker/player_character.ex`（单帧路径 renumber 统一、ack/snapshot 盖 `server_send_ms`）
- `apps/scene_server/lib/scene_server/movement/{engine.ex,ack.ex,remote_snapshot.ex,state.ex}`（tick 语义、ack/snapshot 字段）
- 握手/接入路径（`gate_server` 连接建立、enter-scene）+ `time_sync` 处理点

**服务端（Rust）**：
- `apps/scene_server/native/movement_core/src/integrator.rs`（确保 tick 输入为 server 值；不改算法）

**客户端（TS, `clients/web_client/src`）**：
- `infrastructure/net/gateProtocol.ts`（schema_version + 长度校验 + 解析 `server_send_ms`）
- `infrastructure/net/serverMovementTransport.ts`（time_sync 频率/平滑、offset 暴露）
- `domain/movement/remotePlayer.ts`（时间轴改 wall-clock）、`localPlayer.ts`（jitter 修复 + 和解时间对齐）
- `app/controllers/remotePlayerController.ts`（offset 接入插值）

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
- 新增：插值时间轴跳变计数 = 0；tick 序列断点 = 0；伪造 `client_tick` 注入测试下权威 tick 不受影响。

**验证入口**（复用现有 + 扩展）：
- `powershell scripts\e2e-stdio-movement.ps1`、`scripts\e2e-live-movement.ps1`（drift/reconcile）。
- `node scripts/run_browser_movement_smoke_supervised.js`（浏览器双客户端）。
- 服务端 stdio：`player_state <cid>` 扩展时间/tick 字段；observe 写 `.demo/observe/`。

---

## 8. 风险与回退

| 风险 | 缓解 |
|---|---|
| 热点帧 layout 变更（第一版无兼容层） | web_client 与服务端同步发布；`protocol_version` 握手做版本一致性断言（不一致 fail-fast）；bevy_client 作为参考实现滞后跟进 |
| `server_send_ms` 新时间轴质量需验证（不保留旧路径回退） | observe 对比新旧时间轴 drift 仅作**开发期验证手段**；不达标则合入前修正，**不**保留旧 `serverTick × dt` 路径作运行时回退 |
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
2. `PlayerMove`/`Ack` 携带 `server_send_ms`；客户端插值时间轴改用 wall-clock + clock offset。
3. 单帧/replay 两路径 tick 统一为 server-owned，`client_tick` 注入测试不污染权威 tick。
4. jitter estimator 修正，softError 自适应在稳定/抖动网络下表现合理。
5. 全部门槛通过（§7），observe 产物可复现；线协议规范 + README 已回写。
6. **无迁移债**：旧 `serverTick × dt` 时间轴、单帧 `client_tick` 泄漏路径、靠注释的固定 offset 解码均已删除，代码中不残留兼容/回退/双 schema 开关。
