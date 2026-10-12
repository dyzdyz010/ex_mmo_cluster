# NPC 对话验收工具（只测试）

本目录消费正式 Scene / Gate / Body / Life 入口与真实双端证据，不属于生产运行时。产品边界见 [对话设计](../../docs/10-active/cross-cutting/2026-10-11-npc-dialogue.md)；既有独立服务与人生验收见 [npc_life](../npc_life/README.md)。

当前费用已超上限，付费路径停止。下面 `live` / `memory_check run` 是原验收入口说明，不能在现有额度下继续执行；`prepare` 已在任何运行准备前拒绝耗尽账本，先红后绿的反例见 `paid-quiesce/guard-{red,green}.log`。该检查防止耗尽后再启动，不代表已具备逐请求前的硬token预算控制。

## 真实双端与独立 NPC

`run.py` 固定使用任务拥有的 Demo 容器、长期世界与独立18908记忆库，客户端只启动 `C:/Users/DYZ/orca/workspaces/Voxim/npc-dialogue-20261011` 的正式 Gameplay 地图。它是保留人物历史的持续场景，不是任意新数据库可直接跑的独立回归；初始世界和角色的合法创建入口在 `npc_life/demo.py prepare`，当前已有世界不得重置或补写心智。启动前需要匹配 Hello40 的已冻结客户端模块和正式 release。

```powershell
python -B -m unittest discover -s scripts/npc_dialogue -p test_verify.py
python -B scripts/npc_dialogue/run.py plan
python -B scripts/npc_dialogue/run.py live --run dual-02
python -B scripts/npc_dialogue/run.py check --run dual-02
```

每次使用不存在的运行目录。`budget-ledger.json` 位于 `.demo/observe/npc-dialogue-20261011/`，记载已发生费用、失败轮与每个 bank 已计费用；没有账本不开始付费。脚本先实查出生柱，从空中经正式出生判定落地，再要求 Body 权威位置与 Life 缓存均就绪。玩家站位/相机使用已有只测试作者夹具，不据此声称移动或流送验收。

首句中文通过真实 UMG 的 Enter、Slate字符、Enter发送。双方收到同一确认后才启用两个各自16请求上限的 `life` 大脑；玩家提出话题，NPC自己选择工具与台词。后续包括玩家旁听、取消输入、远处指定对象被拒以及返回附近。Scene每条接纳、每个收件人的投递与各端记录逐笔核对；两个NPC必须在同话题里向对方实际发言，且台词有本人的独立模型请求来源。结束恢复无付费决策的settler，等待在途调用结束并保留用量。输入法候选组合另由原生UI验收，不把 `@type` 当系统IME测试。

首次 `dual-01` 准备缺陷已保留：新出生探针在实心地形内，只有记忆就绪，身体没有入场。玩家首句双端成功后启动模型准备失败，两个已发生决策21230token计入账本；没有把该轮记为通过。新 `npc_ready` 最小反例拒绝这种假就绪；清理某个NPC失败也不会跳过其余角色和trace清理。

## 无模型的真实输入补测

`python -B scripts/npc_dialogue/ui_smoke.py --run ui-new` 要求所有付费大脑与Life均已停止，保留同一任务拥有的Demo、NPC与玩家。通过实际准星O、目标按钮、UMG中文输入和取消验证用户入口，随后停在 `@await_peer finish_manual`，给原生系统IME操作留出总计360秒的有界窗口。完成手动输入及截图检查后，在本运行目录 `b/replay.done` 写入 `finish_manual`，继续只读 `Voxim.Dialogue.Status` 并正常结束。

实际 `ui-01` 在布局bb2c4403下通过，约4分44秒、回放成功、退出0。`automated-verdict.json` 证明目标与回执关联、取消及CLI；`ime-first-enter.json` 与 `ime-verdict.json` 独立证明系统候选Enter不误发和确认中文后发送。截图统一在客户端 `Captures/Dialogue/20261011/`，不得仅以文件存在宣布视觉通过。该单端补测只针对新的布局与原生输入，双端复制证据继续用 `dual-02`，没有重跑付费模型。

## 对话记忆与冷重启

`memory_check.py` 独立检验本轮已发生对话的持久性，输出始终带 `scope: memory_only`。来源目录必须包含 `fixtures.json`、`errors.json`、`clients.json`、完整 `scene.json`、决策 `started.json` / `requests.json`、两份 `before-restore-{cid}.json` 与 `memory-before-{cid}.json`。它核对完整真实 Scene 接纳/投递、两 NPC 的 Body 实际接收历史，以及样本台词来自各自模型的 `say` 调用；按时间选第一组有回应的两句，不从召回结果挑容易通过的句子。两个 NPC 各自最多 16 个请求，全部请求必须结束并有成功用量，累计总预算不超过 2,000,000。

350,000 是 live 的付费决策停止阈值，计划中继续保留 `decision_guard` 和是否触发的 `budget_stop`。停止时已经在途的请求仍须全额计费，但不改变此前权威发言已经发生的事实。记忆检查不依赖整轮 `verdict.accepted`、`errors=[]` 或尾部 UI Status 回放完成；计划和记忆最终 verdict 原样记录 `source.errors`、`source.client_replay` 与 `budget_stop`。例如 `dual-02` 的 31 个已完成请求为 371,662 token，两端回放为 interrupted；这可以进入独立记忆检查，但不能写成整轮 UI 回放通过，也不会修改原失败目录。`minimum_usage` 只合计来源基线与已完成决策的已知下限，实际开始前继续读取当前 bank 用量，超总上限则停止。

```powershell
python -B scripts/npc_dialogue/memory_check.py self-test
python -B scripts/npc_dialogue/memory_check.py plan --source .demo/observe/npc-dialogue-20261011/dual-02
python -B scripts/npc_dialogue/memory_check.py run --source .demo/observe/npc-dialogue-20261011/dual-02 --out .demo/observe/npc-dialogue-20261011/memory-01
```

`plan` 与 `self-test` 完全离线。`run` 会调用真实记忆服务并重启容器，必须在双端运行结束、两 NPC 已恢复 `settler` 后单独执行；它验证登记状态，没有把角色自动切换或创建另一大脑的功能。不要使用 Python `-O`，断言是验收门禁。每次 `run` / `audit` 输出目录必须不存在，失败证据保留，重跑用新目录。

运行步骤与产物：

1. 检查两个 NPC 都为启用且运行中的 `settler`，没有启用的 `life` / `llm` 决策脑。读取实际 Body / Life 与持久行；要求无 `error` / `unsaved_speech`，持久 canonical state 与 Life state 相同。
2. 等已有任务完成后逐 NPC 调用正规 `Life.flush`。轮询 `job`、pending episodes / fragments、Hindsight pending operations / consolidation 与失败计数；`busy` 不能冒充写入完成。等待后续自动任务完成，记录 `before.json`、`flush-{cid}.json`、`retained.json`、每轮 `polls.jsonl`。不调用额外强制 refresh。
3. 调用既有 R7 `server.restart`，只对 `voxim-npc-life-demo-20261011` 做真实 stop/start。要求容器 ID / 镜像不变且 `StartedAt` 改变；保留 loaded BEAM、容器执行身份和 `restart.json`。不重启 Hindsight，不升级镜像，不写心智或 World cursor。
4. 等正式 readiness、注册表恢复、Life 加载及后台任务完成，记录 `after.json`。两个 NPC 的完整 canonical state（含 World 身份和 cursor）必须与重启前严格一致，retained 数量保持。若静默窗口发生新的真实 World 活动，严格比较会失败；保留证据，不能通过忽略游标或补写状态消除失败。
5. 每 NPC 恰好调用一次生产 `Life.context`，以角色名和一般对话查询召回，不向查询注入待验证原话。保存 `query-{cid}.json`、`recall-{cid}.json`，只读实际 recalled facts 引用的原文档，保存 `documents-{cid}.json`。最终再核对 canonical state、后台完成状态和 token，保存 `final.json`、`evidence.json`。

依据为当前固定 **Hindsight 0.10.3** 实例的公开 `/openapi.json`（本地证据 `.demo/observe/npc-life-20261011/hindsight/openapi.json`）、[生产适配器](../../apps/npc_server/lib/npc_server/life/hindsight.ex) 和 [Speech 经历投影](../../apps/npc_server/lib/npc_server/dialogue.ex)。宿主只读 API 固定 `http://127.0.0.1:18908`，生产 Life 使用同一容器 `http://voxim-npc-life-loop-20261011:8888`；版本、端口、镜像与数据卷通过既有 `service.preflight` 检查。只保存公开的统计、来源文档和脱敏观察，不读取环境凭证、私有 endpoint 或原始 LLM trace。

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

`audit` 完全离线，重算来源证明、冷重启不变量和用量；review 必须通过 SHA-256 绑定整份 `evidence.json`。全部通过才输出 `accepted: true, scope: memory_only`；来源 live 的错误与回放状态继续保留。没有合适 recalled fact、内容或归属错误时如实失败，不用更多查询/另一 backend 抵消首次结果。

```mermaid
flowchart LR
  Live[权威对话与 NPC 实际接收来源] --> Flush[正规 Life.flush]
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

## 预算停止后的只读收口

本轮已核对的累计费用为 **2,010,947 token**，超过 **2,000,000** 上限 **10,947**：历史 1,264,841 + dual-02 决策 371,662 + 同期记忆增量 374,444。原决策停止线未覆盖并发 retain、consolidation 和自动模型刷新，不能宣称满足总预算。仅恢复 `settler` 不会关闭附带的 Life，Life 仍可能自动付费；本轮已经从两份持久登记中移除 Life，保持两个 NPC 为 `settler`。原额度不提高、失败不改绿，禁止通过再次 flush / refresh 补齐验收。

`readonly` 是预算停止后的部分取证入口：要求 Life worker 不存在、登记不含 Life、Hindsight 后台 pending 为零；只读已有 DataService 行与 Hindsight facts / documents，各 bank 恰好一次生产 `Hindsight.recall`。`--restart` 只对原服务端容器做正式冷重启，前后比较完整 stored 行（包括 canonical 心智、World cursor、cache 和未 retain 尾部）；不启动 Life，不调用 flush、refresh、retain 或决策模型。

```powershell
python -B scripts/npc_dialogue/memory_check.py readonly --source .demo/observe/npc-dialogue-20261011/dual-02 --out .demo/observe/npc-dialogue-20261011/memory-readonly-new --restart
```

无新增付费依据仅适用于本轮固定服务：`service.py` 与已有 `providers.log` 配置为本地 ONNX CPU embedding 和 FlashRank reranker。仅读取安装源码已核对 `memory_engine.py:8764` 的 `recall_async` → `:9332` 查询 embedding → 数据库检索 → `:9918` 本地排序；`query_analyzer.py` 使用 Dateparser，无生成 LLM。`embeddings.py:449` / `:695` 为进程内 ONNX 推理，`cross_encoder.py:1491` / `:1504` 为本地 FlashRank。公开 facts/documents GET 只走数据库。此结论不能推广到配置了远程 embedding/reranker 的其它服务；实际采集还必须验证前后各 scope 用量完全相等。

真实只读收口产物在 `.demo/observe/npc-dialogue-20261011/memory-readonly-01/`：同容器 ID / image 不变、StartedAt 改变；两份完整 stored 相等；各库一次 adapter recall 后用量完全相等，新增付费 **0**。`verdict.json` 始终为 `accepted:false, scope:memory_readonly_partial`，保留 `paid_budget_passed:false` 和原 live 的 interrupted / budget-stop。两个 NPC 各有 **4** 条尾部仍只在 SQL pending，不能声称已进入 Hindsight。

自动来源链通过与逐句记忆完整性仍分开。`semantic-review.json` 记录实际召回能区分 LifeBuilder 的要求与松岚的观察/暂不修复意愿；但预选首轮两句被概括进较晚话题，询问、自我介绍和条件没有逐句保全，不能换成更容易命中的后续句子再宣布原门禁通过。old fact `a046d690-8cec-4bad-b51f-20af6959f0ad` 概括为“约定”，部分 observation 又省略意愿或角色陈述限定，写成“负责”；它们始终是主观摘要，不是新的 World 真值。

`semantic-review-addendum.json` 另记录已实证的语言缺口：两个 bank 本轮 speech facts 均被抽取为中文，英文 wrapper 包裹中文原话未能满足 NextLoop 的英文事实口径，当前 BGE-small-en / FlashRank ms-marco 检索栈的语言适配仍未解决。本轮未做语言对照，不能把某条检索损失唯一归因于语言。下一步需另轮预算，保留中文原话与身份来源，同时约束英文提取和谨慎归因，再以专门反例验证；不在本轮调松门禁或追加模型。此次没有运行 Life.context 的完整启用链，也没有补写尾部。

离线自测最小范围：完整来源错配、无实际 recall 的文档、旧/新 bank 费用归属、语义复核覆盖与说话者错误、未持久 Speech / canonical 不一致；付费停止后完整发言可独立验记忆，未完成请求及超累计预算仍拒绝。首次 RED 与后续 GREEN 存于 `.demo/observe/npc-dialogue-20261011/memory-script-validation/`；它们只验证验收脚本，不证明真实记忆或冷重启已通过。
