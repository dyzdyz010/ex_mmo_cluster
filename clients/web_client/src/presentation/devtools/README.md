# DevTools presentation boundary

This directory owns the browser-side CLI surface exposed through
`window.__voxelCli`.

## Responsibilities

- `devToolsCli.ts` dispatches commands to the controller that owns the runtime
  state.
- `devToolsParsers.ts` parses command arguments into typed request objects.
- `devToolsFormat.ts` re-exports shared runtime formatters so CLI, HUD, observe
  logs, and bootstrap events use the same coordinate/vector text.
- `devToolsSerializers.ts` converts prefab previews and definitions into
  JSON-safe values.

## Boundary rules

- DevTools modules are read/command adapters. They do not own world, movement,
  render, or transport state.
- CLI commands should call controller/domain APIs instead of reaching into
  renderer or storage internals when an API already exists.
- Observable output should stay JSON-safe and stable enough for smoke scripts.
- Scene-region visualization commands (`scene_regions [on|off]`) and field
  diagnostics (`field_overlay [on|off]`) are render diagnostics only: they may
  read/toggle browser overlay state, but must not mutate voxel truth or server
  leases.
- Voxel phenomenon readback commands (`voxel_combustion`, `voxel_phase`,
  `voxel_object`) are diagnostic adapters. They submit read-only requests to
  the online world adapter and report the latest server-authoritative summary;
  they must not duplicate scene-side combustion, phase-change, or object
  damage rules.
- `chat <world|region|local> <text...>` is a server-session command. It may
  send scope and text through `TransportPump.sendChat()`, but it must never
  accept client-supplied `region_id`, `chunk_coord`, radius, or position as
  channel authority.
