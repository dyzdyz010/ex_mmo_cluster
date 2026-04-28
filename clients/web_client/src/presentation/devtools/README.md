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
