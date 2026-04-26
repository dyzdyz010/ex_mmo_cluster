# Bevy Client 审计 sweep — 修复进度勾销表

**说明**：每条 confirmed item 修复后由 implementer 勾选，reviewer 复核后定稿。

## Slice A: Net + Protocol（9 confirmed）

- [ ] **A-S1** MovementAck correction_flags 偏移前置长度校验
- [ ] **A-S2** 阻塞 TCP 写硬自旋 → 非阻塞缓冲队列
- [ ] **A-S3** UDP 单包接收 → 循环读到 WouldBlock
- [ ] **A-M1** `expect("movement ack")` → 显式错误传播
- [ ] **A-M2** Auth 失败无重试 → 指数退避
- [ ] **A-M3** EnterSceneResult 缺位置 expect → 显式错误路径
- [ ] **A-L1** payload 最小长度未验证 → 各分支前断言
- [ ] **A-L2** 跳帧无检测日志 → PlayerMove 跳帧 log
- [ ] **A-L3** protocol_v2.rs 命名误导 → 文件顶部 TODO 注释
- [ ] **A-L4** observe.rs send 错误吞掉 → 至少记录一次

**已关闭**：A-M4 (false_positive，fastlane race 经多重保护不会发生)

## Slice B: Sim + Movement + Server seq 握手（12 confirmed）

- [ ] **B-S1** + **B-SRV1/2/3** 重连 seq 握手（协议变更原子 commit，含 client/server/规范）
- [ ] **B-S2** 无历史命中时强制 replay pending
- [ ] **B-S3** correction.rs from_bits 校验未知位
- [ ] **B-M1** governance hysteresis band
- [ ] **B-M2** MovementAck 携带 fixed_dt_ms 校验
- [ ] **B-M3** history.rs 容量告警 + retain_recent
- [ ] **B-L1** jitter EWMA 时间衰减 / 静默 reset
- [ ] **B-L2** StatusOverride 与 pending 输入交互文档化 + 测试
- [ ] **B-L3** smoothing_rate_hz 与 jitter 联动

## Slice C: Camera + Input（8 confirmed，C-S2 与 C-L2 合并）

- [ ] **C-S1** cursor grab 监听 Window::focused
- [ ] **C-S2 + C-L2** input_to_world_direction 输出归一化
- [ ] **C-M1** 摄像机 ray-cast 碰撞回退
- [ ] **C-M2** web 默认 pitch 对齐测试
- [ ] **C-M3** manage_cursor_grab run_if 状态变化
- [ ] **C-L1** speed_scale 抽常量 + TODO
- [ ] **C-L3** orbit_motion observer 阈值过滤

## Slice D: Voxel + World + Presentation（8 confirmed）

- [ ] **D-S1** sync_player_visuals 跟踪 prior local_cid
- [ ] **D-S2** sample_motion 孤立 extrapolate observer event
- [ ] **D-S3** presentation/camera vs camera/plugin 边界 + 常量统一
- [ ] **D-M1** animation velocity 从 smoothed position 求导
- [ ] **D-M2** 删除 voxel_material_color/handle 的 _refined 参数
- [ ] **D-M3** voxel parity 测试补 3 类（refined cell / prefab overlap / batch import）
- [ ] **D-L1** smoothing.rs 顶部 doc 说明 snap/lerp 边界
- [ ] **D-L2** 合成 idle_frame.seq=0 内联注释

## Slice E: App glue + Stdio + UI（10 confirmed）

- [ ] **E-S1** stdin 读失败上抛事件
- [ ] **E-S2** Mutex 锁失败 observer log
- [ ] **E-M1** observe.rs emit 写入失败计数 + 阈值禁用
- [ ] **E-M2** SessionCredentials 手写 Debug 跳过 token
- [ ] **E-M3** skill_id 抽常量到一处
- [ ] **E-M4** auto_login 加 30s timeout
- [ ] **E-L1** stdio 命令循环每帧 max 10 条
- [ ] **E-L2** HUD dirty flag 仅变化时重建
- [ ] **E-L3** effects gizmo run_if + DiagRenderToggle
- [x] **E-L4** app/mod.rs 测试 unwrap → expect (commit 300c179)

**已关闭**：E-S3 (false_positive，movement/mod.rs:82 是测试代码 panic)

---

## 完成统计

| 切片 | 总 confirmed | 已修 | 进度 |
|---|---|---|---|
| A | 10 | 0 | 0% |
| B | 12 | 0 | 0% |
| C | 8 | 0 | 0% |
| D | 8 | 0 | 0% |
| E | 10 | 0 | 0% |
| **合计** | **48** | **0** | **0%** |

**注**：A 切片 10 项是因为 A-S1/A-S2/A-S3/A-M1/A-M2/A-M3/A-L1/A-L2/A-L3/A-L4 共 10 条，A-M4 已 false_positive 关闭。
