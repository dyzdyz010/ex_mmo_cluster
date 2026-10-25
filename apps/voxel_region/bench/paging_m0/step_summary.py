"""只测试（Test-only）：打印 run_m0 各级 step-NN.json 的要点。用法：python step_summary.py <run_dir>"""
import glob
import json
import sys

for p in sorted(glob.glob(sys.argv[1] + "/step-*.json")):
    s = json.load(open(p))
    r, st, t = s["report"], s["stages"]["macro_stages"], s["turns"]["turns"]
    busy = sum(v["sum_us"] for v in t.values()) / 1e6
    print(f"N={s['n']} commits={r['commits']} span={r['span_s']}s rate={r['commits']/max(r['span_s'],1):.2f}/s "
          f"commit p50/p95/p99/max ms={[round(r['commit_us'][k]/1000) for k in ('p50','p95','p99','max')]} "
          f"world_busy={busy:.1f}s/{r['span_s']}s snapshot_phase={s['snapshot_phase_s']}s")
    print("   stages p50 ms:", {k[:-3]: round(v['p50'] / 1000, 1) for k, v in st.items()})
    print("   deltas", r["deltas"], "delta MB", round(r["delta_bytes"] / 2**20, 1),
          "WAL MB", round(s["pg_delta"]["wal_bytes"] / 2**20, 1), "pg xact", s["pg_delta"]["xact_commit"])
    print("   snapshots", [(x["window"], round(x["bytes"] / 2**20, 1), round(x["us"] / 1e6, 1)) for x in r["snapshots"]])
    top = sorted(t.items(), key=lambda kv: -kv[1]["sum_us"])[:5]
    print("   turns", [(k, v["n"], round(v["sum_us"] / 1e6, 1), round(v["max_us"] / 1000)) for k, v in top])
