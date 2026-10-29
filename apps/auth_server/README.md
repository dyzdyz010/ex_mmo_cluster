# AuthServer

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:20000`](http://localhost:20000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Prefab HTTP 契约与回归

`/ingame/voxel/prefabs`、`/game/prefabs` 与 `/playtest/prefabs` 复用同一 World 读取边界；成功响应仍使用原发布顺序、名称、发布者和冻结 VXPD 字节。P3 按需读取的源文件缺失、身份不符或缓存预算失败应返回 HTTP 503、稳定 JSON `{"error":"voxel_prefabs_unavailable"}`，并记录含 scene_id 与原 reason 的结构化 `voxel_prefabs_unavailable` 日志；不返回空列表或备用来源。

最小模块集成回归为 `test/auth_server_web/controllers/voxel_prefabs_controller_test.exs` 的 3 项：既有成功 golden 与开发鉴权、邀请码鉴权，以及合法 `.vxpd/.pub` 启动且 raw 缓存确认为空后删除源文件的故障注入。后者通过真实 Phoenix endpoint 断言 503 和诊断日志，不向 authority 写状态。World 使用真实 FileStore / 文件 overlay；Auth 启动会带起 DataService.Repo，测试复用 `MmoTest.Database` 创建并清理 `config/test.exs` 所属 VM 的新库，未替代 World、路由或 HTTP。此文件只证明 HTTP 接缝，不覆盖真实客户端呈现、性能或全玩家链路。

从本目录以正常构建图执行 `mix.bat test --no-start test/auth_server_web/controllers/voxel_prefabs_controller_test.exs --trace`；需可用 PostgreSQL。本轮隔离环境只使用 `127.0.0.1:26810` 的 `voxim-pg-paging1024`，不设 `MMO_TEST_DB_NAME`。2026-10-28 已取得目标冷源失败首红（2/3 passed），修复后 3 项通过；精确环境、源身份和原始红绿证据记入根 `.superpowers/sdd/voxel-authority-sharding/task-prefab-http-failure.md`。

## 邀请码完整显示

管理后台 `/admin` 新签发的邀请码在生成结果、刷新后的列表及搜索结果中均完整显示。复用既有 `auth_invites.hint` 展示字段保存原码，摘要继续负责兑换匹配；历史仅有掩码的记录保持原样，不推测或补造原码。控制台 `AuthServer.Admin.list_invites/1` 读取同一展示值，无需数据库迁移。

回归通过正常注册、管理员授权、网页登录、生成表单、重新 GET 与完整码搜索验证 HTTP 输出，并复用 Identity 的签发测试检查持久化读回。使用 `MmoTest.Database` 管理独占测试库与 TestMailer，真实 Auth、PostgreSQL、Phoenix endpoint；不覆盖浏览器视觉或部署。运行：`mix.bat test --no-start test/auth_server_web/controllers/account_controller_test.exs test/auth_server/identity_test.exs:85`（在本目录，需 PostgreSQL）。

## 邀请码人数上限

后台生成表单要求填写“每码可注册人数”（正整数）；同一码允许多人注册，成功人数达到上限后显示“已用完”。列表显示已使用人数、上限及最近使用者，仍可按任何历史使用者邮箱／账号 ID 搜索。未删除、未停用的邀请码可以修改上限，但不能低于已注册人数；增加上限后可继续使用。到期、停用、删除规则保持有效。

迁移 `20261028000001` 把旧使用者记录迁入 `auth_invite_uses`，旧码保留 1 人上限，管理员可自行提高；旧掩码仍不能还原。CLI：`AuthServer.Admin.generate_invites(1, "批次", nil, 20)`、`AuthServer.Admin.set_invite_limit(id, 30)`；API 创建参数 `max_uses`，修改入口 `POST /account/admin/invites/:id/limit`。既有三参数 CLI／省略额度的 API 保留 1 人语义。

决策、并发不变量及测试矩阵见 [人数额度决策](../../docs/10-active/infra/2026-10-28-invite-capacity.md)。本次 24 项真实数据库／HTTP／迁移测试通过；追加的网页多人注册与降额拒绝回归也通过。证据在 `.demo/observe/invite-capacity/`，不覆盖浏览器视觉或游戏玩法。

## 部署记录

当前线上为 `voxim-server:20261028-invite-capacity`：自定义人数与记录迁移已部署，登录页 HTTP 200；线上事务验证多人注册、用尽拒绝、提高上限后继续注册与后台 HTML，验证数据已回滚。发布源码、旧 Compose、数据库备份与结果在服务器 `/data/voxim_qinglan/releases/20261028-invite-capacity/`。此版本修改了账号表结构，不能只切回旧镜像；必须先停应用、执行本次迁移降级（多人历史存在时会拒绝），详见人数额度决策。

2026-10-28 已部署至 `https://account.hemifuture.cn/admin`：镜像 `voxim-server:20261028-invite-display` 基于线上 `20261008-qinglan`，仅重编译 `AuthServer.Admin`、`AccountAdminController`、`AccountAdminHTML` 三个模块，未携带当前开发树的其他变更。线上登录页 HTTP 200；RPC 经真实数据库验证签发、列表读回、完整码搜索与 HTML 输出，验证事务已回滚。服务器 `/data/voxim_qinglan/releases/20261028-invite-display/` 保存构建源码、数据库备份、旧 Compose、验证日志和部署结果；本地证据为 `.demo/observe/invite-display-deploy/`。回退可恢复该目录的 `docker-compose.before.yml` 到部署根后运行 `docker compose up -d --no-deps app`，本次无 schema 迁移。

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
