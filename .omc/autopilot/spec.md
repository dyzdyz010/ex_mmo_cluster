# Spec: Unified Movement Sync Architecture (2026-04-20 P2)

> **本轮定位（架构统一）**
>
> 上一轮 autopilot 已经完成：seq-first reconcile、128 帧 history、ack_seq 优雅降级、pending_correction 指数衰减、stdio 诊断。
> 本轮目标是把现有"能跑起来"的移动同步，**统一**为 MMO 业界标准的"单一真相源 + 状态机 + bit-exact 可回放"架构。
>
> 非本轮：tick 频率调整（原 100ms 保留）、手感参数再调（max_jerk/max_decel 保留 GDC/Unreal 默认的注释参考值）。

## Goal

把客户端 Rust 预测器、服务端 Rust NIF 积分器、服务端 Elixir 参考积分器这三份**平行实现**，统一为**单一 Rust crate 作为真相源**；同时把已有的 `MovementMode` enum 升级为真正的状态机（至少保留 Walking / Scripted / Disabled 三个挂载槽位），为后续跳跃、位移技能、坐骑提供零改核心的扩展点。

参考模型：**Unreal `CharacterMovementComponent` + Valve Source `cl_interp_ratio` + Bernier 2001 *Latency Compensating Methods in Client/Server In-game Protocol Design*。**
这是 WoW / FFXIV / New World / ESO / Lost Ark 公开资料中反复出现的组合。

## Non-goals（本轮明确不做）

- **不改线协议 opcode**：`0x01` MovementInput（25B）、`0x8B` MovementAck（77B）、`0x83` PlayerMove（70B）字段顺序与大小不动。本轮只在已保留字段（如 `movement_mode: u8`、`correction_flags: u32`）里定义语义，不新增字节。
- **不改 tick 频率**：服务端 100ms tick、客户端 10Hz 上报保留，后续 B 路线再降频。
- **不调手感参数**：`MovementProfile` 默认值保留（`max_speed=220, max_accel=1200, max_decel=1400, max_jerk=9000`），但新增**来源注释**标注 Unreal CMC / Valve / GDC 对应的"MMO 推荐区间"作为 C 路线的路标。
- **不加跳跃/位移技能代码**：本轮只预留 `MovementMode::Scripted` 枚举值 + 一个不接管逻辑的 stub，不做 Falling 重力、不做 RootMotionSource。
- **不改 rapier3d 物理**：`scene_ops` 的物理积分路径与本轮解耦；本次重构只动运动学 kinematics。

## 当前架构摘要（Explore 结论，2026-04-20 基线）

| 组件 | 现状 | 单一源？ |
|------|------|----------|
| Client predictor | `clients/bevy_client/src/sim/predictor.rs::step` Rust | 否（和 NIF 独立实现） |
| Server NIF integrator | `apps/scene_server/native/movement_engine/src/integrator.rs::step` Rust | 否 |
| Server Elixir integrator | `apps/scene_server/lib/scene_server/movement/integrator.ex::step` | 仅作"参考对账"用途，不是热路径 |
| Profile | 三处独立定义，手工同步 | 否 |
| InputFrame | Client Rust / Elixir / Rust NIF 三处 struct | 否 |
| MovementState | 三处 | 否 |
| MovementMode enum | 已存在（Grounded/Airborne/Disabled），但 step 永远返回 Grounded | 形同虚设 |
| Seq / Tick 双命名空间 | 已在 wire 上（InputFrame 带 seq+client_tick，Ack 带 ack_seq+auth_tick） | 已 OK |
| History ring | Input 128 / State 256 | 已 OK |
| Reconcile | seq-first + tick fallback + soft/hard 阈值 | 已 OK |
| Visual smoothing | pending_correction 指数衰减 + render hard snap | 已 OK |
| Remote interp | 延迟 100ms，外推上限 250ms | 轻微偏离 Valve 默认（150ms） |

**核心痛点**：三份平行 Rust/Elixir 实现。任何一处 step 算法调整，必须手工在另外两处同步，否则 replay 会漂移（当前靠纪律维持，不是架构保证）。

## 统一架构（目标态）

```
apps/scene_server/native/movement_core/        ← 新建：单一真相 Rust crate
  Cargo.toml                                    ← 无任何外部依赖（除 nalgebra/glam）
  src/lib.rs                                    ← 公开 API
  src/profile.rs                                ← MovementProfile（f64 全量）
  src/input.rs                                  ← InputFrame { seq, client_tick, dt_ms, input_dir, speed_scale, movement_flags, movement_mode }
  src/state.rs                                  ← MovementState { position, velocity, acceleration, movement_mode, tick, seq }
  src/mode.rs                                   ← MovementMode state machine（Walking / Scripted / Disabled + transition API）
  src/integrator.rs                             ← step / replay（唯一权威实现）
  src/ack.rs                                    ← MovementAck struct（客户端可复用反序列化）

clients/bevy_client/Cargo.toml
  [dependencies]
  movement_core = { path = "../../apps/scene_server/native/movement_core" }

apps/scene_server/native/movement_engine/Cargo.toml
  [dependencies]
  movement_core = { path = "../movement_core" }
  rustler = ...
  # integrator.rs 改成极薄的 NIF 壳，内部调用 movement_core::step
  # types.rs 保留 Rustler 序列化，但底层数值结构引用 movement_core 的类型

apps/scene_server/lib/scene_server/movement/integrator.ex
  → 保留为参考实现 + 测试锚点；热路径统一走 NIF
  → 加注释：「此实现仅供对账/文档用途，运行时等价于 movement_core::step」
```

**关键不变量（Determinism Contract）**：
- 所有浮点统一 `f64`
- `fixed_dt_ms` 精确整数（100）
- `MovementProfile` 两端完全同值（通过共享 crate 自动保证）
- step 输入 `(MovementState, InputFrame, MovementProfile)` 确定性产生唯一输出（无时钟依赖、无 RNG）
- MovementMode 转移作为 step 的一部分（而不是外部注入），保证 replay 时 mode 轨迹一致

## User Stories（验收锚点）

### US-1 `movement_core` crate 骨架 + profile/input/state 统一
**目标**：新建 `apps/scene_server/native/movement_core` Rust crate（**独立 crate，不建 workspace，通过 path-dep 被下游引用**），把 `MovementProfile`、`InputFrame`、`MovementState`、`MovementMode` 这四个数据结构提取为 crate 内唯一定义。

> **关键设计决策（回应 critic R1 + R2）**：
> - 仓库没有 root `Cargo.toml` workspace，每个 NIF 是独立 crate。movement_core 延续这一约定：**独立 crate，crate-type = `["rlib"]`，零外部依赖**。下游（`movement_engine` / `bevy_client`）通过 `path = "..."` 引入。
> - **MovementMode 枚举保留现有 3 个变体 `Grounded/Airborne/Disabled`**，**新增第 4 个变体 `Scripted`** 为位移技能预留挂载点。不做任何重命名。Default = `Grounded`。
> - **f64 权威**：core 内部全用 `f64`。NIF 本就是 f64，无损。**客户端 Bevy 侧保持 f32 Vec3 作为存储 / 渲染类型**，predictor 包 f32↔f64 转换后调 core。客户端 ↔ NIF 数值不要求严格 bit-exact，**f32 量化预算 ≤ 1e-4**（现有 soft=2.0 / hard=256.0 阈值高出 6 个数量级）。

**验收**：
- `cargo build -p movement_core` 退出码 0
- `movement_core/Cargo.toml` 不声明 `[workspace]`，`crate-type = ["rlib"]`
- `MovementProfile::default()`：220 / 1200 / 1400 / 9000 / 0 / 1.0 / 100ms / `max_speed_scale=1.0`
- `MovementMode` 枚举含 `Grounded/Airborne/Scripted/Disabled`；`Default::default() == Grounded`
- 单元测试 ≥3：profile default、mode default、state idle round-trip

**Files**：
- 新建 `apps/scene_server/native/movement_core/{Cargo.toml,src/*.rs}`
- **不**修改任何根配置（无 workspace）

### US-2 `movement_core::step` 权威积分器 + MovementMode 状态机骨架
**目标**：把现有 `predictor.rs::step` 的 jerk-limited 积分算法完整迁入 `movement_core::integrator::step`，并按已有 `MovementMode::{Grounded, Airborne, Scripted, Disabled}` 分派：

- `Grounded`：现有 jerk-limited kinematics（本轮唯一实际走代码的 mode；对应当前所有运行时行为）
- `Airborne`：**暂时复用 grounded_step 的实现**（当前服务端/客户端永远返回 Grounded；Airborne 预留给未来跳跃/下落，本轮不加重力）
- `Scripted`：stub no-op（保留 state.position/velocity/acceleration 不变，只推进 tick/seq）。⚠️ 含 `# Safety` doc comment 说明：未来接入 RootMotionSource 后，此分支将由外部覆盖状态，不要依赖 velocity 传递
- `Disabled`：velocity/acceleration 归零，position 不变

`step` 内部按 `state.movement_mode` 分派；mode transition 由 `MovementMode::transition(prev, &input) -> Self` 在 step 开头决定（本轮始终返回 `Grounded`，保持与现行为等价）。

**验收**：
- `cargo test -p movement_core` 含 ≥8 个 case（grounded accel、grounded brake、grounded turn、grounded jerk-clamp、scripted no-op、disabled zero-out、airborne==grounded、replay multi-step golden）
- **Bit-exact 的严格范围**：core `step` 与 `apps/scene_server/native/movement_engine/src/integrator.rs::step`（当前实现）**逐字等价**（都是 f64 域）。与 `clients/bevy_client/src/sim/predictor.rs::step`（f32 域）**不要求严格 bit-exact**，允许 ≤ 1e-4 量化漂移。
- golden test 输入输出硬编码若干固定轨迹（直线 10 帧 / 刹车 5 帧 / 转向 5 帧），位置/速度/加速度误差 < 1e-12

**Files**：`apps/scene_server/native/movement_core/src/{integrator.rs,mode.rs}`

### US-3 Client Bevy 切换到 `movement_core`（服务端 NIF 切换之后执行）
**目标**：把 `clients/bevy_client` 的 step 权威路径改为引用 `movement_core::step`。**客户端继续使用 Bevy 原生 `Vec3(f32)` 作为存储 / 渲染类型**；只在 `sim/predictor.rs::step` 入口做 f32 → f64 转换，调用 core，出口再 f64 → f32 转换。

> **为什么不把客户端也改 f64**：Bevy 生态全 f32（Transform / Camera / 物理），牵动整个渲染管线。f64 化留作后续独立工作。本轮只统一算法，不统一精度。

> **为什么先 NIF 后客户端**（回应 critic R6）：NIF 侧是 f64 域、测试确定性高；先把 core 接入 NIF，golden test 过了再接入客户端，能更早暴露 core 内部 bug。

**验收**：
- `clients/bevy_client/Cargo.toml` 引用 `movement_core = { path = "../../apps/scene_server/native/movement_core" }`
- `sim/predictor.rs::step` 删除内部算法，改为 thin wrapper：Vec3(f32) → [f64;3] → `movement_core::step` → [f64;3] → Vec3(f32)
- `sim/types.rs::MovementMode` 改为 `pub use movement_core::MovementMode;`（变体名不变：`Grounded/Airborne/Scripted/Disabled`）
- `sim/types.rs::PredictedMoveState` 字段保持 Bevy Vec3（f32），内部调用路径走 core；或作 newtype 包住 core 类型（按调用点改动成本选）
- `sim/profile.rs::MovementProfile` 保持 f32 字段（作为 Bevy 侧的"客户端视图"），同时提供 `fn to_core(&self) -> movement_core::MovementProfile` 做 f32→f64 升精度；core 侧的 `max_speed_scale` 在 client profile 缺失时默认 1.0
- 客户端 `cargo check --all-targets` 退出码 0
- `cargo test --lib sim::` 全部通过（旧测试对等价 API 迁移）
- e2e：`scripts/e2e-stdio-movement.ps1` 跑通，`reconcile_stats.hard_snaps == 0`，`max_correction_distance < 16.0`
- 客户端 ↔ NIF step 结果量化漂移 ≤ 1e-4（由一个新增对账测试验证）

**Files**：
- `clients/bevy_client/Cargo.toml`
- `clients/bevy_client/src/sim/{predictor.rs,types.rs,profile.rs}`
- `clients/bevy_client/src/world/local_player.rs`（调用点）
- `clients/bevy_client/src/sim/{history,reconcile,governance}.rs`（如 PredictedMoveState 字段路径变更）

### US-4 Server NIF 切换到 `movement_core`（先于 US-3 执行）
**目标**：让 `apps/scene_server/native/movement_engine` 依赖 `movement_core`；NIF 函数 `step`/`replay` 变成极薄的 Rustler 适配层（反序列化 → 调 `movement_core::step` → 序列化回 Elixir term）；删除 `movement_engine/src/integrator.rs` 的算法内核。

> **关键适配细节（回应 critic R3 + R5）**：
> - **Atom ↔ MovementMode 转换**：不能用 `From` trait 通用实现。要在 `movement_engine/src/types.rs` 写显式函数 `fn atom_to_mode(env: Env, atom: Atom) -> MovementMode`，内部 `if atom == atoms::grounded() { Grounded } else if atom == atoms::airborne() { Airborne } else ...`。反向 `fn mode_to_atom(mode: MovementMode) -> Atom` 同理。
> - **`atoms.rs` 更新**：已有 `grounded/airborne/disabled` 三个原子，**新增 `scripted` 原子** 以匹配 core 的第 4 个变体。
> - **`seq` 字段剥离**：`movement_core::MovementState` 含 `seq: u32`，但 Elixir `%State{}` 结构体不含 seq（`state.ex:10-11` 固定键集 `[:position, :velocity, :acceleration, :movement_mode, :tick]`）。NIF shim 在构造 Elixir term 时**显式丢弃 seq**（返回 Elixir 的 state map 不含该 key），Elixir 侧无需改动。`seq` 保留在 Rust 层作为 core 内部状态。
> - **`max_speed_scale`**：Rustler `MovementProfile` struct（types.rs:37）已有该字段，core 保持同名同语义；两端零改。

**验收**：
- `cd apps/scene_server/native/movement_engine && cargo build` 退出码 0
- 根目录 `mix compile` 退出码 0
- `cd apps/scene_server && mix test --no-start` 现有 movement 测试全绿
- NIF `step` 调用链：Elixir Engine.step → Rustler NIF → `movement_core::integrator::step`
- Elixir 模块 `SceneServer.Movement.Integrator` 顶部 `@moduledoc` 标注「参考实现，非运行时热路径；运行时走 `SceneServer.Native.MovementEngine.step`」
- Elixir %State{} 返回的 map **不包含 seq 字段**（通过现有 pattern match 测试验证）

**Files**：
- `apps/scene_server/native/movement_engine/Cargo.toml`
- `apps/scene_server/native/movement_engine/src/{integrator.rs,types.rs,atoms.rs,lib.rs}`
- `apps/scene_server/lib/scene_server/movement/integrator.ex`（@moduledoc 注释）

### US-5 Remote Interpolator：Valve 默认延迟（保守对齐）
**目标**：把 `world/remote_player.rs` 的 `INTERPOLATION_DELAY_SECS` 从 `0.1` 调到 `0.15`（Valve Source 2001 默认，业界抗抖动经典值）；外推上限从 `0.25` 保留；加头注释说明两个数字的出处。

**验收**：
- `INTERPOLATION_DELAY_SECS == 0.15`
- `MAX_REMOTE_EXTRAPOLATION_SECS == 0.25`
- 头注释引用 "Valve Source Engine Networking" 或 Bernier 2001
- 已有远端插值测试更新（如果对数值敏感）

**Files**：`clients/bevy_client/src/world/remote_player.rs`

### US-6 文档 + 参数路标注释
**目标**：
- 在 `MovementProfile` 当前默认值旁加注释，标注 Unreal CMC / Valve 的推荐区间，作为 C 路线调参时的路标：
  ```rust
  // max_speed: 220.0           // MMO 步行 180-250u/s（WoW ~220，FFXIV ~300）
  // max_accel: 1200.0          // Unreal CMC 默认 2048；MMO 更保守
  // max_decel: 1400.0          // 推荐 3000+ 以消除 "滑行感"（C 路线）
  // max_jerk: 9_000.0          // 推荐 30_000+ 近乎取消 jerk（C 路线）
  ```
- 在 `docs/2026-04-20-移动同步架构实现.md` 追加章节：「2026-04-20 P2 统一架构」描述 crate 结构 + state machine + bit-exact 契约
- `.omc/progress.txt` 追加本轮重构的一段 changelog

**验收**：三处文档都有实质性更新，单元测试 / e2e 不因此失败

**Files**：`clients/bevy_client/src/sim/profile.rs`、`apps/scene_server/native/movement_core/src/profile.rs`、`docs/2026-04-20-移动同步架构实现.md`、`.omc/progress.txt`

## Acceptance（Go/No-go）

必须全部绿才能结束本轮：
1. `cargo build -p movement_core`（新 crate 成功构建）
2. `cargo test -p movement_core`（crate 内单元测试全绿，含 ≥5 step case + golden test）
3. `cd clients/bevy_client && cargo check --all-targets && cargo test --lib`（客户端绿）
4. `mix compile`（整个 umbrella 绿）
5. `cd apps/scene_server && mix test --no-start`（服务端现有测试绿）
6. `scripts/e2e-stdio-movement.ps1`（或 .sh）执行成功，`reconcile_stats.hard_snaps == 0`，`max_correction_distance < 16.0`
7. 三语言 step 结果一致性 golden test 通过（core 输出 vs 旧 Elixir integrator 输出，≥3 条轨迹）

## 测试策略

**单元**：
- `movement_core`：step 的数值 golden test（固定 seed 轨迹，期望值硬编码）
- `movement_core`：mode dispatch（Walking/Scripted/Disabled 各一条）
- 客户端 `sim::reconcile` 的现有回归测试（对 API 迁移后等价）

**集成**：
- 客户端 headless stdio e2e（已有 scripts/e2e-stdio-movement）
- Elixir 侧 `Engine.step` 与新 NIF 的等价性测试（同 input → 同 output）

**Golden**：
- 三条固定输入序列（直线、刹车、转向）在 `movement_core` 下的输出 vs 现 `integrator.ex` 输出，位置/速度/加速度逐 tick 比较，精度 1e-9

## 风险 & 回退

| 风险 | 预防 | 回退 |
|------|------|------|
| Cargo workspace 配置冲突（两个 NIF crate + 一个共享 crate） | US-1 单独 landing，独立跑 `cargo build -p movement_core` 验证 | 共享 crate 作 path dep 单独挂，不强行合 workspace |
| Rustler 序列化语义差异（共享 crate 不依赖 rustler，types 通过 wrapper 桥接） | 在 movement_engine 侧用 newtype + From/Into 桥接 | 保留现有 `types.rs` 序列化层，core 只做计算 |
| 服务端 NIF binary 重编译导致 `mix compile` 长时间挂起 | `run_in_background: true` 跑编译，另起 QA | 必要时回滚 NIF 改动，仅留 crate 骨架 |
| 客户端 Bevy Vec3（f32） vs core f64 类型不一致 | 入口/出口做 explicit cast，保持 core 内 f64 权威 | 客户端仍用 glue 层，不暴露 f32 到 core 内部 |
| 三语言对账 golden 失败 | 先让 Elixir `integrator.ex` 保留，作为 golden 来源 | 如 core 与 integrator.ex 出现 1 ULP 偏差，接受阈值 1e-9 |

## 调试工作流

```
# 基线
cargo build -p movement_core
cargo test -p movement_core

# 客户端
cd clients/bevy_client && cargo check --all-targets && cargo test --lib

# 服务端
mix compile
cd apps/scene_server && mix test --no-start

# e2e
.\scripts\start-server.ps1 -Detach    # 后台启 server
.\scripts\start-client.ps1 -Headless -Stdio
# stdio: Move 1 0 / Stop / reconcile_stats / diag_render

# 三语言对账 golden
# movement_core cargo test 含嵌入式 golden 轨迹
```

## 后续路线（本轮不做）

- **B 路线**（tick 调频）：server 100ms → 33ms、client predict 100ms → 16ms，带 input 降频补偿
- **C 路线**（手感调参）：`max_jerk` 30_000+、`max_decel` 3000-5000，让刹车从 350ms 降到 50ms 内
- **P5+**：在 `MovementMode::Scripted` 上挂 RootMotionSource 式位移技能（闪现、冲锋、拉拽）
- **Jump/Fall**：新增 `MovementMode::Airborne`（已在 enum 中预留），加重力积分
- **PVP 防作弊**：服务端 step 前的速度/位移带宽检查（当前 `correction_flags` 已预留 u32）
