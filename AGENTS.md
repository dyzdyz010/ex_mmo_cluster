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

- 同级 `../Voxim`（UE5.8）是**当前主线客户端与联调焦点**；路线以其 `starter.md`、`Docs/M1/plan.md` 和 brief 为准。`clients/Voxia` 仅作算法、行为与性能参考。
- `clients/web_client` 与 `clients/bevy_client` 是**逻辑归档客户端**——代码和历史证据保留原位，默认不读取、不开发、不验证、不进入 CI / 发布 / 进度判断；只有用户显式点名时才临时纳入任务。
- 现行 Session/Voxel wire SSOT 是纯 `apps/mmo_contracts/lib/mmo_contracts/{session,voxel}/codec.ex` 与 `voxel/payload.ex`；旧 Gate codec 只保留有活调用方的旧领域。G0 的 31 个冻结字节不能随抽取重捕获。

## 2. 架构铁律

1. **服务端权威优先**：移动、AOI、战斗、体素、object state、field truth 等核心运行时状态以服务端 authority 为准。客户端可以预测、预览和呈现，但不能成为 confirmed truth 来源。
2. **confirmed voxel truth 只吃服务端**：Voxim 在线确认态只接受服务端 region payload、日志/事务与意图结果；Voxia 的旧 snapshot/delta/object/field 协议是参考实现；归档 Web / Bevy 若被用户显式临时纳入，也必须遵守同一规则。本地编辑只允许作为 preview、pending UI 或离线模式能力。体素编辑全程服务端权威、不做客户端乐观预测（点击只发 intent，等服务端广播 delta/快照才渲染）；乐观预测仅用于移动和技能特效。
3. **体素基线的权威接纳边界**：客户端本地 world pack / region manifest / chunk baseline / diff chain 的强制入场校验及缺包拒绝规则仅属 **legacy/reference（Voxia 旧客户端契约）**，不作为 Voxim 入场前置条件。Voxim 当前 R6 消费服务端 region payload、日志/事务与意图结果，经既有 canonical 管线形成确认态；M1 计划由完整权威 R6 L0 payload 的 CanonicalBootstrap 接入同一管线，全部规定 L0 驻留、初始 collider 建好且同 T/N/R 的 TimelineFence 已消费才发 Ready（详见 [`../Voxim/Docs/M1/plan.md §2`](../Voxim/Docs/M1/plan.md)）。实际不完整或身份/版本不符的权威来源仍必须显式拒绝，不得把缺失当空气或用本地包、snapshot/resync 静默兜底；该 bootstrap/Ready runtime **待实施**，G1 仅完成字节 owner 抽取。
4. **边界清晰**：Gate 负责协议 decode / 鉴权 / 转发；World 负责事务、region / scene 路由和跨 app 编排；Scene / ChunkProcess 拥有 chunk hot truth 与 field runtime；DataService 负责 canonical persistence；客户端只消费权威结果。
5. **Field kernel 不直接改世界**：`FieldKernel` 只能演化 `FieldRegion` / `FieldLayer` 并产出结构化 `FieldEffect`；voxel / object / combat truth 写回必须经过 ChunkProcess 或明确的 authority dispatcher。
6. **跨 app 不绕边界**：跨 app 通信优先通过 Interface 模块、稳定公共 API、`BeaconServer.Client` 和既有 region routing；不要硬编码节点名、PID 或直接穿透别的 app 内部 worker。
7. **按阶段冻结协议**：G1 必须保持 G0 Session/Voxel 全部字节与含义；新 Movement 按 Voxim M1 合同另行冻结，**无旧移动兼容义务**。现行 codec SSOT 在纯 mmo_contracts，以其 golden 与 Voxim decoder 验证。旧 Gate/NPC/战斗有活调用方时保留；归档 Web / Bevy parity 不作门禁。
8. **显式失败，不静默降级**：连接、鉴权、movement reconcile、voxel intent、field source、kernel effect、消息编解码、NIF 调用、持久化写入失败时，要返回可诊断错误并打结构化日志；禁止吞错后伪装成功。
9. **迁移期兼容要可见**：PostgreSQL 主路径与 Mnesia 遗留路径并存时，代码和文档必须标明当前来源、兼容原因、退出条件。
10. **唯一生产组合根**：每个客户端/可执行系统必须只有一个包含全部已批准成果的正式组合根，作为联合调试、效果测试和里程碑验收的唯一运行事实。参数、专用地图和 probe 可以隔离验证子系统，但必须显式标为 `probe/compatibility`，不得成为第二条“正式路径”，也不得用单模块通过冒充全系统完成。新成果只有接入唯一生产根、由根级 readiness/CLI 联合验证后，才可写成已进入正式客户端流程；迁移期子模块可以被根组合，但 GameMode/入口不得并列生成多个生产 world root。
11. **体素空间契约只认完整 XYZ**：近场窗口、远景壳、page/cell identity、coverage、LOD、cache、prefetch、handoff 和预算必须按完整三维坐标定义。默认近场 `3×3×3 tiles = 27 tiles = 9261 chunks`；单轴跨越一整个 tile 时 `entered/exited = 9 tiles = 3087 chunks`、`retained = 18 tiles = 6174 chunks`。XZ tile column、有限 Y 带和把 Y 固定为零的设计仅允许作为 `docs/20-archive/` 历史证据，不得作为当前设计、兼容运行时或新功能基础。

### 2.1 架构设计指导思想（系统正交，最高纲领）

详见 [`docs/30-reference/overview/2026-06-27-架构设计指导思想-系统正交.md`](docs/30-reference/overview/2026-06-27-架构设计指导思想-系统正交.md)。动手/设计前先读并过其「开工前自查清单」。三条核心：

1. **系统正交**：每个系统只负责一件清晰的事；系统间只走**稳定契约**，不共享可变的隐式假设。改 A 莫名弄坏概念上无关的 B，就是隐藏耦合，是设计缺陷。
2. **自维护不变量**：一个系统对外承诺的**所有**不变量（**含活性/续租/超时/重连等时间性不变量**）必须由它**自己持续维护**；绝不让别的系统的正确性悄悄依赖一个**没人维护**的假设。警惕「一次性建立、之后没人管」的资源（订阅/lease/连接/缓存/content_version）静默失效。
3. **显式契约 > 隐式假设**：跨系统依赖要么**承诺方强制维护契约**，要么**依赖方对破坏鲁棒（自愈）**。

> 血泪案例：挖放体素「被接受却不显示」，根因是订阅缺活性维护、lease 静默过期（站着不动也会坏，移动是红鲱鱼）。诊断 bug 先排除红鲱鱼（问「这故障跟我以为的原因真有因果吗」）。

### 2.2 通用设计纪律（所有代码与文档适用）

> 下列纪律与本节架构铁律共同生效。所谓“极简”，是把必要复杂度集中在唯一 owner、信任边界和不变量构造入口，删除内部链路上的重复防御与偶然复杂度。

1. **极简哲学**：只引入完成当前已批准目标所需的最少概念、状态、分支、配置和层级；同等正确的方案优先删除、复用与直接组合。任何新增抽象必须有当前调用方、明确职责和可验证收益。
2. **DRY（语义去重）**：同一业务规则、契约、常量、状态所有权或算法只定义一次；其他位置必须调用、导入、生成或链接到权威定义，禁止复制后各自演化。不要把表面相似误判为同一语义：生命周期或变化原因不同的代码不得为消除文本重复而强行共用抽象。
3. **唯一事实源（SSOT）**：每项对外有意义的事实必须明确唯一 owner 与 canonical source；文档摘要、CLI、缓存、视图和兼容表示只能是可追溯的派生物，并具备生成、同步或失效机制。发生冲突时以权威源为准并修复派生物，禁止从多个来源猜测、拼接或按“哪个可用就用哪个”决定真值。
4. **高内聚、低耦合**：数据、行为、入口校验和不变量构造应由同一职责模块完整拥有；模块只暴露类型化合法状态、显式失败结果与完成协作所需的最小稳定契约。禁止共享可变内部状态、穿透内部 worker、依赖全局执行顺序，或让调用方拼装本应由模块维护的正确性。
5. **功能模块正交**：不同功能应成为可独立理解、测试、替换和演化的变化轴，只在明确的组合根或编排边界协作。修改 A 若迫使概念上无关的 B 同步修改，先视为隐藏耦合并修正边界，不用额外开关、条件分支或同步补丁掩盖。
6. **信任边界校验一次**：外部输入、持久化加载、网络 / 进程边界、权限与安全、并发提交，以及不变量构造入口，必须由负责接纳数据的权威模块完成一次必要校验，并把结果构造成类型化合法状态或显式失败。合法状态进入内部可信链路后，后续模块必须直接消费该契约，禁止重复同一校验、二次解析原始数据、全量扫描状态、增设兜底分支或层层 `fail-closed`。只有数据再次跨越新的信任边界时才重新验证；下游可以处理契约显式返回的失败状态，并只校验自己新构造的不变量，但不得重新推断或复核上游已保证的不变量。
7. **不过度设计、不过度兜底**：没有当前需求或失败证据，不预建扩展点、通用框架、兼容层、第二实现、自动重试、自愈或降级路径。兜底只在产品契约或已验证失败模型明确要求时存在，并由对应 owner 在明确边界内实现，同时写清触发条件、语义边界、可观测性、测试和退出条件；否则显式失败。禁止下游以“以防万一”为由追加重复门禁、状态扫描或备用真值路径。
8. **证据优先决策，禁止凭空发明**：凡影响架构、算法、协议、数据模型、模块边界、正确性、安全、并发、性能或运行行为的实质性技术决策，实施前必须查证学术界或工业界已有最佳实践。依据优先级为标准 / 官方规范 / 官方文档 / 权威源码、同行评审论文 / 经典专业著作、成熟工业系统的工程文档 / 技术报告 / 事故复盘；二手文章只能作为检索线索，禁止仅凭模型记忆、个人偏好或“看起来合理”决策。采用依据时必须说明来源、适用条件、与本项目约束的对应关系及取舍，并记入最近的既有决策稿、阶段日志、README 或 engineering note，不为小改动另造文档。确无可适用实践而必须创造时，须标记为“原创决策”，并在实施前向用户报告检索范围、现有方案不适用的原因、创造理由、风险、不变量与验证方式。
9. **自然数据流**：批次、组、队列、mailbox 与生产者/消费者只承担运输与调度，决定“什么时候、按什么顺序到达”；它们不得成为第二真值，不得附带自己的正确性协议，也不得让分组边界改变单元语义。输入的合法性由唯一 owner 在构造边界一次性冻结为不可变、类型化的合法状态与确定顺序，内部消费者此后只按同一种自然单元线性推进，不为“最后一个”“跨帧的那个”“量特别大的那个”另设特殊事务、合并放大或第二条流水。派生结论（覆盖、延迟集合、凭证、进度）必须从该唯一序列与既有 fence 推导，不复制成可写状态。验收阈值、测试门禁与观测指标只属于测试与验收侧，禁止反向编译进生产路径变成重复扫描、层层检查、兜底或备用路径；生产代码要么让自然流按契约推进，要么在真实信任边界显式返回可诊断失败。若自然流上某个不可分割单元的成本本身超标，修复点在产生该单元的上游划分，不在消费侧加补丁。

## 3. 工程方法约束

1. **CLI + 结构化日志优先**：客户端 / 服务端联调与验收优先使用 CLI 可观测接口和结构化日志，不把截图或视觉检查作为唯一判断依据。
2. **先定义可观测面再实现**：新增或修改交互式运行时逻辑前，先明确调试时需要从 CLI / 日志直接读到哪些状态、输入、输出、错误原因，再实现功能本身。
3. **非 GUI 调试面必须等价**：当前主线 Voxim 必须提供等价的 CLI / 日志调试面；若用户显式临时纳入归档浏览器客户端，它也必须提供 `window` 命令入口、结构化 observe 日志和可导出的运行时快照。
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
14. **最小充分测试**：测试范围由本次变更的契约、失败模型和直接影响边界推导，不由“跑得越多越安全”推导。先写能证伪本次改动的最小测试（改前红、改后绿），再补该改动自身引入的边界与回归；禁止为求保险盲目扩大 suite、抬高环境档次、加大数据量或重复验证上游契约已经保证、其它用例已经覆盖的事实。只有当改动触达共享契约、跨模块边界，或已有失败证据显示风险确实扩散时才扩大范围，并在验收说明中写清扩大的理由与它能抓住的具体破坏。

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
- WebSocket 双客户端 smoke：`node scripts/run_ws_dual_smoke_supervised.js`，结构化产物写入 `.demo/observe/`。
- Voxia 参考客户端 CLI（非 Voxim 默认验收）：`node clients/Voxia/scripts/voxia_stdio_cli.js --cmd "..."`；服务端 CLI：`elixir --sname voxia_server_cli --cookie mmo scripts/voxia_server_stdio_cli.exs --cmd "..."`。
- 完整命令清单见 [`docs/30-reference/engineering/project-engineering-guide.md`](docs/30-reference/engineering/project-engineering-guide.md) 与 [`docs/00-current-truth/impl/README.md`](docs/00-current-truth/impl/README.md)。
- 归档客户端：Web / Bevy 不进入默认验证；只有用户显式点名时才按各自 README 运行历史测试或工具。

## 6. 关键路径（索引）

- 项目“此刻为真”入口：[`docs/00-current-truth/README.md`](docs/00-current-truth/README.md)（含模块表、实现速查、已知缺口）
- 工程背景 / 技术栈 / 命令：[`docs/30-reference/engineering/project-engineering-guide.md`](docs/30-reference/engineering/project-engineering-guide.md)
- Phoenix phx.new 规则：[`docs/30-reference/engineering/phoenix-phx-new-guidelines.md`](docs/30-reference/engineering/phoenix-phx-new-guidelines.md)
- 系统正交设计纲领：[`docs/30-reference/overview/2026-06-27-架构设计指导思想-系统正交.md`](docs/30-reference/overview/2026-06-27-架构设计指导思想-系统正交.md)
- 线协议：[`docs/30-reference/protocol/2026-04-10-线协议规范.md`](docs/30-reference/protocol/2026-04-10-线协议规范.md)（现行 Session/Voxel 真值在纯 mmo_contracts，旧 Gate 只持有遗留领域）
- 体素权威主索引：[`docs/10-active/cross-cutting/voxel-server-authority-phase-overview.md`](docs/10-active/cross-cutting/voxel-server-authority-phase-overview.md)
- 体素 baseline 边界决策：[`docs/30-reference/protocol/2026-06-29-voxel-baseline-streaming-boundary.md`](docs/30-reference/protocol/2026-06-29-voxel-baseline-streaming-boundary.md)
- Voxia 参考实现的纯 3D 窗口 / 远景壳路线：[`docs/10-active/voxel-far-field/2026-07-12-pure-3d-voxel-shell-migration.md`](docs/10-active/voxel-far-field/2026-07-12-pure-3d-voxel-shell-migration.md)
- 旧体素同步 / 窗口 / 渲染设计（仅历史证据）：[`docs/20-archive/voxel-authority/2026-06-29-voxel-sync-window-and-render-design.md`](docs/20-archive/voxel-authority/2026-06-29-voxel-sync-window-and-render-design.md)
- Phase 7 局部场路线图：[`docs/10-active/field-emergence/2026-05-16-phase7-local-field-runtime-roadmap.md`](docs/10-active/field-emergence/2026-05-16-phase7-local-field-runtime-roadmap.md)
- 当前会话 / 后续接力：[`docs/10-active/cross-cutting/_session-handoff.md`](docs/10-active/cross-cutting/_session-handoff.md)
- 当前客户端：[`../Voxim/starter.md`](../Voxim/starter.md)；参考客户端：[`clients/Voxia/README.md`](clients/Voxia/README.md)
- M1 抽取与待实施边界：[`2026-09-08-voxim-m1.md`](docs/10-active/movement-sync/2026-09-08-voxim-m1.md)（authority/QUIC/bootstrap runtime 未由 G1 实现）
- 归档客户端策略：[`docs/10-active/cross-cutting/2026-07-14-web-bevy-client-archive-policy.md`](docs/10-active/cross-cutting/2026-07-14-web-bevy-client-archive-policy.md)
