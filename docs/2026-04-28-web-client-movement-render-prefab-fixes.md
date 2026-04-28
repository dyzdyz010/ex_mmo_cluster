# Web Client Movement / Render / Prefab Fixes (2026-04-28)

Purpose: durable handoff notes for future sessions working in
`clients/web_client` after the movement-smoothness, prefab-preview, spawn, and
simulated fallback fixes.

Primary commit:

- `7eaa2cd9ed3476ae211e6332b79c42645aa8517c`
  `Make browser movement feel local on real terrain`

Search keywords:

- `clients/web_client`
- `simulated-local`
- `decorativeRemoteActor`
- `cid=42002`
- `resolveInitialLocalSpawn`
- `surfaceCenterYAtWorldXZ`
- `groundY`
- `wire-bounds`
- `prefabPreviewGeometry`
- `renderer=webgpu`
- `renderer=webgl`
- `totalCorrections`
- `AOI priority`

## User-Visible Problems

The browser client had four connected symptoms:

1. Local movement felt jittery despite running locally.
2. Prefab placement preview could freeze or stutter badly.
3. A cube that looked like an NPC circled the scene forever.
4. The local avatar appeared suspended above the terrain instead of standing on
   the ground.

## Root Causes

### Local movement jitter

The simulated fallback path was still behaving like a network demo. It delayed
acks and the local render path rewound phase on accepted acks, so even
authoritative no-op confirmations could visually disturb the current rendered
position.

Relevant files:

- `clients/web_client/src/infrastructure/net/simulatedMovementTransport.ts`
- `clients/web_client/src/app/controllers/localPlayerController.ts`
- `clients/web_client/src/domain/movement/governance.ts`

### Prefab preview stalls

The old prefab hover path could rebuild expensive translucent micro ghost
geometry during interaction. That made placement feel blocked by CPU-side
preview recomputation rather than by actual placement rules.

Relevant files:

- `clients/web_client/src/render/chunkRenderer.ts`
- `clients/web_client/src/render/prefabPreviewGeometry.ts`
- `clients/web_client/src/voxel/prefab/*`

### Fake circling "NPC"

`SimulatedLocalMovementTransport` generated a decorative remote actor on a
circular path so older HUD / interpolation code had something to show. The
actor used `cid=42002`, was not real AOI state, and was easy to misread as a
real NPC.

Relevant file:

- `clients/web_client/src/infrastructure/net/simulatedMovementTransport.ts`

### Avatar floating

The local default spawn used hard-coded `y=650`. Movement initialization then
treated that same value as `groundY`, so the render layer preserved the
airborne offset above terrain instead of snapping the avatar to the voxel
surface.

Relevant files:

- `clients/web_client/src/app/spawn.ts`
- `clients/web_client/src/app/bootstrap.ts`
- `clients/web_client/src/app/controllers/localPlayerController.ts`
- `clients/web_client/src/app/controllers/renderOrchestrator.ts`
- `clients/web_client/src/voxel/worldStore.ts`

## Fixes Landed

### Simulated transport is local-only

`simulated-local` now immediately produces ordered local acks from the same
prediction runtime and does not synthesize remote snapshots.

Diagnostic expectation:

- `window.__voxelCli.run("transport").data.movementTransport.fallbackTransport.decorativeRemoteActor`
  is `false` when server-ws falls back.
- `window.__voxelCli.run("players").data.remote.entities` is `[]` unless real
  AOI snapshots arrive.

Do not reintroduce decorative remote snapshots into `simulated-local`. Remote
entities should come only from real `player_enter` / `player_move` / AOI input.

### Accepted acks preserve render phase

Accepted acks no longer rewrite the per-frame render simulation position,
velocity, and acceleration. They still update sequence/tick/mode/ground data,
but visual phase continues locally unless there is a real correction.

Expected diagnostics:

- `reconcile_stats.totalAcks` may increase every tick.
- `reconcile_stats.totalCorrections` should stay at `0` for accepted local
  fallback acks.

### Local spawn uses terrain surface

`resolveInitialLocalSpawn(world)` computes the actor center from the seeded
voxel terrain via `WorldStore.surfaceCenterYAtWorldXZ(...)`.

In the verified default world, the local player starts at:

- `-350.0,260.0,-280.0`

The render rule remains:

- display Y = `surfaceCenterY + max(0, movementY - movementGroundY)`

That rule is intentional because jump visuals must preserve airborne offset.
The fix is to start `movementY` and `movementGroundY` on the correct terrain
surface, not to remove the airborne offset logic.

### Prefab preview uses cheap wire geometry while hovering

The interactive hover preview is now a low-cost wire outline (`wire-bounds`).
Precise micro rasterization and overlap legality stay in the actual
`WorldEditController -> WorldStore` placement path and CLI preview commands.

Expected diagnostics after selecting a prefab:

- `window.__voxelCli.run("snapshot").data.prefabPreview.renderStyle`
  should be `"wire-bounds"` during hover preview.
- `renderObjectCount` should stay small for hover preview.

### Renderer backend is explicit

The web client now uses `rendererBackend.ts` to prefer WebGPU where possible
and fall back to WebGL. Runtime can force a backend with:

- `http://127.0.0.1:5173/?renderer=webgpu`
- `http://127.0.0.1:5173/?renderer=webgl`
- `VITE_RENDER_BACKEND=webgl npm run dev`

Use `window.__voxelCli.run("renderer")` or `snapshot.renderer` before making
claims about backend behavior.

## Verification Performed

Web client:

```powershell
cd clients/web_client
npm run lint
npm run typecheck
npm test
npm run build
npm audit --audit-level=moderate
```

Repo checks:

```powershell
git diff --cached --check
node --check scripts/ws_dual_smoke.js
cmd /c mix format --check-formatted
```

Focused server checks with temporary local Postgres:

```powershell
$env:MMO_DB_PORT='55432'
cmd /c mix test apps/gate_server/test/gate_server/codec_test.exs apps/gate_server/test/gate_server/tcp_connection_protocol_test.exs
cmd /c mix test apps/scene_server/test/scene_server/aoi/priority_test.exs apps/scene_server/test/aoi_item_test.exs
```

Browser CLI smoke on `http://127.0.0.1:5174/?renderer=webgl`:

- `decorativeRemoteActor=false`
- `remote_count=0`
- `players.remote.entities=[]`
- recent observe `remote_snapshot` count = `0`
- `player_rendered=-350.0,260.0,-280.0`
- `groundY=260`
- prefab hover preview uses `wire-bounds`

Known caveat: the final browser pass hit `auto_login_failed:502`, so that
specific browser smoke verified `simulated-local` fallback. Server-side
movement / AOI priority coverage was verified through focused ExUnit and the
updated WebSocket smoke path.

## Practical Debug Entry Points

Browser console:

```js
window.__voxelCli.run("snapshot");
window.__voxelCli.run("transport");
window.__voxelCli.run("players");
window.__voxelCli.run("reconcile_stats");
window.__voxelCli.run("renderer");
window.__voxelObserve.recent(50);
```

Useful assertions:

- Local fallback should have no fake remote entities.
- Accepted fallback acks should not increment correction counters.
- Local spawn should be on terrain center height, not `650`.
- Jump should change rendered Y while preserving the terrain-based ground.
- Prefab hover preview should remain wire-only and cheap.

## Files To Read First Next Time

- `clients/web_client/src/app/bootstrap.ts`
- `clients/web_client/src/app/spawn.ts`
- `clients/web_client/src/app/controllers/localPlayerController.ts`
- `clients/web_client/src/app/controllers/renderOrchestrator.ts`
- `clients/web_client/src/infrastructure/net/simulatedMovementTransport.ts`
- `clients/web_client/src/render/chunkRenderer.ts`
- `clients/web_client/src/render/prefabPreviewGeometry.ts`
- `clients/web_client/src/render/rendererBackend.ts`
- `clients/web_client/src/presentation/devtools/devToolsCli.ts`
- `clients/web_client/src/voxel/prefab/README.md`
