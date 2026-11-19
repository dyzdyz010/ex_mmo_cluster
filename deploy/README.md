# Voxim server deployment

One release (`voxim_server`) runs the canonical World, Auth (HTTP) and Gate (QUIC) on one BEAM node.
Scenes are started from a topology file: one local Scene, plus any number of Scene peer nodes started
from the same release on the same host (Qinglan: two Scenes split at X = 41 m). Postgres holds the
authoritative overlay log, accounts/characters and NPC memories.

## Files

| File | Purpose |
|---|---|
| `build-image.sh <version>` | Build `voxim-server:<version>` (needs the sibling `Voxim` repo as a named build context) |
| `docker-compose.yml` | `db` (Postgres 16, 127.0.0.1 only) + `app` (host network, memory limit) |
| `.env.example` | Every setting; copy to `.env` |
| `upgrade.sh <version>` | Backup (pg_dump + published prefabs) → switch version → wait for QUIC |
| `nginx.conf.example` | TLS termination for the portal and game hosts (see Domains) |

## Domains

Flat names under `hemifuture.cn`, one level deep, so the shared `*.hemifuture.cn` wildcard certificate covers
them all. This also matches the other products on that host (`calix.`, `eval.`, `huanxi.`, `inkstone.`, `mail.`).
Hosts are split by audience: browsers carry cookies, while the game client carries bearer tokens, large
downloads and UDP.

| Host | Serves | Notes |
|---|---|---|
| `account.hemifuture.cn` | Player portal: `/auth` (account centre, `/` → `/auth`), `/admin` (invites) | `PHX_HOST`; mail links point here; session cookie stays on this host |
| `mmo.hemifuture.cn` | Game service: `/account/*` client API, `/game/*` world data, `/playtest/*` legacy; QUIC `20003/udp` | Shipped clients and the QUIC certificate (`server_name`) use this name, so keep it. `/auth` → 301 portal |
| `notify.mmo.hemifuture.cn` | Sender domain for Aliyun DirectMail (`noreply@notify.mmo.hemifuture.cn`, SMTP `smtpdm.aliyun.com:465`) | SPF/DKIM (`aliyun-cn-hangzhou`)/DMARC/MX records only, no web host; `mail.hemifuture.cn` is the Stalwart mailbox server, so keep them separate |

Names describe the role, not the project: the game may be renamed, and only page and mail text would follow.

Reserved; create these only when a feature needs them (prefixed with the service, like `notify.mmo.`):

- `mmo-admin.` — move `/admin` here when it needs an IP allow-list or extra auth in front.
- `mmo-cdn.` — client packages and large world assets via OSS+CDN.
- `mmo-status.` — a status page.

Further worlds or shards should come from a server list returned by the API, not from new DNS names in shipped
clients.

The brand site stays on `skopunarverk.com` (Cloudflare) and links to the portal.

Every proxied location must send `X-Real-IP $remote_addr`. The app trusts it only from a loopback peer and uses
it for per-client rate limits; without it, every player shares one 60-request/minute bucket.

## Data directory (`VOXIM_DATA_DIR`, mounted at `/srv/voxim`)

```
worldgen-manifest.json      # explicit generation manifest → content_version
kernel-manifest.bin         # published movement kernel; kernel_id = sha256(file)
world/<content_version>/    # generated baseline cache (L0 on demand, L1–L5 baked) + prefabs/ (player-published, back up)
scenes/scene-*.json         # Scene configs (L0 window, travel bounds, spawn, profile)
scenes/topology.json        # which Scenes run where (see below)
catalogs/                   # properties.json, environment.json, magic-catalog.json, prefabs/
tls/server.pem, server.key  # QUIC certificate (the client pins its CA)
invites.json                # invite-code digests for /playtest/*
```

The release runs as uid 1000 (`voxim`); on a Linux host `chown -R 1000:1000` the data dir. World generation writes
baseline files and published prefabs into it.

Topology (`VOXIM_TOPOLOGY`); at most one `local` Scene, every `peer` Scene gets its own node:

```json
{"scenes": [
   {"scene_id": 1, "config": "/srv/voxim/scenes/scene-1.json", "node": "local", "replica": true},
   {"scene_id": 2, "config": "/srv/voxim/scenes/scene-2.json", "node": "peer", "schedulers": "1:1"}],
 "neighbours": [[1, 2]],
 "report": "/srv/voxim/scenes/topology-state.json"}
```

Without `VOXIM_TOPOLOGY` the release runs a single Scene from `VOXIM_M1_CONFIG` against the World directly.

## First start

```sh
./build-image.sh 20260930-release01        # on the build machine
docker save voxim-server:20260930-release01 | gzip > voxim-server.tgz   # copy + docker load on the host
cp .env.example .env                        # fill secrets, version, paths
docker compose up -d
docker compose logs -f app                  # migrations, bake check, voxim_topology_ready, voxim_quic_listener
```

Startup order is fixed by the application dependencies: migrations (`bin/server`) → World (bakes / verifies the
L1–L5 baseline before anything listens) → Scenes (topology) → Auth + Gate. A cold baseline bake can take minutes.

## Operations

- Remote shell: `docker compose exec app bin/voxim_server remote`; one-off calls: `bin/voxim_server rpc '<expr>'`.
- Catalog publication for a release (advances the playable property catalog in one World transaction):
  `bin/voxim_server rpc 'VoxelRegion.World.publish_parameters(VoxelRegion.World, "/srv/voxim/catalogs/<next>.json", Base.decode16!("<current digest>", case: :lower))'`,
  then point `VOXIM_PROPERTY_CATALOG_PATH` at the new file.
- Upgrade: `./upgrade.sh <version>`. Rollback: `pg_restore --clean` the printed dump, restore the prefabs archive,
  set the old `VOXIM_VERSION`, `docker compose up -d app`.
- Client and server must match: the Gate rejects a client whose protocol version, kernel_id or profile_id differ.
  Ship a new client package together with any server that changes the protocol (Voxim `Docs/Distribution.md`).

## Sizing notes (from the Qinglan host)

- No swap + a runaway BEAM stalls the whole host: always set `VOXIM_MEM_LIMIT` below host RAM; two Scenes steady at
  1.4–1.7 GB, so 8 GB hosts use `4000m`; keep `VOXEL_REGION_PAYLOAD_CACHE_MB` and generation concurrency small.
  Since 2026-11-19 Qinglan runs alone on a Tencent Cloud 2 vCPU / 8 GB host (7679 MiB visible) with `5500m`,
  leaving about 2.1 GiB for Postgres, nginx, dockerd and the cloud agents.
- Host networking is required when the host routes traffic through a TUN proxy (bridged container UDP replies are lost).
- UE's default `HttpActivityTimeout` (30 s) is shorter than a cold region request; the client sets 120–180 s.

## NPC 常驻应用

同一 `voxim_server` release 包含平级的 Gate 和 NPC 应用。NPC 登记、模型配置与持久化表保持原语义，
运维 RPC 入口改为 `NpcServer.Registry`，状态读 `NpcServer.Bootstrap.status()`。
Gate 重启不重启 NPC；正式服务启动由 `NpcServer.Bootstrap` 恢复 enabled 登记。
详见 [NPC 应用说明](../apps/npc_server/README.md)。升级请重启 release，旧 `GateServer.Npc.*` 名称不保留兼容转发。

统一形态（注册表 brain `"npc"`）的登记要求运行环境里有三组变量，都不入库、缺一个登记即失败：选择用的 Jev 接口
（缺省 `TYPESAFE_API_URL` / `TYPESAFE_API_KEY` / `TYPESAFE_MODEL`；`NPC_JEV_API=openai` 时改用 `NPC_JEV_URL` / `NPC_JEV_KEY` /
`NPC_JEV_MODEL`），记忆库地址 `NPC_LIFE_HINDSIGHT_URL`（或写在登记参数里），写作（反思、日计划、说话）的接口
`NPC_REFLECT_URL` / `NPC_REFLECT_KEY` / `NPC_REFLECT_MODEL`（形状由 `NPC_REFLECT_API` 选）。
各自的用途与请求形状以 [NPC 运行时说明](../apps/npc_server/lib/npc_server/README.md) 为准（“注册表”“反思”两节），这里不复述。
变量名与说明见 `.env.example` 的 NPC 一组（整组注释掉、值留空：启用时取消注释并填写；可选项不用就保持注释——
空值不等于不写：`NPC_JEV_API`、`NPC_REFLECT_API`、`NPC_JEV_THINKING`、`NPC_JEV_MAX_TOKENS`、`NPC_LLM_TIMEOUT_MS` 为空时登记被拒，
三个 `*_EFFORT`（`NPC_LLM_EFFORT`、`NPC_JEV_EFFORT`、`NPC_REFLECT_EFFORT`）为空时空串会原样随请求发出，`NPC_LLM_CACERTFILE`
为空时空串会被当成 CA 文件路径、https 请求连不上（最后这条是读源码所得，未实测））。llm / life 大脑另需 `NPC_LLM_*` 一组，
同样列在 `.env.example` 里。
**现状（2026-11-18）**：生产 NPC `enabled=0`，这些变量还没有配进任何部署环境；`.env.example` 已列出 NPC 一组，
启用 `"npc"` 登记之前要先在 `.env` 里填好。

**每天花费额度（2026-11-19 起）**：配了 `NPC_LIFE_HINDSIGHT_URL` 即视为启用 NPC，此时 `NPC_SPEND_LIMIT_USD`、`NPC_SPEND_STOP_RATIO`、
`NPC_SPEND_PRICES` 必填（`NPC_SPEND_OFF_PEAK` 可选），缺或非法 **release 启动失败**；没配 `NPC_LIFE_HINDSIGHT_URL` 时额度不读这些变量，
Life 的后台工作按“无法计量”一直停着（现状生产不受影响）。形状与取值见 `.env.example` 的花费额度一组，行为见
[NPC 运行时说明](../apps/npc_server/lib/npc_server/README.md)“每天花费额度”。额度要读 Hindsight 自己的 LLM 追踪并按库开关自动巩固，
所以 Hindsight 容器的 `HINDSIGHT_API_LLM_TRACE_ENABLED` 与 `ENABLE_BANK_CONFIG_API` **不得关**。账本表 `npc_spend_ledger` 随常规迁移建立。

**模型 key 与崩溃转储**：各 `*_KEY`（含 llm / life 大脑的 `NPC_LLM_KEY`）登记时先校验是合法的 HTTP 头值：非空、首尾为
0x21–0x7E、中间只有 0x20–0x7E 与制表符（不含 CR / LF 等控制字符，RFC 9110 §5.5；也不含 NBSP、零宽空格、全角字符等非 ASCII
字节——有意比 RFC 严格，与 Mint HTTP/1 一致），不合法即登记被拒、错误只报变量名与原因，不自动 trim——Windows 编辑的 `.env`
留下 CRLF、从网页复制 key 时带进的不可见字符都要先改掉。之后在 NPC 进程里以闭包（`NpcServer.Secret`）流转，进程状态与崩溃
报告里不是原文；据 ERLEF 安全工作组《Protecting sensitive data》，闭包也不会写进崩溃转储（本仓库未测）。

残余是发请求时的明文请求头（读 finch 0.25.0 / mint 1.11.0 / hpax 1.1.0 与本机 OTP / Elixir 源码所得，未实测；细节见
`NpcServer.Http` moduledoc 的“密钥”）：
- `https` 模型主机走 HTTP/2，在途请求连同请求头存在 Finch 的 HTTP/2 池进程里，请求结束才删除；
- 写作 endpoint 的 Messages 形状用 `x-api-key`，它不在 HPACK 静态表里，key 会进连接的动态编码表，**留在池进程里直到连接关闭
  或被新条目挤出**，不只是在途期间（Bearer 用的 `authorization` 在静态表里，值不进动态表）；
- 池进程崩溃时 Finch 没有 `format_status`：Elixir 打印的 gen_statem 终止报告里，`Queue:`（可能含排队中的请求及其头）在任何
  日志级别都会出现，`State:`（在途请求与编码表）在 debug 级别出现——生产不要开 debug 级别日志；
- VM 崩溃时这些进程的堆会进 `erl_crash.dump`。

建议生产在 `.env` 里写 `ERL_CRASH_DUMP_BYTES=0`（ERTS 读这个环境变量，0 表示不写转储），或至少保证转储文件不落在
可被他人读取、会被收集上传的位置；代价是 VM 整体崩溃（如内存耗尽）后没有转储可查，只剩 release 日志与容器退出码。

### 青岚内存兜底

`qinglan-memory-guard.py` 是青岚部署运维脚本，安装于 `/data/voxim_qinglan/ops/`，dyz cron每分钟调用。
原始cgroup v2 memory.current >4300MiB告警，>4800MiB持续180秒受控重启（对应容器上限5500m，余量规则见脚本常量注释）；每日UTC21:00也请求重启，所有自动重启共用一小时冷却与flock。
日志按UTC日轮转、14天/16MiB上限；SMTP复用现有release.env，收件人由ops/notify.json指定。
`--dry-run` 不重启、不发邮件、不写状态，仅真实采样和验证判定；停用删除crontab中 `# qinglan-memory-guard` 行。
阈值及完整部署记录见 `.demo/observe/qinglan-deploy-20261029/RUNBOOK.md` §8。
