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
- **⚡ Heavy math lives in Rust.** The hot paths — rigid-body physics, spatial indexing, terrain noise — are native NIFs. The terrain generator alone runs **~39× faster** than its Elixir prototype (a 1-million-cell heightmap in ~188 ms).
- **🧬 A world with rules, not just geometry.** Light, heat, chemical reactions, and electric circuits are first-class field simulations. Place a torch, complete a circuit, start a fire — gameplay *emerges* from physics instead of being scripted.
- **🛡️ Fault-tolerant and horizontally scalable.** Built on Erlang/OTP: a self-healing supervision tree, automatic cluster discovery, and a distributed registry that keeps the world coherent across nodes — and survives the loss of any one of them.

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
| `data_service` | Canonical persistence (PostgreSQL via Ecto) |
| `mmo_contracts` | Shared cross-app contracts |

## Tech stack

| Layer | Choice |
|-------|--------|
| Runtime | Elixir 1.19 · Erlang/OTP 28 |
| Clustering | `libcluster` (discovery) · `Horde` (distributed registry / supervisor) |
| Web | Phoenix 1.8 · LiveView 1.1 · Bandit |
| Persistence | PostgreSQL via Ecto |
| Native compute | Rust via Rustler 0.37 — `rapier3d-f64` physics, octree, terrain noise |
| Wire format | Voxim QUIC with Session/Movement/Voxel codecs in `mmo_contracts`; legacy TCP uses `packet:4` |

## Quickstart

```bash
mix deps.get
mix compile
mix ecto.migrate -r DataService.Repo
# launch an interactive cluster node
iex --name scene1 --cookie mmo -S mix
```

Run the tests:

```bash
mix test
```

> **Windows note:** compile native NIFs from a VS Dev Command Prompt (`VsDevCmd.bat`) so `cl` / `nmake` are on PATH. See `CLAUDE.md` → *Windows 运行补充*.

## The clients

| Client | Engine | Role |
|--------|--------|------|
| **[Voxim](../Voxim)** | Unreal Engine 5.8 | 唯一客户端；阶段与验收以其 starter、M1/M4a/R7 记录为准 |

`clients/Voxia`、`clients/web_client`、`clients/bevy_client` 已弃用（2026-09-30），服务端对应的旧链路已删除。

---

<div align="center">
<sub><b>The Genesis Initiative</b> — a living world, simulated honestly.</sub>
</div>
