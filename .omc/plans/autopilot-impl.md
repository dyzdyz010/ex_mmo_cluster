# Implementation Plan: Movement Sync Rework

执行分支：master 直接推进（用户已授权）
参考规范：`.omc/autopilot/spec.md`

## Stage 0 —— PRD 落地 + 基线
- [x] `.omc/autopilot/spec.md` 覆盖更新
- [x] `.omc/plans/autopilot-impl.md` 覆盖更新（本文件）
- [x] `.omc/prd.json` 建立，US-A/B/C/D 含可验证验收标准
- [ ] `cd clients/bevy_client && cargo check` 基线确认当前可编译

## Stage 1 —— US-C 按 ack_seq 重构对账（底层基础）
先做 seq 改造，后续 US-A 的 render drift 计算依赖它。
- [ ] `sim/types.rs`：`PredictedMoveState` 增加 `seq: u32`（idle 时 0）
- [ ] `sim/predictor.rs`：`step()` 让 next.seq = input.seq
- [ ] `sim/history.rs::PredictedHistory`：新增 `state_at_seq(seq)`、`latest_seq()`、`truncate_after_seq(seq)`
- [ ] `sim/reconcile.rs`：主键改 `ack_seq`，fallback 到 `auth_tick`；`state_at_seq/tick` miss 时根据 `correction_distance` 决定 soft/hard，而不是无条件 HardSnap
- [ ] `sim/reconcile.rs` 三个现有 test 更新 + 新增 `reconcile_falls_back_gracefully_when_seq_misses` 测试
- [ ] `world/local_player.rs::build_input_frame` 保证 frame.seq 单调，`apply_local_input` 传 seq 给 predictor

## Stage 2 —— US-B 调参 + extend_prediction_through 修正
独立于 US-C，可并行。
- [ ] `sim/governance.rs::Default`：`soft_position_error=2.0`、`hard_snap_distance=256.0`、`max_replay_frames=32`
- [ ] `world/remote_player.rs` 常量：`INTERPOLATION_DELAY_SECS=0.1`、`MAX_REMOTE_EXTRAPOLATION_SECS=0.25`
- [ ] `world/local_player.rs::extend_prediction_through`：改用 idle `MoveInputFrame`（input_dir=ZERO，movement_flags=BRAKE），避免 stale 方向累积
- [ ] 更新受影响的 test（governance default, remote_player interpolation tests）

## Stage 3 —— US-A Visual Smoothing + stdio 诊断
依赖 Stage 1 的 seq。
- [ ] `world/local_player.rs::LocalPredictionRuntime`：
  - 增加 `pending_correction: Vec3`、`smoothing_rate_hz: f32`（默认 12.0）、`last_render_position: Vec3`
  - 新 API：`apply_correction_offset(delta)`（在 ack 差分时调用）、`render_position(dt_secs) -> Vec3`（exponential decay）
- [ ] `app.rs::LocalRenderPrediction` 改造：
  - 删除 `sync_full_state` 硬贴预测状态的逻辑
  - 只保留"ack 时写 pending_correction"的路径
  - `advance_local_render_prediction` 读取 `local_prediction.render_position(dt)` + 当前预测状态
- [ ] `app.rs::sync_player_visuals`：本地角色路径也走 `smooth_translation`（不再 `target` 直接赋值）
- [ ] `net.rs::LocalPosition` emit：input send 不再发 LocalPosition（或标记 source=Prediction），只在 ack 收到差分时 emit LocalPosition(source=Ack)；避免 10-20Hz 双重触发
- [ ] `stdio.rs`：新增 `ClientStdioCommand::ReconcileStats`、`::DiagRender`；`emit` 输出 `reconcile_stats` 与 `diag_render` 事件，字段：corrections/replays/hard_snaps/last_corr_dist；render_pos/pred_pos/drift/pending_corr

## Stage 4 —— US-D 编译 + 烟测 + 回归
- [ ] `cd clients/bevy_client && cargo check --all-targets`
- [ ] `cd clients/bevy_client && cargo test --lib sim::`
- [ ] `cd clients/bevy_client && cargo test --lib world::`
- [ ] 整 umbrella `mix compile`（服务器侧 sanity）
- [ ] `scripts/e2e-stdio-movement.ps1` 新脚本：headless 启动 → 一串 Move → Stop → 读 reconcile_stats/diag_render → 断言
- [ ] 若 Windows powershell 执行策略失败，提供 `scripts/e2e-stdio-movement.sh` 替代

## Stage 5 —— Code review + deslop + 终验
- [ ] architect agent 按 US-A/B/C/D 验收项逐条核验
- [ ] ai-slop-cleaner 对 ralph 本轮修改的文件做 cleanup pass
- [ ] 再跑一遍 cargo test + 烟测

## 风险与回退
- **pending_correction 收敛率**：12 Hz 是初值，若过慢再调到 18；过快则 UE 风格的"丝滑"会变成"硬"。通过 diag_render 的 drift 实测定。
- **Windows fmt/lint**：Rust 修改只做 cargo fmt 本目录（不破坏 Elixir）。
- **ack_seq 0 的 spawn 帧**：ack_seq=0 作为 spawn sentinel 兼容原行为，reconcile 时 seq=0 走 tick 路径。
- **回退方案**：整轮以一个 commit 推进；若烟测失败且定位困难，`git reset --hard` 到当前 master。
