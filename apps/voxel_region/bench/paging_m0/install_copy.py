"""只测试（Test-only）：M0“冷内容份数”轴——把同一份如园经既有维护入口 `World.parcel_install` 再装一份到远处。

  python install_copy.py <deploy> <parcels_dir> <receipts_dir> <tag> <dx> <dy> <dz>

批次与顺序沿用 2026-10-23 演练（Voxim Docs/Playtest/tools/ruyuan_qinglan_20261023.py BATCHES），但不含当时 OOM 未装上的
garden-g4，使每份内容与演练副本里的第一份相同。key 带 tag，同 key 只装一次（parcel.ex 幂等），所以中断后重跑只读回执。
parcels_dir 是从 D:/hemifuture/Backups/ruyuan-20261024/ 解出的副本，不读受保护原件。
安装在节点上的独立进程里调用，回执写 receipts_dir/<key>.json；本端轮询回执并每 5 s 记录 OS 内存与系统可用内存；可用内存低于 FLOOR 时停掉隔离节点并失败退出。
"""
from pathlib import Path
import json
import sys
import time

import psutil

import m0

FLOOR = 2_500_000_000  # 系统可用内存下限（字节）

BATCHES = ([f"ruyuan-sky-v1-x{i}" for i in range(5)] + [f"ruyuan-low-v1-x{i}" for i in range(5)] +
           [f"ruyuan-garden-v1-g{i}" for i in (1, 3, 0, 2)])


def install_one(deploy, parcels, receipts, tag, name, delta, log):
    key = f"m0-{tag}-{name}"
    done = receipts / f"{key}.json"
    if done.exists() and json.loads(done.read_text()).get("ok"):
        return json.loads(done.read_text())
    done.unlink(missing_ok=True)
    src, out = (parcels / f"{name}.etf").as_posix(), done.as_posix()
    m0.rpc(deploy, f'''spawn(fn ->
  p = :erlang.binary_to_term(File.read!("{src}"))
  t0 = System.monotonic_time(:millisecond)
  r = try do
    case VoxelRegion.World.parcel_install(VoxelRegion.World, "{key}", p, {{{delta[0]}, {delta[1]}, {delta[2]}}}) do
      {{:ok, r}} -> %{{ok: true, seq: r.seq, cells: r.cells, instances: r.instances, removed_instances: r.removed_instances,
        attachments: r.attachments, liquid_cells: r.liquid_cells, box: Tuple.to_list(r.box) |> Enum.map(&Tuple.to_list/1)}}
      {{:error, reason}} -> %{{ok: false, error: inspect(reason)}}
    end
  catch kind, reason -> %{{ok: false, error: String.slice(inspect({{kind, reason}}), 0, 4000)}}
  end
  File.write!("{out}", Jason.encode!(Map.put(r, :install_ms, System.monotonic_time(:millisecond) - t0)))
end)
:started''')
    began = time.monotonic()
    rec = m0.record(deploy)
    while not done.exists():
        rows = m0.mem(rec["pid"])
        assert rows, "node exited during install"
        avail = psutil.virtual_memory().available
        log.write(json.dumps({"utc": time.time(), "key": key, "rss_sum": sum(r["rss"] for r in rows),
                              "peak_wset": max(r["peak_wset"] for r in rows), "sys_available": avail}) + "\n")
        log.flush()
        if avail < FLOOR:
            # 开发机内存护栏：只停本隔离节点（安装是单笔 PG 事务，中途停机不落半份），不碰其它进程。
            for p in m0.tree(rec["pid"]):
                p.kill()
            raise MemoryError(f"system available {avail} < {FLOOR} during {key}; isolated node killed")
        time.sleep(5)
    time.sleep(1)
    result = dict(json.loads(done.read_text()), parcel=name, delta=list(delta), seconds=round(time.monotonic() - began, 1))
    done.write_text(json.dumps(result, indent=1))
    return result


def main():
    deploy, parcels, receipts, tag = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4]
    delta = tuple(int(v) for v in sys.argv[5:8])
    receipts.mkdir(parents=True, exist_ok=True)
    with open(receipts / f"mem-{tag}.jsonl", "a", encoding="utf-8") as log:
        for name in BATCHES:
            r = install_one(deploy, parcels, receipts, tag, name, delta, log)
            print(json.dumps({k: r.get(k) for k in ("parcel", "ok", "seq", "cells", "instances", "install_ms", "error")}),
                  flush=True)
            assert r["ok"], r


if __name__ == "__main__":
    main()
