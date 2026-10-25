"""只测试（Test-only）：M0“同页反复安装”增长轴——把同一份如园按 10-23 原位 Δ(+3952, −200, +96) 原样再装 rounds 遍。

  python reinstall.py <deploy> <parcels_dir> <out_dir> --dump /tmp/backup.dump --rounds 2

每遍 14 批经 `World.parcel_install`（key 带遍号，见 install_copy.py）。目标格已等值时不写 overlay，所以世界内容不变，
只有安装历史（D3 世代 / epochs 等）可能增长。每遍之后重启节点，记录冷启动就绪 / 峰值与空闲字段堆（重启后量，
排除运行中垃圾），以及该遍安装的 OS 内存峰值。

`--skip` 跳过的批次写进 meta。2026-10-25 实测：garden-g2 原位重装被既有维护入口拒绝
（`{:target_attachment_crosses_boundary, 25143}`——目标盒里有第一遍装入的玩家独立附件，parcel 规则是盒内不随树清除的附件整批拒绝），
所以本轴只用其余 13 批。
"""
from pathlib import Path
import argparse
import json
import time

import m0
import install_copy
import run_m0

HERE = Path(__file__).resolve().parent
DELTA = (3952, -200, 96)


def idle_heap(deploy, out, name):
    started = m0.start(deploy)
    m0.rpc(deploy, f'Code.compile_file("{(HERE / "probe.ex").as_posix()}")\n:ok')
    time.sleep(60)
    heap = run_m0.rpc_json(deploy, "VoxelRegion.Bench.M0Probe.field_heap()")
    heap = json.loads(heap) if isinstance(heap, str) else heap
    row = {"name": name, "ready_seconds": started.get("ready_seconds"), "startup_peak_rss_sum": started.get("startup_peak_rss_sum"),
           "field_heap": heap}
    (out / f"heap-{name}.json").write_text(json.dumps(row, indent=1))
    print(json.dumps({"name": name, "ready_s": row["ready_seconds"], "heap_mb": heap["total_heap_mb"], "epochs": heap["epochs"],
                      "top": {k: heap["top_fields_mb"][k] for k in ("entries", "refined", "epochs", "component_cache")}}), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("deploy")
    ap.add_argument("parcels")
    ap.add_argument("out")
    ap.add_argument("--dump", required=True)
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--skip", action="append", default=[], help="不重装的批次名（可多次）")
    a = ap.parse_args()
    deploy, parcels, out = Path(a.deploy), Path(a.parcels), Path(a.out)
    out.mkdir(parents=True, exist_ok=False)
    cfg = m0.config(deploy)
    (out / "meta.json").write_text(json.dumps({"args": vars(a), "restored": run_m0.restore(cfg, a.dump), "delta": DELTA}, indent=1))
    try:
        idle_heap(deploy, out, "r0")
        for i in range(1, a.rounds + 1):
            tag = f"re{i}"
            receipts = out / tag
            receipts.mkdir()
            with open(receipts / f"mem-{tag}.jsonl", "a", encoding="utf-8") as log:
                for name in [b for b in install_copy.BATCHES if b not in a.skip]:
                    r = install_copy.install_one(deploy, parcels, receipts, tag, name, DELTA, log)
                    print(json.dumps({k: r.get(k) for k in ("parcel", "ok", "seq", "cells", "install_ms", "error")}), flush=True)
                    assert r["ok"], r
            m0.stop(deploy)
            idle_heap(deploy, out, f"r{i}")
    finally:
        m0.stop(deploy)


if __name__ == "__main__":
    main()
