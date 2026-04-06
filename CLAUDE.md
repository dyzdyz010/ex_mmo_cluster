# CLAUDE.md

## Project Overview

This is an MMORPG game server cluster built with Elixir/OTP. It is structured as a Mix umbrella project with 12 specialized microservice applications under `apps/`. The system uses distributed Erlang clustering, Mnesia for the database layer, Protocol Buffers for client communication, and Rust NIFs (via Rustler) for performance-critical physics and spatial operations.

## Tech Stack

- **Language**: Elixir ~> 1.14, Erlang OTP 25
- **Runtime versions**: See `.tool-versions` (Erlang 25.2.2, Elixir 1.14.3-otp-25)
- **Web framework**: Phoenix 1.6 (auth_server, visualize_server)
- **Database**: Mnesia via Memento (distributed Erlang database)
- **Serialization**: Protocol Buffers (protox), JSON (Jason)
- **Native extensions**: Rust via Rustler (physics with rapier3d, spatial indexing with octree)
- **Frontend**: Phoenix LiveView, esbuild, Tailwind CSS

## Repository Structure

```
ex_mmo_cluster/              # Umbrella root
├── config/config.exs        # Global umbrella configuration
├── mix.exs                  # Root project definition
├── .tool-versions           # asdf runtime versions
└── apps/
    ├── gate_server/         # TCP socket server for client connections
    ├── agent_server/        # Player character logic handler (GenServer per player)
    ├── agent_manager/       # Manages agent_server instances
    ├── scene_server/        # Scene logic, physics (Rust NIFs), AOI system
    ├── world_server/        # World-level logic, scene management
    ├── beacon_server/       # Cluster-wide resource discovery & monitoring
    ├── auth_server/         # User authentication (Phoenix web app)
    ├── visualize_server/    # Game state visualization (Phoenix LiveView)
    ├── data_init/           # Database schema definitions (Mnesia tables)
    ├── data_service/        # In-memory database interface (poolboy worker pool)
    ├── data_store/          # On-disk persistent database interface
    └── data_contact/        # Database cluster node coordination
```

## Architecture Layers

```
Clients
  ↓
Connection Layer:    auth_server, gate_server
  ↓
Game Logic Layer:    agent_server / agent_manager, scene_server / world_server
  ↓
Data Layer:          data_service (RAM), data_store (disk), data_contact (cluster)
  ↓
Infrastructure:      beacon_server (cluster coordination)
```

## Common Commands

```bash
# Install dependencies
mix deps.get

# Compile all apps
mix compile

# Run the formatter
mix format

# Run tests (all apps)
mix test

# Run tests for a specific app
mix test apps/scene_server/test/

# Generate protobuf code (gate_server)
mix proto_gen

# Initialize database
mix db_initialize

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
    │   ├── interface.ex     # Message interface (handles incoming calls/casts)
    │   └── {domain}.ex      # Domain logic workers
    ├── native/              # Rust NIF bindings (scene_server only)
    ├── db_ops/              # Database operation modules
    └── proto/               # Protocol Buffer definitions
```

### OTP Patterns

- **Supervision strategy**: `:one_for_one` (restart only the failed child)
- **DynamicSupervisor**: Used for spawning dynamic worker pools (players, connections)
- **GenServer callbacks**: Always annotated with `@impl true`
- **Process groups**: `:pg` module for cluster-wide pub/sub broadcasting
- **Interface pattern**: Each app exposes an `Interface` module as its public API for inter-app `GenServer.call/cast` communication

### Naming

- Modules: `PascalCase` following `{AppName}.{Feature}.{Type}` (e.g., `SceneServer.AoiManager`)
- Files: `snake_case.ex` matching module name segments
- App names: `snake_case` with descriptive suffixes (`_server`, `_manager`, `_service`, `_store`)

### Code Style

- Use `require Logger` for logging
- Pattern matching in function heads over conditional logic
- Pipe operator `|>` for data transformation chains
- Map-based state in GenServers: `%{key: value}`
- Comments may be in Chinese (original author's language)

## Database Schema

Defined in `apps/data_init/lib/data_init/table_def.ex`:

- `User.Account` — User account records
- `User.Character` — Player character data
- `User.AccountSession` — Active session tracking

Uses Mnesia (via Memento) with both RAM and disk copies across cluster nodes.

## Rust Native Extensions

Located in `apps/scene_server/native/`:

| Crate | Purpose |
|-------|---------|
| `scene_ops` | Physics simulation (rapier3d-f64), character movement |
| `octree` | Spatial indexing for efficient neighbor queries |

Key NIF module: `SceneServer.Native.SceneOps`

Functions include: `new_character_data/0`, `movement_tick/3`, `update_character_movement/3`, `get_character_location/1`, `new_physics_system/0`

Building Rust NIFs requires a Rust toolchain installed on the system.

## Testing

- Framework: ExUnit (built-in)
- Each app has `test/` with `test_helper.exs` and `*_test.exs` files
- Phoenix apps include `test/support/` with shared test utilities (e.g., `ConnCase`, `DataCase`)
- Run all tests: `mix test`
- Run single app: `mix test apps/<app_name>/test/`

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `phoenix` | Web framework (auth, visualization) |
| `phoenix_live_view` | Real-time UI for visualize_server |
| `memento` | Mnesia database wrapper |
| `protox` | Protocol Buffers encoding/decoding |
| `rustler` | Elixir-to-Rust NIF bridge |
| `poolboy` | Worker pool management (data_service) |
| `bcrypt_elixir` | Password hashing (auth_server) |
| `ranch` | TCP socket acceptor pool (gate_server) |
| `jason` | JSON encoding/decoding |

## Notes for AI Assistants

- This is an umbrella project — always consider which app(s) a change affects
- Inter-app communication uses GenServer calls/casts via Interface modules; respect this boundary
- The `scene_server` app has Rust NIFs — changes to native code require Rust compilation
- Mnesia tables are defined in `data_init` but accessed through `data_service` (RAM) and `data_store` (disk) — keep this separation
- No CI/CD is configured; validate changes locally with `mix test` and `mix compile`
- The project uses distributed Erlang — node names and cookies are required for clustering
- Protocol Buffer `.proto` files live in a git submodule (`mmo_protos`)
