# 日计划纯函数核心的测试夹具

`test/npc_server/npc_life_day_plan_test.exs` 用。取自 S1-R8 离线测量里规划模型的真实应答（`.demo/` 不进 git，所以复制到这里）。
路径相对 `.demo/observe/npc-slice1-20261112/s1r8/`。只复制，不手写、不改正文。

| 文件 | 来源 | 取法 |
|---|---|---|
| `s1r8-<名>.json` | `raw/W_<名>.json`（Anthropic Messages 形状的真实应答）与 `results.json` | `text`：应答里唯一的 `text` 块原文；`now` / `now_minute`：该份材料的此刻（`results.json` 的 `rows` 与 `materials`）；`activity_names`：`candidates` 的六个名字；`s1r8_checks`：`rows[<名>].checks` 里 S1-R8 当时记的检查 1–5 结果与条数、`by` 读数 |

选这 4 份：`R1-r1`（18 份里唯一不过检查 5：条数 6 超过 5）、`R3-r1`（有 `cannot_yet`，且同名活动 `visit_plaza` 出现两次）、`R2-r1`（夜间 22:26）、`R5-r1`（凌晨 01:42，两条 `cannot_yet`，`times` 为 2）。
