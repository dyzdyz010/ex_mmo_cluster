# Shared

Responsibilities:

- `events/` owns typed app event contracts and the in-memory event bus.
- `runtimeFormat.ts` owns stable coordinate/vector formatting used by CLI, HUD, diagnostics, and bootstrap observe logs.

Boundaries:

- Shared modules must stay stateless and domain-neutral.
- Shared helpers may depend on public data contracts, but must not own runtime state or call controllers directly.
