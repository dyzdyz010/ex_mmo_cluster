# NPC 运行时

分类：全局系统功能。统一输入与记忆规范见
[模型上下文契约](../../../../../docs/10-active/cross-cutting/2026-09-22-npc-context-memory-contract.md)。

- `Body` 接正式 Session/Player，产生观察并把动作交给 authority。
- `Runtime` 组合任意 Brain，统一命令路由、记忆调用、技能 worker、中断、停止确认与终态记录。
- `Context` 从权威 profile 派生身体说明；`Perception` 复用父脑和设计会话的感知范围、schema 与 World 查询。
- `Brain.Llm` 组合当前观察、近期结果和逐轮检索记忆，只负责模型决策及 Responses 适配。
- `Skills.Design` 维护本次草稿/Responses 历史，可自行观察、读写记忆、检查和发布；World 放置交给父脑的 build。
- `Memory` 提供模型记忆工具与上下文投影；`DataService.NpcMemory` 按永久 cid 持久化和检索。
- `Skill` 定义 `definition/1` 与 `run/3`，`Skills` 按 profile 注册；内置 Build / Design / Wilderness 都实现它。
- `Scheduler` 定义 `decide/2`，Jev 为现有适配；分类器不能操作世界。荒野技能仍复用 Builder 状态机。
- `Http` 提供共享 JSON 出站；`Perception.project/3` 提供共享模型感知投影，技能不反向依赖 Llm。

新对话式决策入口必须遵守上下文契约。旧 Builder 的一次性蓝图规划接口本轮未改成自主多轮工具会话。
测试入口在 `apps/gate_server/test/gate_server/npc_*`；真实模型用例必须显式选择 `live_llm`。

## 2026-10-06 共用运行层增量

用户批准方向：功能模块通过稳定契约供 LLM、行为树和脚本复用。先完成技能调用闭环，再扩展后端和玩家能力。
本增量保持 Player / World 真值、移动输入和原子动作裁决不变；不接入身体交互、施法或正式聊天。

- [x] 将长技能启动、内部 Outcome 路由、中断、停止确认和结束记录从 Llm 提取到 Runtime。
  Body 组合 Runtime 与所选 Brain；同步 Brain 输出和异步 Brain 命令都经过同一入口。
- [x] 技能提供公共描述与执行契约；调度通过独立策略接口调用，Jev 为现有实现，无配置时不产生模型请求。
- [x] 非 LLM 后端完成同一个 build，拒绝原因和事务序号原样返回；非 LLM 也能调用已有 Memory 工具。
- [x] 复用中断时序、stop 被替代、worker 崩溃与 Body 退出测试，增加非 LLM 场景和真实 World 扣料/拒绝接缝。
- [x] 更新接口说明和实际运行记录；双客户端实跑与本地模块验证分别报告。

契约：每个技能调用只有一个终态；停止要等待 worker 退出以及 Body 的停止确认；不能撤销已提交世界事务，
失败不能冒充完成。后端必须立即返回事件回调，慢请求独立执行。测试使用手排 Body 事件控制中断竞争，
World 接缝使用真实 Session / Scene / Player / World 与有限作者供给；模型替身仅替代外部付费服务。

依据：Elixir behaviour 将通用生命周期与回调实现分开；BehaviorTree.CPP 的异步动作使用运行中、终态与 halt。
本项目沿用现有命令身份和 Outcome，不引入行为树库或另一条权威链路。
参考：https://hexdocs.pm/elixir/typespecs.html 与 https://www.behaviortree.dev/docs/guides/asynchronous_nodes/ 。

### 接入方式

现有 `Body.start_link(..., brain: {模块, profile})` 不变；Body 自动组合 Runtime。
同步后端实现 Brain 的两个回调；慢后端在 init 时保存 self()，异步命令投回这个 Runtime 接收端。
角色的世界操作仍经 Body / Player / World，不把技能内部命令、HTTP 或 worker 生命周期交给后端重写。

```elixir
# 全局系统功能配置示例；definition_hex / anchor_micro 由调用方从正式已发布定义和目标取得。
brain: {GateServer.Npc.Brain.Routine, %{
  skills: %{build: %{}},
  steps: [%{verb: :skill, skill: :build, args: %{
    "definition" => definition_hex, "anchor_micro" => anchor_micro, "orientation" => 0
  }}]
}}
```

- 添加技能：实现 `GateServer.Npc.Skill`，配置 `skills: %{名字: %{module: 实现模块, ...}}`。
  `definition/1` 拥有参数说明，`run/3` 在 worker 内接纳输入并返回一个终态；无需改 Llm / Runtime 分派。
  字符串工具名只在已配置名字中匹配，不把模型输出转成新原子。
- 添加中断策略：实现 `GateServer.Npc.Scheduler.decide/2`，配置
  `interrupt_policy: {实现模块, 配置}`，返回 `:continue`、`{:interrupt, 原因}` 或 `{:error, 原因}`。
  该字段独立于旧 `scheduler` Jev endpoint（荒野技能内部分类仍使用它）；两者都未配置则不请求调度模型。
- 取消：向 Body / Runtime 提交 `%{id: 原技能调用号, verb: :cancel_skill}`，终态仍对应原调用。
  已提交事务保留；停止失败明确回报。首个观察前提交技能或记忆得到 `invalid_session`，不会杀死 NPC。
- 查看：`Skills.tools(profile)` 返回启用能力及参数，`Body.observe(body).outcomes` 包含技能终态。
  `npc_skill_outcome` 日志带状态、用量和策略请求次数；无法取得的子任务用量保持未知。

### 范围与剩余工作

本增量实现后端共用的技能、记忆命令与中断运行契约；脚本是真实非 LLM 调用方，尚未新增通用行为树引擎。
HTTP 已独立，但 Responses 协议仍由 Llm / Design / Builder 各自解释，尚未统一为跨供应商模型接口。
Memory 的存储模块注入保留既有契约；原子动作能力描述尚未全部收为一个目录。
玩家 ToolAction / 施法与 NPC 的入口对齐、正式聊天和 gather 是后续独立功能增量。

真实模块回归发现 Scene.drop 原顺序先停止 Player、后发 mmo_close，NPC 会先收到 DOWN(:normal)，
导致既有测试期待的会话关闭原因丢失。调整为先通知 owner 再停止 Player；保持原断言并验证两向清理。
原失败在 `Voxim/Saved/npc-runtime-world1.log`。新增启动时序用例改前因 nil.self 失败，
保存在 `npc-runtime-readiness-red.log`，接纳边界修复后再验证。

### 本地验证记录（2026-10-06）

源码：`npc-shared-runtime-20261006` 分支，本节随实现一并提交；基底 `52ac3aac`。
环境：Windows 原生正式 Mix 构建图，`MIX_ENV=test`，独立测试 PostgreSQL
`voxim-pg-p0-body-20261005`（127.0.0.1:26909）；数据库由既有测试入口按 VM 隔离并清理。
以下命令均退出 0，日志位于相邻 `Voxim/Saved/`。

在 `apps/gate_server` 执行：

```powershell
mix.bat test --no-start test/gate_server/npc_skill_brain_test.exs test/gate_server/npc_skills_test.exs test/gate_server/npc_brain_llm_test.exs test/gate_server/npc_jev_test.exs test/gate_server/npc_memory_test.exs test/gate_server/npc_skill_design_test.exs test/gate_server/npc_wilderness_test.exs test/gate_server/npc_brain_builder_test.exs test/gate_server/npc_body_test.exs test/gate_server/npc_body_world_test.exs --seed 0
```

93 通过、9 排除，102.6 秒，`npc-runtime-final.log`。
其中真实 Session / Scene / Player / World 场景证明：脚本调用 build 获得越界拒绝后仍可成功建造，
资源只扣一次，返回事务与世界结果对应；世界提交后再取消 worker 不撤销已发生的建造和扣料。
外部模型使用替身，替身不替代正在验证的 authority。

在 `apps/scene_server` 执行：

```powershell
mix.bat test --no-start test/scene_server/movement/voxim_scene_test.exs test/scene_server/movement/voxim_player_test.exs test/scene_server/movement/p0_body_lifecycle_test.exs --seed 0
```

35 通过，25.3 秒，`npc-runtime-scene-regression.log`，覆盖会话退出顺序改动的直接边界。
最终整理共享参数说明及自定义技能到 Llm 的解析断言后，在 `apps/gate_server` 补验：

```powershell
mix.bat test --no-start test/gate_server/npc_skills_test.exs test/gate_server/npc_skill_design_test.exs --seed 0
```

20 通过，9.4 秒，`npc-runtime-contract-final.log`；这些与前一轮存在重叠，不累加为独立用例数量。
9 个排除项涉及真实模型或规模场景，不计通过；本轮没有付费模型调用、UE 双客户端实跑、性能验收或分发验证。
本记录证明已实现并完成服务端模块集成验证，不表示 NPC 全部接口化或客户端验收已完成。
