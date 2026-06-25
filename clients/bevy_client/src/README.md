# Bevy client module map

This directory is organised by Bevy `Plugin` boundary. The composition root
in `app::run` is ~80 lines: it inserts shared resources, registers
`LoginPlugin` + `BevyClientPlugins` + `DefaultPlugins`, then runs.

`BevyClientPlugins` (in `app/plugins.rs`) is a `PluginGroup` that registers
the 12 domain plugins listed below in canonical
`Network → Stdio → Input → Logic → Sync → Render` order
(see `app/schedule.rs::ClientSet`). Each plugin owns its resources,
components, events, and systems; cross-plugin communication is by
`Res<…>` reads on shared resources (`WorldState`, prediction state) or
events. No plugin is allowed to mutate another plugin's domain state
directly.

## Plugins

| Plugin | Module | Owns |
| --- | --- | --- |
| `LoginPlugin` | `login.rs` | egui login UI + `AppState` machine |
| `NetworkPlugin` | `net/plugin.rs` | drain `NetworkEvent`s into `WorldState` / prediction / effect cues |
| `StdioPlugin` | `stdio/plugin.rs` | drain queued stdio commands and route to network/voxel/movement |
| `InputPlugin` *(stub)* | `app/plugins.rs` | reserved for shared input scaffolding (most input lives in domain plugins) |
| `CameraPlugin` | `camera/plugin.rs` | orbit camera follow, mouse drag, `Ctrl+wheel` zoom |
| `ChatPlugin` | `chat/plugin.rs` | chat input mode + draft buffer + chat-log/chat-input HUD components |
| `VoxelPlugin` | `voxel/plugin.rs` | center-ray selection, voxel edit input, voxel mesh sync, prefab preview gizmos, target-point marker |
| `SkillPlugin` | `skill/plugin.rs` | Shift+1-4 skill keys, Tab actor cycling, Shift+RMB target-point picking |
| `MovementSyncPlugin` | `movement/plugin.rs` | keyboard movement sample, configured uplink tick, local render-prediction integration |
| `EffectPlugin` | `effects/plugin.rs` | transient skill/combat visual cues (projectile, AOE ring, melee/chain arc, impact pulse) |
| `HudPlugin` | `hud/plugin.rs` | HUD text aggregation (status, transport, voxel hotbar, AOI peers, RTT) |
| `PresentationPlugin` | `presentation/plugin.rs` | local + remote actor visuals + actor-material lookup |
| `ObservePlugin` *(stub)* | `app/plugins.rs` | reserved for observe-log lifecycle hooks |

## Pure non-Bevy modules (no `Plugin`s)

- `session/` — identity + connection lifecycle domain: `SessionCredentials` + `session::auth` (HTTP `auto_login`); later phases add `ConnectionPhase` + reconnect/re-auth
- `config.rs` — `ClientConfig` (env-backed transport/observe config)
- `protocol.rs` — wire format DTOs (audit A-L3 renamed `protocol_v2.rs` to `movement_codec.rs`)
- `movement_codec.rs` — typed movement-input + movement-ack adapters between wire and sim
- `input/` — `MoveInputFrame` + movement flag constants
- `sim/` — prediction, reconciliation, replay governance, jitter EWMA
- `world/` — local-prediction runtime, remote-actor identity, remote-player
  buffered snapshot motion
- `voxel/{core,world,prefab,cli}/` — pure voxel storage, prefab geometry,
  CLI parser; `voxel/plugin.rs` is the Bevy adapter on top
- `presentation/{animation,smoothing,camera}` — pure smoothing and animation
  state helpers
- `stdio/{mod.rs,plugin.rs}` — parser + emit helpers (mod.rs); poll system
  (plugin.rs)
- `headless/{runner,voxel_runner,script,state}` — non-visual automation /
  QA entrypoints (no Bevy app)
- `net/{events,fastlane,observe,runtime,thread,transport}` — pure I/O,
  state machine, and observation translation; `net/plugin.rs` is the
  Bevy adapter on top
- `observe.rs` — `ClientObserver` (structured log writer)

## Composition root (`app::run`)

`app/mod.rs` keeps:

- The four shared resources `WorldState`, `MovementIntent`,
  `MovementDispatchState`, `LocalRenderPrediction` (read by multiple
  Plugins).
- The `SceneRenderAssets` resource and the `setup` system that creates the
  scene (camera, HUD text nodes, target-point marker, lights, mesh +
  material handles) — Plugins consume the assets but do not own
  scene-graph startup.
- `enter_game_setup` — spawns the network thread when entering
  `AppState::Game`.
- Pure helpers used across plugins: `net_to_world`,
  `sim_to_render_position`, `render_to_sim_position`, `ray_from_viewport`,
  `ray_intersection_with_y_plane`, `push_line`, `voxel_save_dir`.

## Server / sim contract

- Local player movement follows server-authoritative prediction and
  reconciliation (see `world::local_player::LocalPredictionRuntime`).
- Remote actors consume server snapshots plus `ActorIdentity` metadata.
- NPCs are represented as remote actors with explicit
  `RemoteActorKind::Npc`, not by inferring from CID ranges.
- Voxel is offline-local — see `docs/2026-04-25-bevy-client-web-parity-voxel-migration.md`.

## Restructure design

Full design lives in
`docs/superpowers/specs/2026-04-25-bevy-client-restructure-design.md`.
Phases 0-4 (system migration into Plugins) are complete on the
`feat/bevy-client-restructure` branch. Phase 5 (replace shared `ResMut`
with domain events between plugins) and Phase 6 (per-plugin tests) are
deferred to a follow-up plan that will land alongside the bug-fix work
for camera, raycast, view-relative movement, movement sync, and prefab
placement.
