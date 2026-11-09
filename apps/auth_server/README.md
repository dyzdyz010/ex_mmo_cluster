# AuthServer

The server supports Linux only. Run the commands below from this directory in Linux (WSL on this Windows host), with the project toolchain and PostgreSQL available. From Windows, enter this directory with `wsl.exe --cd /mnt/d/hemifuture/ex_mmo_cluster/apps/auth_server`. See the [engineering guide](../../docs/30-reference/engineering/project-engineering-guide.md).

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:20000`](http://localhost:20000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## 密码长度规则（当前：8–20 字符）

按本次产品要求，设置新密码只检查字符串长度为 8–20 个字符，不要求字符种类，也不使用常见密码名单。`AuthServer.Identity.password_min_length/0` 与 `password_max_length/0` 是范围的唯一来源，注册、旧账号认领、改密和重置共用；网页约束与错误提示读取同一范围。既有超过 20 字符的密码仍可登录，也可作为当前密码完成改密；上限只约束本次设置的新密码。

字符计数沿用 [Elixir `String.length/1`](https://hexdocs.pm/elixir/1.19.5/String.html#length/1) 的 Unicode 字素语义；密码仍经既有 [Argon2 哈希与验证](https://hexdocs.pm/argon2_elixir/Argon2.html) 路径，不截断或改写输入。[HTML `maxlength`](https://html.spec.whatwg.org/multipage/input.html#attr-input-maxlength) 按 UTF-16 代码单元计数，直接设为 20 会误挡合法的 20 个 emoji，因此网页仅输出同源 `data-maxlength`，由既有脚本使用 [ECMA-402 `Intl.Segmenter`](https://tc39.es/ecma402/#segmenter-objects) 的 `grapheme` 分段实时提示并设置表单有效性。原生 `minlength=8` 可提前拦截明显过短的输入，其余按字素补齐校验；无脚本时仍可正常提交，由服务端作最终裁决。

本次最小回归范围为 Identity 公共入口与 Phoenix 网页／JSON 注册入口的 7／8／20／21 字符边界、纯数字、原名单密码、中文、emoji 与组合字符，以及注册／认领／改密／重置共用范围、旧长密码登录和确认改密。依赖真实 Auth、PostgreSQL 和独占新测试库（`MmoTest.Database` 在退出时删除），只替换邮件投递为 TestMailer；网页检查实际 HTTP 表单属性、范围提示和既有脚本的字素计数／有效性，不据此声明浏览器视觉或部署通过。Linux 在本目录运行 `mix test --no-start test/auth_server/identity_test.exs test/auth_server_web/controllers/account_portal_controller_test.exs test/auth_server_web/controllers/account_controller_test.exs`；本轮原始日志写入根 `.demo/observe/password-range-20261104/`。

本轮 WSL 回归为 `38 tests, 0 failures`；Linux Node 23.7 执行 `node --test test/auth_server_web/account_ui_test.mjs` 的 1 项真实脚本组件测试通过，覆盖 7／8／20／21 字素、emoji、组合字符和超长错误清除。组件测试只替换 DOM 运输面，执行生产 `account_ui.js` 并观察提示与 `validationMessage`，不证明浏览器视觉。红测记录与所有绿测、命令、源码摘要在上述观察目录；生产候选沿用实际运行镜像，仅追加 4 个 Auth BEAM，不携带工作树中的协议或其他功能改动。

`2026-11-04 08:30 UTC` 已发布 `voxim-server:20261104-password-range`。生产内 8／20 字符（含 emoji）注册、登录通过，7／21 字符拒绝，513 字符旧凭据登录通过；自有测试事务已回滚，无账号／证明／邀请码遗留。公开 CSRF 表单与 JSON API 的四个长度边界通过，双 Scene 与 QUIC 就绪；实际协议 41、kernel/profile、13 条迁移、配置和挂载保持一致。镜像包、输入与证据在根 `.demo/observe/password-range-deploy-20261104/`，生产备份和回退说明在 `/data/voxim_qinglan/releases/20261104-password-range/`。

### 2026-11-03 最小长度调整的历史验证与发布

以下保留当时的验证与发布事实，不代表本轮 8–20 字符范围已经验证或部署；当时原始日志位于根 `.demo/observe/password-length-20261103/`。

本轮在 WSL 以 Erlang/OTP 28.3.1、Elixir 1.19.5 实跑：修改前 33 项中 11 项因旧规则／表单约束失败；修改后同组 33 项全部通过。`red.log`／`green.log`、对应退出码与源码摘要、`environment.log` 和 `run.sh` 保存在上述目录，可用 `bash .demo/observe/password-length-20261103/run.sh green` 从仓库根复跑。

生产发布：`2026-11-04 03:45 UTC` 已从 `voxim-server:20261102-beacon-motion` 更新为 `voxim-server:20261103-password-length`。沿用生产 OTP 27.2.4／Elixir 1.18.5，仅重编译 4 个 Auth 模块；生产协议 41、kernel/profile、13 条迁移、挂载与限额均未变。正式根的 baseline、两 Scene、QUIC 与公开网页已就绪；独占事务内的 4 类密码完成注册／登录／authenticate 后全部回滚，公网表单与 JSON API 的 7／8 字符边界也通过。镜像包、冻结输入与发布证据在根 `.demo/observe/password-length-deploy-20261103/`，生产配置备份与 46,692,861 字节数据库备份在 `/data/voxim_qinglan/releases/20261103-password-length/`；回退步骤见该处 `RUNBOOK.md`。

## Prefab HTTP 契约与回归

`/ingame/voxel/prefabs`、`/game/prefabs` 与 `/playtest/prefabs` 复用同一 World 读取边界；成功响应仍使用原发布顺序、名称、发布者和冻结 VXPD 字节。P3 按需读取的源文件缺失、身份不符或缓存预算失败应返回 HTTP 503、稳定 JSON `{"error":"voxel_prefabs_unavailable"}`，并记录含 scene_id 与原 reason 的结构化 `voxel_prefabs_unavailable` 日志；不返回空列表或备用来源。

最小模块集成回归为 `test/auth_server_web/controllers/voxel_prefabs_controller_test.exs` 的 3 项：既有成功 golden 与开发鉴权、邀请码鉴权，以及合法 `.vxpd/.pub` 启动且 raw 缓存确认为空后删除源文件的故障注入。后者通过真实 Phoenix endpoint 断言 503 和诊断日志，不向 authority 写状态。World 使用真实 FileStore / 文件 overlay；Auth 启动会带起 DataService.Repo，测试复用 `MmoTest.Database` 创建并清理 `config/test.exs` 所属 VM 的新库，未替代 World、路由或 HTTP。此文件只证明 HTTP 接缝，不覆盖真实客户端呈现、性能或全玩家链路。

从本目录在 Linux 以正常构建图执行 `mix test --no-start test/auth_server_web/controllers/voxel_prefabs_controller_test.exs --trace`；需可用 PostgreSQL。历史实跑（2026-10-28）使用 `127.0.0.1:26810` 的 `voxim-pg-paging1024`，未设 `MMO_TEST_DB_NAME`，取得目标冷源失败首红（2/3 passed），修复后 3 项通过；精确环境、源身份和原始红绿证据记入根 `.superpowers/sdd/voxel-authority-sharding/task-prefab-http-failure.md`。该历史环境不代表当前服务已启动。

## 邀请码完整显示

管理后台 `/admin` 新签发的邀请码在生成结果、刷新后的列表及搜索结果中均完整显示。复用既有 `auth_invites.hint` 展示字段保存原码，摘要继续负责兑换匹配；历史仅有掩码的记录保持原样，不推测或补造原码。控制台 `AuthServer.Admin.list_invites/1` 读取同一展示值，无需数据库迁移。

回归通过正常注册、管理员授权、网页登录、生成表单、重新 GET 与完整码搜索验证 HTTP 输出，并复用 Identity 的签发测试检查持久化读回。使用 `MmoTest.Database` 管理独占测试库与 TestMailer，真实 Auth、PostgreSQL、Phoenix endpoint；不覆盖浏览器视觉或部署。运行：`mix test --no-start test/auth_server_web/controllers/account_controller_test.exs test/auth_server/identity_test.exs:85`（在本目录的 Linux 环境，需 PostgreSQL）。

## 邀请码人数上限

后台生成表单要求填写“每码可注册人数”（正整数）；同一码允许多人注册，成功人数达到上限后显示“已用完”。列表显示已使用人数、上限及最近使用者，仍可按任何历史使用者邮箱／账号 ID 搜索。未删除、未停用的邀请码可以修改上限，但不能低于已注册人数；增加上限后可继续使用。到期、停用、删除规则保持有效。

迁移 `20261028000001` 把旧使用者记录迁入 `auth_invite_uses`，旧码保留 1 人上限，管理员可自行提高；旧掩码仍不能还原。CLI：`AuthServer.Admin.generate_invites(1, "批次", nil, 20)`、`AuthServer.Admin.set_invite_limit(id, 30)`；API 创建参数 `max_uses`，修改入口 `POST /account/admin/invites/:id/limit`。既有三参数 CLI／省略额度的 API 保留 1 人语义。

决策、并发不变量及测试矩阵见 [人数额度决策](../../docs/10-active/infra/2026-10-28-invite-capacity.md)。本次 24 项真实数据库／HTTP／迁移测试通过；追加的网页多人注册与降额拒绝回归也通过。证据在 `.demo/observe/invite-capacity/`，不覆盖浏览器视觉或游戏玩法。

## 历史部署记录（2026-10-28）

以下保留当日实跑证据，不代表当前线上版本已重新核验。

当日部署版本为 `voxim-server:20261028-invite-capacity`：自定义人数与记录迁移已部署，登录页 HTTP 200；线上事务验证多人注册、用尽拒绝、提高上限后继续注册与后台 HTML，验证数据已回滚。发布源码、旧 Compose、数据库备份与结果在服务器 `/data/voxim_qinglan/releases/20261028-invite-capacity/`。此版本修改了账号表结构，不能只切回旧镜像；必须先停应用、执行本次迁移降级（多人历史存在时会拒绝），详见人数额度决策。

2026-10-28 已部署至 `https://account.hemifuture.cn/admin`：镜像 `voxim-server:20261028-invite-display` 基于线上 `20261008-qinglan`，仅重编译 `AuthServer.Admin`、`AccountAdminController`、`AccountAdminHTML` 三个模块，未携带当前开发树的其他变更。线上登录页 HTTP 200；RPC 经真实数据库验证签发、列表读回、完整码搜索与 HTML 输出，验证事务已回滚。服务器 `/data/voxim_qinglan/releases/20261028-invite-display/` 保存构建源码、数据库备份、旧 Compose、验证日志和部署结果；本地证据为 `.demo/observe/invite-display-deploy/`。回退可恢复该目录的 `docker-compose.before.yml` 到部署根后运行 `docker compose up -d --no-deps app`，本次无 schema 迁移。

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
