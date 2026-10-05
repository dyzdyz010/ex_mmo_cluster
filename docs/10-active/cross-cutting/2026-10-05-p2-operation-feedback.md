# P2 authoritative operation feedback

Classification: operation metadata and projection are Global system; tests and this execution record are Test-only.
Contract/design: `../Voxim/Docs/Audio/P2-operation-feedback.md`. The original isolated audio implementation used Hello37; the integrated version below uses Hello38.

## Integrated Hello38 result

2026-10-05: combined audio with the current magic/projectile and account source snapshot in `p2-integrate`, commit `f51de56d`; client `p2-integrate-client` commit `410e09a5`. Main workspaces received only the P2 merge delta, preserving other tasks and their indexes. Both former Hello37 variants are rejected by the combined Hello38 contract.

- Formal Mix contracts: 138 executed, 0 failures. Affected damage/phase/macro-Prefab/projection files: 152 discovered, 1 existing realtime exclusion, 151 executed, 0 failures; independent PostgreSQL port26979, no injected authority state.
- Formal Docker image `voxim-server:20261005-p2-integrated38`, ID `sha256:0d1ddf8a52a4eda8dcfdf36c05dc92c0def1acb8d04cd496b54a501f4313a9ac`; client rebuilt and 25 related UE Automation tests passed both in isolation and in main.
- Fresh world `run-07`: 24 accepted real crosshair/key requests, each matching exactly one operation on both clients; actual refusal, query and reconnect produced no extra operation. Both replay scripts succeeded and both processes exited0. `acceptance.json` is true. Original failed runs remain unchanged.
- This proves P2 on the combined build, not the entire magic/account feature acceptance or subjective listening, movement/streaming, benchmarks, packaging or distribution. The two rendered clients and this task's service/PG containers have exited.

Evidence is retained once in `../Voxim/Saved/P2/Audio/`: `integration-build-identity.json`, `integration-contracts.log`, `integration-world.log`, `integration-client-tests.txt`, `main-integration-tests.txt`, and `run-07/`. Media: `../Voxim/Captures/P2/operation-07/`. Reproducible formal Mix wrapper `integration-mix.sh` selects `mmo_contracts test --no-start --seed 0`, or `voxel_region test --no-start test/damage_world_test.exs test/phase_world_test.exs test/prefab_macro_world_test.exs test/log_projection_test.exs --seed 0`.

## Original isolated implementation

Successful player tool hit/dig, ordinary build, attachment create/remove, and Prefab place/replace/remove attach one immutable `operation` to the existing canonical transaction. Macro positions use the central micro cell; Prefabs choose the lexicographically first actual added/removed footprint element after support pruning. Host removal emits the host operation once. Snow/Ice and water-displacing solid builds use the same settlement path. Queries, rejections, duplicate requests, author setup, thermal evolution, and liquid scoop/pour produce no operation. Liquid transfer sounds are outside this increment.

The existing live `liquid_falls` metadata is the implementation precedent: operation is removed before persistent append, World retention, Replica history, and historical region projection; canonical/Replica live deltas retain it only within the receiver's XYZ region box. No new transport, authority state, or geometry inference was added. The tag 3 layout is the frozen spec; tag 2 bytes remain unchanged, either tag order is accepted, unknown/duplicate/truncated metadata and invalid kind are rejected.

Verification (2026-10-05, isolated `ex_mmo_cluster-p1`):

- Codec RED: frozen hand-written operation bytes were omitted by the previous encoder. New codec plus existing liquid test: 9 passed. Entire `mmo_contracts`: 137 passed, exit 0.
- World RED: normal partial hit had no operation. Public World scenarios cover hit/break/build, attachment create/remove and host break, mixed micro Prefab place/replace/remove, Snow4/Ice20, water displacement, and macro Prefab placement/F dismantle.
- Replica RED: live-forwarded operation survived in `canonical_deltas_after`; after stripping the transient metadata, the same regression passes.
- Affected World/projection files discovered 152 tests: 1 realtime excluded, 150 passed, 1 environment failure (stopped PostgreSQL on 26909). After starting the existing isolated test PostgreSQL container, macro Prefab and projection files passed all 20 tests, exit 0, including the previously blocked actual database test. The first phase fixture used chunk indices as a region subscription box; corrected to the existing canonical region contract. Requests now correlate delta by returned transaction seq.

Commands use the existing formal wrapper:

```text
wsl -d Ubuntu-22.04 --exec /bin/bash /mnt/c/Users/DYZ/Documents/dev/hemifuture/Voxim/Saved/P1/Environment/mix.sh mmo_contracts test --no-start --seed 0
wsl -d Ubuntu-22.04 --exec /bin/bash /mnt/c/Users/DYZ/Documents/dev/hemifuture/Voxim/Saved/P1/Environment/mix.sh voxel_region test --no-start test/damage_world_test.exs test/phase_world_test.exs test/prefab_macro_world_test.exs test/log_projection_test.exs --seed 0
wsl -d Ubuntu-22.04 --exec /bin/bash /mnt/c/Users/DYZ/Documents/dev/hemifuture/Voxim/Saved/P1/Environment/mix.sh voxel_region test --no-start test/prefab_macro_world_test.exs test/log_projection_test.exs --seed 0
```

Raw logs: `../Voxim/Saved/P2/Audio/server-*.log`, including original failures. Earlier PowerShell Tee pipelines returned shell status 1 for compiler warnings despite zero Mix failures; final runs explicitly exit with the native Mix/WSL exit code.

This proves formal codec and World/Replica/persistence module boundaries. Real two-client audio/render validation and release Docker build belong to the enclosing P2 task; this record does not claim them or the eventual combined magic-36/client-37 integration.
