# CLAUDE.md

本文件是 Claude Code 在本仓库的入口——**只保留约束指针与索引**。工程背景、技术栈、命令、结构等较长内容已迁出（见下方索引）。

> **工程准则与约束铁律的单一来源是 [`AGENTS.md`](AGENTS.md)，动手前先读它**，尤其：
> - 架构铁律（服务端权威、confirmed truth 只吃服务端、基线校验硬失败、边界清晰、显式失败…）— AGENTS.md §2
> - 系统正交设计纲领（系统正交 / 自维护不变量含时间性 / 显式契约）— AGENTS.md §2.1，**设计前必读并过自查清单**
> - 工程方法约束（CLI 优先、三入口覆盖、禁补丁式修复、阶段改动先有决策稿、中文注释、活用 mermaid…）— AGENTS.md §3
> - 客户端口径（Voxia 焦点 / web parity / bevy 参考）— AGENTS.md §1

## 本仓工作纪律（Claude Code 专属补充，AGENTS.md 未覆盖的执行细节）

- **决策稿先行**：阶段性 / 架构性改动先在 `docs/voxel-server-authority/` 或 `docs/plans/` 落决策稿（目标、范围、决策项、测试矩阵、进度日志），再动手。
- **逐 step 推进**：每个 step 改完 `mix format` + 跑最小相关测试 + 记进度日志；**默认不 `git push`**（除非用户明确要求）；全新系统不留向后兼容包袱。
- **改前先定位 app**：umbrella 项目，先判断影响哪个 app；跨 app 通信走 Interface 模块 / `BeaconServer.Client`，不绕边界、不硬编码节点名。
- **Rust NIF**：`scene_server` 带 Rust NIF，改 native 要考虑 Rustler 0.37.3 API 与 Rust 编译链。
- **Windows 运行**：Mix 通过 VS Dev Command Prompt（`VsDevCmd.bat` + `HEX_HTTP_CONCURRENCY=1` / `HEX_HTTP_TIMEOUT=120`）；PowerShell 被 `mix.ps1` 签名策略拦截时用 `cmd /c mix ...`。细节见 [`docs/project-engineering-guide.md`](docs/project-engineering-guide.md)。

## 索引

| 需要什么 | 去哪读 |
| --- | --- |
| 工程准则 / 约束铁律 | [`AGENTS.md`](AGENTS.md) |
| 工程背景 / 技术栈 / 命令 / 结构 / 编码约定 | [`docs/project-engineering-guide.md`](docs/project-engineering-guide.md) |
| Phoenix 1.8 / phx.new 规则 | [`docs/phoenix-phx-new-guidelines.md`](docs/phoenix-phx-new-guidelines.md) |
| 项目“此刻为真”的设计与实现状态 | [`docs/current_status/README.md`](docs/current_status/README.md) |
| 体素世界主线（baseline / 同步 / 渲染） | [`docs/voxel-server-authority/README.md`](docs/voxel-server-authority/README.md) |
| 局部场 / 涌现 | [`docs/plans/2026-05-16-phase7-local-field-runtime-roadmap.md`](docs/plans/2026-05-16-phase7-local-field-runtime-roadmap.md) |
| 原始设计文档（证据源） | [`docs/original/`](docs/original/) |
| 线协议（真值=`gate_server/codec.ex`） | [`docs/original/2026-04-10-线协议规范.md`](docs/original/2026-04-10-线协议规范.md) |
