# 反思模块的测试夹具

`test/npc_server/npc_reflection_test.exs`、`npc_reflection_writer_test.exs`、`npc_reflection_round_test.exs` 与 `npc_life_test.exs` 的反思用例用。全部取自真实实跑与离线测量的导出（`.demo/` 不进 git，所以复制到这里），
只复制或删减，不手写、不用被测规则计算。路径相对 `.demo/observe/npc-slice1-20261112/`。

| 文件 | 来源 | 取法 |
|---|---|---|
| `s1t-experiences.json` | `s1t/export/hindsight-documents-list.json`（S1-T 真实 bank 的 108 份文档） | 每份只留 `id`、`at_ms`（`retain_params.event_date` 换成 Unix 毫秒）、`tags`；按 (`at_ms`, `id`) 排，同离线脚本 `s1x2_reflect.py` 的 `load_documents` |
| `s1x2-moments.json` | `s1x2/moments.json` | 原样复制（触发时刻、各轮的此刻与问到的问题、人名） |
| `system-prompt.txt` | `s1x2/system-prompt.txt` | 原样复制 |
| `character.txt` | `s1t/states/asked-20261113T164745.373Z.txt` | `Character: ` 一行之后的原文 |
| `round{1,4}-right-now.txt` | `s1x2/rounds/{1,4}/right-now.txt` | 原样复制 |
| `round{1,4}-happened-Q_place.json` | `s1x2/rounds/{1,4}/materials-Q_place.json` | 各条的 `body`（编号之前的正文），原次序 |
| `round{1,4}-user-Q_place.txt` | `s1x2/rounds/{1,4}/user-Q_place.txt` | 原样复制（真实发出的用户消息） |
| `round4-before.json` | `s1x2/rounds/4/before.json` | 三个问题各自之前的日记正文（`journal`） |
| `gateway-response.json` | `s1x3/gateway/resp-a-repro.json`（网关核实时的一次真实响应，请求见同目录 `req-a-repro.json`） | 原样复制（content 第一块是空的 `thinking`，第二块是 `text`；`stop_reason` 为 `end_turn`） |
| `round{1,4}-rawobs.txt` | `s1t/export/rawobs/`（`s1x2/rounds/{1,4}/plan.json` 的 `rawobs`：离线“此刻”的日号与身体一句取自它） | 原样复制（`inspect` 出的 Elixir 字面量，测试里 `Code.eval_string` 还原成观察） |
| `round4-recalled-Q_place.json` | `s1x2/rounds/4/materials-Q_place.json` | 只留两次召回的各条（`kind` 为 `raw` / `observation`），每条留 `kind`、`id`、`at`、`type`、`tags`、原文 `text` 与离线渲染的 `body`，原次序 |
| `check-samples.json` | `s1x2/reflections/{4-Q_self,5-Q_place,1-Q_place}.json`、`s1x2/rounds/*/materials-*.json`、`s1x3/variants/N4_selfplan.txt`、`s1x2/rounds/1/store-Q_place.json` | 真实应答原文、材料条数、离线检查的句数 / 编号 / 正文；4-Q_self 的收尾一句取 S1-X3 新栏里的原文；1-Q_place 存进反思库的 tags 与原文 |

重新生成（在仓库根，本机要有上面的 `.demo` 目录）：

```sh
python -I apps/npc_server/test/support/fixtures/reflection/regenerate.py .
```
