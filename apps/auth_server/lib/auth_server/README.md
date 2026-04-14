# AuthServer runtime map

This directory contains the auth-side runtime and local demo orchestration
helpers.

## Runtime pieces

- `application.ex`
  - starts Phoenix plus the cluster-facing auth interface
- `worker/interface.ex`
  - registers `auth_server` and resolves `data_service`
- `sup/interface_sup.ex`
  - supervisor wrapper for the auth interface
- `auth_worker.ex`
  - token issuance/verification and character authorization

## Demo helpers

The `demo/` subtree is intentionally colocated with auth because the local demo
needs real token issuance and seeded accounts/characters to exercise the real
runtime path.

See `demo/README.md` for the demo-specific flow.
