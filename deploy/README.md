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
| `voxim.hemifuture.cn` | Player portal: `/auth` (account centre, `/` → `/auth`), `/admin` (invites) | `PHX_HOST`; mail links point here; session cookie stays on this host |
| `mmo.hemifuture.cn` | Game service: `/account/*` client API, `/game/*` world data, `/playtest/*` legacy; QUIC `20003/udp` | Shipped clients and the QUIC certificate (`server_name`) use this name, so keep it. `/auth` → 301 portal |
| `notify.hemifuture.cn` | Sender domain for Aliyun DirectMail (`noreply@notify.hemifuture.cn`) | SPF/DKIM/DMARC records only; `mail.hemifuture.cn` is the Stalwart mailbox server, so keep them separate |

Reserved; create these only when a feature needs them:

- `voxim-admin.` — move `/admin` here when it needs an IP allow-list or extra auth in front.
- `voxim-cdn.` — client packages and large world assets via OSS+CDN.
- `voxim-status.` — a status page.

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
- Host networking is required when the host routes traffic through a TUN proxy (bridged container UDP replies are lost).
- UE's default `HttpActivityTimeout` (30 s) is shorter than a cold region request; the client sets 120–180 s.
