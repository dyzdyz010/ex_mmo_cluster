# 玩家使用遥测（商业验证最小埋点）

分类：全局系统功能；测试为 Test-only。日期：2026-11-10（2026-11-22 从 `telemetry-20261110` 的未提交工作移植到 master `1069899a`）。
状态：**已实现，未部署，未真实客户端实跑**。

## 目的与契约

目前 `auth_sessions` 没有创建时间，无法计算 D1/D7 留存与游玩时长。本项只追加三类事件到既有 `auth_audit`
（actor=`gate`，object_id=账号 id，不记邮箱），不新建表、不读不改任何账号或世界真值：

| 事件 | 触发点 | details |
|---|---|---|
| `session_start` | Gate Join 被接纳且 `Session.claim` 成功 | `{}` |
| `session_end` | `QuicConnection.terminate`（仅当已 Join） | `duration_s`（整秒，单调时钟）、`reason`（`close/3` 的原因，或 terminate 原因） |
| `first_edit` | 世界意图经 `Intent.run` 返回 `{:ok, _}`（服务端确认）后 | `{}`；每账号终身一行，由语句内 `NOT EXISTS` 保证，每个编辑 worker 至多触发一次 SQL |

没有账号的角色（NPC）不记。写库在一次性 Task 中，失败只记 `telemetry_failed` 警告，不影响会话，不重试。
`first_edit` 是"首个被确认的世界意图"（挖、放、建造、生产等），不区分具体动作。

## 查询示例

D1：对 `register`（`accounts.inserted_at`）后第 1 个日历日有 `session_start` 的账号占比；
时长：`details->>'duration_s'` 汇总；漏斗：注册 → `session_start` → `first_edit`。

## 验证与未验证

- 已测（真实 PostgreSQL，本 VM 独占库）：`data_service/test/data_service/player_telemetry_test.exs` 5 项；
  `gate_server/test/gate_server/telemetry_test.exs` 3 项。删去 `NOT EXISTS` 后"终身一行"用例按预期失败。
  "写库失败只记警告"用例断言 `telemetry_failed` 日志确实发出。
- 2026-11-22 移植后（WSL，OTP 29.1.2 / Elixir 1.20.5）：umbrella `mix compile --warnings-as-errors` 通过，接线已编译；
  `gate_server` 的 `--only quic_transport`（真实 QUIC，62 通过）与其余用例（43 通过）全绿。QUIC 用例里能看到
  入场后 `session_start` 被调用、正常关闭时 `session_end` 被调用（用例不建库，写库失败只出警告，不影响会话）。
  `voxim_prefab_publish_dispatch_test.exs` 的 state 夹具补上 Dispatch 契约里的 `:cid`。
- 未验证：真实双端；生产部署。
- `session_end` 只在连接进程走 `{:stop, …}` 正常结束时写入（对端关闭 → `{:quic, :closed, …}`、鉴权会话失效）。
  连接进程不捕获退出信号，因此被 `:kill` 或被监督者以 `:shutdown` 停掉（例如节点停机、发版重启）时 `terminate`
  不执行，这些会话没有 `session_end`。统计时长要容忍缺失，必要时以最后一次事件为界。
