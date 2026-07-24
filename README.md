<div align="center">

# The Genesis Initiative

### A planet-scale, server-authoritative, emergent voxel MMO — built on the BEAM, accelerated by Rust.

*Every block is server truth. Every law of the world is simulated. Nothing the client says is taken on faith.*

</div>

---

`ex_mmo_cluster` is the beating heart of **The Genesis Initiative**: a distributed game server that generates an **unbounded** procedural voxel universe, simulates its physics and emergent systems, and streams that world — as authoritative truth — to native clients like **[Voxia](clients/Voxia)** (Unreal Engine 5.8).

It is an experiment in answering one question: *what does an MMO look like when the server is genuinely the source of truth, the world is procedurally infinite, and the engine underneath it never stops scaling?*

## Why this is different

- **🌍 Server-authoritative by construction.** Movement, voxel edits, physics, object state, and field interactions are all confirmed by the server. Clients render and predict — they never invent. Cheating isn't patched; it's architecturally impossible.
- **♾️ An unbounded, deterministic world.** Terrain is procedurally generated from a single seed — flat plains, sunken basins, and ridged mountains breaking **1 km** in height — across a 32 × 32 km showcase that is, mathematically, infinite. We *transmit the seed and persist only what changed*; pristine terrain costs nothing to store.
- **⚡ Heavy math lives in Rust.** The hot paths — rigid-body physics, spatial indexing, terrain noise — are native NIFs. The terrain generator alone runs **~39× faster** than its Elixir prototype (a 1-million-cell heightmap in ~188 ms).
- **🧬 A world with rules, not just geometry.** Light, heat, chemical reactions, and electric circuits are first-class field simulations. Place a torch, complete a circuit, start a fire — gameplay *emerges* from physics instead of being scripted.
- **🛡️ Fault-tolerant and horizontally scalable.** Built on Erlang/OTP: a self-healing supervision tree, automatic cluster discovery, and a distributed registry that keeps the world coherent across nodes — and survives the loss of any one of them.

## Architecture

A Mix umbrella of focused OTP applications, each a clean responsibility boundary, communicating over stable interfaces and a custom binary protocol.

```
                        ┌──────────────────────────────────────────┐
   Active client ──────▶│  Connection   auth_server · gate_server  │  custom binary protocol
   (Voxia / UE5)        │               (TCP, packet:4 framing)    │  over TCP
                        └──────────────────────────────────────────┘
                                          │
                        ┌──────────────────────────────────────────┐
                        │  Game logic   scene_server · world_server │  ← Rust NIFs:
                        │               physics · AOI · voxels ·    │    rapier3d-f64 physics,
                        │               fields · terrain            │    octree, terrain noise
                        └──────────────────────────────────────────┘
                                          │
                        ┌──────────────────────────────────────────┐
                        │  Data         data_service (PostgreSQL / Ecto)
                        └──────────────────────────────────────────┘
                                          │
                        ┌──────────────────────────────────────────┐
                        │  Infra        beacon_server (libcluster + Horde)
                        └──────────────────────────────────────────┘
```

| App | Role |
|-----|------|
| `gate_server` | TCP gateway + custom binary codec — the client's door into the cluster |
| `auth_server` | Authentication (Phoenix) |
| `scene_server` | Hot game truth: physics, AOI, voxel store, fields — **Rust-accelerated** |
| `world_server` | World-layer coordination + durable voxel control plane |
| `data_service` | Canonical persistence (PostgreSQL via Ecto) |
| `beacon_server` | Cluster service discovery (libcluster + Horde) |
| `visualize_server` | Live world visualization (Phoenix LiveView) |
| `mmo_contracts` | Shared cross-app contracts |

## Tech stack

| Layer | Choice |
|-------|--------|
| Runtime | Elixir 1.19 · Erlang/OTP 28 |
| Clustering | `libcluster` (discovery) · `Horde` (distributed registry / supervisor) |
| Web | Phoenix 1.8 · LiveView 1.1 · Bandit |
| Persistence | PostgreSQL via Ecto |
| Native compute | Rust via Rustler 0.37 — `rapier3d-f64` physics, octree, terrain noise |
| Wire format | Custom binary protocol (`packet:4`); see `docs/30-reference/protocol/2026-04-10-线协议规范.md` |

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
| **[Voxia](clients/Voxia)** | Unreal Engine 5.8 | 唯一现役产品客户端；Milestone A / A10 lifecycle、完整 XYZ near/far 流送/transition/后继预取活性、阶段 2、跨 LOD 表面材质语义及最终绑定已收口，阶段 3 尚未启动 |
| [`clients/web_client`](clients/web_client) | TypeScript · Three.js | 归档；仅显式点名时使用 |
| [`clients/bevy_client`](clients/bevy_client) | Rust · Bevy | 归档；仅显式点名时使用 |

---

<div align="center">
<sub><b>The Genesis Initiative</b> — a living world, simulated honestly.</sub>
</div>
