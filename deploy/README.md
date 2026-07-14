# deploy

本目录是生产 Docker Compose 部署入口。

## 文件职责

- `docker-compose.yml`：定义 `postgres`、`app` 和可横向扩缩的 `scene` 服务。
- `.env.example`：部署环境变量模板，包含镜像地址、端口、数据库、集群和 `SCENE_SERVER_COUNT`。
- `nginx.conf.example`：宿主机 nginx HTTPS 反向代理模板。
- `upgrade.sh`：日常升级入口；拉取业务镜像，执行 migration，更新 app/scene，并可选替换宿主机静态客户端。
- `setup_multi_fixture.exs`：本地/临时验收数据准备脚本，不参与容器启动。

## 运行关系

`app` 使用镜像内的 `ex_mmo_cluster` release，启动 edge/world/data 等控制面与入口服务。
`scene` 使用同一镜像内的 `ex_mmo_scene` release，只启动 scene runtime；不要给 `scene`
绑定宿主机端口，这样才能通过 Compose 扩容多个副本。
`app` 的 BEAM 节点名固定为 `app@app.ex-mmo-cluster.internal`，并通过 Compose 网络 alias
发布同名地址，避免 Erlang long-name 模式把 Docker 短主机名 `app` 判定为非法 hostname。
`scene` 节点继续在启动时用容器 IP 生成 long-name，以便同一服务可横向扩容。

生产服务器当前约定部署目录为 `/data/ex_mmo_cluster`。`docker-compose.yml` 内部固定让 release
监听容器端口 `20000/20001/20002/20003`；`.env` 中的 `AUTH_PORT`、`VISUALIZE_PORT`、
`GATE_TCP_PORT`、`GATE_UDP_PORT` 是宿主机发布端口，用于兼容已有公网入口或 nginx 配置。

配置 scene server 数量时修改 `.env` 中的 `SCENE_SERVER_COUNT`，并用下面的命令应用。
`SCENE_SERVER_COUNT` 由 shell 展开，所以需要先把 `.env` 导入当前 shell：

```bash
set -a; . ./.env; set +a
docker compose up -d --scale scene=${SCENE_SERVER_COUNT}
```

`SCENE_SERVER_COUNT` 必须至少为 `1`，因为 `app` 中的 World/Gate 启动路径会等待
`:scene_server` 注册。每个 `scene` 容器都会启动自己的 `DataService.Repo` 连接池，扩容时要把
数据库连接预算按 `app + scene_count` 估算，必要时降低 `MMO_DB_POOL_SIZE` 或提高 Postgres 限制。

业务镜像由 `.github/workflows/docker-publish.yml` 推送到 Aliyun ACR，`IMAGE_TAG` 应填该 workflow
发布的完整镜像地址。`web_client` 已逻辑归档，不属于日常发布；默认
`ALLOW_ARCHIVED_WEB_CLIENT_DEPLOY=false` 且 `WEB_CLIENT_IMAGE_TAG` 为空，`upgrade.sh` 只升级服务端。
只有用户显式要求部署归档 Web 客户端时，才手动触发
`.github/workflows/web-client-publish.yml`，并同时设置
`ALLOW_ARCHIVED_WEB_CLIENT_DEPLOY=true` 与非空 `WEB_CLIENT_IMAGE_TAG`。此时 `upgrade.sh` 才会从
镜像复制 `/usr/share/nginx/html` 到 `WEB_CLIENT_DIST_DIR`，供宿主机 nginx 的 `/client/` alias 服务。

日常升级优先使用：

```bash
cd /data/ex_mmo_cluster
./upgrade.sh
```
