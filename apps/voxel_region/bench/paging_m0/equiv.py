"""只测试（Test-only）：M2a 迁移等价（m2a-page-store.md §7、§8 第 9 项）。

  python equiv.py <deploy> <out_dir> --dump /tmp/backup.dump

流程：隔离库从容器内 dump 重新还原（M2a 之前的库：只有日志、没有页表）→ 启动节点（旧日志全量回放 + 启动规范化，
首个切点即迁移）→ 迁移切点发布前在 World 内采集 A → 等迁移切点发布 → 正常停机 → 再启动（按页恢复）→ 采集 B → 停机 →
逐字段（判定器 a）、逐区域正式读取（判定器 b）比较。两侧都只在空闲节点上采集，seq 必须等于迁移切点。
任何一步失败即停止（不重试）；系统可用内存低于 20 GB 时只杀本脚本启动之后出现的 erl 进程并中止。
"""
from pathlib import Path
import argparse
import json
import sys
import threading
import time

import psutil

import m0
from run_m0 import restore

HERE = Path(__file__).resolve().parent
FLOOR_GB = 20


def erl_pids():
    return {p.pid for p in psutil.process_iter(["name"]) if (p.info["name"] or "").lower().startswith("erl")}


def watchdog(baseline, stop, tripped):
    while not stop.is_set():
        if psutil.virtual_memory().available < FLOOR_GB * 2**30:
            for pid in erl_pids() - baseline:
                try:
                    psutil.Process(pid).kill()
                except psutil.NoSuchProcess:
                    pass
            tripped.set()
            return
        stop.wait(1)


def capture(deploy, out, side):
    path = (out / f"{side}.json").as_posix()
    summary = m0.rpc(deploy, f'Code.compile_file("{(HERE / "equiv.ex").as_posix()}")\n'
                             f'VoxelRegion.Bench.PagingEquiv.capture("{path}", 30)', 3_600_000)
    return json.loads(summary.strip().splitlines()[-1])


def compare(a, b):
    fields = sorted(set(a["digests"]) | set(b["digests"]))
    field_diff = [f for f in fields if a["digests"].get(f) != b["digests"].get(f)]
    keys = sorted(set(a["reads"]) | set(b["reads"]))
    read_diff = [k for k in keys if a["reads"].get(k) != b["reads"].get(k)]
    return {"fields": len(fields), "field_diff": field_diff, "regions": len(keys), "read_diff": read_diff[:50],
            "read_diff_count": len(read_diff),
            "counts": {f: a["digests"][f].split(":")[0] for f in fields if f in a["digests"]}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("deploy")
    ap.add_argument("out")
    ap.add_argument("--dump", required=True)
    a = ap.parse_args()
    deploy, out = Path(a.deploy), Path(a.out)
    out.mkdir(parents=True, exist_ok=False)
    cfg = m0.config(deploy)
    baseline = erl_pids()
    stop, tripped = threading.Event(), threading.Event()
    threading.Thread(target=watchdog, args=(baseline, stop, tripped), daemon=True).start()
    meta = {"args": vars(a), "started_utc": time.time(), "restored": restore(cfg, a.dump)}
    (out / "meta.json").write_text(json.dumps(meta, indent=2))
    try:
        started = m0.start(deploy)
        meta["a_start"] = {k: started[k] for k in ["ready_seconds", "startup_peak_rss_sum", "log"]}
        sa = capture(deploy, out, "A")
        meta["a"] = sa
        print(json.dumps({"A": sa}), flush=True)
        # 迁移切点 C = 启动规范化后的 seq；A 在启动后的自然提交（若有）走完后采集，seq = X >= C。只等 C 发布就停机
        # （不等后续切点），B = 按页恢复 C + 重放日志后缀 (C, X]。C 已发布后才采到的 A 可能已被按区压实换过基底表示，
        # 原始 overlay / region_bases 摘要只作参考，等价以其余字段与正式读取为准（result.json 的 a_after_publish）。
        cut = sa["cut"] or sa["published"]
        assert cut is not None and sa["seq"] >= cut and not sa["thermal_run"], sa
        meta["a_published"] = json.loads(m0.rpc(deploy, f"VoxelRegion.Bench.PagingEquiv.await_published({cut}, 1800)",
                                                1_900_000).strip().splitlines()[-1])
        assert meta["a_published"]["seq"] == sa["seq"], meta["a_published"]
        meta["a_stop"] = m0.stop(deploy)["after"]
        started = m0.start(deploy)
        meta["b_start"] = {k: started[k] for k in ["ready_seconds", "startup_peak_rss_sum", "log"]}
        sb = capture(deploy, out, "B")
        meta["b"] = sb
        print(json.dumps({"B": sb}), flush=True)
        meta["b_stop"] = m0.stop(deploy)["after"]
        assert sb["seq"] == sa["seq"] and sb["published"] is not None and cut <= sb["published"] <= sb["seq"]             and not sb["thermal_run"], sb
        result = compare(json.loads((out / "A.json").read_text()), json.loads((out / "B.json").read_text()))
        result["a_after_publish"] = sa["published"] is not None
        result["b_prefix"], result["cut"], result["seq"] = sb["published"], cut, sa["seq"]
        same_representation = not result["a_after_publish"] and sb["published"] == cut
        representation = set() if same_representation else {"overlay", "region_bases"}
        result["equal"] = not (set(result["field_diff"]) - representation) and result["read_diff_count"] == 0
        (out / "result.json").write_text(json.dumps(result, indent=2))
        print(json.dumps(result), flush=True)
        if not result["equal"]:
            sys.exit(1)
    finally:
        if m0.status(deploy)["running"]:
            meta["final_stop"] = m0.stop(deploy)["after"]
        stop.set()
        meta["memory_watchdog_tripped"] = tripped.is_set()
        (out / "meta.json").write_text(json.dumps(meta, indent=2, default=str))


if __name__ == "__main__":
    main()
