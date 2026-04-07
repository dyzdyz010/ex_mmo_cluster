# CLAUDE.md

## Project Overview

This is an MMORPG game server cluster built with Elixir/OTP. It is structured as a Mix umbrella project with 12 specialized microservice applications under `apps/`. The system uses distributed Erlang clustering with libcluster for auto-discovery, PostgreSQL (via Ecto) for persistent data, a custom binary protocol for client communication (see `PROTOCOL.md`), and Rust NIFs (via Rustler) for performance-critical physics and spatial operations.

## Tech Stack

- **Language**: Elixir ~> 1.15, Erlang OTP 27
- **Runtime versions**: See `.tool-versions` (Erlang 27.3.4.9, Elixir 1.18.4-otp-27)
- **Web framework**: Phoenix 1.6 (auth_server, visualize_server)
- **Database**: PostgreSQL via Ecto (primary), Mnesia via Memento (legacy, migration in progress)
- **Serialization**: Custom binary codec (`GateServer.Codec`, see `PROTOCOL.md`), JSON (Jason)
- **Native extensions**: Rust via Rustler 0.36 (physics with rapier3d-f64, spatial indexing with octree)
- **Clustering**: libcluster (node discovery), Horde (distributed registry/supervisor)
- **Frontend**: Phoenix LiveView, esbuild, Tailwind CSS

## Repository Structure

```
ex_mmo_cluster/              # Umbrella root
├── config/config.exs        # Global umbrella configuration
├── mix.exs                  # Root project definition
├── .tool-versions           # asdf runtime versions
├── PROTOCOL.md              # Wire protocol specification
├── MIGRATION_PLAN.md        # Architecture migration roadmap
└── apps/
    ├── gate_server/         # TCP socket server, custom binary codec
    ├── agent_server/        # Player character logic handler (GenServer per player)
    ├── agent_manager/       # Manages agent_server instances
    ├── scene_server/        # Scene logic, physics (Rust NIFs), AOI system
    ├── world_server/        # World-level logic, scene management
    ├── beacon_server/       # Cluster service discovery (libcluster + Horde HA)
    ├── auth_server/         # User authentication (Phoenix web app)
    ├── visualize_server/    # Game state visualization (Phoenix LiveView)
    ├── data_init/           # Database schema definitions (Mnesia tables, legacy)
    ├── data_service/        # Database interface (PostgreSQL via Ecto + poolboy)
    ├── data_store/          # On-disk persistent database interface (legacy Mnesia)
    └── data_contact/        # Database cluster node coordination (legacy Mnesia)
```

## Architecture Layers

```
Clients
  ↓ (custom binary protocol over TCP, packet:4 framing)
Connection Layer:    auth_server, gate_server
  ↓
Game Logic Layer:    agent_server / agent_manager, scene_server / world_server
  ↓
Data Layer:          data_service (PostgreSQL via Ecto)
  ↓
Infrastructure:      beacon_server (libcluster + Horde, distributed)
```

## Common Commands

```bash
# Install dependencies
mix deps.get

# Compile all apps
mix compile

# Run the formatter
mix format

# Run tests (all apps, requires distributed node for some)
mix test

# Run tests for a specific app (standalone, no cluster needed)
cd apps/gate_server && mix test --no-start
cd apps/data_service && mix test --no-start
cd apps/beacon_server && mix test --no-start

# Initialize Mnesia database (legacy)
mix db_initialize

# Run Ecto migrations (PostgreSQL)
mix ecto.migrate -r DataService.Repo

# Migrate data from Mnesia to PostgreSQL
mix migrate_to_pg

# Start a cluster node (interactive)
iex --name <node_name> --cookie mmo -S mix

# Example: start a scene server node
iex --name scene1 --cookie mmo -S mix
```

## Code Conventions

### Module Organization

Each app follows a consistent structure:

```
app_name/lib/
├── app_name.ex              # Main module
└── app_name/
    ├── application.ex       # OTP Application (supervision tree root)
    ├── sup/                 # Supervisor modules
    │   ├── interface_sup.ex # Message routing supervisor
    │   └── {domain}_sup.ex  # Domain-specific supervisors
    ├── worker/              # GenServer workers
    │   ├── interface.ex     # Cluster interface (beacon registration via BeaconServer.Client)
    │   └── {domain}.ex      # Domain logic workers
    ├── native/              # Rust NIF bindings (scene_server only)
    ├── schema/              # Ecto schemas (data_service only)
    ├── db_ops/              # Database operation modules
    └── codec.ex             # Binary protocol codec (gate_server only)
```

### OTP Patterns

- **Supervision strategy**: `:one_for_one` (restart only the failed child)
- **DynamicSupervisor**: Used for spawning dynamic worker pools (players, connections)
- **GenServer callbacks**: Always annotated with `@impl true`
- **Process groups**: `:pg` module for cluster-wide pub/sub broadcasting
- **Interface pattern**: Each app has `worker/interface.ex` that registers with the beacon via `BeaconServer.Client` and declares its resource/requirement dependencies
- **Service discovery**: `BeaconServer.Client.join_cluster/0`, `.register/4`, `.get_requirements/1`

### Naming

- Modules: `PascalCase` following `{AppName}.{Feature}.{Type}` (e.g., `SceneServer.AoiManager`)
- Files: `snake_case.ex` matching module name segments
- App names: `snake_case` with descriptive suffixes (`_server`, `_manager`, `_service`, `_store`)

### Code Style

- Use `require Logger` for logging; use `Logger.warning/2` (not deprecated `Logger.warn`)
- Pattern matching in function heads over conditional logic
- Pipe operator `|>` for data transformation chains
- Map-based state in GenServers: `%{key: value}`
- Comments may be in Chinese (original author's language)

## Database

### PostgreSQL (Primary — via Ecto)

Configured in `config/config.exs` under `:data_service, DataService.Repo`.

Schemas defined in `apps/data_service/lib/data_service/schema/`:
- `DataService.Schema.Account` — User accounts (id, username, password, salt, email, phone)
- `DataService.Schema.Character` — Player characters (id, account, name, title, attrs, position, hp/sp/mp)

Migrations in `apps/data_service/priv/repo/migrations/`.

### Mnesia (Legacy — being phased out)

Table definitions remain in `apps/data_init/lib/table_def.ex` for the migration task (`mix migrate_to_pg`). The `data_store` and `data_contact` apps still reference Mnesia but `data_service` worker now exclusively uses PostgreSQL.

## Rust Native Extensions

Located in `apps/scene_server/native/`:

| Crate | Rustler | Purpose |
|-------|---------|---------|
| `scene_ops` | 0.36.1 | Physics simulation (rapier3d-f64 0.16), character movement |
| `octree` | 0.36.1 | Spatial indexing for efficient neighbor queries |
| `coordinate_system` | 0.36.1 | Legacy coordinate system (replaced by octree) |

Key NIF module: `SceneServer.Native.SceneOps`

Functions: `new_character_data/5`, `movement_tick/2`, `update_character_movement/5`, `get_character_location/2`, `new_physics_system/0`

**Rustler 0.36 API**: Resources use `#[rustler::resource_impl] impl Resource for T {}` (not the old `rustler::resource!` macro). NIF functions use `#[rustler::nif]` attribute. Module init uses `rustler::init!("Elixir.Module.Name")` without explicit function list.

Building Rust NIFs requires a Rust toolchain (tested with rustc 1.94).

## Client Protocol

See `PROTOCOL.md` for the complete wire protocol specification.

- **Framing**: 4-byte big-endian length prefix (`{packet, 4}` on TCP socket)
- **Format**: `<<msg_type::8, payload::binary>>` — Erlang binary pattern matching
- **Codec**: `GateServer.Codec` — zero-allocation decode for fixed-size messages
- **Hot path**: Movement (89 bytes), PlayerMove broadcast (33 bytes)

## Cluster Service Discovery

Beacon server provides distributed service discovery:

- **libcluster**: Auto-discovers cluster nodes (gossip strategy in dev, configurable for prod)
- **Horde**: Distributed registry ensures `BeaconServer.Beacon` is accessible cluster-wide
- **BeaconServer.Client**: Stable API used by all Interface modules — no hardcoded node names
- **No single point of failure**: Beacon process can run on any node, discovered via Horde registry

## Testing

- Framework: ExUnit (built-in)
- Run standalone app tests: `cd apps/<app> && mix test --no-start`
- Apps with database tests (data_service) require PostgreSQL running
- Apps requiring cluster (data_contact, data_store) need distributed Erlang
- CI pipeline: `.github/workflows/ci.yml`

| App | Tests | Notes |
|-----|-------|-------|
| gate_server | 46 | Codec, TCP framing, dispatch |
| data_service | 10 | Ecto schemas, duplicate checks |
| beacon_server | 7 | Client API, registration, requirements |
| scene_server | 4 | NIF calls (requires Rust) |
| agent_server | 2 | Smoke test |
| world_server | 2 | Smoke test |

## Key Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `phoenix` | 1.6 | Web framework (auth, visualization) |
| `phoenix_live_view` | 0.17 | Real-time UI for visualize_server |
| `ecto_sql` | ~> 3.12 | PostgreSQL database interface |
| `postgrex` | latest | PostgreSQL driver |
| `memento` | 0.3.2 | Mnesia wrapper (legacy, being phased out) |
| `rustler` | ~> 0.36 | Elixir-to-Rust NIF bridge |
| `libcluster` | ~> 3.4 | Cluster node auto-discovery |
| `horde` | ~> 0.9 | Distributed registry and supervisor |
| `poolboy` | 1.5 | Worker pool management (data_service) |
| `bcrypt_elixir` | 3.x | Password hashing (auth_server) |
| `jason` | 1.4 | JSON encoding/decoding |

## Notes for AI Assistants

- This is an umbrella project — always consider which app(s) a change affects
- Inter-app communication uses GenServer calls/casts via Interface modules; respect this boundary
- The `scene_server` app has Rust NIFs — changes to native code require Rust compilation with Rustler 0.36 API
- **Data layer**: `data_service` uses PostgreSQL via Ecto exclusively. Mnesia code in `data_init`/`data_store`/`data_contact` is legacy
- **Service discovery**: All Interface modules use `BeaconServer.Client` — never hardcode node names
- The project uses distributed Erlang — node names and cookies are required for clustering
- Client protocol uses custom binary codec (`GateServer.Codec`), see `PROTOCOL.md` for wire format
- Legacy `.proto` files remain in git submodule (`mmo_protos`) for reference but are not used
- **CI**: GitHub Actions configured — run `mix compile`, `mix test --no-start` for standalone apps
- See `MIGRATION_PLAN.md` for the full architecture migration roadmap (Phases 1-3 complete, 4-5 pending)
