# Implementation Plan: Unified Movement Sync (2026-04-20 P2, critic-revised)

执行分支：`master` 直接推进（用户已授权，按 Stage 绿灯推进，e2e 全绿后合并）
参考规范：`.omc/autopilot/spec.md`（已应用 critic R1-R7 修订）
起点 commit：`da1c150`

## Cargo 拓扑约束（US-1 之前必须确认）

仓库**没有** root `Cargo.toml` workspace；每个 NIF 是独立 crate：
- `apps/scene_server/native/{coordinate_system,movement_engine,octree,scene_ops}`
- `clients/bevy_client`（Bevy 应用，edition 2024）

所有 NIF 使用 `rustler = "0.37.3"`，crate-type = `["cdylib"]`。

**`movement_core` 设计**：
- 独立 crate 位于 `apps/scene_server/native/movement_core`
- `crate-type = ["rlib"]`（**不是** cdylib；不被 Erlang 直接加载）
- **零外部依赖**，纯 `std` + f64
- 通过 **path dependency** 被 `movement_engine`（NIF）和 `bevy_client` 引用，**不建 workspace**
- 在 Bevy 侧：`movement_core = { path = "../../apps/scene_server/native/movement_core" }`
- 在 NIF 侧：`movement_core = { path = "../movement_core" }`

## 不变量（Determinism Contract）

- 所有 step 运算在 `f64` 域
- `fixed_dt_ms` 精确整数
- 无时钟依赖、无 RNG、无全局状态
- MovementMode 转移由 `MovementMode::transition(prev, &input) -> Self` 在 step 首部决定（本轮始终返回 `Grounded`）
- **Bit-exact 范围**：NIF ↔ `movement_core`（两端 f64）严格；**客户端 ↔ NIF** 允许 f32 量化漂移 ≤ 1e-4
- MovementMode 变体：`Grounded / Airborne / Scripted / Disabled`（保留现有 3 个变体，新增 `Scripted`；零重命名）

---

## Stage 0 —— 基线与 PRD
- [x] `.omc/autopilot/spec.md` (P2 critic-revised) 已落地
- [x] `.omc/plans/autopilot-impl.md`（本文件）
- [x] `.omc/prd.json` (US-1..US-8) 已刷新
- [x] `cd clients/bevy_client && cargo check --all-targets` 基线绿（commit `da1c150` 验证通过）
- [ ] `mix compile` 基线绿（Stage 4 前验证）

---

## Stage 1 —— `movement_core` crate 骨架（US-1）

独立 landing，不改现有代码；先让 crate 本身 build + test。

- [ ] 新建 `apps/scene_server/native/movement_core/Cargo.toml`
  ```toml
  [package]
  name = "movement_core"
  version = "0.1.0"
  edition = "2021"

  [lib]
  name = "movement_core"
  path = "src/lib.rs"
  crate-type = ["rlib"]

  [dependencies]
  # 零依赖。后续需 serde derive 再加（本轮不需）。
  ```
- [ ] `src/lib.rs`：`pub mod profile; pub mod input; pub mod state; pub mod mode; pub mod integrator; pub mod ack;` + 顶层 re-export 公开类型
- [ ] `src/profile.rs`：`MovementProfile { max_speed: f64, max_accel: f64, max_decel: f64, max_jerk: f64, friction: f64, turn_response: f64, fixed_dt_ms: u16, max_speed_scale: f64 }`，`Default` 值见 spec
- [ ] `src/input.rs`：`InputFrame { seq: u32, client_tick: u32, dt_ms: u16, input_dir: [f64;2], speed_scale: f64, movement_flags: u16, movement_mode: MovementMode }`；`braking()` 位检测（`movement_flags & 0b10 != 0`）
- [ ] `src/state.rs`：`MovementState { position: [f64;3], velocity: [f64;3], acceleration: [f64;3], movement_mode: MovementMode, tick: u32, seq: u32 }`；`idle(position)` constructor
- [ ] `src/mode.rs`：
  ```rust
  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub enum MovementMode {
      Grounded,
      Airborne,
      Scripted,
      Disabled,
  }
  impl Default for MovementMode { fn default() -> Self { Self::Grounded } }
  impl MovementMode {
      pub fn transition(prev: Self, _input: &InputFrame) -> Self {
          // 本轮：永远保持 prev（本 round 实际只会出现 Grounded）
          prev
      }
  }
  ```
- [ ] `src/ack.rs`：`MovementAck { ack_seq: u32, auth_tick: u32, position: [f64;3], velocity: [f64;3], acceleration: [f64;3], movement_mode: MovementMode, correction_flags: u32 }`
- [ ] `src/integrator.rs`：stub `pub fn step(state, input, profile) -> MovementState { todo!() }`（Stage 2 填）
- [ ] **命令**：`cd apps/scene_server/native/movement_core && cargo build && cargo test`
- [ ] 单元测试 ≥3：profile default / mode default == Grounded / state idle round-trip

**验收绿灯才进 Stage 2。**

---

## Stage 2 —— 权威积分器 + 4-mode dispatch（US-2）

搬算法，按 mode 分派。

- [ ] 通读 `clients/bevy_client/src/sim/predictor.rs::step`（f32 逻辑）→ 语义复刻到 `movement_core::integrator::step`（f64）
- [ ] `integrator::step(state, input, profile)` 顶部：
  ```rust
  let mode = MovementMode::transition(state.movement_mode, input);
  let mut out = match mode {
      MovementMode::Grounded => grounded_step(state, input, profile),
      MovementMode::Airborne => grounded_step(state, input, profile), // 本轮：复用 grounded
      MovementMode::Scripted => scripted_step(state, input, profile),
      MovementMode::Disabled => disabled_step(state, input, profile),
  };
  out.movement_mode = mode;
  out.tick = input.client_tick;
  out.seq = input.seq;
  out
  ```
- [ ] `grounded_step`：完整移植 jerk-limited kinematics：`velocity_error → accel_limit(current, desired, profile, braking) → clamp_vec3_length(velocity_error / dt, accel_limit) → smooth_acceleration(prev_accel, target, max_jerk, dt) → velocity = clamp(prev_vel + acc*dt, max_speed) → position = prev_pos + velocity*dt`
- [ ] `scripted_step`：原样返回 `MovementState { position: prev.position, velocity: prev.velocity, acceleration: prev.acceleration, .. }`；含 `# Safety` doc comment 警示未来接入 RootMotionSource 时由外部 override
- [ ] `disabled_step`：velocity/acceleration = `[0.0;3]`，position 不变
- [ ] `replay(anchor, inputs, profile) -> Vec<MovementState>`：迭代 step
- [ ] 单元测试 ≥8：
  - grounded 直线加速不过 max_speed
  - grounded braking 逐帧减速（带 MOVEMENT_FLAG_BRAKE）
  - grounded 90° 转向受 turn_response 影响
  - grounded jerk clamp（一步加速 ≤ max_jerk * dt）
  - scripted 一帧 no-op（位置/速度不变）
  - disabled 运动中归零
  - airborne == grounded 的输出
  - replay(anchor, N 帧) 与手动 step N 次等价
- [ ] Golden test：3 条固定输入序列 → 硬编码期望位置/速度/加速度，误差 < 1e-12

**验收命令**：`cd apps/scene_server/native/movement_core && cargo test`

---

## Stage 3 —— Server NIF 切换到 `movement_core`（US-4，**先于客户端**）

> **关键原则（critic R6）**：先让 NIF 走通 core，因为服务端 f64 域 + Elixir 固定结构的测试最确定；如果 core 有 bug，这里比客户端先暴露。

- [ ] `apps/scene_server/native/movement_engine/Cargo.toml`：
  ```toml
  [dependencies]
  rustler = "0.37.3"
  movement_core = { path = "../movement_core" }
  ```
- [ ] `movement_engine/src/atoms.rs`：新增 `scripted` 原子
  ```rust
  rustler::atoms! {
      grounded,
      airborne,
      scripted,
      disabled,
  }
  ```
- [ ] `movement_engine/src/types.rs`：显式 atom ↔ core 枚举转换
  ```rust
  pub fn atom_to_mode(env: Env, atom: Atom) -> movement_core::MovementMode {
      use movement_core::MovementMode::*;
      if atom == crate::atoms::grounded().to_term(env) { Grounded }
      else if atom == crate::atoms::airborne().to_term(env) { Airborne }
      else if atom == crate::atoms::scripted().to_term(env) { Scripted }
      else if atom == crate::atoms::disabled().to_term(env) { Disabled }
      else { Grounded }  // 默认
  }

  pub fn mode_to_atom(mode: movement_core::MovementMode) -> Atom {
      use movement_core::MovementMode::*;
      match mode {
          Grounded => crate::atoms::grounded(),
          Airborne => crate::atoms::airborne(),
          Scripted => crate::atoms::scripted(),
          Disabled => crate::atoms::disabled(),
      }
  }
  ```
- [ ] `movement_engine/src/types.rs`：Rustler `MovementState`/`InputFrame`/`MovementProfile` 保留现有 `#[derive(NifStruct)]`；新增 `From` 桥接
  - `impl From<&types::MovementState> for movement_core::MovementState`（含 `seq=0` 默认，NIF 不感知客户端 seq）
  - `impl From<movement_core::MovementState> for types::MovementState`（**丢弃 seq 字段**——Rustler struct 不含 seq，因此天然不会序列化到 Elixir）
- [ ] `movement_engine/src/integrator.rs`：删算法内核，`step` 改为：
  ```rust
  #[rustler::nif]
  fn step(env: Env, state: MovementState, input: InputFrame, profile: MovementProfile) -> MovementState {
      let core_state: movement_core::MovementState = (&state).into();
      let core_input: movement_core::InputFrame = (&input).into_with_env(env);
      let core_profile: movement_core::MovementProfile = (&profile).into();
      let next = movement_core::integrator::step(&core_state, &core_input, &core_profile);
      next.into()
  }
  ```
  `replay` 同理
- [ ] `apps/scene_server/lib/scene_server/movement/integrator.ex`：顶部 `@moduledoc`：
  ```elixir
  @moduledoc """
  参考实现，非运行时热路径。运行时 step/replay 由
  `SceneServer.Native.MovementEngine` → `movement_core::integrator` 提供。
  本模块保留用于对账测试与算法文档参照。
  """
  ```
- [ ] **命令**（后台跑 NIF 编译，防止 mix 30-60s 阻塞）：
  - 后台：`cd apps/scene_server/native/movement_engine && cargo build`
  - 前台：`mix compile`
  - `cd apps/scene_server && mix test --no-start`
- [ ] Elixir 侧 pattern match 冒烟：确认 `%State{}` 返回的 map 不含 `:seq`（现有测试覆盖）

---

## Stage 4 —— Bevy 客户端切换到 `movement_core`（US-3）

`sim/predictor.rs::step` 变 thin wrapper；Bevy Vec3 (f32) 继续作为存储/渲染类型。

- [ ] `clients/bevy_client/Cargo.toml` 增加：
  ```toml
  movement_core = { path = "../../apps/scene_server/native/movement_core" }
  ```
- [ ] `sim/types.rs::MovementMode`：改为 `pub use movement_core::MovementMode;`（变体名完全一致，现有所有 `MovementMode::Grounded` 调用点零改）
- [ ] `sim/types.rs::PredictedMoveState`：字段保持 Bevy Vec3（f32）；暴露一个 `to_core(&self) -> movement_core::MovementState`、`from_core(core: movement_core::MovementState, seq: u32) -> Self` 辅助函数
- [ ] `sim/profile.rs::MovementProfile`：
  - 字段保持 f32（Bevy 侧视图）
  - 新增 `max_speed_scale: f32 = 1.0`（与 core 对齐）
  - 新增 `pub fn to_core(&self) -> movement_core::MovementProfile`：f32→f64 升精度
- [ ] `sim/predictor.rs::step`：删除 accel_limit / smooth_acceleration / clamp_vec3_length 等内部函数
  ```rust
  pub fn step(previous: &PredictedMoveState, input: &MoveInputFrame, profile: &MovementProfile) -> PredictedMoveState {
      let core_prev = previous.to_core();
      let core_input = input.to_core();
      let core_profile = profile.to_core();
      let next = movement_core::integrator::step(&core_prev, &core_input, &core_profile);
      PredictedMoveState::from_core(next, input.seq)
  }
  ```
  （input.to_core 负责 Vec2→[f64;2]、speed_scale f32→f64、movement_mode 注入默认 Grounded）
- [ ] `sim/{history,reconcile,governance}.rs`：不改 API，仅跟着 PredictedMoveState 结构走（字段保 f32 Vec3，零迁移）
- [ ] 现有测试 `cargo test --lib sim::` 覆盖：`step_builds_velocity_gradually_with_acceleration` 和 `braking_uses_deceleration_limit` 不做断言数值收紧（允许 f32 量化漂移），仅保 inequality 断言
- [ ] 新增测试 `client_step_matches_core_within_budget`：同一 input，client step 与 core f64 step，|Δposition| ≤ 1e-4
- [ ] **命令**：
  - `cd clients/bevy_client && cargo check --all-targets`
  - `cd clients/bevy_client && cargo test --lib`

---

## Stage 5 —— Remote Interpolator 默认值对齐 Valve（US-5）

- [ ] `clients/bevy_client/src/world/remote_player.rs`：
  ```rust
  /// Valve Source Engine Networking (Bernier 2001) 推荐的插值延迟 =
  /// 2 × server tick；本项目 server tick=100ms，因此 0.15s 是抗抖动经典值，
  /// 比 1-tick 缓冲额外提供 ~50ms 的 jitter 吸收。
  pub const INTERPOLATION_DELAY_SECS: f32 = 0.15;

  /// 外推上限 0.25s：远端快照断流后，最多再外推 2.5 个 tick 的运动，
  /// 避免因丢包导致远端冻结。Valve Source cl_extrapolate_amount 默认 0.25。
  pub const MAX_REMOTE_EXTRAPOLATION_SECS: f32 = 0.25;
  ```
- [ ] 检查 `sim::tests` / `world::remote_player` 现有数值断言，若依赖 0.1 则同步更新
- [ ] **命令**：`cargo test --lib world::`

---

## Stage 6 —— 文档 + 参数路标（US-6）

- [ ] `movement_core/src/profile.rs` Default 实现每字段注释（Unreal CMC / Valve / GDC 推荐区间）
- [ ] `docs/2026-04-20-移动同步架构实现.md` 追加 "P2 统一架构" 章节：
  - crate 拓扑图（`movement_core` → `movement_engine` + `bevy_client` 的 path-dep 关系）
  - MovementMode 4 变体状态机说明（当前 Scripted/Disabled 已落地，Airborne 当前复用 Grounded，未来挂跳跃）
  - Bit-exact 契约（NIF↔Elixir 严格 / client↔NIF ≤1e-4 预算）
  - 未动项路标（B 路线 tick 调频、C 路线 max_jerk/max_decel 调参、未来 RootMotionSource）
- [ ] `.omc/progress.txt` 追加 P2 changelog

---

## Stage 7 —— Golden 对账（US-7）

- [ ] `apps/scene_server/test/scene_server/movement/integrator_golden_test.exs`（新建）
  - 构造 3 条固定输入序列（直线 10 帧 / 刹车 5 帧 / 转向 5 帧）
  - 对每条序列分别调 `Integrator.step/3`（Elixir 参考实现）和 `SceneServer.Native.MovementEngine.step/3`（NIF → movement_core）
  - 逐 tick 比较 position/velocity/acceleration，误差 < 1e-9
- [ ] **命令**：`cd apps/scene_server && mix test --no-start test/scene_server/movement/integrator_golden_test.exs`

> 若 Elixir ↔ NIF 出现 > 1e-9 漂移，先排查 Elixir `integrator.ex` 是否与 core 有算子顺序差异（如 fma vs mul+add）；必要时放宽到 1e-7 但在测试内明确标注原因。

---

## Stage 8 —— QA + 线协议兼容性 + e2e 烟测（US-8，critic R7 新增）

- [ ] `cargo build -p movement_core`
- [ ] `cargo test -p movement_core`
- [ ] `cd clients/bevy_client && cargo check --all-targets && cargo test --lib`
- [ ] `mix compile`（后台）
- [ ] `cd apps/scene_server && mix test --no-start`
- [ ] **Wire 兼容性（critic R7）**：`cd apps/gate_server && mix test --no-start`——确认 `GateServer.Codec` 相关测试全绿（opcodes `0x01` / `0x8B` / `0x83` 字节布局未变）
- [ ] **字节长度断言**（附加保险）：在 gate_server 现有 codec_test 中确认 MovementInput 编码后 == 25B、MovementAck == 77B、PlayerMove == 70B；若现有测试未覆盖此三个长度，新增断言
- [ ] e2e：`scripts/start-server.ps1 -Detach` → `scripts/start-client.ps1 -Headless -Stdio` → stdio `Move 1 0` ×5 / `Stop` / `reconcile_stats` / `diag_render`
  - 断言：`hard_snaps == 0`、`max_correction_distance < 16.0`、`drift < 2.0`
- [ ] QA 失败时返回对应 Stage 修复；同错 3 轮则停报

---

## Stage 9 —— Review + deslop + final commit

- [ ] `oh-my-claudecode:architect` agent：按 US-1..US-8 验收点逐条核验
- [ ] `oh-my-claudecode:code-reviewer`：代码质量 / SOLID / 命名
- [ ] `oh-my-claudecode:security-reviewer`：wire 字节布局未变 / NIF panic 边界 / Elixir pattern match safety
- [ ] `/oh-my-claudecode:ai-slop-cleaner`（scope = 本轮改动文件列表）
- [ ] 再跑一遍 `cargo test` + `mix test` + e2e
- [ ] `git commit`（按 Stage 1-2 / 3-4 / 5-8 分组，或单 commit 合并，按实际 diff 体量定）
- [ ] `/oh-my-claudecode:cancel`

---

## 风险登记（critic 指认 + 新增）

| # | 风险 | 触发 | 缓解 |
|---|------|------|------|
| R1 | Path-dep 解析失败 | Windows 路径 / symlink | 用相对 `../../apps/...`；CI 覆盖 |
| R2 | Rustler struct 与 core struct 不同名导致 marshalling 混乱 | Stage 3 | 保留 Rustler `types.rs` 定义，通过 `From/Into` 桥接；不让 Rustler 直接见 core |
| R3 | Bevy f32 ↔ core f64 round-trip 精度丢失 | Stage 4 | Core 始终权威；client 每次 step 前后做 cast；预算 ≤1e-4 由新 test 守护 |
| R4 | Elixir Integrator.ex ↔ core 1 ULP 漂移 | Stage 7 | 当前算法无超越函数（只有 clamp/mul/add），风险低；若触发放宽到 1e-7 并标注 |
| R5 | NIF 重编译阻塞 mix | Stage 3 | 后台跑 cargo build，前台跑别的 Stage |
| R6 | `seq` 字段泄漏到 Elixir 结构 | Stage 3 | Rustler `MovementState` struct 不含 seq；From core 时天然丢弃 |
| R7 | Atom 比较 panic | Stage 3 | atoms.rs 新增 `scripted`，mode_to_atom 覆盖全 4 variant；atom_to_mode 含默认 |
| R8 | 线协议字节布局意外变动 | Stage 3 | Stage 8 gate_server codec_test 绿灯 |
| R9 | Stage 顺序误解（client 先） | planning 读错 | 本 plan 明确 Stage 3 = NIF，Stage 4 = client |
| R10 | `Scripted` stub 被未来 dev 误用 | future | stub 含 `# Safety` doc warning |

## 回退方案

- Stage 1-2 独立：失败丢 core 新文件，无影响
- Stage 3 失败：revert `apps/scene_server/native/movement_engine/`；client 未开始
- Stage 4 失败：revert `clients/bevy_client/`；NIF 已切完，双源暂存 1-2 commit 可接受
- 终极回退：`git reset --hard da1c150`（本轮起点）

## 非本轮强调

B 路线（tick 调频）、C 路线（手感调参）、跳跃 / 位移技能、RootMotion、UE5 迁移均明确推迟；本轮仅做"算法单源 + 状态机骨架 + 线协议零改"。
