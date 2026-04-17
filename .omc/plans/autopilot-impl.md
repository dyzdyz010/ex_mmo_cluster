# Phoenix 1.8 升级实施计划

## 执行分支
`phoenix-1-8-upgrade`（已创建，基于 master 67fa037）

## 阶段

### Stage 1 — 准备
- [x] 创建工作分支
- [ ] 安装/升级 `phx_new` archive 到最新（`mix archive.install hex phx_new`）
- [ ] 基线：`mix compile` 当前通过
- [ ] `git commit`: 基线快照（什么都不改，仅标记起点）

### Stage 2 — 归档旧 app
- [ ] 创建 `archive/` 目录
- [ ] `git mv apps/auth_server archive/auth_server_legacy`
- [ ] `git mv apps/visualize_server archive/visualize_server_legacy`
- [ ] 确认 umbrella 自动发现不再包含它们（`mix apps`）
- [ ] `mix deps.get` 会报缺 auth_server（gate_server test dep），**这是预期**
- [ ] 临时让 gate_server 的 `auth_server` test 依赖可接受缺失（保留 `in_umbrella: true, only: :test` —— 下一阶段生成新 auth_server 补回）
- [ ] `git commit`: "Archive Phoenix 1.6 auth/visualize apps before regeneration"

### Stage 3 — 用 phx.new 生成新 auth_server
- [ ] `cd apps && mix phx.new auth_server --no-ecto --umbrella=false --binary-id --install`
  - 注：`phx.new` 在已有 umbrella 的 `apps/` 子目录下会识别 umbrella 结构，自动调整路径和 mix.exs
  - 预期生成：Phoenix 1.8 标准结构 + assets (esbuild+tailwind) + gettext + telemetry
- [ ] 手动补 umbrella path：确保 `build_path`, `config_path`, `deps_path`, `lockfile` 指向 umbrella 根
- [ ] 添加 umbrella deps: `{:data_init, in_umbrella: true}`, `{:data_service, in_umbrella: true}`, `{:beacon_server, in_umbrella: true}`
- [ ] 添加 `{:bcrypt_elixir, "~> 3.0"}`
- [ ] 验证 `mix compile` 新 app 通过

### Stage 4 — 迁移 auth_server 业务
- [ ] 复制业务模块（照原名）：
  - `accounts.ex`, `auth_worker.ex`, `sup/`, `worker/`, `demo/`
  - 保留 `Mailer` 模块（config 引用）
- [ ] 在 `application.ex` 中挂 `interface_children()`（含 `InterfaceSup`）
- [ ] 端口 2 个 controller + 4 个 template 到 Phoenix 1.8 风格（controller + HEEX + 函数组件）
- [ ] 路由：`router.ex` 合并 ingame 路由
- [ ] 迁移 `test/auth_server/` 测试，调整到 1.8 `conn_case`
- [ ] `mix test --no-start` for auth_server 通过

### Stage 5 — 用 phx.new 生成新 visualize_server
- [ ] `cd apps && mix phx.new visualize_server --no-ecto --no-mailer --binary-id --install`
- [ ] 修补 umbrella 路径
- [ ] 添加 `{:beacon_server, in_umbrella: true}`（LiveView 读集群状态）

### Stage 6 — 迁移 visualize_server LiveView
- [ ] 复制 `scene_live/` 逻辑
- [ ] LiveView 0.17 → 1.x API 迁移：
  - `use Phoenix.LiveView` 签名
  - `handle_event` 返回签名
  - `@socket.assigns` 改为直接 `@foo`
  - `<.live_component ... />` 语法
- [ ] 路由 `live "/scenes/:id", SceneLive.Index`
- [ ] 迁移测试

### Stage 7 — 集群集成 & 根 config
- [ ] `config/config.exs`: 确保 `AuthServerWeb.Endpoint`, `VisualizeServerWeb.Endpoint` 配置匹配新生成的密钥/端口
- [ ] `config/test.exs`: 更新
- [ ] `config/dev.exs`, `config/prod.exs`: 更新
- [ ] 两个新 app 的 `config/config.exs` 处理（phx.new 可能生成本地 config，需并入 umbrella root config）

### Stage 8 — 验证
- [ ] `mix compile` 整 umbrella 通过（零 warning 最理想）
- [ ] `mix test` 整 umbrella 通过（gate_server 的 auth_server 依赖测试必须过）
- [ ] 单独 `cd apps/auth_server && mix test --no-start`
- [ ] 单独 `cd apps/visualize_server && mix test --no-start`
- [ ] `mix format --check-formatted`

### Stage 9 — 文档 & 提交
- [ ] 更新 `CLAUDE.md`：Phoenix 1.8、archive 说明
- [ ] 写阶段文档 `docs/2026-04-17-Phoenix-1-8-升级记录.md`
- [ ] 分阶段提交（每个主要节点一个 commit）
- [ ] push feature branch
- [ ] 报告给用户，由用户决定何时 merge 到 master

## 风险 & 回退
- **Windows bcrypt_elixir 编译**：若失败，暂停提醒在 VS Dev Cmd 里预编译
- **LiveView 1.x 语义差异**：若 scene_live 迁移困难，可先保 stub，之后单独迭代
- **phx.new umbrella 行为**：若生成器不按预期认 umbrella，切回手动生成 skeleton 再补
- **回退**：整分支，`git checkout master && git branch -D phoenix-1-8-upgrade`

## 不在本次范围
- 删除 `archive/` 下的旧 app
- 其他 app 的 Phoenix/Plug 相关升级
- Phoenix 1.8 带来的 Tailwind 4 / daisyUI 在既有 UI 上的视觉重做
