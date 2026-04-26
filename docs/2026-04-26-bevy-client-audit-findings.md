# Bevy Client 审计发现清单

**日期**：2026-04-26
**来源**：5 路并行 Explore agent 对 `clients/bevy_client` 的审计
**用途**：作为 validator agent 的输入源

每条格式：`[ID] [档次] [文件:行号] 标题 — 描述 + 修复方向`

---

## 切片 A：Net + Protocol

### 严重
- **A-S1** [Severe] `clients/bevy_client/src/protocol.rs:218` MovementAck correction_flags 偏移可疑 — `read_u32(body, 89)` 读 4 字节，但 body 长度可能不足；规范要求 95 字节，应验长度后再解。**修**：先验长度。
- **A-S2** [Severe] `clients/bevy_client/src/net/transport.rs:44-62` 阻塞 TCP 写硬自旋 — `WouldBlock` 时 `thread::sleep(5ms)`，高频 Movement 上行被累积阻塞。**修**：非阻塞缓冲队列。
- **A-S3** [Severe] `clients/bevy_client/src/net/thread.rs:264-327` UDP 单包接收 — 仅在 `WouldBlock` 时 break，多包积压延后一帧。**修**：循环读到 `WouldBlock`。

### 中等
- **A-M1** [Med] `clients/bevy_client/src/net/runtime.rs:535` `expect("movement ack")` — match arm 未覆盖时 panic。**修**：显式 match。
- **A-M2** [Med] `clients/bevy_client/src/net/thread.rs:116-122` Auth 失败无重试 — 网络抖动需重启客户端。**修**：指数退避。
- **A-M3** [Med] `clients/bevy_client/src/protocol.rs:254-260, 644-647` 可选字段缺失后续 expect — `EnterSceneResult` 缺位置时返回 None，被 expect。**修**：显式错误传播。
- **A-M4** [Med] `clients/bevy_client/src/net/fastlane.rs` & `runtime.rs` Fastlane 重附着竞态 — 旧 UDP 关闭与新连接非原子。**修**：原子化 prepare_attach。

### 轻微
- **A-L1** [Mild] `clients/bevy_client/src/protocol.rs:199-202` payload 最小长度未验证 — 仅检查非空。**修**：各 decode 增加最小长度断言。
- **A-L2** [Mild] `clients/bevy_client/src/net/runtime.rs` 跳帧无检测日志 — `last_remote_move_ticks <= latest_tick` 但不记录间隙。**修**：emit Log 跳帧距离。
- **A-L3** [Mild] `clients/bevy_client/src/protocol_v2.rs` 命名误导 — 实际是 movement 适配层。**修**：本轮仅打 TODO 注释，不重命名（design out-of-scope）。
- **A-L4** [Mild] `clients/bevy_client/src/observe.rs:22` send 错误吞掉 — 接收端断线无感知。**修**：至少记录一次。

---

## 切片 B：Sim + Movement + Server seq 握手

### 严重
- **B-S1** [Severe] `clients/bevy_client/src/world/local_player.rs` `next_seq` 重连无 seq 握手 — `reset()` 回到 1，server 仍期待旧序列号；ack 全错配。**修**：复用 `EnterSceneResult` 增加 `expected_seq` 字段（见设计文档），client `reset_to(seq=N)`。
- **B-S2** [Severe] `clients/bevy_client/src/sim/reconcile.rs:230-274` 无历史命中时 `push(authoritative)` 但不重放 pending 输入 — 后续预测从错误基准累积漂移。**修**：无历史时强制 replay 或拒绝接受。
- **B-S3** [Severe] `clients/bevy_client/src/sim/correction.rs:39` `from_bits` 静默接受未知位 — 可能误触发 Teleport/Accepted。**修**：补 `is_valid_flags()`，未知位下沉到 `None`。

### 中等
- **B-M1** [Med] `clients/bevy_client/src/sim/governance.rs` `soft_position_error` 自适应阈值滞后 1-2 帧 — jitter 异步更新。**修**：hysteresis band 防止阈值边界震荡。
- **B-M2** [Med] `clients/bevy_client/src/sim/{predictor,reconcile,profile}.rs` 与 server `fixed_dt_ms` 耦合无运行时校验 — 200+ 帧 replay 可累积 0.02u 漂移。**修**：ack 携带 dt 用于检测 mismatch（**需 server 改动**——若 validator 确认漂移真实存在）。
- **B-M3** [Med] `clients/bevy_client/src/sim/history.rs` 环形缓冲溢出无告警 — 容量 128/256，溢出无声丢老输入。**修**：80% 容量 warn；retain_recent 主动触发。

### 轻微
- **B-L1** [Mild] `clients/bevy_client/src/sim/jitter.rs` EWMA 无时间衰减 — 静默 1 分钟后 jitter 仍锁高位。**修**：5s 无 ack 自动 reset 或加 decay。
- **B-L2** [Mild] `clients/bevy_client/src/sim/reconcile.rs:67-74` StatusOverride 与 pending 输入交互未文档化 — 测试缺失。**修**：显式文档 + 测试。
- **B-L3** [Mild] `clients/bevy_client/src/sim/plugin.rs:231-235` render 平滑率与 reconcile 周期未联动。**修**：smoothing_rate_hz 与 jitter 一体管理。

### 配套 server 改动（在切片 B 内）
- **B-SRV1** `apps/scene_server/lib/scene_server/...` session 维护 `next_input_seq`，进场/重连写入 `EnterSceneResult.expected_seq`
- **B-SRV2** `apps/gate_server/lib/gate_server/codec.ex` `EnterSceneResult` encode/decode 追加 `expected_seq: u32` BE
- **B-SRV3** `docs/2026-04-10-线协议规范.md` 同步更新 `EnterSceneResult` 字段表

---

## 切片 C：Camera + Input

### 严重
- **C-S1** [Severe] `clients/bevy_client/src/camera/plugin.rs:132-144` cursor grab 状态机不全 — 仅查 `!chat_open`，无视 Alt-Tab/失焦。**修**：监听 `Window::focused` 显式重设。
- **C-S2** [Severe] `clients/bevy_client/src/movement/plugin.rs:111,124` WASD 离散方向 + 相机快旋导致抖动 — `current_movement_direction()` 返回 ±1。**修**：旋转后归一化或低通滤波。

### 中等
- **C-M1** [Med] `clients/bevy_client/src/camera/plugin.rs:115-154` 摄像机无 ray-cast 碰撞回退 — 悬崖/洞穴穿墙。**修**：actor → camera 反向 ray-cast 推回。
- **C-M2** [Med] `clients/bevy_client/src/camera/orbit.rs:42-56` 默认 pitch 与 web 对齐无测试 — 注释指向 0.58 但无验证。**修**：增加集成测试或常量对照。
- **C-M3** [Med] `clients/bevy_client/src/camera/plugin.rs:38` `manage_cursor_grab` 每帧无条件运行 — 可加缓存。**修**：状态变化时再调用。

### 轻微
- **C-L1** [Mild] `clients/bevy_client/src/movement/plugin.rs:158-214` `speed_scale` 硬编码 1.0 — 设计冗余。**修**：预留参数化接口（仅函数签名）。
- **C-L2** [Mild] `clients/bevy_client/src/camera/orbit.rs:58-81` `input_to_world_direction` 未归一化 — W+D 长度 √2，由后续 `length_squared` 隐式过滤不规范。**修**：发包前归一化。
- **C-L3** [Mild] `clients/bevy_client/src/camera/plugin.rs:88-115` 观察者日志过多 — 每帧相机运动都发事件。**修**：仅大偏移时发射。

---

## 切片 D：Voxel + World + Presentation

### 严重
- **D-S1** [Severe] `clients/bevy_client/src/presentation/plugin.rs:149` `sync_player_visuals` 切场景未清理 local visual — `local_cid` 变化时 `PlayerVisual` 与旧 cid 冲突。**修**：`local_cid` 变化主动 despawn。
- **D-S2** [Severe] `clients/bevy_client/src/world/remote_player.rs:141` `sample_motion` clamp 后可能孤立 extrapolate_single — 中等延迟丢包视觉跳跃。**修**：加事件日志 + 边界保护。
- **D-S3** [Severe] `clients/bevy_client/src/presentation/camera.rs` vs `camera/plugin.rs` 职责模糊 — 两个文件都管相机；presentation 是工具函数库，camera/plugin 是驱动系统。**修**：在 presentation/camera.rs 顶部明确 doc + 移除/合并重复函数。

### 中等
- **D-M1** [Med] `clients/bevy_client/src/presentation/plugin.rs:94` animation_state_from_velocity 与 smoothed position 解耦 — teleport 后腿停身体滑。**修**：从 smoothed position 求导，或 smoothing 同时返回 velocity。
- **D-M2** [Med] `clients/bevy_client/src/voxel/plugin.rs:~729-741` `_refined` 参数 no-op — 文档说"未来分化 shader"无明确计划。**修**：删除参数（无未来计划则删，有则开 issue）。
- **D-M3** [Med] `clients/bevy_client/tests/voxel_parity.rs` & `voxel_cli_parity.rs` parity 覆盖缺口 — 缺 refined cell 边界 / prefab 重叠 / batch import 一致性。**修**：补 3 类测试。

### 轻微
- **D-L1** [Mild] `clients/bevy_client/src/presentation/smoothing.rs:15-25` `smooth_translation` 距离检查顺序绕 — `clamp(0,1)` 防外推但可读性低。**修**：顶部加注释说明 snap / lerp 边界。
- **D-L2** [Mild] `clients/bevy_client/src/world/local_player.rs:184-217` 合成 `idle_frame.seq=0` 调试易混淆 — 正常 seq 从 1 起。**修**：注释说明或换值。

---

## 切片 E：App glue + Stdio + UI

### 严重
- **E-S1** [Severe] `clients/bevy_client/src/stdio/mod.rs:77` stdin 读失败直接 break — 接口卡死无恢复。**修**：重试或事件上抛。
- **E-S2** [Severe] `clients/bevy_client/src/login.rs:134` & `net/plugin.rs:36` Mutex 锁失败静默返回 None — 故障无诊断。**修**：observer 记录。
- **E-S3** [Severe] `clients/bevy_client/src/movement/mod.rs:82` 收到非运动命令 panic — 崩网络线程。**修**：返回 Result 优雅处理。

### 中等
- **E-M1** [Med] `clients/bevy_client/src/observe.rs:56-79` emit 未检查写入失败 — 大量日志静默丢失。**修**：监控 send 失败次数，连续失败禁用。
- **E-M2** [Med] `clients/bevy_client/src/config.rs` SessionCredentials token 明文 — 内存/日志/Debug 可见。**修**：`#[derive(Debug)]` 跳过 token 字段；考虑 zeroize。
- **E-M3** [Med] `clients/bevy_client/src/headless/runner.rs:250` & `skill/targeting.rs:76-81` skill_id 与目标模式硬编码 — 无版本同步。**修**：从配置或 server 加载（最小：抽常量到一处）。
- **E-M4** [Med] `clients/bevy_client/src/auth_client.rs:18` `auto_login` 同步阻塞主线程无超时 — auth server 响应慢则主线程卡住。**修**：加 30s timeout（同步 client 用 reqwest blocking timeout）。

### 轻微
- **E-L1** [Mild] `clients/bevy_client/src/stdio/plugin.rs:41-352` & `headless/runner.rs` 命令循环无背压 — `loop try_recv` 一次性处理所有积压。**修**：每帧限 N 条。
- **E-L2** [Mild] `clients/bevy_client/src/hud/plugin.rs` & `chat/plugin.rs` 每帧重新格式化字符串 — 热路径 string alloc。**修**：dirty 才重建。
- **E-L3** [Mild] `clients/bevy_client/src/effects/plugin.rs:35-50` gizmo 无性能开关 — 100+ effect 时帧率下降。**修**：加 diag_render 开关。
- **E-L4** [Mild] `clients/bevy_client/src/app/mod.rs` `LocalRenderPrediction.unwrap()` — 测试代码若 None 会 panic。**修**：测试用 `as_ref()` + `assert!`。

---

## 总计

| 切片 | 严重 | 中等 | 轻微 | 合计 |
|---|---|---|---|---|
| A: Net+Protocol | 3 | 4 | 4 | 11 |
| B: Sim+Movement | 3 | 3 | 3 | 9（+3 server 改动） |
| C: Camera+Input | 2 | 3 | 3 | 8 |
| D: Voxel+World+Presentation | 3 | 3 | 2 | 8 |
| E: App+UI+Stdio | 3 | 4 | 4 | 11 |
| **合计** | **14** | **17** | **16** | **47**（+3 server） |
