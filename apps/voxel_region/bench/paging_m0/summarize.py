"""只测试（Test-only）：把 M0Probe.snapshot() 的 JSON 摘成可读表（按回合总耗时排序）。stdin → stdout。"""
import json
import sys

d = json.load(sys.stdin)
print("turns (kind: n / sum_ms / max_ms / p50<= / p99<= us)")
for k, v in sorted(d["turns"].items(), key=lambda kv: -kv[1]["sum_us"])[:15]:
    print(f"  {k:40s} {v['n']:7d} {v['sum_us']/1000:10.1f} {v['max_us']/1000:9.1f} {v['p50_le_us']:>9} {v['p99_le_us']:>9}")
print("pg (source: n, queue sum/p99, query sum/p99 us)")
for k, v in d["pg"].items():
    q, r = v.get("queue", {}), v.get("query", {})
    print(f"  {k:24s} {v['n']:6d} q={q.get('sum_us')}/{q.get('p99_le_us')} r={r.get('sum_us')}/{r.get('p99_le_us')}")
