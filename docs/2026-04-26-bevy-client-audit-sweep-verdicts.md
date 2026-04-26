# Bevy Client 审计 sweep — Phase 0 Verdicts

**日期**：2026-04-26
**输入**：`docs/2026-04-26-bevy-client-audit-findings.md` 的 47 client + 3 server findings
**评审方式**：5 路 Explore agent 并行核验，read-only

## 汇总（含 Phase 0.7 追研结果）

| 切片 | confirmed | false_positive | needs_more_context | 备注 |
|---|---|---|---|---|
| A: Net+Protocol | 8 | 2 (A-M4 fastlane, A-S3 UDP recv) | 0 | A-S3 在 implementer 阶段二次反证关闭 |
| B: Sim+Movement+Server | 12 | 0 | 0 | B-SRV1 经 0.7 完全 confirmed |
| C: Camera+Input | 8 | 0 | 0 | C-S2 与 C-L2 重复，合并修 |
| D: Voxel+World+Presentation | 8 | 0 | 0 | — |
| E: App+UI+Stdio | 10 | 1 (E-S3 测试代码 panic) | 0 | E-S3 关闭 |
| **合计** | **46** | **3** | **0** | — |

## 关键观察

- **E-S3 false_positive**：`movement/mod.rs:82` 的 panic 是 `#[test]` 函数内的测试断言模式（`let Some(...) else { panic!() };`），并非生产网络线程崩溃。原审计误读，关闭。
- **C-S2 与 C-L2 同源**：input_to_world_direction 未归一化既是上行抖动后果（C-S2）也是命名违反最小惊讶（C-L2），可合并为一处修复。
- **D 切片三聚类**：presentation/camera 边界（D-S3 + D-L1）、remote actor 插值（D-S2 + D-M1）、voxel 测试与 API 卫生（D-M2/M3/L2/S1）。
- **B-SRV2 用户决策已明确**：v1 协议直接末尾追加 expected_seq u32 BE，**不做向后兼容**。原 validator 出于谨慎标 needs_more_context，本汇总按用户决策升级为 confirmed。
- **B-SRV3 文档同步**：归类 confirmed 防遗忘（不是 bug 但是 sweep deliverable）。

## Phase 0.7 追研结论

### A-S3 UDP 单包接收 → false_positive（implementer 二次审查发现）

implementer 阶段实际查看 `clients/bevy_client/src/net/thread.rs:264-326` 时发现：当前代码已经是 draining 循环——
```rust
while let Some(socket) = udp_socket.as_ref() {
    match socket.recv(&mut buf) {
        Ok(n) => { /* process */ }    // 自然 fall-through，下一轮 iteration 继续 recv
        Err(WouldBlock) => break,
        ...
    }
}
```
原 validator A 把 `while let Some(socket) = ...` 误读成"socket 还绑定时一次执行"，实际上它是 while 循环，Ok 路径会再次进入 recv 直到 WouldBlock。多包积压本就是单帧 drain 干净的，无 bug。无需修复。

### A-M4 fastlane race → false_positive

5 处具体证据反证：
1. `runtime.rs:663-669` `attach_request_id` 校验（不匹配的旧响应被丢弃）
2. `runtime.rs:115-119` `next_request_id` 单调递增不重用
3. `thread.rs:382-418` socket 替换原子性（attach 报文成功发送后才赋值新 socket）
4. UDP 消息路由无歧义（其他消息不依赖 fastlane 状态）
5. `fastlane.rs:85-88` `prepare_attach()` 清空旧 ID 同时设置新 ID，无重叠窗口

### B-SRV1 → confirmed，但语义需澄清

**关键发现**：server 端 `PlayerManager` **无 session 持久化**，每次重连都新建 PlayerCharacter（`last_input_seq: 0`）。所以 client 现在的 `reset()` 回到 1 与 server 隐式一致——**B-S1 当前不是 production bug，是架构脆弱性**。

仍按设计落地 `expected_seq` 字段，理由调整为：
- **显式化协议契约**：不依赖"双方都从 1 开始"的隐式假设
- **未来防御**：若 server 引入 session 复用 / supervisor restart 复用旧进程，client 自动对齐
- **可观测性**：debug 日志能直接对照 server expected vs client next

`next_input_seq = last_input_seq + 1` 推导正确（`player_character.ex:228-249` 的 `frame.seq > last_input_seq` 校验确认）。

**实施步骤**（4 处改动）：
1. `apps/gate_server/lib/gate_server/codec.ex:237-240` encode `{:enter_scene_result, :ok, packet_id, {x,y,z}, expected_seq}`，追加 `expected_seq::32-big`
2. `apps/scene_server/lib/scene_server/worker/player_character.ex` 提供 `:get_next_input_seq` call handler 返回 `last_input_seq + 1`
3. `apps/gate_server/lib/gate_server/worker/tcp_connection.ex:472-482` `add_player` 后调 `fetch_next_input_seq(ppid)` 注入 encode
4. `apps/gate_server/test/.../tcp_connection_protocol_test.exs` FakePlayer 加 `:get_next_input_seq` handler，加协议字段测试

---

# Slice A Verdicts

## A-S1: MovementAck correction_flags 偏移可疑
**Verdict**: confirmed
**Evidence**:
根据规范（`docs/2026-04-10-线协议规范.md:383-403`）MovementAck (0x8B) body 应 94 字节：
- ack_seq u32 (0-3), auth_tick u32 (4-7), cid i64 (8-15), location vec3 (16-39), velocity vec3 (40-63), acceleration vec3 (64-87), movement_mode u8 (88), correction_flags u32 (89-92)

`protocol.rs:210-219`：
```rust
0x8B => Ok(ServerMessage::MovementAck {
    ack_seq: read_u32(body, 0)?,
    auth_tick: read_u32(body, 4)?,
    cid: read_i64(body, 8)?,
    location: read_vec3(body, 16)?,
    velocity: read_vec3(body, 40)?,
    acceleration: read_vec3(body, 64)?,
    movement_mode: read_u8(body, 88)?,
    correction_flags: read_u32(body, 89)?,
}),
```

偏移本身正确；问题是缺少**前置长度验证**——若 body < 93 字节，错误从 `read_u32` 隐式返回 ProtocolError，调试困难且无明确语义。

**Suggested fix**: 在 0x8B 分支前加 `if body.len() < 93 { return Err("MovementAck body too short".into()) }` 显式校验。

---

## A-S2: 阻塞 TCP 写硬自旋
**Verdict**: confirmed
**Evidence**: `transport.rs:44-62` `send_tcp_bytes`：
```rust
Err(err) if err.kind() == io::ErrorKind::WouldBlock => thread::sleep(Duration::from_millis(5))
```
WouldBlock 时硬 sleep 5ms 重试，无指数退避无队列缓冲。高频 Movement (~16.7ms 帧) 累积延迟。

**Suggested fix**: 引入 VecDeque/crossbeam 缓冲队列；网络线程定期 flush。

---

## A-S3: UDP 单包接收
**Verdict**: confirmed
**Evidence**: `thread.rs:264-327`：
```rust
while let Some(socket) = udp_socket.as_ref() {
    match socket.recv(&mut udp_read_buffer) {
        Ok(n) => { /* process */ },
        Err(WouldBlock) => break,
        ...
    }
}
```
单次 WouldBlock 即跳出 while。多包积压时仅读一个，余下推迟一帧。

**Suggested fix**: 改为 `loop { recv → continue / WouldBlock → break }`。

---

## A-M1: `expect("movement ack")` 无覆盖
**Verdict**: confirmed
**Evidence**: `runtime.rs:535`：
```rust
let ack = movement_ack_from_server(&message).expect("movement ack");
```
`movement_ack_from_server` 返回 Option，非 MovementAck 时 panic 崩网络线程。

**Suggested fix**: `ok_or_else(|| "non-MovementAck where expected".into())?`。

---

## A-M2: Auth 失败无重试
**Verdict**: confirmed
**Evidence**: `thread.rs:116-122` send_tcp_message Err 时直接 emit_event 退出，无重试。

**Suggested fix**: 指数退避队列，最多 3 次。

---

## A-M3: EnterSceneResult 缺位置 expect
**Verdict**: confirmed
**Evidence**:
- `protocol.rs:254-260`：location 仅当 ok && body>=33 时为 Some，否则 None
- `runtime.rs:484-485`：`location.ok_or_else(|| "enter-scene success missing location".to_string())?`

ok=true 且 body<33 时静默拒绝，错误信息不区分 success/failure 路径。

**Suggested fix**: 显式区分 success(location) / error variant，或允许位置可选。

---

## A-M4: Fastlane 重附着竞态
**Verdict**: needs_more_context
**Evidence**: validator 自述未在本次核验范围阅读 fastlane.rs / runtime.rs 重附着流程。
**追研要求**: Phase 0.7 单独派 validator 专攻；需读 `clients/bevy_client/src/net/fastlane.rs` 全文 + `runtime.rs` 中所有 `fastlane`/`prepare_attach`/`detach` 引用，给出当前生命周期状态机 + 竞态触发条件或反证。

---

## A-L1: payload 最小长度未验证
**Verdict**: confirmed
**Evidence**: `protocol.rs:199-202` `decode_server_payload` 仅检查 `payload.is_empty()`，不验各类型最小长度。

**Suggested fix**: 每个 match 分支前加最小长度断言（或集中在 dispatch 表）。

---

## A-L2: 跳帧无检测日志
**Verdict**: confirmed
**Evidence**: `runtime.rs:519-529` 检测 ack_seq/auth_tick 过期但不记录间隙。PlayerMove 分支无跳帧日志。

**Suggested fix**: PlayerMove 分支：`if latest_tick > server_tick + 1 { emit log "jumped N ticks" }`。

---

## A-L3: protocol_v2.rs 命名误导
**Verdict**: confirmed
**Evidence**: `protocol_v2.rs` 仅含 movement-specific 适配（`movement_ack_from_server`、`WireMoveInputFrame`），非新协议版本。

**Suggested fix**（按设计：仅 TODO，不重命名）: 文件顶部加 `// TODO: rename to movement_codec.rs ...` 注释。

---

## A-L4: send 错误吞掉
**Verdict**: confirmed
**Evidence**: `observe.rs:16-23` `emit_event` 的 `let _ = event_tx.send(event)` 忽略错误。接收端 drop 后无感知。

**Suggested fix**: send 失败至少记录一次 + 终止网络线程或转入降级模式。

---

## Slice A 总结
- confirmed: 10
- false_positive: 0
- needs_more_context: 1（A-M4 fastlane 竞态）

**跨条目观察**: A 切片全为网络 I/O + 协议级问题，互相独立、修复无串联依赖。A-M4 单独追研。
# Slice B Verdicts

## B-S1: Client seq 重连握手缺失
**Verdict**: confirmed
**Evidence**:
- `clients/bevy_client/src/world/local_player.rs:53,73` `reset()` 与 `clear()` 无条件 `next_seq = 1`
- `clients/bevy_client/src/protocol.rs:98-102` `EnterSceneResult` 仅有 `location: Option<NetVec3>`，**无 expected_seq 字段**
- `apps/scene_server/lib/scene_server/.../player_character.ex:82` 维护 `last_input_seq: 0`，但无 next_input_seq 暴露给 EnterSceneResult
- 重连后 client 从 seq=1，server 期待旧序列号 → ack 全错配
**Suggested fix scope**: 见 B-SRV1/2/3。

---

## B-S2: 无历史命中时不重放 pending
**Verdict**: confirmed
**Evidence**:
- `clients/bevy_client/src/sim/reconcile.rs:230-274` `reconcile_without_match()`：行 260 `predicted_history.push(authoritative.clone())` 后无 replay
- pending_frames（行 51）仅统计未重放
**Suggested fix scope**: 无历史命中时强制 replay pending_frames，或拒绝接受该 ack。

---

## B-S3: from_bits 静默接受未知位
**Verdict**: confirmed
**Evidence**:
- `clients/bevy_client/src/sim/correction.rs:39` `CorrectionFlags::from_bits(bits)` 标准行为接受任意 u32
- 未知位静默吞掉，可能误触发 Teleport/Accepted/StatusOverride
**Suggested fix scope**: 添加 `is_valid_flags()` 校验已知掩码；未知位下沉到 `None`。

---

## B-M1: soft_position_error 自适应阈值滞后
**Verdict**: confirmed
**Evidence**:
- `clients/bevy_client/src/world/local_player.rs:169-172` `observe_rtt()` 调用顺序：jitter.observe → governance.apply_jitter
- `governance.rs` 中 soft_position_error 阈值依赖 jitter 状态；但 jitter 异步采样
- reconcile 决策时可能用旧 jitter
**Suggested fix scope**: hysteresis band（±10ms 缓冲带）防边界震荡；或同步化 observe 时序。

---

## B-M2: fixed_dt_ms 耦合无运行时校验
**Verdict**: confirmed
**Evidence**:
- Client `clients/bevy_client/src/sim/profile.rs:41` 硬编码 `fixed_dt_ms: 100`
- Server `apps/scene_server/lib/.../player_character.ex:108` `movement_profile.fixed_dt_ms` 同 100ms（来自配置）
- MovementAck 不携带 dt，client 无法检测 mismatch
**Suggested fix scope**: MovementAck 增加 `server_fixed_dt_ms: u16`（**需 server 改动**），client 校验 mismatch 后告警。

---

## B-M3: 环形缓冲溢出无告警
**Verdict**: confirmed
**Evidence**:
- `clients/bevy_client/src/sim/history.rs:8-10` InputHistory cap=128, PredictedHistory cap=256
- `history.rs:22-28` push 满则 pop_front 无日志
**Suggested fix scope**: 80% 容量 warn；retain_recent 主动剪枝。

---

## B-L1: EWMA 无时间衰减
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/sim/jitter.rs:9-12` 文档明说 "no time-based decay"；行 65 `reset()` 需手动调用。
**Suggested fix scope**: 5s 无 ack 自动 reset；或加 age-aware decay。

---

## B-L2: StatusOverride 与 pending 输入交互未文档化
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/sim/reconcile.rs:67-73` dispatch_status_override 与 pending_frames 交互无说明，无测试。
**Suggested fix scope**: 加注释说明丢弃/重放语义；补 status_override_with_pending_inputs 测试。

---

## B-L3: render 平滑率与 reconcile 周期未联动
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/sim/plugin.rs:231-235` smoothing_rate_hz 独立于 jitter/governance。
**Suggested fix scope**: smoothing_rate_hz 与 JitterEstimator 一体管理；或 render 订阅 jitter 事件。

---

## B-SRV1: Session 维护 next_input_seq
**Verdict**: needs_more_context
**Evidence**:
- `apps/scene_server/lib/scene_server/.../player_character.ex:82` 已有 `last_input_seq: 0`
- 但 enter_scene 流程（行 96-128）未输出 expected_seq 到 EnterSceneResult；Movement.Engine 无 API 暴露 next expected seq
**追研要求**: Phase 0.7 派 validator 阅读 enter_scene 函数全文 + Movement.Engine 接口；确认推导 `next_input_seq = last_input_seq + 1` 是否符合 server 状态机假设。

---

## B-SRV2: EnterSceneResult encode/decode expected_seq
**Verdict**: confirmed
**Evidence**:
- `apps/gate_server/lib/gate_server/codec.ex:236-245` EnterSceneResult 当前 layout：msg_type + packet_id + status + [location]
- 设计明确：v1 协议直接末尾追加 expected_seq u32 BE，**不做向后兼容**
- 原 validator 担心兼容性问题，但用户决策已明确（不兼容、不 fallback）
**Suggested fix scope**: 在 codec.ex 的 encode_enter_scene_result 末尾追加 `<<expected_seq::big-32>>`；decode 同步加字段。客户端 protocol.rs 同改。

---

## B-SRV3: 线协议规范同步更新
**Verdict**: confirmed
**Evidence**: 文档同步本身不是 bug，但属于本次 sweep 必须完成的 deliverable（规范是协议事实源）。归类 confirmed 以免被遗忘。
**Suggested fix scope**: 在 docs/2026-04-10-线协议规范.md EnterSceneResult 字段表追加 expected_seq 行；与 codec 改动同 commit。

---

## Slice B 总结
- confirmed: 11 (B-S1, B-S2, B-S3, B-M1, B-M2, B-M3, B-L1, B-L2, B-L3, B-SRV2, B-SRV3)
- false_positive: 0
- needs_more_context: 1 (B-SRV1 enter_scene 函数全文)

**B-SRV 系列实施可行性**：PlayerCharacter 已有 last_input_seq 状态；EnterSceneResult layout 有扩展空间；Movement.Engine 不需改动；仅 session enter_scene 路径 + codec encode/decode 两处。可行。
# Slice C Verdicts

## C-S1: cursor grab 状态机不全
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/camera/plugin.rs:50-70` `manage_cursor_grab` 仅 `let want_grabbed = matches!(state.get(), AppState::Game) && !chat_open;`；grep 全代码库无 `Window::focused`/focus event 监听。Alt-Tab 后游标仍锁，挡 OS 操作。
**Suggested fix scope**: 监听 `WindowFocused` event 或读 `Window::focused`；失焦时强制 `CursorGrabMode::None`。

---

## C-S2: WASD 离散方向 + 相机旋转抖动
**Verdict**: confirmed
**Evidence**:
- `clients/bevy_client/src/movement/plugin.rs:268-285` `current_movement_direction()` 返回 (±1, ±1)，未归一化
- `clients/bevy_client/src/camera/orbit.rs:72-81` `input_to_world_direction()` 纯旋转无归一化
- W+D 在 yaw=45° 下方向向量长度 ~1.41
- `movement/plugin.rs:173` `input_dir: [direction.x, direction.y]` 直接上行，未归一化
- 下游 `length_squared()` 仅做 0/非0 二值判断，未做幅度规范

**Suggested fix scope**: 在 `input_to_world_direction` 输出前 `normalize_or_zero()`；或在 movement_sender 发包前归一化。

---

## C-M1: 摄像机无 ray-cast 碰撞回退
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/camera/plugin.rs:87-155` 计算 desired_target → 平滑 → 应用 `camera_transform_from_orbit`，无任何碰撞检测。穿墙/进地下风险。
**Suggested fix scope**: actor → camera 反向 ray-cast，命中时 clamp 距离推回；可用 voxel world API（已有 `actor_render_position` 表面采样基础）。

---

## C-M2: 默认 pitch 与 web 对齐无测试
**Verdict**: confirmed
**Evidence**:
- Bevy: `clients/bevy_client/src/camera/orbit.rs:41-56` `pitch: 0.58`
- Web: `clients/web_client/src/render/scene.ts:62` `let orbitPitch = 0.58;`
- 两侧 yaw 都是 π/4 ≈ 0.785；pitch 都是 0.58；**值已对齐**但仅靠注释 + 硬编码，无测试断言

**Suggested fix scope**: bevy 端加常量 `WEB_CLIENT_DEFAULT_PITCH = 0.58` + 单测断言相等；或 design-time const_assert。

---

## C-M3: manage_cursor_grab 每帧无条件运行
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/camera/plugin.rs:38` `.add_systems(Update, manage_cursor_grab)` 无 gating；行 50-70 函数内部分支每帧 evaluate。
**Suggested fix scope**: `.run_if(state_changed::<AppState>().or(resource_changed::<ChatState>()))`；或函数内 cache last_state。

---

## C-L1: speed_scale 硬编码 1.0
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/movement/plugin.rs:175` `speed_scale: 1.0` 硬编码。设计冗余但当前不阻塞。
**Suggested fix scope**: 抽 const + TODO；或预留 Resource SpeedScale(f32)；本 sweep 仅做最小改动。

---

## C-L2: input_to_world_direction 未归一化
**Verdict**: confirmed
**Evidence**: 同 C-S2 evidence；本条聚焦命名与最小惊讶原则，C-S2 聚焦上行抖动后果。
**Suggested fix scope**: 与 C-S2 合并修复（一处改动覆盖两条）。

---

## C-L3: orbit_motion 观察者每帧 emit
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/camera/plugin.rs:102-114` `if delta.length_squared() > 0.0` 内无条件 emit 7 属性 struct。60+ Hz 高音量。
**Suggested fix scope**: `if delta.length_squared() > THRESHOLD` 才 emit（如 5° 等价的 squared 值）。

---

## Slice C 总结
- confirmed: 8
- false_positive: 0
- needs_more_context: 0

**跨条目观察**：C-S2 与 C-L2 重复，可合并为单一修复；C-S1 与 C-M3 都涉及 cursor grab，可一起重构。
# Slice D Verdicts

## D-S1: sync_player_visuals 切场景未清理 local visual
**Verdict**: confirmed
**Evidence**:
- `clients/bevy_client/src/presentation/plugin.rs:88` `desired` map 插入 `local.cid = world_state.local_cid`
- `plugin.rs:148-152` despawn 循环条件 `if cid != params.world_state.local_cid` —— 当 local_cid 已变化时，旧 visual 被正常 despawn
- **但** 1-frame 窗口内新旧 cid 的 PlayerVisual 共存，无显式 prior cid 跟踪
**Suggested fix scope**: 跟踪 prior local_cid，transition 时显式 despawn；或延迟 spawn/despawn 至下一帧。

---

## D-S2: sample_motion clamp 后孤立 extrapolate
**Verdict**: confirmed
**Evidence**:
- `clients/bevy_client/src/world/remote_player.rs:141` `clamp(0.0, MAX_REMOTE_EXTRAPOLATION_SECS)`
- 行 159 fallback `extrapolate_single(latest, now_secs)`；行 205-206 再 clamp dt
- 中等延迟 + 丢包 → 仅 1 个 snapshot → client time 超出阈值 → 静默 cap → 下次 snapshot 到达 (>250ms) 视觉 snap，无 log
**Suggested fix scope**: 进入孤立 extrapolate 路径时 emit observer event；并加边界保护（snap_distance 或 max teleport heuristic）。

---

## D-S3: presentation/camera.rs vs camera/plugin.rs 职责模糊
**Verdict**: confirmed
**Evidence**:
- `presentation/camera.rs` 导出工具 `desired_camera_target()`、`smooth_camera_translation()`，**无 system**
- `camera/plugin.rs` 导出 `CameraPlugin` 含 `manage_cursor_grab` / `update_orbit_camera` system
- plugin.rs:21 import `smooth_translation`；plugin.rs:146-152 内联同样平滑逻辑而**未调用** presentation 的 `smooth_camera_translation`
- 常量分歧：`CAMERA_FOLLOW_SPEED: 8.0` (plugin) vs `12.0` (presentation)
**Suggested fix scope**: presentation/camera.rs 文件顶部 doc 明确"被动工具库"；plugin 调用 presentation 的 helper；常量统一一处。

---

## D-M1: animation_state_from_velocity 与 smoothed position 解耦
**Verdict**: confirmed
**Evidence**:
- `clients/bevy_client/src/presentation/plugin.rs:93-94` 用 `motion.velocity`（remote snapshot 缓冲）
- `plugin.rs:118-124` 视觉 position 走 `smooth_translation()`（presentation 层平滑）
- teleport 时：sample_motion 清缓冲，返回新 position + 旧 velocity → animation 用旧 velocity → 腿停身体滑
**Suggested fix scope**: 从 smoothed position 数值微分得 velocity；或 smoothing.rs 同时返回 velocity。

---

## D-M2: voxel_material_color/handle 的 _refined 参数 no-op
**Verdict**: confirmed
**Evidence**:
- `clients/bevy_client/src/voxel/plugin.rs:718` `voxel_material_color(material_id, _refined: bool)` —— `_` 前缀表示未用
- `plugin.rs:735` `voxel_material_handle(assets, material_id, _refined: bool)` 同样未用
- 函数体注释明说精化 cell 故意共用 opaque 颜色/材质（避免 flicker）
- 调用方读 `cell.refined` 但**从不**传给两函数；`_refined` 是死参数
**Suggested fix scope**: 删除 `_refined` 参数（design 已说明：无未来计划则删）。

---

## D-M3: voxel parity 测试覆盖缺口
**Verdict**: confirmed
**Evidence** (`tests/voxel_parity.rs` 126 行 + `voxel_cli_parity.rs` 73 行)：
- 已覆盖：jump flag、microgrid resolution & bounds、builtin prefab smoke counts、round-trip snapshot、boundary snap contact rules
- **未覆盖**：
  1. refined cell 多 cell 重叠
  2. prefab 放置与现有块重叠
  3. WorldImport 多 prefab 顺序导入一致性
**Suggested fix scope**: 补 3 类测试。

---

## D-L1: smooth_translation 距离检查顺序
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/presentation/smoothing.rs:6-25` clamp 在 lerp 前防外推但缺顶部注释。
**Suggested fix scope**: 文件顶部加 doc 说明 snap / lerp 边界；或保留代码加内联注释。

---

## D-L2: 合成 idle_frame.seq=0 易混淆
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/world/local_player.rs:205-207` 合成 idle frame seq=0；正常 input frame seq 从 1 起。
**Suggested fix scope**: 内联注释说明 seq=0 标记 synthetic frame（不上行）；或换个语义清晰的 sentinel 值。

---

## Slice D 总结
- confirmed: 8
- false_positive: 0
- needs_more_context: 0

**跨条目观察**：D 切片三类问题——presentation/camera 边界（D-S3 + D-L1）、remote actor 插值（D-S2 + D-M1）、voxel 测试与 API 卫生（D-M2 + D-M3 + D-L2 + D-S1）。建议 implementer 按这三类分组改。
# Slice E Verdicts

## E-S1: stdin 读失败无重试
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/stdio/mod.rs:77-112` stdin 线程首次 I/O 错误（管道关闭、终端断开）emit error 后无条件 break；主线程对 ClientStdioInterface 的 try_recv 永久 None。
**Suggested fix scope**: stdin 错误后 emit + 上抛 channel event（让 Bevy 端感知断开），或重试若可恢复（管道 reopen 通常不可恢复，至少要让上层知道）。

---

## E-S2: Mutex 锁失败无诊断
**Verdict**: confirmed
**Evidence**:
- `clients/bevy_client/src/login.rs:134` `let Ok(receiver) = pending.0.lock() else { return; };`
- `clients/bevy_client/src/net/plugin.rs:36` `let Ok(receiver) = bridge.rx.lock() else { return; };`

两处均 early return 无日志；poisoned lock = 底层线程 panic，掩盖故障。
**Suggested fix scope**: 锁失败 emit observer error；如可恢复 break out，否则 panic 让 Bevy 早死早超生（debug 模式）。

---

## E-S3: 收到非运动命令 panic
**Verdict**: false_positive
**Evidence**: `clients/bevy_client/src/movement/mod.rs:79-83` 是 `#[test]` 函数内 `let Some(...) else { panic!("expected movement command") };` 的测试断言模式，**不是**生产网络线程路径。生产 `next_movement_command()` 的调用在 movement/plugin.rs，已用 Option 模式正常处理 None。

**结论**：原审计错误归因。movement/mod.rs:82 的 panic 是测试代码标准用法（test 失败本就该 panic）。无生产 bug。
**追研建议**：若审计真担心运行时 panic，需用 grep 在 net/thread.rs 找其他 panic 点；当前未发现。本条直接关闭。

---

## E-M1: emit 写入失败吞掉
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/observe.rs:76-78` `let _ = sink.send(line)` 忽略错误。
**Suggested fix scope**: send 失败计数 + 阈值后禁用 sink；或 fallback stdout。

---

## E-M2: SessionCredentials token 明文 Debug
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/config.rs:31-37`：
```rust
#[derive(Clone, Debug, Resource)]
pub struct SessionCredentials {
    pub username: String,
    pub cid: i64,
    pub token: String,  // Debug 会打印
}
```
**Suggested fix scope**: 手写 `impl Debug` 跳过 token；或使用 `secrecy::SecretString`。

---

## E-M3: skill_id / target_mode 硬编码
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/skill/targeting.rs:75-81`：
```rust
fn skill_target_mode(skill_id: u16) -> SkillTargetMode {
    match skill_id {
        1 | 2 | 4 | 101 => SkillTargetMode::Actor,
        3 => SkillTargetMode::Point,
        _ => SkillTargetMode::Unknown,
    }
}
```
+ `headless/runner.rs:250` 同硬编码。
**Suggested fix scope**: 抽常量到一处（或从 config 加载）；若有 server skill 元数据 endpoint 走 server pull（本 sweep 暂只做常量集中）。

---

## E-M4: auto_login 无 timeout
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/auth_client.rs:19` `ureq::post(&url).send_json(...)`，未设 `.timeout()`，主线程同步阻塞。
**Suggested fix scope**: `ureq::AgentBuilder::new().timeout(Duration::from_secs(30)).build()` + `.timeout()` per request。

---

## E-L1: stdio 命令循环无背压
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/stdio/plugin.rs:53-56` `loop { try_recv → break on None }` 单帧处理全部积压。
**Suggested fix scope**: 每帧 max N（如 10）条命令 + 剩余下帧处理。

---

## E-L2: HUD 每帧重复 format
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/hud/plugin.rs:79-128` 每帧 `format!()` 重建 HUD 字符串。
**Suggested fix scope**: dirty flag（数据变化才重建）；或 cache 上一帧字符串比较。

---

## E-L3: gizmo 无性能开关
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/effects/plugin.rs:30,53-83` `draw_effect_gizmos` 无条件运行。
**Suggested fix scope**: 加 `Resource DiagRenderToggle(bool)` + `.run_if(...)`。

---

## E-L4: 测试 unwrap()
**Verdict**: confirmed
**Evidence**: `clients/bevy_client/src/app/mod.rs:532,538,556,571` 测试代码用 `unwrap()`，前置条件不满足时 panic message 不友好。
**Suggested fix scope**: 改用 `.expect("message")` 或显式 `assert!(render.render_state.is_some(), ...)`。

---

## Slice E 总结
- confirmed: 10
- false_positive: 1 (E-S3 movement/mod.rs:82 是测试代码 panic)
- needs_more_context: 0

**跨条目观察**：E 切片三类问题——失败处理静默（E-S1, E-S2, E-M1）、安全/超时（E-M2, E-M4）、性能/卫生（E-L1~L4）。E-S3 是审计误判，关闭无需修复。
