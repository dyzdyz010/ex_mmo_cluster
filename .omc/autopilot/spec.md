# Spec: Movement Synchronization Architecture Rework (2026-04-20)

## Goal
消除 bevy_client 本地角色"卡顿 + 持续修正位置"现象，将移动同步重构为业界标准的"客户端预测 + 服务器纠偏 + 视觉平滑"三层架构（Quake/Valve 经典模型 + Unreal Exponential Smoothing），并让所有调试可通过 stdio 命令在 headless 模式下自动化验证。

## Non-goals
- 不改服务器权威逻辑（scene_server 的 movement_tick 保持原实现）
- 不改线协议 opcode 或字段顺序
- 不引入新依赖（除非必要）
- 不加图形 UI 相关调试面板，全部通过 stdio 可观测

## 架构评估结论
业界最佳实践已足够：**Quake3/Valve Source 的客户端预测 + 权威纠偏 + 远端实体插值** 是 MMORPG/FPS 的事实标准。本次不发明新算法，但**融合 Unreal 的 Exponential Network Smoothing** 作为可视化层的收敛策略。
- 预测层（Prediction）：已有 `LocalPredictionRuntime` 保留 input + predicted history。保留。
- 对账层（Reconciliation）：已有 `sim::reconcile`。改成按 `ack_seq` 主键、`tick` 辅助的查找；对账窗口外的 ack 优雅降级（按 correction_distance 阈值而不是盲目 HardSnap）。
- 可视化层（Visual Smoothing）：**新建**。引入 `pending_correction: Vec3` 指数衰减；渲染位置 = 预测位置 + 衰减校正量，而不是每个 LocalPosition 事件硬贴。
- 远端插值层（Entity Interpolation）：已有 Hermite 插值。延迟从 0.15s 调到 0.1s，外推上限从 0.12s 调到 0.25s 抗丢包。

## 根因映射
| 症状 | 根因 | 修复归属 |
|------|------|---------|
| "卡顿" | app.rs `LocalRenderPrediction.sync_full_state` 在每次 `LocalPosition` 事件（input send + ack recv）都硬贴 anchor_state 并清 partial_elapsed；本地角色 `sync_player_visuals` 直接赋值不过平滑 | US-A |
| "持续修正位置" | `governance.hard_snap_distance=32` + `soft_position_error=0.01` 过严；`extend_prediction_through` 复用 stale `last_input_frame` 导致 idle 帧下还在累积推进 | US-A + US-B |
| "远端角色顿挫" | `INTERPOLATION_DELAY=0.15s` 偏大，网络抖动下 playback 时常落入单帧外推分支 | US-B |
| "长距 ack 直接 HardSnap" | `reconcile.state_at_tick` 查询落空时无条件 HardSnap，忽略 correction_distance | US-C |

## User Stories

### US-A Visual Smoothing Layer + stdio 诊断
**目标**：重写 `LocalRenderPrediction` 为基于 `LocalPredictionRuntime.current_state()` 的投影层 + `pending_correction` 向量指数衰减；net.rs 发送/收到 ack 时只写 `pending_correction` 差分，不动预测状态；sync_player_visuals 本地角色路径走 smooth_translation；新增 stdio `diag_render` 与 `reconcile_stats` 命令。

**Files**: `clients/bevy_client/src/app.rs`、`clients/bevy_client/src/world/local_player.rs`、`clients/bevy_client/src/net.rs`、`clients/bevy_client/src/stdio.rs`

### US-B 参数调整 + extend_prediction_through 修正
**目标**：
- `sim/governance.rs` 默认：`soft_position_error: 0.01 → 2.0`，`hard_snap_distance: 32.0 → 256.0`，`max_replay_frames: 24 → 32`
- `world/remote_player.rs`：`INTERPOLATION_DELAY_SECS: 0.15 → 0.1`，`MAX_REMOTE_EXTRAPOLATION_SECS: 0.12 → 0.25`
- `world/local_player.rs::extend_prediction_through`：停止复用 `last_input_frame`，改用 idle（零 input）帧

**Files**: `clients/bevy_client/src/sim/governance.rs`、`clients/bevy_client/src/world/remote_player.rs`、`clients/bevy_client/src/world/local_player.rs`

### US-C 按 ack_seq 恢复对账优雅降级
**目标**：
- `sim/types.rs::PredictedMoveState` 增加 `seq: u32` 字段（或 `history` 侧维护 seq→state 映射）
- `sim/history.rs::PredictedHistory` 新增 `state_at_seq/latest_seq/truncate_after_seq`
- `sim/reconcile.rs`：优先 `ack_seq` 匹配；匹配成功走现有分支；匹配失败且 `ack.correction_flags == 0` 时只做 soft correction（不 HardSnap），只有 `correction_distance ≥ hard_snap_distance` 才硬吸附

**Files**: `clients/bevy_client/src/sim/types.rs`、`clients/bevy_client/src/sim/history.rs`、`clients/bevy_client/src/sim/reconcile.rs`、`clients/bevy_client/src/world/local_player.rs`（传递 seq）、`clients/bevy_client/src/sim/predictor.rs`（保留 seq）

### US-D 验证 headless 烟测
**目标**：
- `cargo check --all-targets` 通过
- `cargo test --lib sim::`、`cargo test --lib world::` 通过
- `scripts/e2e-stdio.ps1` 扩展为：执行 Move→Stop 循环，读 `reconcile_stats` 断言 `hard_snaps == 0`、`max_correction_distance < 16.0`；读 `diag_render` 断言本地渲染与预测位置偏差 < 2.0 units

## Acceptance（Go/No-go）
1. `cargo check --all-targets` 通过
2. `cargo test --lib` 在 bevy_client 全部通过（含更新后的 sim:: 测试）
3. headless 烟测：bevy_client 跑一段 Move→Stop 循环，`reconcile_stats` 输出 `hard_snaps == 0` 且 `replays >= 1`
4. 启用 stdio 的本地演练：连续移动 30 秒，`diag_render` 读出的 `render_drift` 始终 < 2.0
5. `mix compile` 整 umbrella 无新警告（服务器侧无修改，应绿）

## 调试工作流（stdio first，no GUI）
```
# 启动 headless 客户端（已有 --headless 走向）
./target/debug/bevy_client --headless --username smoke_a

# stdio 命令验证
> Move 1.0 0.0
> Move 1.0 0.0
> reconcile_stats
reconcile_stats corrections=4 replays=4 hard_snaps=0 last_corr_dist=0.12
> diag_render
diag_render render_pos=105.3,200.0,100.0 pred_pos=105.4,200.0,100.0 drift=0.1 pending_corr=0.02
> Stop
> reconcile_stats
reconcile_stats corrections=6 replays=5 hard_snaps=0 last_corr_dist=0.04
```
