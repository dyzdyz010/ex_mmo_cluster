# 2026-04-13 移动同步 vNext 阶段二：Rustler 计算核心

## 本轮目标

把服务端移动积分的纯算法核心下沉到 Rustler，使 `SceneServer` 的权威运动主路径开始真正使用 Rust 计算，而不是只停留在蓝图层。

## 本轮完成

### 1. 新增 Rustler movement_engine

新增：

- `apps/scene_server/lib/scene_server/native/movement_engine.ex`
- `apps/scene_server/native/movement_engine/`

其中 Rust crate 被拆成了：

- `src/lib.rs`
- `src/types.rs`
- `src/math.rs`
- `src/integrator.rs`
- `src/atoms.rs`

这样不会把 NIF 实现塞进一个超大文件。

### 2. Rustler 已实现的能力

当前 NIF 提供：

- `step(state, input_frame, profile)`
- `replay(anchor_state, input_frames, profile)`

并且直接对接：

- `SceneServer.Movement.State`
- `SceneServer.Movement.InputFrame`
- `SceneServer.Movement.Profile`

### 3. SceneServer.Movement.Engine 已切到 Rustler 主路径

`SceneServer.Movement.Engine.step/4` 现在直接调用：

- `SceneServer.Native.MovementEngine.step/3`

`SceneServer.Movement.Engine.replay/3` 也已提供统一门面。

这意味着：

- 运行时权威 movement 不再只是 Elixir integrator
- Elixir `Integrator` 现在主要承担：
  - 参考实现
  - 行为对照测试

### 4. 对照验证已补齐

`apps/scene_server/test/scene_server/movement/integrator_test.exs` 新增：

- native step 与 Elixir integrator 结果一致测试
- native replay 与逐帧 Elixir 积分结果一致测试

## 当前架构意义

这一轮完成后：

- **协议层** 已进入 vNext
- **运行时主路径** 已进入 vNext
- **服务端计算核心** 也开始进入 Rustler

也就是说，现在不是只有“Rust 更适合做计算密集型任务”的设计结论，而是已经真正落地到了服务端权威 movement 上。

## 已验证

- `cargo test`
- `mix test`
- `powershell -ExecutionPolicy Bypass -File .\\scripts\\e2e-stdio.ps1 -ObserveDir .demo/e2e-vnext-stage2-rustler`

## 仍建议的下一步

下一阶段最值得继续推进的是：

1. **更完整的 rollback / replay 窗口治理**
2. **远端 snapshot buffer + 插值窗口**
3. **camera / animation 更彻底绑定 presentation state**
4. **Rustler 与客户端 profile 参数对齐治理**
