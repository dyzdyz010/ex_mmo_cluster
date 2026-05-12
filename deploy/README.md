# deploy

本目录是生产 Docker Compose 部署入口。

## 文件职责

- `docker-compose.yml`：定义 `postgres`、`app` 和可横向扩缩的 `scene` 服务。
- `.env.example`：部署环境变量模板，包含镜像地址、端口、数据库、集群和 `SCENE_SERVER_COUNT`。
- `nginx.conf.example`：宿主机 nginx HTTPS 反向代理模板。
- `setup_multi_fixture.exs`：本地/临时验收数据准备脚本，不参与容器启动。

## 运行关系

`app` 使用镜像内的 `ex_mmo_cluster` release，启动 edge/world/data 等控制面与入口服务。
`scene` 使用同一镜像内的 `ex_mmo_scene` release，只启动 scene runtime；不要给 `scene`
绑定宿主机端口，这样才能通过 Compose 扩容多个副本。

配置 scene server 数量时修改 `.env` 中的 `SCENE_SERVER_COUNT`，并用下面的命令应用。
`SCENE_SERVER_COUNT` 由 shell 展开，所以需要先把 `.env` 导入当前 shell：

```bash
set -a; . ./.env; set +a
docker compose up -d --scale scene=${SCENE_SERVER_COUNT}
```

`SCENE_SERVER_COUNT` 必须至少为 `1`，因为 `app` 中的 World/Gate 启动路径会等待
`:scene_server` 注册。每个 `scene` 容器都会启动自己的 `DataService.Repo` 连接池，扩容时要把
数据库连接预算按 `app + scene_count` 估算，必要时降低 `MMO_DB_POOL_SIZE` 或提高 Postgres 限制。

镜像由 `.github/workflows/docker-publish.yml` 推送到 Aliyun ACR，`IMAGE_TAG` 应填该 workflow
发布的完整镜像地址。
