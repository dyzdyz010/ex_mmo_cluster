# Task 4：正式 NPC 人生接线

实现：Life 单一持久 owner；独立 World poll 与 Hindsight worker；Runtime 注入身份和 canonical 心智；Social 包装原 Settler Tree；
LLM 在请求 worker 中只读缓存认识并召回一次。未修改 Task 1 World、Task 2 State、Task 3 Hindsight，也未改 wire 或客户端。
Life 默认关闭；启用的 llm 档案默认 60 次/小时，显式预算可收紧。所有 HTTP/状态 owner 跟随原 Body/Runtime 生命周期。

## CLI 与 Demo 登记

永久 bank 为 `npc-life-<cid>`。服务 URL 必须来自 JSON life.url 或 `NPC_LIFE_HINDSIGHT_URL`；生产没有本轮 Test-only 实例默认值。

```elixir
{:ok, data} = GateServer.Npc.Life.observe(cid)
IO.puts(Jason.encode!(GateServer.Npc.Context.plain(data)))
GateServer.Npc.Life.flush(cid)                 # {:ok, %{status: :started | :busy | :empty}}
GateServer.Npc.Life.refresh(cid)               # {:ok, %{status: :started | :busy}}
GateServer.Npc.Life.context(cid, "Who helped or harmed my construction?")
```

Test-only Demo 的完整登记形状（definition_hex、工地及 spawn 使用 Demo 已批准作者资产；不要猜另一个定义）：

```elixir
GateServer.Npc.Registry.put("LifeBuilder", %{
  scene_id: 1, spawn: {63.0, 416.9, 107.0}, brain: "settler",
  params: %{
    "definition" => definition_hex,
    "sites" => [%{"anchor_micro" => [544, 3344, 864], "orientation" => 0, "stand" => [63.0, 107.0]}],
    "revisit_ticks" => 36000, "tools" => %{"1" => "镐"},
    "life" => %{"url" => "http://voxim-npc-life-loop-20261011:8888"}
  }
})
```

实际 RPC 示例，替换 server-container/cid 为本轮已运行身份即可，Body 位置另由其既有 observe 读取：

```sh
docker exec <server-container> bin/voxim_server rpc 'IO.inspect(GateServer.Npc.Life.observe(<cid>), limit: :infinity)'
docker exec <server-container> bin/voxim_server rpc 'IO.inspect(GateServer.Npc.Life.flush(<cid>))'
docker exec <server-container> bin/voxim_server rpc 'IO.inspect(GateServer.Npc.Life.refresh(<cid>))'
docker exec <server-container> bin/voxim_server rpc 'IO.inspect(GateServer.Npc.Life.context(<cid>, "Who helped or harmed my construction?"), limit: :infinity)'
```

同名 Registry.put 保留 cid/记忆，替换 brain 为 llm，参数 `goal/tools/life/max_requests_per_hour: 1` 可验证同 cid 的有限一次真实决策；
Life.context 返回 mind、mental_models、model_metadata、memories、recall_latency_ms、memory_retrieval=hindsight_once。
Hindsight models/facts 是历史主观证据，不是 World 当前数量/余额/位置。

## 已验证的契约与证据

先运行缺 Life/Social 的 5 个 RED，再分别保留感谢重复、停止拒绝、站立层、预算、配置缺失的 RED/GREEN。
原始本地结果位于 `.demo/task4-*.log`，仅为 Test-only 运行产物，未计作真实双端 Demo。

| 可证伪的错误 | 对应最小用例 |
|---|---|
| DB 拒绝却推进游标/心智或丢 pending | `real database rejection keeps canonical cursor and pending atomic until storage accepts the World event`：真实 PostgreSQL trigger 拒写、真实 World 新事务；恢复写入后只评价一次 |
| 初始化 DB 失败被当成空新生状态 | `failed durable initialization is explicit and does not publish a cursor` |
| 慢 retain 阻塞 World 或 Body；旧完成快照覆盖新事件 | `durable authority appraisal progresses during slow retain; completion removes only sent fragments`：两笔真实 World 伤害，第二笔发生在 retain 悬挂中，Body.stop 得到终态 |
| 重启重复评价/恢复出厂值 | 同一用例真实 kill Body，监督者恢复同 cid，canonical 与尾片段完全相同 |
| HTTP 失败丢片段、逐帧自动重试或重造 id | `failed retain preserves sealed identity and stays diagnostic while Body continues`：失败后 pending 未删，显式重试 id 不变 |
| 每次短伤害抽取一个文档或每轮决策 refresh | `short facts form one fragment; models refresh after first retain and dirty cadence, never on context`：两条短经历封为一个片段、首次 refresh、后续 dirty 到 10min 才 refresh |
| Llm 同时做词法和 Hindsight 检索 | `production Llm decision uses current mind, cached models and exactly one recall without lexical retrieval`：真实生产 Llm 请求 worker，词法读取替身若被调用直接失败 |
| 取消技能还未 settle 就开始社交移动 | Social 的 `social movement waits for halted skill terminal and preserves authority failure` |
| stop 失败仍移动，拒绝被当到达 | Social 的 `failed halt stop...` 与 `rejected gratitude move...` |
| 感谢/谨慎在工作间 pingpong，重启重新感谢 | Social 的完成感谢、已在范围、restored acknowledgement、谨慎 hold 用例 |
| 把自身中心高度写成目的地脚层 | Social 的 uneven-ground 接缝要求省略 y，复用已存在 Body 权威导航契约 |
| Life 配置污染关闭 profile 或使用实验默认 URL | `npc_life_registry_test` 与原 `npc_registry_test` 精确 profile 期望 |

命令在 `apps/gate_server` 运行，使用 Test-only PostgreSQL 127.0.0.1:26769，凭据只配置进程环境；config/test.exs 的真正名称是
`MMO_DB_HOST/PORT/USER/PASSWORD`，未指定 `MMO_TEST_DB_NAME`，每次 VM 自动建独占库并在 suite 后清理。

```powershell
mix test --no-start test/gate_server/npc_life_test.exs test/gate_server/npc_social_test.exs test/gate_server/npc_life_registry_test.exs
mix test --no-start test/gate_server/npc_life_test.exs test/gate_server/npc_social_test.exs test/gate_server/npc_life_registry_test.exs test/gate_server/npc_registry_test.exs test/gate_server/npc_tree_test.exs test/gate_server/npc_skill_brain_test.exs test/gate_server/npc_brain_llm_test.exs test/gate_server/npc_memory_test.exs
mix test --no-start test/gate_server/npc_life_registry_test.exs test/gate_server/npc_life_test.exs test/gate_server/npc_social_test.exs test/gate_server/npc_body_test.exs test/gate_server/npc_body_world_test.exs
```

最后核心：16 passed（`.demo/task4-final-core.log`）；上述直接影响回归：86 passed，38.9s（`.demo/task4-regression.log`，后续新增配置测试单独通过）。
最终生产接缝：62 passed、7 excluded，129.8s（`.demo/task4-final-seams.log`）；排除项来自既有测试标签。此轮额外覆盖 Body 与 Body/World，原因是新增 Runtime 身份接线及 Social 复用省略 y 的导航契约；不扩大到无关全仓测试。
依赖编译的既有警告包含 mmo_contracts bitstring、Voxel World 类型推断和本 Windows 未构建 quicer；任务新模块没有新增编译警告。

## 限制与操作语义

已实现并完成模块集成验证；真实 HTTP 成本、四份模型内容人工核对、正式镜像、真实双端行为与服务/Hindsight 联合重启由 Task 5 验收。
此处 Hindsight 替身只证明 Life 的并发交接，网络适配器语义复用 Task 3 测试，不宣称真实模型结果。
跨系统不是事务 exactly-once；片段使用稳定 document_id，失败/崩溃后可能重投相同文档。
回避与谨慎的 release 条件是来源离开当前观察；同来源可见时保持站位，避免恢复施工再次向其靠近。
社交目标拒绝保留诊断且不逐帧重投；halt/settle stop 失败冻结 Social，需修复后重启。
世界身份不符/gap 显式保留旧游标；不能用新世界起点或空事件偷偷兜底。
