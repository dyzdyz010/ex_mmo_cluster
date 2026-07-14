# CLAUDE.md

本文件是 Claude Code 在本仓库的入口——**只保留约束指针与索引**。工程背景、技术栈、命令、结构等较长内容已迁出（见下方索引）。

> **工程准则与约束铁律的单一来源是 [`AGENTS.md`](AGENTS.md)，动手前先读它**，尤其：
> - 架构铁律（服务端权威、confirmed truth 只吃服务端、基线校验硬失败、边界清晰、显式失败…）— AGENTS.md §2
> - 系统正交设计纲领（系统正交 / 自维护不变量含时间性 / 显式契约）— AGENTS.md §2.1，**设计前必读并过自查清单**
> - 工程方法约束（CLI 优先、三入口覆盖、禁补丁式修复、阶段改动先有决策稿、中文注释、活用 mermaid…）— AGENTS.md §3
> - 客户端口径（Voxia 唯一现役 / Web 与 Bevy 逻辑归档）— AGENTS.md §1

## 本仓工作纪律（Claude Code 专属补充，AGENTS.md 未覆盖的执行细节）

- **决策稿先行**：阶段性 / 架构性改动先在 `docs/10-active/<子系统>/`（如 `voxel-far-field`、`field-emergence`、`voxel-authority`）落决策稿（目标、范围、决策项、测试矩阵、进度日志），再动手；收口后随文档治理归入 `docs/20-archive/<子系统>/`。文档分层规则见 [`docs/README.md`](docs/README.md)。
- **逐 step 推进**：每个 step 改完 `mix format` + 跑最小相关测试 + 记进度日志；**默认不 `git push`**（除非用户明确要求）；全新系统不留向后兼容包袱。
- **改前先定位 app**：umbrella 项目，先判断影响哪个 app；跨 app 通信走 Interface 模块 / `BeaconServer.Client`，不绕边界、不硬编码节点名。
- **Rust NIF**：`scene_server` 带 Rust NIF，改 native 要考虑 Rustler 0.37.3 API 与 Rust 编译链。
- **Windows 运行**：Mix 通过 VS Dev Command Prompt（`VsDevCmd.bat` + `HEX_HTTP_CONCURRENCY=1` / `HEX_HTTP_TIMEOUT=120`）；PowerShell 被 `mix.ps1` 签名策略拦截时用 `cmd /c mix ...`。细节见 [`docs/30-reference/engineering/project-engineering-guide.md`](docs/30-reference/engineering/project-engineering-guide.md)。

## 索引

> 文档已按功能分层（`00-current-truth` / `10-active` / `20-archive` / `30-reference` / `90-obsolete`）。**先看文档总地图**，再按需进具体文件。

| 需要什么 | 去哪读 |
| --- | --- |
| **文档总地图（分层规则 + 各层用途）** | [`docs/README.md`](docs/README.md) |
| 工程准则 / 约束铁律 | [`AGENTS.md`](AGENTS.md) |
| 工程背景 / 技术栈 / 命令 / 结构 / 编码约定 | [`docs/30-reference/engineering/project-engineering-guide.md`](docs/30-reference/engineering/project-engineering-guide.md) |
| Phoenix 1.8 / phx.new 规则 | [`docs/30-reference/engineering/phoenix-phx-new-guidelines.md`](docs/30-reference/engineering/phoenix-phx-new-guidelines.md) |
| 项目“此刻为真”的设计与实现状态 | [`docs/00-current-truth/README.md`](docs/00-current-truth/README.md) |
| 体素世界主线（baseline / 同步 / 渲染） | [`docs/10-active/cross-cutting/voxel-server-authority-phase-overview.md`](docs/10-active/cross-cutting/voxel-server-authority-phase-overview.md) |
| 局部场 / 涌现 | [`docs/10-active/field-emergence/2026-05-16-phase7-local-field-runtime-roadmap.md`](docs/10-active/field-emergence/2026-05-16-phase7-local-field-runtime-roadmap.md) |
| 历史归档（已收口，仍有效） / 长稳参考 | [`docs/20-archive/`](docs/20-archive/) · [`docs/30-reference/`](docs/30-reference/) |
| 已失效文档（仅存 provenance，勿作依据） | [`docs/90-obsolete/`](docs/90-obsolete/) |
| 线协议（真值=`gate_server/codec.ex`） | [`docs/30-reference/protocol/2026-04-10-线协议规范.md`](docs/30-reference/protocol/2026-04-10-线协议规范.md) |
