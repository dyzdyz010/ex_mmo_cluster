# 日计划纯函数核心的测试夹具

`test/npc_server/npc_life_day_plan_test.exs` 用。取自 S1-R8 离线测量里规划模型的真实应答（`.demo/` 不进 git，所以复制到这里）。
路径相对 `.demo/observe/npc-slice1-20261112/s1r8/`。只复制，不手写、不改正文。

| 文件 | 来源 | 取法 |
|---|---|---|
| `s1r8-<名>.json` | `raw/W_<名>.json`（Anthropic Messages 形状的真实应答）与 `results.json` | `text`：应答里唯一的 `text` 块原文；`now` / `now_minute`：该份材料的此刻（`results.json` 的 `rows` 与 `materials`）；`activity_names`：`candidates` 的六个名字；`s1r8_checks`：`rows[<名>].checks` 里 S1-R8 当时记的检查 1–5 结果与条数、`by` 读数 |

选这 4 份：`R1-r1`（18 份里唯一不过检查 5：条数 6 超过 5）、`R3-r1`（有 `cannot_yet`，且同名活动 `visit_plaza` 出现两次）、`R2-r1`（夜间 22:26）、`R5-r1`（凌晨 01:42，两条 `cannot_yet`，`times` 为 2）。

## 规划提示词的金标（`npc_life_day_plan_prompt_test.exs` 用）

| 文件 | 来源 | 取法 |
|---|---|---|
| `requests-R1.json`、`requests-R5.json` | `s1r8/requests/R1-r1.json`、`R5-r1.json`（S1-R8 真实发出的 Anthropic 请求体） | 原样复制；测试从中拆回材料，断言产品拼出的**用户消息**与 `messages[0].content` 逐字节相同（没有可选块时回顾的用户消息与 S1-R8 相同）。系统提示词的金标是下文的 `review-request-*.json`（S1-R8 模板随 T-1a 删去） |
| `activities.json` | `s1r7/export/request-template.json` 的 `candidates` | 只取每个候选的 `name` 与 `criterion`（`plan.md` 说词表就是它，产品里是 `profile.activities`） |

选 `R1`（有人在场、小屋被毁，`About this` 为 `nothing yet`）与 `R5`（凌晨、40 条记忆、`About this` 有内容）。

任务层 T-1a 起日计划退化为每日回顾（系统提示词换成 `DayPlan.Prompt.review_system_prompt/2`，S1-R8 模板与 `system_prompt/2` 已删）：
`requests-R1/R5.json` 只剩**用户消息**金标（没有任务块时回顾的用户消息与 S1-R8 逐字节相同）。S1-R8 的真实应答 `s1r8-*.json`
没有 `tasks` 键（那时还没有任务层）：**单测**（`npc_life_day_plan_test` 的列表规则、`npc_mind_test` 与 `npc_life_day_plan_round_test` 的计划栏渲染）
经回顾的唯一校验点 `Tasks.check/3` 检查时补一个空的 `"tasks": {"open": [], "drop": []}`——校验器的输入本是任意模型文本，这与那些用例里
手改过的应答变体同类（任务层决策稿 §7 偏差 D-9）。Life 集成用例不这样做，回放的是下文 K-0 复测的真实回顾应答原文。

## 每日回顾的金标与真实应答（任务层 T-1a）

路径相对 `.demo/observe/npc-task-k0-20261119/retest-1/`（K-0 复测：回顾新模板 + 格式行 `object` 改法之后，真实 DeepSeek 2026-11-19 15:48–15:51Z）。

| 文件 | 来源 | 取法 |
|---|---|---|
| `review-request-R1.json`、`review-request-R5.json` | `requests/review/R1.json`、`R5.json`（产品渲染、真实发出的回顾请求：`character`、`vocabulary`、`system`、`user`、此刻） | 原样复制；`npc_life_day_plan_prompt_test` 断言 `review_system_prompt/2` 对同一人格卡与词表逐字节相同，`npc_life_day_plan_integration_test` 由 R1 的 `system` 去掉说话一行得出不配说话时的回顾系统提示词 |
| `review-R1-r1.json`、`review-R1-r2.json`、`review-R1-r3.json` | `raw/review/R1-r1.json` 等（DeepSeek chat completions 原始应答，`finish_reason` 都是 `stop`）与 `requests/review/R1.json` | `text`：`choices[0].message.content` 原文；`now` / `now_minute` / `day`：该份材料的此刻。R1-r1 合法、开两个任务（重建；点名 Corvin `actor 1906495721474`）；R1-r2 合法、一个不点名的任务；R1-r3 被拒 `{:too_many_items, 6}` |
| `review-R4-r2.json`、`review-R4-r3.json` | `raw/review/R4-r2.json`、`R4-r3.json` 与 `requests/review/R4.json`（同上） | 取法同上（第 1419 日 19:45）。R4-r2 合法：`guard_hut` 21:30 前两次与 23:45 前一次（同名意图两条，日计划集成测试的记账用例用它）；R4-r3 合法、时限都在 20:30 之后（重排用） |

日计划集成测试（`npc_life_day_plan_integration_test`）只用不点名的几份（词表不配说话也核得过）：R1-r2、R4-r2、R4-r3；被拒用 R1-r3；
配说话的用例用 R1-r1（Corvin 在观察里）。这几份都开了任务，产品照常采用。
