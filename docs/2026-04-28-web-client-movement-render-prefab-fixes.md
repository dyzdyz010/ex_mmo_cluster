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
- `micro-wire`
- `prefabPreviewGeometry`
- `renderer=webgpu`
- `renderer=webgl`
- `totalCorrections`
- `AOI priority`
- `AOI adapter DOWN`
- `movementGroundY`
- `RemotePlayerController`

## User-Visible Problems

The browser client had four connected symptoms:

1. Local movement felt jittery despite running locally.
2. Prefab placement preview could freeze or stutter badly.
3. A cube that looked like an NPC circled the scene forever.
4. The local avatar appeared suspended above the terrain instead of standing on
   the ground.
5. With two browser clients, local movement was smooth but remote players could
   freeze/stutter badly and remote jump height was not visible.

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

### Remote player stutter and missing jump sync

There were three separate issues in the remote path:

1. A server-side `SceneServer.Aoi.AoiItem` can exit while the authoritative
   `SceneServer.PlayerCharacter` continues running. Before the fix, the player
   actor kept a dead `aoi_ref`, so remote observers stopped receiving fresh
   `player_move` snapshots and froze on the last tick.
2. `RemotePlayerController` copied every delivered snapshot directly into
   `renderedPosition`. That bypassed the snapshot interpolation buffer and
   created visible packet-rate snapping even when delivery was healthy.
3. `RenderOrchestrator` rendered remote avatars without a movement ground
   baseline. Airborne Y offset arrived in the remote snapshot, but display Y was
   forced back to the terrain surface.

Relevant files:

- `apps/scene_server/lib/scene_server/worker/player_character.ex`
- `apps/scene_server/lib/scene_server/worker/aoi/aoi_manager.ex`
- `clients/web_client/src/app/controllers/remotePlayerController.ts`
- `clients/web_client/src/app/controllers/renderOrchestrator.ts`

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

### Prefab preview uses cheap micro wire geometry while hovering

The interactive hover preview is now a low-cost micro occupancy wire outline
(`micro-wire`). It keeps the prefab's true microgrid shape, but renders only
plain `LineSegments` with no translucent fill, glow, or ghost mesh.

Boundary snapping still uses the same rasterized prefab preview cells that the
editing layer exposes. Overlap legality remains owned by the actual
`WorldEditController -> WorldStore` placement path and CLI preview commands.

Expected diagnostics after selecting a prefab:

- `window.__voxelCli.run("snapshot").data.prefabPreview.renderStyle`
  should be `"micro-wire"` during hover preview.
- `renderObjectCount` should stay small for hover preview.

Follow-up correction from visual review:

- Do not replace prefab placement preview with macro-cell boxes. The preview
  must preserve the prefab's micro occupancy shape.
- The cheap path is a plain micro wireframe: one `LineSegments` object,
  `LineBasicMaterial`, no transparent mesh, no glow, and no filled placeholder.
- Browser CLI smoke on `http://127.0.0.1:5174/?renderer=webgl` after selecting
  `builtin_sphere`: `renderStyle="micro-wire"`, `cellCount=280`,
  `renderObjectCount=1`, `wireSegmentCount=1176`.

Follow-up performance and placement correction:

- The remaining hover stall was not caused by the wireframe renderer. The
  measured hot path was `previewBoundarySnap(...)`: legacy stairs-on-stairs
  preview averaged about `289 ms` per call because it enumerated an entire
  macro cell of target boundary points.
- `PrefabBoundarySnapRequest.anchorMicroCoord` is now the fast path used by
  hover preview and right-click placement. It fixes the target contact micro to
  the actual aimed adjacent micro slot, then tests the incoming prefab boundary
  points in contact-center order until a non-overlapping candidate is found.
- The same stairs-on-stairs middle-step probe now uses `mode="anchored"`,
  `targetBoundaryCount=1`, `anchorCandidateCount=25`, and averaged about
  `13.5 ms` per preview call in browser CLI smoke.
- CLI diagnostics can reproduce the anchored path with:
  `prefab_snap_preview builtin_stairs 20 10 20 0 1 0 rot0 163 84 164`.

### Renderer backend is explicit

The web client now uses `rendererBackend.ts` to prefer WebGPU where possible
and fall back to WebGL. Runtime can force a backend with:

- `http://127.0.0.1:5173/?renderer=webgpu`
- `http://127.0.0.1:5173/?renderer=webgl`
- `VITE_RENDER_BACKEND=webgl npm run dev`

Use `window.__voxelCli.run("renderer")` or `snapshot.renderer` before making
claims about backend behavior.

### Remote AOI and jump sync are recovered

`PlayerCharacter` now monitors its `AoiItem`. If the AOI fan-out adapter exits,
the player actor recreates it, re-registers the current authoritative position,
forces an AOI refresh, and republishes the current movement snapshot.

`RemotePlayerController` now seeds `renderedPosition` from the first snapshot
only. Later snapshots update the interpolation buffer and movement mode without
directly snapping the rendered transform. It also tracks `movementGroundY` from
grounded snapshots.

`RenderOrchestrator` passes remote `movementGroundY` into the same display rule
used by the local player:

- display Y = `surfaceCenterY + max(0, movementY - movementGroundY)`

Expected diagnostics during a two-client jump:

- A's `window.__voxelCli.run("players").data.remote.entities[0].interpolationMode`
  stays `"interpolated"` under healthy local delivery.
- A's remote entity `movementMode` becomes `"airborne"` while B is jumping.
- A's remote entity `movementGroundY` remains at the grounded baseline.
- A's `snapshot.actorDisplay.remote.y` rises above its grounded display Y.

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

Focused remote movement checks:

```powershell
mix.bat test apps/scene_server/test/scene_server/worker/player_character_test.exs
cd clients/web_client
npm test -- remotePlayerController.test.ts
npm run lint -- --quiet
```

Two browser clients on `http://127.0.0.1:5174/?renderer=webgl` after restarting
the server:

- A observed B with `receivedRemoteSnapshotCount=356`,
  `lastRemoteTickByCid={B:392}`, `interpolationMode="interpolated"`.
- B observed A with `receivedRemoteSnapshotCount=344`,
  `lastRemoteTickByCid={A:389}`, `interpolationMode="interpolated"`.
- During B's jump, A observed remote `movementMode="airborne"`,
  `movementGroundY=100`, interpolated tick growth from `629` through `636`, and
  `actorDisplay.remote.y` rising from `460` to about `529.8`.

Browser CLI smoke on `http://127.0.0.1:5174/?renderer=webgl`:

- `decorativeRemoteActor=false`
- `remote_count=0`
- `players.remote.entities=[]`
- recent observe `remote_snapshot` count = `0`
- `player_rendered=-350.0,260.0,-280.0`
- `groundY=260`
- prefab hover preview uses `micro-wire`

Known caveat: the final browser pass hit `auto_login_failed:502`, so that
specific browser smoke verified `simulated-local` fallback. Server-side
movement / AOI priority coverage was verified through focused ExUnit and the
updated WebSocket smoke path.

Follow-up smoke hardening:

- `node scripts/run_ws_dual_smoke_supervised.js` is now the repeatable
  WebSocket movement smoke. It uses the full `MIX_ENV=dev` runtime, runs DB
  create/migrate/seed for `ws_smoke_a` and `ws_smoke_b`, writes
  `.demo/observe/ws-dual-smoke-summary.json`, and cleans up the booted runtime.
- The probe asserts enter-scene success, movement ack delivery, authoritative
  airborne jump, remote `player_move` tick growth, AOI priority metadata, remote
  airborne mode, and remote jump Y/Z rise on the observing client.

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
- Remote jump should show the same airborne mode and display Y rise on another
  client; if it freezes, inspect AOI adapter liveness and
  `players.remote.entities[*].latestServerTick`.
- Prefab hover preview should remain micro-shape, wire-only, and cheap.

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
