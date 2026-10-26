"""只测试（Test-only）：M2b 重启基准的前置——把隔离库还原成 M2a 之前的 dump 并完成一次迁移发布，然后正常停机。

  python migrate.py <deploy> <out_dir> --dump /tmp/backup.dump

流程：还原隔离库 → 启动（旧日志全量回放，首个切点即迁移）→ 等迁移切点发布 → 正常停机。之后 `run_m0.py`（不带 --dump）
在同一库上启动即是“有前缀的重启”（M2b 按需装页），其 startup.json 即重启就绪与启动峰值。
任何一步失败即停止（不重试）；系统可用内存低于 20 GB 时只杀本脚本启动之后出现的 erl 进程并中止。
"""
from pathlib import Path
import argparse
import json
import threading
import time

import m0
from equiv import erl_pids, watchdog
from run_m0 import restore

HERE = Path(__file__).resolve().parent


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
    try:
        started = m0.start(deploy)
        meta["migrate_start"] = {k: started[k] for k in ["ready_seconds", "startup_peak_rss_sum", "log"]}
        seq = int(m0.rpc(deploy, "GenServer.call(VoxelRegion.World, :seq, :infinity)").strip().splitlines()[-1])
        meta["published"] = json.loads(m0.rpc(deploy, f'Code.compile_file("{(HERE / "equiv.ex").as_posix()}")\n'
                                                      f"VoxelRegion.Bench.PagingEquiv.await_published({seq}, 1800)",
                                              1_900_000).strip().splitlines()[-1])
        meta["stop"] = m0.stop(deploy)["after"]
    finally:
        if m0.status(deploy)["running"]:
            meta["final_stop"] = m0.stop(deploy)["after"]
        stop.set()
        meta["memory_watchdog_tripped"] = tripped.is_set()
        (out / "meta.json").write_text(json.dumps(meta, indent=2, default=str))
        print(json.dumps(meta, default=str), flush=True)


if __name__ == "__main__":
    main()
