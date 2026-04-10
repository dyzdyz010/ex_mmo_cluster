# gate_server 协议补全计划

**快照日期：** 2026-04-10

本文专门聚焦 `gate_server`，回答三个问题：

1. **现在已经实现了什么？**
2. **距离“协议完整”还缺什么？**
3. **建议按什么顺序继续实现？**

相关文档：

- `2026-04-10-线协议规范.md` —— 当前线上线格式定义
- `2026-04-10-传输协议现状与后续规划.md` —— 传输层现状与未来 TCP + UDP/KCP 分流计划
- `2026-04-07-增量迁移计划.md` —— 仓库级迁移路线图

主要代码入口：

- `apps/gate_server/lib/gate_server/application.ex`
- `apps/gate_server/lib/gate_server/worker/interface.ex`
- `apps/gate_server/lib/gate_server/worker/tcp_acceptor.ex`
- `apps/gate_server/lib/gate_server/worker/tcp_connection.ex`
- `apps/gate_server/lib/gate_server/codec.ex`

---

## 1. 执行摘要

`gate_server` 已经完成了**协议格式迁移**：

- 已经切到自定义二进制消息
- TCP 已使用 `{packet, 4}` 做长度前缀分帧
- `GateServer.Codec` 已经是运行时实际使用的编解码器
- scene 的 AOI 广播已经能通过 gate 回推给客户端

但 `gate_server` **还没有完成协议行为层**。

当前主要缺口有：

- 连接状态机没有真正落地
- 请求/响应关联字段（`packet_id`）只完成了一半
- 错误语义过于粗糙
- auth / session / cid 绑定还不完整
- time sync 还不是一个正式可用的同步协议
- 现有测试主要覆盖 codec / framing，没有覆盖连接级协议规则

当前实现最准确的描述是：

> **线格式已经完成，协议契约还没有完成。**

另外一个重要补充是：

> gate ↔ auth 的验证调用本身现在已经存在，后续 auth 相关工作更偏向
> **会话绑定和协议语义补全**，而不是“先找一个缺失的 verifier”。

---

## 2. 目前已经实现的部分

## 2.1 监督树与运行时结构

`gate_server` 当前会启动三个核心部分：

- interface supervisor
- TCP acceptor supervisor
- TCP connection supervisor

参考：

- `apps/gate_server/lib/gate_server/application.ex`

这已经足够支撑：

- 一个监听 acceptor
- 每个客户端 socket 对应一个 `TcpConnection` 进程

---

## 2.2 服务发现与依赖解析

`GateServer.Interface` 当前会：

- 通过 `beacon_server` 加入集群发现
- 注册 `:gate_server`
- 等待 `:scene_server`
- 懒加载解析 `:auth_server`

参考：

- `apps/gate_server/lib/gate_server/worker/interface.ex`

当前重要行为：

- `scene_server` 在启动时被视为必需依赖
- `auth_server` 在启动时被视为可选依赖，按需查找

这意味着：

- scene 相关路径默认应该可用
- auth 相关协议路径必须能容忍 auth 暂时不可达

---

## 2.3 传输与分帧

gate 当前仍然是 **TCP-only**：

- `:gen_tcp.listen(..., [:binary, packet: 4, active: true, reuseaddr: true])`

参考：

- `apps/gate_server/lib/gate_server/worker/tcp_acceptor.ex`

这与 `2026-04-10-线协议规范.md` 中的现行规格一致。

---

## 2.4 当前 codec 覆盖范围

`GateServer.Codec` 当前已支持：

### 客户端 → 服务端

- `Movement`
- `EnterScene`
- `TimeSync`
- `Heartbeat`
- `AuthRequest`

### 服务端 → 客户端

- `Result`
- `PlayerEnter`
- `PlayerLeave`
- `PlayerMove`
- `EnterSceneResult`
- `TimeSyncReply`
- `HeartbeatReply`

参考：

- `apps/gate_server/lib/gate_server/codec.ex`

也就是说，gate 的核心线上路径已经不再依赖 protobuf。

---

## 2.5 当前 happy path 流程

当前运行中的大致流程如下：

1. 客户端通过 TCP 建连
2. 创建 `TcpConnection`
3. 客户端发送自定义二进制消息
4. gate 通过 `GateServer.Codec.decode/1` 解码
5. gate 分发到 scene / auth 逻辑
6. gate 通过 `GateServer.Codec.encode/1` 回包或广播

参考：

- `apps/gate_server/lib/gate_server/worker/tcp_connection.ex`
- `apps/gate_server/lib/gate_server/codec.ex`

当前已实现的分发包括：

- `{:movement, ...}` → `SceneServer.PlayerCharacter`
- `{:enter_scene, cid}` → `SceneServer.PlayerManager`
- `:time_sync` → `SceneServer.PlayerCharacter`
- `{:heartbeat, ...}` → gate 直接回复
- `{:auth_request, username, code}` → `auth_server`

scene 侧广播也已经连通：

- `{:player_enter, ...}`
- `{:player_leave, ...}`
- `{:player_move, ...}`

这些广播来自 scene AOI 逻辑，再推回当前 TCP 客户端连接。

---

## 3. 目前还不完整的部分

## 3.1 状态机只存在于 state 字段里，没有体现在行为里

`TcpConnection` 的 state 当前包含：

- `status: :waiting_auth`
- `status: :authenticated`
- `scene_ref`
- `cid`
- `agent`

参考：

- `apps/gate_server/lib/gate_server/worker/tcp_connection.ex`

但实现里并没有系统性地强制协议顺序。

明显例子：

- `enter_scene` 并不要求已经认证
- `movement` 并不要求已经认证
- `movement` 默认假设 `scene_ref` 已存在
- `time_sync` 默认假设 `scene_ref` 已存在

这说明现在的协议行为仍然过度依赖 happy path。

### 影响

- 非法消息顺序不会被统一归一化成协议错误
- 某些非法状态仍然可能导致崩溃或非常模糊的失败
- 后续继续扩协议时风险会越来越大

### 一个当前可观察的具体风险

`tcp_closed` 路径已经能容忍 `scene_ref == nil`，但 `tcp_error` 仍然默认认为 scene 进程一定存在，并无条件调用 `GenServer.call(spid, :exit)`。

也就是说：

- 如果连接还没 `EnterScene` 就发生 TCP error
- 当前错误处理路径仍然可能触发不必要的失败

---

## 3.2 请求/响应关联只做了一半

`2026-04-10-线协议规范.md` 里为服务端回复定义了 `packet_id`。

但当前运行时基本都在发送：

- `packet_id = 0`

典型位置包括：

- movement reply
- enter-scene reply
- auth result

与此同时，当前客户端请求消息里又**没有** request id。

### 影响

- 客户端无法可靠地把响应和请求对应起来
- 线格式里虽然有这个字段，但运行时语义是空的
- 如果后面再上更复杂客户端行为，迟早还得返工

### 必须做出的决策

二选一：

1. 直接删除 `packet_id`，保持简化同步模型
2. 保留 `packet_id`，给请求也补上 request id，让关联真正成立

建议：**保留，并做成真实语义**。

---

## 3.3 错误语义过于粗糙

当前错误处理大致是：

- decode 失败 → 只打日志
- auth 失败 → 通用 `Result error`
- enter-scene 失败 → 通用 `EnterSceneResult error`

目前缺少明确的协议级错误分类，例如：

- unauthenticated
- invalid_state
- malformed_payload
- auth_unavailable
- scene_unavailable
- cid_mismatch
- already_in_scene
- not_in_scene

### 影响

- 客户端拿到的信息太少
- 协议问题排查困难
- 回退、重试、降级逻辑都很难设计干净

---

## 3.4 Auth 语义没有真正和会话绑定起来

当前 `AuthRequest` 包含：

- `username`
- `code`

但 gate 当前实际上只验证 `code`。

`username` 虽然被 decode 出来了，但在 gate 路径里没有被真正参与约束。

### 影响

- 身份绑定强度不够
- token claims、请求用户名、激活角色、当前连接之间没有形成闭环
- 未来做多角色、重连恢复时很难可信

### 这里要特别说明

- `AuthServer.AuthWorker.verify_token/1` 现在已经存在，也能验证签名 token
- 当前真正缺的，是 gate 没有把“已验证 claims”强约束到 username / cid / session 规则上

---

## 3.5 CID 所有权语义不清晰

当前 movement 请求里带了客户端提供的 `cid`，但 gate 在分发路径里实际上并不信任这个值，而是用 `state.cid` 回包。

这说明协议层还没有把这些问题定义清楚：

- 客户端能不能在每条消息里自由指定 cid？
- cid 是不是应该被连接会话固定？
- `EnterScene` 是否意味着“该连接只激活一个当前角色”？

### 影响

- 协议语义不清楚
- 客户端和服务端很容易各自理解出不同的“活跃角色”含义

建议方向：

> `EnterScene` 应该负责为该连接建立“当前活跃角色”，之后 movement 应该绑定到连接状态，而不是继续信任任意客户端传入 cid。

---

## 3.6 Time sync 还只是占位语义

当前流程大致是：

- gate 把 `TimeSync` 转发给 scene player
- scene 在时间戳状态和 `:end` 之间切换
- gate 可能回一个最简 `TimeSyncReply`

但当前 reply 负载太少，不足以支持正式同步协议。

### 影响

- 客户端无法做正式 RTT / offset 计算
- scene 层承担了很多本应更靠近 gate/session 的网络时间逻辑
- 现在的行为很难被视为一个清晰的正式协议

建议方向：

改为显式 request/reply，同步信息至少足够支持：

- RTT 估算
- offset 估算
- jitter 观察

---

## 3.7 测试在 codec 层不错，但连接级协议测试不足

当前已有测试主要覆盖：

- 二进制 decode / encode
- codec 边界值
- TCP framing 行为

参考：

- `apps/gate_server/test/gate_server/codec_test.exs`
- `apps/gate_server/test/gate_server/codec_edge_cases_test.exs`
- `apps/gate_server/test/gate_server/codec_dispatch_test.exs`
- `apps/gate_server/test/gate_server/tcp_framing_test.exs`

当前缺的测试类别包括：

- 未认证时 `EnterScene` 是否被拒绝
- 未进场景时 `Movement` 是否被拒绝
- 非法状态是否返回稳定错误
- auth 不可用时是否返回稳定协议错误
- scene 不可用时是否返回稳定协议错误
- cid 不匹配时如何处理
- 连接 teardown / cleanup 是否可靠
- time sync 是否符合文档约定

所以当前协议依然是：

> **codec 层测试比较好，行为契约层测试明显不足。**

---

## 4. 建议的目标协议契约

## 4.1 连接状态机

建议状态：

```text
connected
  -> authenticated
  -> in_scene
  -> closed
```

建议允许消息：

| 状态 | 允许消息 |
|---|---|
| `connected` | `AuthRequest`, `Heartbeat` |
| `authenticated` | `EnterScene`, `Heartbeat`, 可选 `TimeSync` |
| `in_scene` | `Movement`, `TimeSync`, `Heartbeat` |
| `any` | 连接关闭处理 |

建议规则：

- 非法消息顺序必须返回明确协议错误
- 不能再静默忽略非法状态跳转

---

## 4.2 身份与会话规则

建议规则：

1. `AuthRequest` 用于认证连接
2. auth 成功后把 claims / session 上下文保存进连接状态
3. `EnterScene(cid)` 必须在 auth 之后才能调用
4. `EnterScene(cid)` 必须验证该 `cid` 是否属于当前认证身份
5. `EnterScene` 成功后，该连接拥有一个明确的活跃 `cid`
6. 后续 movement 必须作用在这个连接绑定的活跃角色上

这会把以下几层真正闭合起来：

- token
- username
- character id
- scene process

---

## 4.3 结果与错误模型

建议为 `Result` 类消息定义统一错误码族：

| Code | Meaning |
|---|---|
| `0x00` | ok |
| `0x01` | malformed_message |
| `0x02` | unauthenticated |
| `0x03` | invalid_state |
| `0x04` | auth_unavailable |
| `0x05` | scene_unavailable |
| `0x06` | cid_mismatch |
| `0x07` | already_in_scene |
| `0x08` | not_in_scene |
| `0x09` | internal_error |

`EnterSceneResult` 可以有两种方向：

- 保留专用消息，但对齐同一套错误码语义
- 或者收敛成更统一的 Result 风格

两种都可以，关键是：

> **一致性比风格更重要。**

---

## 4.4 请求关联

建议目标是：

- 所有需要直接响应的请求，都携带 `request_id`

候选消息：

- `AuthRequest`
- `EnterScene`
- `TimeSync`
- 可选 `Heartbeat`
- 如果 movement 仍然保留 ack，也可以给 `Movement` 加

这样 `packet_id` 才会真正有意义，也能为以后双通道演进留好空间。

---

## 4.5 Time sync 重设计

建议形态：

### 客户端 → 服务端

`TimeSyncRequest`

- `request_id`
- `client_send_ts`

### 服务端 → 客户端

`TimeSyncReply`

- `request_id`
- `client_send_ts`
- `server_recv_ts`
- `server_send_ts`

这样客户端就能算出：

- RTT
- offset
- jitter 趋势

除非有非常强的 gameplay 原因，否则 time sync 更适合留在 gate/session 层，而不是放在 scene player 行为里。

---

## 5. 建议的实施阶段

## Phase A —— 先把当前 TCP 契约改成 fail-closed

目标：

- 在不改消息布局的前提下，先把当前 TCP 协议做安全、做稳

2026-04-10 实施进展：

- `TcpConnection` 已开始强制关键状态顺序：
  - auth 后才能 `EnterScene`
  - 进入场景后才能 `Movement` / `TimeSync`
- `auth_server` / `scene_server` 不可用路径已改为 fail-closed
- `tcp_error` 对 `scene_ref == nil` 已做安全处理
- 新增了行为级协议测试：`apps/gate_server/test/gate_server/tcp_connection_protocol_test.exs`

任务：

1. 在 `TcpConnection` 中落实连接状态跳转
2. 明确拒绝非法消息顺序
3. 统一错误回复语义
4. 所有 `scene_ref` / auth 依赖改为 fail-closed
5. 用连接级行为测试覆盖以上规则

这一阶段的明确**非目标**：

- 不做 request-id 线格式改造
- 不改 time-sync 包结构
- 不开始做 UDP/KCP

最可能变更的文件：

- `apps/gate_server/lib/gate_server/worker/tcp_connection.ex`
- `2026-04-10-线协议规范.md`
- `apps/gate_server/test/gate_server/tcp_connection_protocol_test.exs`

---

## Phase B —— 补齐 auth / cid / session 绑定

目标：

- 让“已认证身份”和“当前活跃角色所有权”真正可信

2026-04-10 实施进展（真实来源校验补充）：

- `data_service` 新增了按用户名查询账户与按账号校验角色归属的 worker/dispatcher 接口
- `AuthServer.Accounts` 现在以 `data_service` 作为主数据来源，而不是旧 Mnesia 账户表
- `AuthServer.AuthWorker.authorize_character/2` 已引入真实账户/角色归属校验
- `GateServer.TcpConnection` 在 `EnterScene` 前会先走 claim-based 约束，再走 auth 节点的真实角色归属校验
- gate/auth/data 相关测试已覆盖允许归属、拒绝归属与数据源可用路径

2026-04-10 实施进展：

- `AuthRequest.username` 已开始与 token claims 中的用户名进行一致性校验
- auth 成功后，连接会保存显式 session 上下文（包括 `username`、`session_id`、claims）
- 当 token claims 中声明了 `cid` 或 `allowed_cids` 时，`EnterScene(cid)` 会执行约束校验
- 当 token claims 未声明 cid 约束时，系统会继续进入 auth 节点的真实角色来源校验
- 新增 / 更新了以下测试：
  - `apps/auth_server/test/auth_server/auth_worker_test.exs`
  - `apps/gate_server/test/gate_server/tcp_connection_protocol_test.exs`

任务：

1. 用清晰结构把 auth claims 绑定到连接 state
2. 定义 `username`、token claims 与 `cid` 的一致性规则
3. 强制 `EnterScene` 必须在 auth 之后
4. 明确连接上“当前活跃角色”的所有权语义

最可能变更的文件：

- `apps/gate_server/lib/gate_server/worker/tcp_connection.ex`
- `apps/auth_server/lib/auth_server/auth_worker.ex`
- `apps/auth_server/lib/auth_server_web/controllers/ingame_controller.ex`
- 以及可能涉及的 scene/auth 对外接口

---

## Phase C —— 让 request/reply 关联真正成立

目标：

- 在行为契约稳定之后，再解决只做了一半的关联语义

2026-04-10 实施进展：

- `AuthRequest`、`EnterScene`、`Movement`、`TimeSync` 已支持 request_id 新格式
- Gate 对上述新格式请求已开始在响应中回显对应 `packet_id`
- 旧请求兼容分支已移除，当前主线协议统一采用新格式
- 扩展了 codec 与 gate 协议测试以覆盖 request_id 回显行为

任务：

1. 确认是否保留 request id
2. 如果保留，则把 request id 补进请求消息布局
3. 把 request id 正式传递进响应
4. 同步更新测试和协议文档

最可能变更的文件：

- `2026-04-10-线协议规范.md`
- `apps/gate_server/lib/gate_server/codec.ex`
- `apps/gate_server/test/gate_server/codec_test.exs`

---

## Phase D —— 重做 time sync

2026-04-10 实施进展：

- `TimeSync` 已从 scene 内部占位逻辑迁回 gate 级连接协议
- 当前请求格式为 `request_id + client_send_ts`
- 当前响应格式为 `packet_id + client_send_ts + server_recv_ts + server_send_ts`
- `TimeSync` 现在在 `authenticated` 与 `in_scene` 状态都允许
- 兼容分支已移除，当前文档以新格式为唯一主线规范


目标：

- 让 time sync 变成一个正式可用的网络时间同步特性，而不是占位响应

任务：

1. 定义正式 request/reply 时间同步协议
2. 决定时间同步逻辑属于 gate 还是 scene
3. 去掉现在 toggle 式的 `:end` 行为
4. 增加 roundtrip 测试

最可能变更的文件：

- `2026-04-10-线协议规范.md`
- `apps/gate_server/lib/gate_server/codec.ex`
- `apps/gate_server/lib/gate_server/worker/tcp_connection.ex`
- 如果 scene 仍保留部分时序逻辑，还会涉及 `apps/scene_server/lib/scene_server/worker/player_character.ex`

---

## Phase E —— 等协议契约稳定后，再整理 gate 文档入口与应用说明

目标：

- 去掉模板味，文档和当前真实实现对齐

建议更新：

1. 保持 `apps/gate_server/README.md` 为轻量入口索引
2. 围绕当前运行时职责完善 `apps/gate_server/docs/2026-04-10-应用说明.md`
3. 在应用说明中链接到 `2026-04-10-线协议规范.md` 和本文
4. 去掉旧“Hex package / 模板应用”式表述

建议涉及文件：

- `apps/gate_server/README.md`
- `apps/gate_server/docs/2026-04-10-应用说明.md`
- 如果入口导航有变化，可能还要改 `README.md`

---

## Phase F —— 在 TCP 契约稳定后，补广义协议行为测试

目标：

- 证明的是协议行为，而不只是二进制布局

建议新增测试：

1. 未认证 `EnterScene` 被拒绝
2. 未认证 `Movement` 被拒绝
3. `EnterScene` 前 `Movement` 被拒绝
4. auth 不可用时返回稳定协议错误
5. scene 不可用时返回稳定协议错误
6. auth 成功后连接状态正确更新
7. enter-scene 成功后连接状态正确更新
8. cid 非法 / 状态非法时返回稳定错误
9. time sync 返回的负载符合文档约定

建议新增文件：

- `apps/gate_server/test/gate_server/tcp_connection_protocol_test.exs`
- `apps/gate_server/test/gate_server/integration_protocol_test.exs`

---

## Phase G —— 只有 TCP 真的稳定后，再分离高频流量

目标：

- 把高频流量迁移到 UDP/KCP，同时不把当前语义混乱带过去

2026-04-10 实施进展：

- fast-lane attach bootstrap 已实现（TCP ticket + UDP attach ACK）
- movement uplink 已迁入 UDP fast lane
- 当前尚未迁移 `PlayerMove` 下行广播，仍属于下一步执行阶段

依赖关系：

- 这一阶段应该在 **Phase A–F 都完成之后** 再开始

原因：

- 否则传输层复杂度会把现有会话/协议语义问题进一步放大

参考：

- `2026-04-10-传输协议现状与后续规划.md`

---

## 6. 按文件看，接下来各自要做什么

## `apps/gate_server/lib/gate_server/worker/tcp_connection.ex`

需要补的内容：

- 显式状态守卫
- 稳定的错误回包 helper
- fail-closed 依赖处理
- auth / session 校验

**第一补丁**最应该聚焦：

- auth-before-enter-scene
- enter-scene-before-movement/time-sync
- nil-safe 的 `tcp_error` / scene cleanup
- invalid-state / unavailable-service 的稳定回复

后续补丁再做：

- request/reply 关联
- cid/session 更细的绑定校验

这是协议补全里最关键的实现文件。

## `apps/gate_server/lib/gate_server/codec.ex`

需要补的内容：

- 最终版 request/reply 字段设计
- request id 相关字段
- 更丰富的错误负载
- time-sync 新消息布局

它是当前运行时二进制布局的单一事实来源。

## `2026-04-10-线协议规范.md`

需要补的内容：

- 和实际运行时行为完全对齐
- 去掉“只写了一半”的语义
- 固化最终 request/reply 与错误模型
- 增加状态/顺序章节，明确客户端哪些消息在什么阶段合法

## `apps/gate_server/test/...`

需要补的内容：

- 行为级协议测试
- 而不只是 codec/framing 测试

## `apps/gate_server/docs/2026-04-10-应用说明.md`

需要补的内容：

- 文档现代化
- 当前协议概览
- 链到 `2026-04-10-线协议规范.md` 和本文

当前 gate 文档主体应位于 `docs/`，README 只保留为入口索引。

---

## 7. 建议的“立即下一步”

`真实角色来源校验` 的第一轮已经完成。现在最值得继续推进的是：

### 新的立即里程碑

**“PlayerMove 下行广播迁入 UDP fast lane”**

定义：

- 在现有 UDP movement uplink 的基础上，把高频 `PlayerMove` 下行广播迁入 UDP
- 让附着的 UDP peer 接收更低延迟的玩家移动广播
- 保持当前 TCP 主通道仍可承载可靠控制流
- 不破坏当前已收口的身份、角色归属与时间同步边界

这一里程碑的明确**非目标**：

- 不回退当前已收口的 gate/auth/data 身份边界
- 不重新引入旧协议兼容分支

完成这一步之后，再顺序推进：

- transport-level rollout and operational hardening

---

## 8. 最终判断

当前 `gate_server` 已经不再卡在线格式上。

它现在的核心问题是：

> **协议语义还没收口，而不是序列化没有做好。**

所以最稳妥的补全路线应该是：

> **先把 TCP 协议契约做稳，再去拆分高频流量。**

这是当前风险最低、后续维护性最好的实现路径。
