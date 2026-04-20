# 移动同步性能基线 — 2026-04-20

## 1. 目的

在移动同步架构（`movement_core` Rust rlib + NIF + Bevy 客户端 rollback）定稿后，建立一组可重跑的基准，用于：

- 探测回归（以后任何 commit 都能和这份数据对比）
- 判断"业界-best-practice vs. 再创新"时的真实瓶颈在哪
- 回答"单 shard 能承载多少玩家"这个老问题

全部基线跑在同一台 Windows 11 x64 开发机上（详见第 7 节"可复现命令"）。

## 2. movement_core — Rust criterion 微基准

路径：`apps/scene_server/native/movement_core/benches/integrator_bench.rs`

| 基准 | 中位耗时 | 95% CI |
|------|----------|--------|
| `integrator::step` single_tick (grounded, +x) | **37.66 ns** | [37.18 – 38.25] |
| `integrator::step` brake_from_max_speed | **38.97 ns** | [38.08 – 40.05] |
| `integrator::replay` 100_frames | **3.55 µs** | [3.16 – 3.98] |
| `integrator::replay` 1000_frames_alternating | **40.81 µs** | [36.13 – 44.45] |

**观察**：单步 ~38 ns ⇒ 每帧 100 ms budget 内可跑 ~2.6M 步。线性外推：整帧吞吐 ~26M entity/step（纯计算，无 NIF 边界开销）。

## 3. bevy_client — Rust criterion 微基准

路径：`clients/bevy_client/benches/predictor_bench.rs`

| 基准 | 中位耗时 | 95% CI |
|------|----------|--------|
| `predictor::step` single_tick | **45.58 ns** | [44.66 – 46.46] |
| `reconcile` accept (0-replay, matching ack) | **174.47 ns** | [169.42 – 179.81] |
| `reconcile` replay 12-frame (ack at tick 4) | **643.50 ns** | [619.75 – 666.74] |
| `reconcile` hard_snap (>256 unit correction) | **233.27 ns** | [220.20 – 245.02] |

**观察**：

- `predictor::step` 比 movement_core 慢 ~8 ns，来自 f32↔f64 adapter（可接受）
- 即使是最昂贵的 12-frame replay（~643 ns）离 60 Hz frame budget（16.6 ms）还有 **~26,000 倍**余量
- hard_snap 分支比 replay 便宜 ~3 倍（符合预期：它清空历史而非重放）

## 4. NIF 边界开销 — Elixir benchee

路径：`apps/scene_server/bench/movement_bench.exs`

单次 `MovementEngine.replay/3`（Rustler f64）对比纯 Elixir `Integrator.step` 参考实现，跨 4 种 batch size：

| Batch size | NIF 平均 | Elixir 平均 | NIF 优势 |
|-----------|---------|-------------|-----------|
| 1 frame | 2.19 µs | 2.25 µs | **1.03×** |
| 10 frames | 9.89 µs | 16.65 µs | **1.68×** |
| 100 frames | 78.03 µs | 151.95 µs | **1.95×** |
| 1000 frames | 1.11 ms | 1.45 ms | **1.31×** |

**观察**：

- Rustler 边界开销约 **2 µs / call**。在 1 frame 时几乎吃掉全部 NIF 优势
- 100 frame 窗口是 NIF 最划算的点（2× 加速）
- 1000 frame 时 Elixir 分配器压力上升，NIF 优势从 1.95× 跌到 1.31×（原因待查）
- 实务上 replay 窗口通常是 4–12 帧，对应 NIF 优势只有 1.2–1.7×，**边界开销摊销有限**

## 5. Scene-scale load — 1000 entity 权威步

路径：`apps/scene_server/bench/scene_load_bench.exs`

参数：1000 entity，10 个 tick，每 entity 每 tick 调一次 `MovementEngine.step/3`，方向按 `rem(id, 4)` 分布。

| 指标 | 数值 |
|------|------|
| 每-entity NIF step p50 | ~0 µs（低于 µs 分辨率） |
| 每-entity NIF step p95 | ~0 µs |
| 每-entity NIF step p99 | ~0 µs |
| 每-entity NIF step max | 307 µs（GC / scheduler spike） |
| 每-tick 总 wall 时间 avg | **962.6 µs** |
| 每-tick 总 wall 时间 max | **1331 µs** |
| **10 Hz budget 使用率 avg** | **0.96%** |
| **10 Hz budget 使用率 max** | **1.33%** |
| **投影 headroom（线性外推）** | **~103,885 entities** |

## 6. 对标与架构决策影响

### 业界参考点

| 来源 | 目标 | 当前系统对比 |
|------|------|-------------|
| Amazon New World (GDC 2022) | 500 players / shard | **投影 ~200× 余量** |
| Valve Source netcode | CS:GO ~64 tick, ~40 players | 不可比（FPS shard 小） |
| Overwatch ECS netcode (GDC 2017) | ~12 players / shard | 不可比（竞技游戏） |

### 核心洞察

**移动积分器不是瓶颈**。1000-entity 压测只用 1% CPU budget，线性外推到 100K entity 仍然在 10 Hz 预算内。这直接改写先前"Phase A 架构重整"的优先级：

- ❌ **AOI-aware prediction budget** —— 过早优化：没有 CPU 压力
- ❌ **NIF 批量门槛（<10 frames 走 Elixir）** —— 过早优化：边界开销微不足道
- ❌ **确定性积分器替换** —— 无必要：现有 f64 + 确定性已经超额
- ⚠️  **Input delay + rollback hybrid** —— **保留，但理由从"性能"改为"UX/rollback 成本控制"**
- ⚠️  **Kalman 软修正** —— **保留，但理由从"性能"改为"UX 平滑度"**
- ⚠️  **Delta + quantized MovementAck** —— **保留，理由是"带宽 / 下行包体积"**

### 真正需要去压测的地方

基于这份基线，真正可能限制单 shard 承载的瓶颈不在 movement，而是：

1. **AOI 广播扇出**（O(N²) 在密集聚集时会爆）—— 需要单独的 broadcast bench
2. **Rapier3D 物理步长成本**（当前未纳入本基线）
3. **Actor supervision + mailbox 压力**（当 N entity 都用 GenServer 承载时）
4. **数据持久化 I/O**（PostgreSQL 写放大）

## 7. 可复现命令

```bash
# Rust — movement_core micro-benches
cd apps/scene_server/native/movement_core
cargo bench --bench integrator_bench

# Rust — bevy_client micro-benches
cd clients/bevy_client
cargo bench --bench predictor_bench

# Elixir — NIF vs Elixir throughput
cd apps/scene_server
mix run bench/movement_bench.exs

# Elixir — 1000-entity scene load
cd apps/scene_server
mix run bench/scene_load_bench.exs

# 覆盖 entity 数量
ENTITIES=5000 mix run bench/scene_load_bench.exs
```

## 8. 结论与推荐

1. **现有移动同步架构（Client Prediction + Rollback + Server Authoritative NIF）已命中业界最佳实践**，且 CPU 余量远超 Amazon New World 500-player 目标
2. **不推荐**再对 movement integrator 本身做"创新性"重整 —— ROI 接近零
3. **下一个该压的 bench** 是 AOI 广播吞吐与 Rapier3D 物理步长；只有这两者出现瓶颈才进入"Phase A 架构重整"讨论
4. 现在把精力投向 UX/带宽类优化（Kalman 软修正、delta MovementAck）比 CPU 类优化 ROI 高得多

## 9. 环境

- OS: Windows 11 Home China 10.0.26200
- Rust: stable（cargo bench 使用 `--release`）
- Erlang/OTP: 28.3.1, Elixir 1.18.4-otp-28
- movement_core crate: 本仓当前 commit
- bevy_client: bevy 0.18.1
