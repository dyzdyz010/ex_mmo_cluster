# NPC 运行时

分类：全局系统功能。统一输入与记忆规范见
[模型上下文契约](../../../../../docs/10-active/cross-cutting/2026-09-22-npc-context-memory-contract.md)。

- `Body` 接正式 Session/Player，产生观察并把动作交给 authority。
- `Context` 从权威 profile 派生身体说明；`Perception` 复用父脑和设计会话的感知范围、schema 与 World 查询。
- `Brain.Llm` 组合当前观察、近期结果和逐轮检索记忆，调度动作与技能。
- `Skills.Design` 维护本次草稿/Responses 历史，可自行观察、读写记忆、检查和发布；World 放置交给父脑的 build。
- `Memory` 提供模型记忆工具与上下文投影；`DataService.NpcMemory` 按永久 cid 持久化和检索。
- `Jev` 只分类是否中断，不能操作世界；荒野技能仍复用 Builder 的既有规划/执行状态机。

新对话式决策入口必须遵守上下文契约。旧 Builder 的一次性蓝图规划接口本轮未改成自主多轮工具会话。
测试入口在 `apps/gate_server/test/gate_server/npc_*`；真实模型用例必须显式选择 `live_llm`。
