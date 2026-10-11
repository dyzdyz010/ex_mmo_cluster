# NPC 对话验收工具（只测试）

本目录消费正式 Scene / Gate / Body / Life 入口与真实双端证据，不属于生产运行时。产品边界见 [对话设计](../../docs/10-active/cross-cutting/2026-10-11-npc-dialogue.md)；既有独立服务与人生验收见 [npc_life](../npc_life/README.md)。

## 对话记忆与冷重启

`memory_check.py` 在一次已通过的 `run.py live` 之后运行。来源目录必须包含 `fixtures.json`、`verdict.json`、`errors.json`、完整 `scene.json`、决策 `started.json` / `requests.json` 与两份 `memory-before-{cid}.json`。它只接纳两个 NPC 各自最多 16 个且全部结束的成功决策，总决策 token 小于 350,000。实际双方定向对话中按时间选择第一组有回应的两句作为预登记样本，两个 NPC 都必须实际收到这两句；不从召回结果挑容易通过的句子。

```powershell
python -B scripts/npc_dialogue/memory_check.py self-test
python -B scripts/npc_dialogue/memory_check.py plan --source .demo/observe/npc-dialogue-20261011/dual-01
python -B scripts/npc_dialogue/memory_check.py run --source .demo/observe/npc-dialogue-20261011/dual-01 --out .demo/observe/npc-dialogue-20261011/memory-01
```

`plan` 与 `self-test` 完全离线。`run` 会调用真实记忆服务并重启容器，必须在双端运行结束、两 NPC 已恢复 `settler` 后单独执行；它验证登记状态，没有把角色自动切换或创建另一大脑的功能。不要使用 Python `-O`，断言是验收门禁。每次 `run` / `audit` 输出目录必须不存在，失败证据保留，重跑用新目录。

运行步骤与产物：

1. 检查两个 NPC 都为启用且运行中的 `settler`，没有启用的 `life` / `llm` 决策脑。读取实际 Body / Life 与持久行；要求无 `error` / `unsaved_speech`，持久 canonical state 与 Life state 相同。
2. 等已有任务完成后逐 NPC 调用正规 `Life.flush`。轮询 `job`、pending episodes / fragments、Hindsight pending operations / consolidation 与失败计数；`busy` 不能冒充写入完成。等待后续自动任务完成，记录 `before.json`、`flush-{cid}.json`、`retained.json`、每轮 `polls.jsonl`。不调用额外强制 refresh。
3. 调用既有 R7 `server.restart`，只对 `voxim-npc-life-demo-20261011` 做真实 stop/start。要求容器 ID / 镜像不变且 `StartedAt` 改变；保留 loaded BEAM、容器执行身份和 `restart.json`。不重启 Hindsight，不升级镜像，不写心智或 World cursor。
4. 等正式 readiness、注册表恢复、Life 加载及后台任务完成，记录 `after.json`。两个 NPC 的完整 canonical state（含 World 身份和 cursor）必须与重启前严格一致，retained 数量保持。若静默窗口发生新的真实 World 活动，严格比较会失败；保留证据，不能通过忽略游标或补写状态消除失败。
5. 每 NPC 恰好调用一次生产 `Life.context`，以角色名和一般对话查询召回，不向查询注入待验证原话。保存 `query-{cid}.json`、`recall-{cid}.json`，只读实际 recalled facts 引用的原文档，保存 `documents-{cid}.json`。最终再核对 canonical state、后台完成状态和 token，保存 `final.json`、`evidence.json`。

依据为当前固定 **Hindsight 0.10.3** 实例的公开 `/openapi.json`（本地证据 `.demo/observe/npc-life-20261011/hindsight/openapi.json`）、[生产适配器](../../apps/gate_server/lib/gate_server/npc/life/hindsight.ex) 和 [Speech 经历投影](../../apps/gate_server/lib/gate_server/npc/dialogue.ex)。宿主只读 API 固定 `http://127.0.0.1:18908`，生产 Life 使用同一容器 `http://voxim-npc-life-loop-20261011:8888`；版本、端口、镜像与数据卷通过既有 `service.preflight` 检查。只保存公开的统计、来源文档和脱敏观察，不读取环境凭证、私有 endpoint 或原始 LLM trace。

## 来源与语义结论分开

自动检查要求实际召回 fact 的 `document_id` 指向本 NPC bank 的文档，并从原文逐项核对 conversation、turn、speaker ID / epoch / kind / name、target、毫秒时间、原话，以及本人的 `I said` / `I heard` 视角。不能拿另一个 NPC bank 的文档、未被召回引用的文档或只匹配关键词当证据。当前检查要求实际返回的文档引用；仅有 `source_fact_ids` 而没有可核对文档的派生 observation 不足以通过本门禁。

一个文档可能包含多句经历，因此“召回事实引用正确原文档”还不等于事实正确概括了指定一句。`run` 完成后 `verdict.json` 仍为 `accepted: false, semantic_review_pending: true`，退出码 0 只表示证据采集完整。复制 `review-template.json` 为单独的新文件，实际阅读 `recall-{cid}.json` 与原文档，对每 NPC 的两句逐项填写：

- 选择确实支持该句话的 `fact_id`；候选集合来自真实召回与文档关联。
- 核对说话者和具体内容，不能把听到的他人发言写成本人发言。
- 核对提议、打算或角色陈述没有被当作已经发生的 World 事实。
- 三个布尔结论都为真才通过；`note` 写具体 fact 与原话如何对应，补 `reviewer` / `reviewed_at`。复核可以由读过产物的执行代理完成，不另调用评审模型，不勾空白模板。

```powershell
python -B scripts/npc_dialogue/memory_check.py audit --evidence .demo/observe/npc-dialogue-20261011/memory-01 --review .demo/observe/npc-dialogue-20261011/memory-review-01.json --out .demo/observe/npc-dialogue-20261011/memory-audit-01
```

`audit` 完全离线，重算来源证明、冷重启不变量和用量；review 必须通过 SHA-256 绑定整份 `evidence.json`。全部通过才输出 `accepted: true`。没有合适 recalled fact、内容或归属错误时如实失败，不用更多查询/另一 backend 抵消首次结果。

```mermaid
flowchart LR
  Live[Scene 实际对话与双端通过] --> Flush[正规 Life.flush]
  Flush --> Drain[retain 与后台任务完成]
  Drain --> Restart[同一服务端容器冷重启]
  Restart --> Recall[各一次 Life.context]
  Recall --> Source[召回 fact → 原文档 → 权威 Speech]
  Source --> Review[逐句内容与说话者复核]
  Review --> Audit[离线 accepted 判定]
```

## 费用与失败

累计历史基数读取本次 live 的 `fixtures.cumulative_tokens_before`（最初为 **1,243,611**），上限 **2,000,000**。失败运行的已发生决策与记忆费用须先由运行账本计入这个基数，完整 fixtures 保留在 `plan.json`，`prior_runs` 也进入用量报告；不能因某轮未通过而丢掉它的费用。fixtures 的 `memory_accounted_tokens: {"cid": 已计入累计基数的该 bank token}` 明确每个 bank 已记费用。本轮总量为 `fixtures 累计基数 + live 全部已完成决策 token + Σ(各 bank current − accounted)`，要求 `0 ≤ accounted ≤ memory-before`，避免费用重复与遗漏。

没有显式 bank 账本时，缺省旧 NPC 的 accounted 为本轮 `memory-before`，新 NPC 为 0。新 bank 的初始化费用不在该轮基数中，所以其 `memory-before` 只作准备阶段证据，**不能扣除**。复用失败轮 bank 时应使用账本记录的已计费用，不能凭“第二 NPC”猜测它完全新建。统计计入 input 与 output、全部 scopes；每次开始 flush / recall 前及每轮观察都会检查已报告总量。正在执行的后端任务仍可能继续计费，只有全部完成后的 `final.json` 可作最终总数，不能把采样时未报告的费用当零。

新增失败请求、operation / consolidation 失败、预算超限、身份/来源/持久性不一致或等待超时都会停止发起后续步骤并保存 `failure.json`，再做一次只读失败取证。`failure-observation.json` 的 `final_usage_known: false` 表示仍有在途任务或观察缺口；不会取消后台任务并宣称费用已清零。原文件不覆盖。

离线自测最小范围：完整来源错配、无实际 recall 的文档、旧/新 bank 费用归属、语义复核覆盖与说话者错误、未持久 Speech / canonical 不一致。首次 RED 与后续 GREEN 存于 `.demo/observe/npc-dialogue-20261011/memory-script-validation/`；它们只验证验收脚本，不证明真实记忆或冷重启已通过。
