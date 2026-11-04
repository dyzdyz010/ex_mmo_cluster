<div align="center">

# The Genesis Initiative

### A planet-scale, server-authoritative, emergent voxel MMO — built on the BEAM, accelerated by Rust.

*Every block is server truth. Every law of the world is simulated. Nothing the client says is taken on faith.*

</div>

---

`ex_mmo_cluster` is the beating heart of **The Genesis Initiative**: a distributed game server that generates an **unbounded** procedural voxel universe, simulates its physics and emergent systems, and streams that world — as authoritative truth — to the **[Voxim](../Voxim)** client (Unreal Engine 5.8), its only client.

It is an experiment in answering one question: *what does an MMO look like when the server is genuinely the source of truth, the world is procedurally infinite, and the engine underneath it never stops scaling?*

## Why this is different

- **🌍 Server-authoritative by construction.** Movement, voxel edits, physics, object state, and field interactions are all confirmed by the server. Clients render and predict — they never invent. Authentication and authority checks remain explicit trust boundaries.
- **♾️ An unbounded, deterministic world.** Terrain is procedurally generated from a single seed — flat plains, sunken basins, and ridged mountains breaking **1 km** in height — across a 32 × 32 km showcase that is, mathematically, infinite. Voxim receives authoritative region payloads and overlay transactions; the server owns the explicit generation manifest and persists edits.
- **⚡ Native simulation kernels.** Rust NIFs provide the shared Voxim movement kernel, thermal simulation, and world generation. Elixir owns runtime orchestration and authoritative commits.
- **🧬 A world with rules, not just geometry.** The canonical World commits heat, combustion, phase changes, liquids, loose materials, and electric-circuit effects through its authoritative runtime. See the [voxel subsystem](apps/voxel_region/README.md) for ownership and implementation boundaries.
- **🛡️ Explicit OTP ownership and topology.** Supervision trees own local processes. A configured JSON topology starts Scene peers on the same host and registers their routes; the canonical World remains on the main node. This deployment does not establish arbitrary-node-loss high availability.

Current ownership, composition and acceptance boundaries: [Voxim runtime](docs/00-current-truth/design/server/voxim-runtime.md).

## Architecture

A Mix umbrella of focused OTP applications, each a clean responsibility boundary, communicating over stable interfaces and a custom binary protocol.

```
                        ┌──────────────────────────────────────────┐
   Active client ──────▶│  Connection   auth_server · gate_server  │  custom binary protocol
   (Voxim / UE5)        │               QUIC streams + datagrams   │  over QUIC
                        └──────────────────────────────────────────┘
                                          │
                        ┌──────────────────────────────────────────┐
                        │  Game logic   scene_server · world_server │  ← Rust NIFs
                        │  Canonical    voxel_region                │
                        │               material / thermal / edits │
                        └──────────────────────────────────────────┘
                                          │
                        ┌──────────────────────────────────────────┐
                        │  Data         data_service (PostgreSQL / Ecto)
                        └──────────────────────────────────────────┘
```

| App | Role |
|-----|------|
| `gate_server` | Voxim QUIC gateway (auth, session, voxel intents) |
| `auth_server` | Authentication (Phoenix) |
| `scene_server` | Movement authority, collision history, AOI and body simulation |
| `voxel_region` | Voxim canonical World, material transactions, generated baseline, overlay persistence and read-only replicas |
| `world_server` | Scene routing, cross-Scene transfer and the deployment topology (`WorldServer.Topology`) |
| `npc_server` | Resident autonomous NPC perception, decisions and actions; Scene owns NPC bodies, movement and AOI ([runtime](apps/npc_server/README.md)) |
| `data_service` | Canonical persistence (PostgreSQL via Ecto) |
| `mmo_contracts` | Shared cross-app contracts |

## Tech stack

| Layer | Choice |
|-------|--------|
| Runtime | Elixir 1.19 · Erlang/OTP 28 |
| Topology | `WorldServer.Session` · optional `WorldServer.Topology` with explicit JSON routes and local OTP `:peer` nodes |
| Web | Phoenix 1.8 · LiveView 1.1 · Bandit |
| Persistence | PostgreSQL via Ecto |
| Native compute | Rust via Rustler 0.37.3 — shared Voxim movement, thermal simulation, world generation |
| Wire format | Voxim QUIC with Session/Movement/Voxel codecs in `mmo_contracts` |

## Quickstart

The server supports Linux only. Run development, builds and tests as native Linux processes; on this Windows host, use WSL Linux. Install the Erlang/Elixir versions in `.tool-versions`, Rust and the required Linux build dependencies, with PostgreSQL available for database commands. See the [engineering guide](docs/30-reference/engineering/project-engineering-guide.md) for commands and [deployment guide](deploy/README.md) for the single `voxim_server` release and Scene topology.

```bash
mix deps.get
mix compile
mix ecto.migrate -r DataService.Repo
# launch an interactive development node
iex --name scene1 --cookie mmo -S mix
```

Run the tests:

```bash
mix test
```

From Windows, enter the Linux workspace with `wsl.exe --cd /mnt/d/hemifuture/ex_mmo_cluster`, then run the commands above inside WSL. Windows runs the UE client and Linux control tools; Linux Docker images are used for distribution and production.

## The clients

| Client | Engine | Role |
|--------|--------|------|
| **[Voxim](../Voxim)** | Unreal Engine 5.8 | 唯一客户端；阶段与验收以其 starter、M1/M4a/R7 记录为准 |

`clients/Voxia`、`clients/web_client`、`clients/bevy_client` 已弃用（2026-09-30），服务端对应的旧链路已删除。

---

<div align="center">
<sub><b>The Genesis Initiative</b> — a living world, simulated honestly.</sub>
</div>
