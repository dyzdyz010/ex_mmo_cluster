# 任务推进的真实应答（任务层 T-1b）

`test/npc_server/npc_life_tasks_integration_test.exs` 用。都是 K-0 离线测量里 DeepSeek（`deepseek-flash`）对产品渲染的请求给出的**原始回执**，
原样复制（`.demo/` 不进 git）：不手写、不改字节。测试经写作函数替身回放 `choices[0].message.content` 原文；K-9 一例把整份回执字节交给 HTTP 替身。
路径相对 `.demo/observe/npc-task-k0-20261119/`。

| 文件 | 来源 | 请求（来源旁 `requests/` 下同名） | 应答 | 用途 |
|---|---|---|---|---|
| `advance-A01.json` | `retest-1/raw/advance/A01.json` | 复测 R1-r1 的重建任务（`gather_stone → build_hut → guard_hut`），`gather_stone` 失败 `exhausted` 后推进（`waiting = failed`） | `continue` 三步（`gather_stone`、`build_hut`、`guard_hut`），另写了 `cannot`；`finish_reason = stop` | 失败 → 推进 → 采用新步骤（`cannot` 只计数） |
| `advance-A06.json` | `retest-1/raw/advance/A06.json` | 复测 R1-r1 的问 Corvin 任务（`confront_wrecker → speak_to Corvin`）步骤用完后推进（`waiting = steps_done`） | `done`，带 `note` | 步骤用完 → done 关闭、写经历 |
| `advance-A17.json` | `raw/advance/A17.json`（K-0 首轮） | 停滞推进；K-0 首轮的词表含 `look_for` | `continue`：`look_for "actor 1906495721474"` → `speak_to` | 被拒：`look_for` 现在不在词表里（T-2 才上线），产品 `Tasks.check/3` 给 `{:unknown_activity, "look_for"}`。正文没改——真实模型产出、今天的产品会拒（K-0 与复测的推进应答在当时的词表下全部合格，没有别的真实被拒样本，所以不做变体）。**T-2 `look_for` 进词表后这份应答的被拒原因会变**（不再是 `{:unknown_activity, "look_for"}`，也可能不再被拒），届时被拒用例与断言要重定（统筹记在 T-2 清单） |
| `review-R1-r1-raw.json` | `retest-1/raw/review/R1-r1.json` | 复测回顾 R1 | 正文与 `../day_plan/review-R1-r1.json` 的 `text` 相同（那一份只取了正文） | K-9 一例：真实 `Writer` 经 HTTP 替身收到整份回执 |

`A01`、`A06` 的材料与 `../day_plan/review-R1-r1.json` 开出的两个任务是同一组（复测 R1-r1 → 推进 F / D 两例），集成测试里回顾开出的任务与推进应答对得上。
用户给的路径写的是 `raw/advance/A01.json`、`A06.json`，但所述内容（采石失败 `exhausted` 后 continue；Corvin 任务步骤用完 done）是复测 `retest-1/` 里的那两份
（K-0 首轮的 A01 是 `build_hut` 缺料、A06 是 R5 材料的另一个任务），按规划 §3 取复测的。
