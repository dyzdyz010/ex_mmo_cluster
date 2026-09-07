# Voxim M0 server experiment

This standalone Rust executable runs the same movement crate used by the UE DLL.
It is an offline scene-server experiment, with no BEAM/NIF wiring or M1 network protocol.

Check out `Voxim` and `ex_mmo_cluster` as sibling directories. Use Rust 1.98.0.
From the **Voxim root**, run:

```powershell
cargo run --release --locked --manifest-path ../ex_mmo_cluster/apps/scene_server/native/voxim_m0/Cargo.toml -- Docs/M0/fixtures/suite.json Docs/M0/runtime/server-manual
```

The path dependency points at `Voxim/Plugins/VoximMovement/Native`; there is no copied
movement implementation here. Both lock files select identical dependency versions.
The supplied fixture contains canonical Y-up occupancy, metre-scale geometry, ordered
initialization, movement parameters and tick-indexed input segments. Output consists
of 44 step traces and raw collider build/update/character-step timing samples.

For the measured Windows/Linux/UE experiment, exact source hashes, behavior tests,
scope and reproduction commands, see `Voxim/Docs/M0/README.md`. Run
`python Docs/M0/tools/run_replays.py` from that checkout to recreate the Windows and
offline WSL Linux data. Its metadata identifies both repositories' input files;
checking out only this repository does not provide the shared core.
