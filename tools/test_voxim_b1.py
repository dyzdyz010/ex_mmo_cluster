"""Compile B1 authority and run isolated tests, without attaching to live nodes."""
import argparse
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = [
    "apps/mmo_contracts/lib/mmo_contracts/voxel/skins.ex",
    "apps/mmo_contracts/lib/mmo_contracts/voxel/refined.ex",
    "apps/mmo_contracts/lib/mmo_contracts/voxel/payload.ex",
    "apps/mmo_contracts/lib/mmo_contracts/voxel/codec.ex",
    "apps/voxel_region/lib/voxel_region/file_store.ex",
    "apps/voxel_region/lib/voxel_region/collision_source.ex",
    "apps/voxel_region/lib/voxel_region/prefab.ex",
    "apps/voxel_region/lib/voxel_region/damage.ex",
    "apps/voxel_region/lib/voxel_region/overlay_log.ex",
    "apps/voxel_region/lib/voxel_region/world.ex",
    "apps/voxel_region/lib/voxel_region/replica.ex",
    "apps/scene_server/lib/scene_server/movement/player.ex",
    "apps/gate_server/lib/gate_server/session/sink.ex",
    "apps/gate_server/lib/gate_server/session/dispatch.ex",
    "apps/gate_server/lib/gate_server/session/quic_connection.ex",
]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--prepare-only", action="store_true")
parser.add_argument("--interaction-only", action="store_true")
parser.add_argument("--world-file-only", action="store_true")
args = parser.parse_args()
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
container = "voxim-m1-demo-20260908"
remote = "/tmp/b1-" + out.name

def run(cmd):
    return subprocess.run(cmd, capture_output=True, check=True)

run(["docker", "exec", container, "mkdir", "-p", remote])
tests = ["apps/voxel_region/test/damage_test.exs"]
if (ROOT / "apps/voxel_region/test/damage_world_test.exs").exists():
    tests.append("apps/voxel_region/test/damage_world_test.exs")
if args.world_file_only:
    tests = ["apps/voxel_region/test/world_test.exs"]
for f in FILES + tests:
    run(["docker", "cp", str(ROOT / f), container + ":" + remote + "/" + Path(f).name])
runner = 'Code.compiler_options(ignore_module_conflict: true)\nCode.prepend_path("' + remote + '")\n'
for f in FILES:
    runner += 'for {m,b} <- Code.compile_file("' + remote + '/' + Path(f).name + '"), do: File.write!("' + remote + '/"<>Atom.to_string(m)<>".beam",b)\n'
if not args.prepare_only:
    runner += "Logger.configure(level: :warning)\nExUnit.start(autorun: false,timeout: 300_000)\n"
    if args.interaction_only:
        runner += "ExUnit.configure(exclude: [:test],include: [:interaction_latency])\n"
    if args.world_file_only:
        runner += "ExUnit.configure(exclude: [:test],include: [:replica])\n"
    for f in tests:
        runner += 'Code.require_file("' + remote + '/' + Path(f).name + '")\n'
    runner += "r=ExUnit.run()\nSystem.halt(if r.failures>0,do: 1,else: 0)\n"
(out / "runner.exs").write_text(runner, encoding="utf8")
run(["docker", "cp", str(out / "runner.exs"), container + ":" + remote + "/runner.exs"])
r = subprocess.run(["docker", "exec", "-e", "LANG=C.UTF-8", "-e", "ERL_LIBS=/home/dyz/.cache/voxim-m1-demo/build/lib", container, "elixir", "--erl", "+S 2:2", remote + "/runner.exs"], capture_output=True)
(out / "tests.log").write_bytes(r.stdout + r.stderr)
print((r.stdout + r.stderr).decode("utf8", errors="replace"))
print("Compiled directory: " + remote)
raise SystemExit(r.returncode)
