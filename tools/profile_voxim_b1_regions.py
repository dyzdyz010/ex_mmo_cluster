"""Run the existing isolated fixture with owner call profiling; no live node or DB calls."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".demo/observe/b1-regions-profile"
OUT.mkdir(parents=True, exist_ok=True)
source = (ROOT / "tools/benchmark_voxim_b1_interaction.exs").read_text(encoding="utf8")
source = source.replace('[{"before",old_source},{"after",new_source}]', '[{"after",new_source}]')
source = source.replace('  destroyed=B1InteractionProbe.edit(w,0)', '''  :eprof.start()
  :eprof.start_profiling([w])
  destroyed=B1InteractionProbe.edit(w,0)
  :eprof.stop_profiling()
  :eprof.analyze(:total,sort: :time)
  :eprof.stop()''')
script = OUT / "profile.exs"
script.write_text(source, encoding="utf8")
container = "voxim-m1-demo-20260908"
subprocess.run(["docker", "cp", str(script), container + ":/tmp/b1-regions-profile.exs"], check=True)
with (OUT / "profile.log").open("wb") as stream:
    r = subprocess.run(["docker", "exec", "-e", "LANG=C.UTF-8", "-e",
        "ERL_LIBS=/home/dyz/.cache/voxim-m1-demo/build/lib", container,
        "elixir", "--erl", "+S 2:2", "-pa", "/tmp/b1-b1-ingress-green",
        "/tmp/b1-regions-profile.exs", "/tmp/b1-b1-region-probe/world.ex",
        "/tmp/b1-b1-ingress-green/world.ex", "/tmp/b1-interaction-perf/log.etf",
        "/tmp/b1-profile-perf"], stdout=stream, stderr=subprocess.STDOUT)
raise SystemExit(r.returncode)
