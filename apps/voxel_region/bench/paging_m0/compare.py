"""只测试（Test-only）：把多轮 run_m0 的冷内容份数轴摘成一张对比表。用法：python compare.py <run_dir> [<run_dir> ...]

每轮：启动就绪 / 峰值、空闲 World 堆与主要字段、各级吞吐与提交延迟、World 进程 long_gc（中位 / 最长 / 次数）、
OS 进程树 rss 最高值与结束存活堆。只读 run 目录，不连节点。
"""
import glob
import json
import sys
from pathlib import Path


def load(p):
    # field-heap-end.json 是 rpc 原样输出，前面可能有节点日志行；取最后一行 JSON。
    text = Path(p).read_text(encoding="utf-8-sig").strip()
    try:
        v = json.loads(text)
    except json.JSONDecodeError:
        v = json.loads(text.splitlines()[-1])
    return json.loads(v) if isinstance(v, str) else v


def gc(run):
    rows = [json.loads(l) for l in (run / "probe" / "events.jsonl").read_text(encoding="utf-8-sig").splitlines()]
    world = sorted(r["info"]["timeout"] for r in rows if r["kind"] == "long_gc" and r["name"] == "Elixir.VoxelRegion.World")
    if not world:
        return "-"
    return f"n={len(world)} p50={world[len(world) // 2]} max={world[-1]} ms"


def main():
    for d in sys.argv[1:]:
        run = Path(d)
        st, idle = load(run / "startup.json"), load(run / "idle.json")
        fh = load(idle["field_heap"]) if isinstance(idle["field_heap"], str) else idle["field_heap"]
        top = fh.get("top_fields_mb")
        if top is None:
            breakdown = fh["field_breakdown"]
            fields = f"field breakdown {breakdown['status']}: {breakdown['reason']}"
        else:
            fields = ", ".join(f"{key} {top.get(key, 'unavailable')}" for key in
                               ["entries", "refined", "epochs", "component_cache", "prefabs"])
        os_peak = max(json.loads(l)["rss_sum"] for l in (run / "os.jsonl").read_text(encoding="utf-8-sig").splitlines()) / 1e9
        end = run / "field-heap-end.json"
        end_heap = load(end)["total_heap_mb"] if end.exists() else None
        print(f"== {run.name}: seq {fh.get('seq', 'unavailable')} ready {st['ready_seconds']} s, startup peak {st['startup_peak_rss_sum'] / 1e9:.2f} GB, "
              f"idle World heap {fh['total_heap_mb']} MiB ({fields}), epochs n={fh.get('epochs', 'unavailable')}, "
              f"OS rss max (all phases) {os_peak:.2f} GB, end heap {end_heap} MiB, World long_gc {gc(run)}")
        for p in sorted(glob.glob(str(run / "step-*.json"))):
            s = load(p)
            r, st = s["report"], s["stages"]["macro_stages"]
            c = r["commit_us"]
            print(f"   N={s['n']}: {r['commits'] / max(r['span_s'], 1):.2f}/s, commit p50/p99/max "
                  f"{c['p50'] // 1000}/{c['p99'] // 1000}/{c['max'] // 1000} ms, errors {r['error_count']}, "
                  f"stages p50 ms {dict((k[:-3], round(v['p50'] / 1000, 1)) for k, v in st.items())}")


if __name__ == "__main__":
    main()
