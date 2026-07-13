# AGENTS.md — ex_mmo_cluster（Elixir/OTP MMORPG 集群）

> 本文件是本仓库**跨工具的工程准则单一来源**——**只保留约束性铁律与索引**。任何 AI 代理在本仓库工作前必读。
> 工程背景、技术栈、命令、结构、编码约定等较长参考内容已迁出，按需查阅：
> - 工程背景 / 技术栈 / 仓库结构 / 常用命令 / 编码约定 → [`docs/30-reference/engineering/project-engineering-guide.md`](docs/30-reference/engineering/project-engineering-guide.md)
> - Phoenix 1.8 / `phx.new` 专项规则 → [`docs/30-reference/engineering/phoenix-phx-new-guidelines.md`](docs/30-reference/engineering/phoenix-phx-new-guidelines.md)
> - 项目“此刻为真”的设计与实现状态 → [`docs/00-current-truth/README.md`](docs/00-current-truth/README.md)
> - 历史归档 / 证据源 → [`docs/20-archive/`（历史归档）· `docs/30-reference/`（长稳参考）](docs/20-archive/)

## 1. 项目与当前焦点

`ex_mmo_cluster` 是探索 MMORPG 风格分布式服务架构的 Elixir umbrella 项目（`gate_server`、`scene_server`、`world_server`、`agent_server`、`auth_server`、`data_service`、`beacon_server`、`mmo_contracts` 等），核心方向是**服务端权威**的移动、AOI、体素、局部场与物理现象运行时。当前推进重点是体素世界生产化（baseline = 算法基底 + delta + 轻量 H，见 [`docs/10-active/cross-cutting/voxel-server-authority-phase-overview.md`](docs/10-active/cross-cutting/voxel-server-authority-phase-overview.md)）与局部场运行时（Phase 7+）。Mnesia 相关 app 是迁移期兼容组件，不要把旧拓扑误认为最终架构。

**客户端口径（统一到 `docs/00-current-truth/`，覆盖任何旧文档的相反表述）**：

- `clients/Voxia`（UE5.8）是**当前真实联调焦点**——新功能、近场交互、远景 LOD、debug overlay、stdio CLI 的最新实跑证据在此。
- `clients/web_client` 是**仓库级默认 parity / oracle 参考**——协议字节序、decoder parity 默认以它验收。
- `clients/bevy_client` 是 **Rust 参考实现**。
- 不要把任一客户端误当协议唯一真值源：wire codec 真值以 `apps/gate_server/lib/gate_server/codec.ex` 为准。

## 2. 架构铁律

1. **服务端权威优先**：移动、AOI、战斗、体素、object state、field truth 等核心运行时状态以服务端 authority 为准。客户端可以预测、预览和呈现，但不能成为 confirmed truth 来源。
2. **confirmed voxel truth 只吃服务端**：在线客户端（Voxia / web / bevy）只能通过服务端 `ChunkSnapshot` / `ChunkDelta` / `VoxelIntentResult` / `ObjectStateDelta` / `FieldRegionSnapshot` 更新确认态；本地编辑只允许作为 preview、pending UI 或离线模式能力。体素编辑全程服务端权威、不做客户端乐观预测（点击只发 intent，等服务端广播 delta/快照才渲染）；乐观预测仅用于移动和技能特效。
3. **体素基线校验硬失败**：进入场景前必须校验客户端本地 world pack / region manifest / chunk baseline / diff chain 的完整性与版本；缺包、hash 不匹配、manifest 不一致、diff chain 断裂等都视为客户端数据不可被信任，必须拒绝进入场景并返回可诊断错误，禁止用运行时 `ChunkSnapshot`、resync、自愈逻辑或静默兜底绕过校验。
4. **边界清晰**：Gate 负责协议 decode / 鉴权 / 转发；World 负责事务、region / scene 路由和跨 app 编排；Scene / ChunkProcess 拥有 chunk hot truth 与 field runtime；DataService 负责 canonical persistence；客户端只消费权威结果。
5. **Field kernel 不直接改世界**：`FieldKernel` 只能演化 `FieldRegion` / `FieldLayer` 并产出结构化 `FieldEffect`；voxel / object / combat truth 写回必须经过 ChunkProcess 或明确的 authority dispatcher。
6. **跨 app 不绕边界**：跨 app 通信优先通过 Interface 模块、稳定公共 API、`BeaconServer.Client` 和既有 region routing；不要硬编码节点名、PID 或直接穿透别的 app 内部 worker。
7. **协议层只追加不破坏**：新增 wire 字段必须保持旧字段字节序和含义稳定；涉及客户端 decoder 的改动，默认以 `clients/web_client` parity / 字节序验收为准，并在 Voxia 侧补实跑验证。
8. **显式失败，不静默降级**：连接、鉴权、movement reconcile、voxel intent、field source、kernel effect、消息编解码、NIF 调用、持久化写入失败时，要返回可诊断错误并打结构化日志；禁止吞错后伪装成功。
9. **迁移期兼容要可见**：PostgreSQL 主路径与 Mnesia 遗留路径并存时，代码和文档必须标明当前来源、兼容原因、退出条件。
10. **唯一生产组合根**：每个客户端/可执行系统必须只有一个包含全部已批准成果的正式组合根，作为联合调试、效果测试和里程碑验收的唯一运行事实。参数、专用地图和 probe 可以隔离验证子系统，但必须显式标为 `probe/compatibility`，不得成为第二条“正式路径”，也不得用单模块通过冒充全系统完成。新成果只有接入唯一生产根、由根级 readiness/CLI 联合验证后，才可写成已进入正式客户端流程；迁移期子模块可以被根组合，但 GameMode/入口不得并列生成多个生产 world root。

### 2.1 架构设计指导思想（系统正交，最高纲领）

详见 [`docs/30-reference/overview/2026-06-27-架构设计指导思想-系统正交.md`](docs/30-reference/overview/2026-06-27-架构设计指导思想-系统正交.md)。动手/设计前先读并过其「开工前自查清单」。三条核心：

1. **系统正交**：每个系统只负责一件清晰的事；系统间只走**稳定契约**，不共享可变的隐式假设。改 A 莫名弄坏概念上无关的 B，就是隐藏耦合，是设计缺陷。
2. **自维护不变量**：一个系统对外承诺的**所有**不变量（**含活性/续租/超时/重连等时间性不变量**）必须由它**自己持续维护**；绝不让别的系统的正确性悄悄依赖一个**没人维护**的假设。警惕「一次性建立、之后没人管」的资源（订阅/lease/连接/缓存/content_version）静默失效。
3. **显式契约 > 隐式假设**：跨系统依赖要么**承诺方强制维护契约**，要么**依赖方对破坏鲁棒（自愈）**。

> 血泪案例：挖放体素「被接受却不显示」，根因是订阅缺活性维护、lease 静默过期（站着不动也会坏，移动是红鲱鱼）。诊断 bug 先排除红鲱鱼（问「这故障跟我以为的原因真有因果吗」）。

## 3. 工程方法约束

1. **CLI + 结构化日志优先**：客户端 / 服务端联调与验收优先使用 CLI 可观测接口和结构化日志，不把截图或视觉检查作为唯一判断依据。
2. **先定义可观测面再实现**：新增或修改交互式运行时逻辑前，先明确调试时需要从 CLI / 日志直接读到哪些状态、输入、输出、错误原因，再实现功能本身。
3. **非 GUI 调试面必须等价**：浏览器客户端也要提供等价的非 GUI 调试面，例如 `window` 暴露的命令入口、结构化 observe 日志、可导出的运行时快照。
4. **观察产物可复现、易清理**：默认写入 `.demo/observe/` 或显式配置的 observe 目录，便于自动化调试与回归。
5. **功能必须可验证、可测试、可操作**：不能只实现底层核心而让用户无法触发、无法观察、无法判断是否正确。
6. **用户交互必须三入口覆盖**：涉及用户交互的功能必须提供真实用户操作入口、自动化测试入口、CLI / 日志验证入口，并在最终验收中覆盖这些入口。
7. **禁止补丁式修复**：遇到 bug 先定位根因和边界归属，再修复；不要用局部 hack、吞错、硬编码等待、临时绕路掩盖架构问题。
8. **阶段性改动先有决策稿**：新增 phase、重排运行时边界、协议扩展、事务 / supervisor / field runtime 变化，应先在 `docs/10-active/<子系统>/` 写目标、范围、决策项、测试矩阵和进度日志（收口后移入 `docs/20-archive/`；文档分层见 `docs/README.md`）。
9. **不确定就查本仓真相源**：对 Phoenix / LiveView / Ecto / Rustler / 协议语义 / FieldRuntime / voxel 事务不确定时，先查本仓 README、阶段文档、协议文档、目录 README 和现有测试，再动手。
10. **复杂任务职责隔离**：复杂改动尽量把设计、实现、验证分开做；最终说明中要区分实现内容、验证证据和残余风险。
11. **代码旁文档同步维护**：
   - Elixir 公共模块补 `@moduledoc`，公共函数补 `@doc`。
   - Rust 公共模块补 `//!`，公共类型 / 函数补 `///`。
   - 稳定子系统目录（如 `movement/`、`combat/`、`npc/`、`worker/`、`sup/`、客户端子目录）应有 `README.md` 说明职责、结构和关系。
   - 涉及监督树、运行时分层、协议层与实现层关系变化的修改，必须同步更新最近的目录 README 或阶段进度文档。
12. **写文档时活用 mermaid 图**对概念、流程、所有权、阶段边界进行解释。
13. **代码中的所有注释统一用中文。**

## 4. 推荐工作流

1. **定位影响范围**：先判断改动属于哪个 app、客户端、协议层、NIF、数据层、voxel、field runtime 或文档主线。
2. **读最近文档**：优先读所在目录 `README.md`、`docs/00-current-truth/`、相关阶段文档和测试入口。体素 / 局部场相关改动先读 [`docs/10-active/cross-cutting/voxel-server-authority-phase-overview.md`](docs/10-active/cross-cutting/voxel-server-authority-phase-overview.md) 与 [`docs/10-active/field-emergence/2026-05-16-phase7-local-field-runtime-roadmap.md`](docs/10-active/field-emergence/2026-05-16-phase7-local-field-runtime-roadmap.md)。
3. **设计可观测性**：定义 CLI / observe 产物字段，尤其是连接状态、输入意图、movement 坐标、voxel target、field source、region id、消息收发、错误原因。
4. **实现与文档同步**：代码、测试、README / 阶段文档一起改；协议、监督树、事务、field runtime 或 authority 边界变化必须落文档。
5. **验证闭环**：优先跑最小相关测试，再跑必要的 client / smoke；验收说明必须列出命令和可复现产物位置。

## 5. 验证入口

- 根级常规验证：`mix compile`、`mix test`。根 `mix.exs` 当前没有 `precommit` alias，不要假设 `mix precommit` 在 umbrella 根可用。
- Phoenix app 验证：`cd apps/auth_server && mix precommit`、`cd apps/visualize_server && mix precommit`。
- 单 app 测试：`cd apps/<app> && mix test --no-start`，按影响范围选择。
- Web client 验证：`cd clients/web_client && npm test`；涉及构建 / 类型边界时补 `npm run build`。
- WebSocket 双客户端 smoke：`node scripts/run_ws_dual_smoke_supervised.js`，结构化产物写入 `.demo/observe/`。
- Voxia 客户端 CLI：`node clients/Voxia/scripts/voxia_stdio_cli.js --cmd "..."`；服务端 CLI：`elixir --sname voxia_server_cli --cookie mmo scripts/voxia_server_stdio_cli.exs --cmd "..."`。
- 完整命令清单见 [`docs/30-reference/engineering/project-engineering-guide.md`](docs/30-reference/engineering/project-engineering-guide.md) 与 [`docs/00-current-truth/impl/README.md`](docs/00-current-truth/impl/README.md)。

## 6. 关键路径（索引）

- 项目“此刻为真”入口：[`docs/00-current-truth/README.md`](docs/00-current-truth/README.md)（含模块表、实现速查、已知缺口）
- 工程背景 / 技术栈 / 命令：[`docs/30-reference/engineering/project-engineering-guide.md`](docs/30-reference/engineering/project-engineering-guide.md)
- Phoenix phx.new 规则：[`docs/30-reference/engineering/phoenix-phx-new-guidelines.md`](docs/30-reference/engineering/phoenix-phx-new-guidelines.md)
- 系统正交设计纲领：[`docs/30-reference/overview/2026-06-27-架构设计指导思想-系统正交.md`](docs/30-reference/overview/2026-06-27-架构设计指导思想-系统正交.md)
- 线协议：[`docs/30-reference/protocol/2026-04-10-线协议规范.md`](docs/30-reference/protocol/2026-04-10-线协议规范.md)（真值以 `apps/gate_server/lib/gate_server/codec.ex` 为准）
- 体素权威主索引：[`docs/10-active/cross-cutting/voxel-server-authority-phase-overview.md`](docs/10-active/cross-cutting/voxel-server-authority-phase-overview.md)
- 体素 baseline 边界决策：[`docs/30-reference/protocol/2026-06-29-voxel-baseline-streaming-boundary.md`](docs/30-reference/protocol/2026-06-29-voxel-baseline-streaming-boundary.md)
- 体素同步 / 窗口 / 渲染设计：[`docs/30-reference/protocol/2026-06-29-voxel-sync-window-and-render-design.md`](docs/30-reference/protocol/2026-06-29-voxel-sync-window-and-render-design.md)
- Phase 7 局部场路线图：[`docs/10-active/field-emergence/2026-05-16-phase7-local-field-runtime-roadmap.md`](docs/10-active/field-emergence/2026-05-16-phase7-local-field-runtime-roadmap.md)
- 当前会话 / 后续接力：[`docs/10-active/cross-cutting/_session-handoff.md`](docs/10-active/cross-cutting/_session-handoff.md)
- 客户端：[`clients/Voxia/README.md`](clients/Voxia/README.md)、[`clients/web_client/README.md`](clients/web_client/README.md)、[`clients/bevy_client/README.md`](clients/bevy_client/README.md)
