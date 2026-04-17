# Phoenix 1.8 升级迁移 Spec

## 目标
把 `auth_server` 和 `visualize_server` 从 Phoenix 1.6 升级到 Phoenix 1.8 最新稳定版，**使用 `mix phx.new` 生成的模板项目作为骨架**，迁移业务逻辑进入新项目。旧项目归档到 `archive/`，不再参与编译与分发，未来某个时间点再删。

## 约束
- Phoenix 1.8 latest stable
- 保持单 app 形态（不拆 `_web`）
- 工作分支：`phoenix-1-8-upgrade`（不动 master）
- 旧项目**归档而非删除**：`apps/<app>/` → `archive/<app>_legacy/`

## 必须保留的公共 API（被 gate_server 依赖）
```
AuthServer.AuthWorker.verify_token/1
AuthServer.AuthWorker.validate_cid/2
AuthServer.AuthWorker.fetch_authorized_character/2
AuthServer.AuthWorker.validate_username/2
AuthServer.AuthWorker.build_session_claims/1 or /2
AuthServer.AuthWorker.issue_token/1
AuthServer.Interface  (cluster 接口进程)
AuthServer.Mailer     (config/test.exs 引用，但 lib 里无 deliver_ 调用，可精简)
```
以及 BeaconServer 注册名 `:auth_server`。

## 新项目 phx.new 选项
- `auth_server`: `--no-ecto`（业务数据走 data_service）+ 保留 mailer 模板（config 已引用） + 保留 LiveDashboard
- `visualize_server`: `--no-ecto --no-mailer`（visualize 无 DB、无邮件，保留 LiveDashboard）

## 迁移范围

### auth_server 业务（从 archive 迁入新 app）
- `lib/auth_server/accounts.ex`
- `lib/auth_server/auth_worker.ex`
- `lib/auth_server/sup/interface_sup.ex`
- `lib/auth_server/worker/interface.ex`
- `lib/auth_server/demo/` (6 文件)
- `lib/auth_server_web/controllers/ingame_controller.ex` → Phoenix 1.8 风格
- `lib/auth_server_web/controllers/page_controller.ex` → Phoenix 1.8 风格
- `lib/auth_server_web/templates/ingame/*.heex` → 1.8 函数组件
- `test/auth_server/` → 跟随代码

### visualize_server 业务
- `lib/visualize_server_web/live/scene_live/` → LiveView 1.x 重写
- `lib/visualize_server_web/router.ex` 中 live 路由配置
- `test/visualize_server/`

## 非目标
- 不动 master（只在 feature 分支）
- 不立即删除旧 app（只移到 `archive/`）
- 不升级其他 app（只 auth_server / visualize_server）
- 不重写业务逻辑（只适配 Phoenix 1.8 API 变化）

## 验收
1. `mix compile` 整 umbrella 通过
2. `mix test` 整 umbrella 通过（含 gate_server 依赖 auth_server 的测试）
3. `cd apps/auth_server && mix test --no-start` 通过
4. `cd apps/visualize_server && mix test --no-start` 通过
5. `archive/` 目录存在，内含两个 legacy app，不在 umbrella 编译路径
