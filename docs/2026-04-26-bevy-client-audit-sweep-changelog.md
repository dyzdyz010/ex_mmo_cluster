# Bevy Client 审计 sweep — 修复进度勾销表

**说明**：每条 confirmed item 修复后由 implementer 勾选，reviewer 复核后定稿。

## Slice A: Net + Protocol（9 confirmed）

- [x] **A-S1** MovementAck correction_flags 偏移前置长度校验 (f636b0f)
- [x] **A-S2** 阻塞 TCP 写硬自旋 → 指数退避 + 1s 总时长上限 (8525633)
- [x] **A-S3** ~~UDP 单包接收~~ → 二次审查后为 **false_positive**：`net/thread.rs:264-326` 已经是 `while let Some(socket) { match recv ... Ok => process+continue, WouldBlock => break }` 的标准 draining 循环。原 validator A 误读代码（把 `while let` 看成绑定检查而非循环条件）。无需修复。
- [x] **A-M1** `expect("movement ack")` → 显式错误传播 (f636b0f)
- [x] **A-M2** Auth 失败无重试 → 3 次重试指数退避 (8525633)
- [x] **A-M3** EnterSceneResult 缺位置 expect → 显式错误路径 (f636b0f)
- [x] **A-L1** payload 最小长度未验证 → 各分支前断言 (f636b0f)
- [x] **A-L2** 跳帧无检测日志 → PlayerMove 跳帧 log (f636b0f)
- [x] **A-L3** protocol_v2.rs 命名误导 → 文件顶部 TODO 注释 (704ead7)
- [x] **A-L4** observe.rs send 错误吞掉 → 至少记录一次 (f636b0f)

**已关闭**：A-M4 (false_positive，fastlane race 经多重保护不会发生)

## Slice B: Sim + Movement + Server seq 握手（12 confirmed）

- [x] **B-S1** + **B-SRV1/2/3** EnterSceneResult.expected_seq 协议变更原子 commit (1fc5507)
- [x] **B-S2** 无历史命中时强制 replay pending (661d948)
- [x] **B-S3** correction.rs from_bits 校验未知位 → 未知位下沉到 None (661d948)
- [x] **B-M1** governance 上升即时/下降 25% 混合的非对称 hysteresis (661d948)
- [x] **B-M2** MovementAck.fixed_dt_ms 协议字段 + client 漂移日志 (765bb44)
- [x] **B-M3** history overflow_drops 计数 + is_at_high_water (661d948)
- [x] **B-L1** jitter reset_if_stale + observe_rtt_at + reset_with_seq 一并清理 (661d948)
- [x] **B-L2** dispatch_status_override 加正式 doc，已有测试覆盖契约 (661d948)
- [x] **B-L3** smoothing_rate_hz **故意**与 jitter 解耦，文档化原因 (661d948)

## Slice C: Camera + Input（8 confirmed，C-S2 与 C-L2 合并）

- [ ] **C-S1** cursor grab 监听 Window::focused
- [ ] **C-S2 + C-L2** input_to_world_direction 输出归一化
- [ ] **C-M1** 摄像机 ray-cast 碰撞回退
- [ ] **C-M2** web 默认 pitch 对齐测试
- [ ] **C-M3** manage_cursor_grab run_if 状态变化
- [ ] **C-L1** speed_scale 抽常量 + TODO
- [ ] **C-L3** orbit_motion observer 阈值过滤

## Slice D: Voxel + World + Presentation（8 confirmed）

- [x] **D-S1** sync_player_visuals 跟踪 prior local_cid (6a8f215)
- [x] **D-S2** sample_motion 孤立 extrapolate observer event (6a8f215)
- [x] **D-S3** presentation/camera 文档化为被动工具库 + 常量明示职责 (6a8f215)
- [x] **D-M1** animation velocity 从 smoothed position 求导 (6a8f215)
- [x] **D-M2** 删除 voxel_material_color/handle 的 _refined 参数 (704ead7)
- [x] **D-M3** voxel parity 测试补 3 类（refined cell / prefab overlap / batch import）(1045b66)
- [x] **D-L1** smoothing.rs 顶部 doc 说明 snap/lerp 边界 (704ead7)
- [x] **D-L2** 合成 idle_frame.seq=0 内联注释 (704ead7)

## Slice E: App glue + Stdio + UI（10 confirmed）

- [x] **E-S1** stdin 读失败上抛事件 (32fbb82)
- [x] **E-S2** Mutex 锁失败 observer log (32fbb82 login.rs + d7655e8 net/plugin.rs)
- [x] **E-M1** observe.rs emit 写入失败计数 + 256 间隔 stderr (32fbb82)
- [x] **E-M2** SessionCredentials 手写 Debug 跳过 token (ddaaa2a)
- [x] **E-M3** skill_id 抽常量到一处 (ddaaa2a)
- [x] **E-M4** auto_login 加 30s timeout (32fbb82)
- [x] **E-L1** stdio 命令循环每帧 max 16 条 (ddaaa2a)
- [x] **E-L2** HUD 用 Bevy `is_changed()` 仅资源变化时重建 (e4aa47e)
- [x] **E-L3** effects gizmo run_if + EffectGizmosEnabled (ddaaa2a)
- [x] **E-L4** app/mod.rs 测试 unwrap → expect (commit 300c179)

**已关闭**：E-S3 (false_positive，movement/mod.rs:82 是测试代码 panic)

---

## 完成统计

| 切片 | 总 confirmed | 已修 | 进度 |
|---|---|---|---|
| A | 9 | 9 | 100% ✅ (A-S3 改判 false_positive) |
| B | 12 | 12 | 100% ✅ |
| C | 8 | 0 | 0% |
| D | 8 | 8 | 100% ✅ |
| E | 10 | 10 | 100% ✅ |
| **合计** | **48** | **0** | **0%** |

**注**：A 切片 9 项有效 = 10 条 - A-S3（implementer 二次审查改判 false_positive）。A-M4 在 Phase 0.7 已关闭。
