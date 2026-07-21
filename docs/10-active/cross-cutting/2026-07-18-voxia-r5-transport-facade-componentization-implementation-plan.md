# Voxia R5 Transport façade 组件化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans,
> superpowers:test-driven-development and superpowers:systematic-debugging task-by-task.

**Goal:** 保留 `UVoxiaTransportSubsystem` 的全部公共签名、TCP pump 与 GameInstance 生命周期入口，按批准
顺序把 baseline、near-window、confirmed stores、Interest/action 和旧 far build 的可变状态与自维护
不变量迁入独立组件，使 façade 不再成为跨领域状态所有者。

**Architecture:** 每次只迁移一个 owner。先为组件写纯值 RED 合同，再把状态、reset、时间性维护和纯
snapshot 物理移入组件；Transport 只传入外部依赖、转发原 API 并编排 TCP/HTTP 回调。调用方、wire、
CLI schema、错误文本、默认值、计数器、generation、可见效果和唯一生产根均保持不变。组件不能回查
Transport；旧 public API 在所有调用方迁移前不删除。

## 不变边界

- 不修改 wire codec/opcode/body、baseline H gate、完整 XYZ coverage、confirmed truth、movement 或场景入口。
- 不修改 public Transport 方法签名、CLI token/envelope/schema、observe event/field 或错误 reason。
- baseline 磁盘资产跨 session 保留；confirmed session reset 仍按原事务发布一次 revision。
- prepare worker 必须自行维护 timeout、stale quarantine、retry/failure epoch、physical fuse 与 generation。
- Interest/action gateway 必须自行维护 enqueue/send/ack/expiry、auto-flush cadence 与 reset。
- legacy VHI/SVO runtime 只服务显式 probe/compatibility；迁出 Transport 不得恢复为生产路径。
- 新增/修改代码注释使用中文。

### Task 1：R5 结构与 snapshot 合同

- [x] 冻结五个组件的 reset/generation/timeout/lease/snapshot 行为与稳定 contract label。
- [x] 增加 Transport façade reflection/static 门禁，禁止五类 owner 字段重新散回 façade。

### Task 2：baseline repository

- [x] 引入 `FVoxiaBaselineRepository`，迁移 HTTP/磁盘 metadata、pack index、路径、持久化状态与纯 snapshot。
- [x] façade 保留原 baseline API/HTTP callback，只通过 repository transition 执行 begin/apply/fail/reset。

### Task 3：near-window coordinator

- [x] 引入 `FVoxiaNearWindowCoordinator`，迁移 prepare state、worker gate/mailbox/tracker、WorldGen load queue、
  timeout/retry/lease/generation 与 snapshot。
- [x] façade 只注入 baseline/store/WorldGen 外部操作；同帧 Pump、stale result 与 fuse 语义保持。

### Task 4：confirmed world stores

- [x] 引入 `FVoxiaConfirmedWorldStores`，聚合 voxel、field、remote actor、object state、admission/residency counters。
- [x] session reset、revision 发布、resync throttle 与纯 snapshot 由组件维护；inbound façade 只 decode/委托。

### Task 5：Interest/action gateway

- [x] 引入 `FVoxiaInterestActionGateway`，迁移两个 outbox、result、auto-flush cadence、wire status 与 reset。
- [x] façade 只提供 `SendFrame` 回调和 inbound decoded payload；原 public getter/JSON 完整委托。

### Task 6：legacy far runtime

- [x] 引入 `FVoxiaLegacyFarBuildRuntime`，迁移 VHI/SVO pipeline、result、presentation/upload/fade/raymarch 状态。
- [x] 从 Transport 头删除旧 build owner 字段；旧 public probe API 继续委托且 production gate 不变。

### Task 7：验证、文档与提交

- [x] Development build 与五个 focused component/Transport Automation。
- [x] 全量 Automation 不少于 R4 的 77 项、0 failure/warning。
- [x] 唯一生产根 Null-RHI 25 路、production CLI 与显式 legacy probe CLI smoke。
- [x] 更新 Net/根 README 与治理进度，运行 `git diff --check`。
- [x] 分仓提交：client `refactor(governance): componentize transport facade`；outer
  `docs(voxia): record R5 transport facade`。

## 验证证据

- 客户端提交：`5f9e741`（`refactor(governance): componentize transport facade`）。
- Development build：`VoxiaEditor Win64 Development` 编译、UHT 与链接成功。
- focused Automation：`Voxia.Net` 为 `17/17 Success`，最终 coordinator timeout/lease 用例为 `1/1 Success`；
  覆盖五个组件的 reset/identity/snapshot、gateway cadence、时间性不变量和 Transport owner 防回散门禁。
- 全量 Automation：`83/83 Success`、0 failure、0 warning；产物
  `.demo/observe/voxia_governance_r5_timeout_owner_full_final_20260719/`。
- 唯一生产根 Null-RHI：25 路通过、clean exit、far release=`11/11/0`；产物
  `.demo/observe/voxia_phase1_2026-07-18T17-43-53-305Z_null_rhi_1280x720/`。
- production CLI：root `ready=true`、`session_ready=true`、`single_composition_root=true`；产物
  `.demo/observe/voxia_governance_r5_timeout_owner_production_cli_20260719.log`。
- 显式 legacy probe CLI：使用隔离 probe 参数启动，`near_mesh.present=true`、`rendered=true`；产物
  `.demo/observe/voxia_governance_r5_timeout_owner_legacy_probe_cli_20260719.log`。
- `git diff --check` 通过；客户端提交未触碰 wire codec、GameMode、统一根或 production actor 文件。
