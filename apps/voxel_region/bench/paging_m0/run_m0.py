"""只测试（Test-only）：区域分页 M0 一轮基准的编排。

  python run_m0.py <deploy> <out_dir> --dump /tmp/backup.dump --steps 1,2,4,8 --step-seconds 180

流程：隔离库从容器内 dump 重新还原 → 启动节点（记录启动内存曲线）→ 编译探针与负载（各一次）→ 空闲段 →
字段堆 → 逐级 N 个互不重叠的活跃窗口 → 每级收集负载报告、回合直方图、World 分阶段日志、检查点日志、PG WAL 增量 → 停机。
全程 OS 进程树内存每秒采样。任何一步失败即停止（不重试），已产出的证据保留在 out_dir。
"""
from pathlib import Path
import argparse
import json
import re
import subprocess
import threading
import time

import m0

HERE = Path(__file__).resolve().parent

# 窗口中心（canonical 米，x / z）：第一个在如园中央，其余按 spacing 网格向外。默认 256 m 互不重叠（radius 1 的盒宽 186 m）；
# 小于 186 m 即为重叠窗口。
GRID = [(0, 0), (1, 0), (0, 1), (-1, 0), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1), (2, 0), (0, 2), (-2, 0),
        (0, -2), (2, 1), (1, 2), (-2, 1), (-1, 2), (2, -1), (1, -2), (-2, -1), (-1, -2), (2, 2), (-2, 2), (2, -2)]
ORIGIN = (3988, 163)


def windows(n, spacing=256):
    return [{"id": i + 1, "x": ORIGIN[0] + spacing * dx, "z": ORIGIN[1] + spacing * dz} for i, (dx, dz) in enumerate(GRID[:n])]


def psql(cfg, sql):
    pg = cfg["pg"]
    out = subprocess.run(["docker", "exec", pg["container"], "psql", "-U", pg["user"], "-d", pg["db"], "-At", "-c", sql],
                         capture_output=True, text=True, check=True)
    return out.stdout.strip()


def restore(cfg, dump):
    pg = cfg["pg"]
    run = lambda *a: subprocess.run(["docker", "exec", pg["container"], *a], capture_output=True, text=True, check=True)
    run("psql", "-U", pg["user"], "-d", "postgres", "-q", "-c", f"DROP DATABASE IF EXISTS {pg['db']};", "-c",
        f"CREATE DATABASE {pg['db']};")
    run("pg_restore", "-U", pg["user"], "-d", pg["db"], "--no-owner", dump)
    return psql(cfg, "select count(*), max(seq) from voxel_overlay_log")


def pg_counters(cfg):
    row = psql(cfg, "select pg_current_wal_lsn() - '0/0'::pg_lsn, xact_commit, tup_inserted, tup_deleted "
                    "from pg_stat_database where datname = current_database()")
    wal, commits, ins, dele = row.split("|")
    return {"wal_bytes": int(float(wal)), "xact_commit": int(commits), "tup_inserted": int(ins), "tup_deleted": int(dele)}


def rpc_json(deploy, expr):
    return json.loads(m0.rpc(deploy, expr).strip().splitlines()[-1])


def log_lines(path, start):
    with open(path, "rb") as f:
        f.seek(start)
        data = f.read()
    return data.decode("utf-8", "replace").splitlines(), start + len(data)


def stage_summary(lines):
    def pick(tag):
        return [dict((k, int(v)) for k, v in re.findall(r"(\w+)=(\d+)", l)) for l in lines if tag in l]

    def stats(rows):
        out = {}
        for k in sorted({k for r in rows for k in r if k.endswith("_us")}):
            v = sorted(r[k] for r in rows if k in r)
            out[k] = {"n": len(v), "p50": v[len(v) // 2], "p95": v[int(0.95 * (len(v) - 1))], "max": v[-1],
                      "sum": sum(v)}
        return out

    tx = pick("voxel_region transaction ")
    return {
        "macro_stages": stats(pick("voxel_macro_stages")),
        "transaction": stats(tx),
        "transaction_bytes": sorted(r.get("bytes", 0) for r in tx)[len(tx) // 2] if tx else None,
        "checkpoint": [l for l in lines if "voxel_checkpoint" in l],
    }


def osmon_thread(deploy, out, stop):
    rec = m0.record(deploy)
    with open(out, "a", encoding="utf-8") as f:
        while not stop.is_set():
            rows = m0.mem(rec["pid"])
            f.write(json.dumps({"utc": time.time(), "rss_sum": sum(x["rss"] for x in rows), "beams": rows}) + "\n")
            f.flush()
            stop.wait(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("deploy")
    ap.add_argument("out")
    ap.add_argument("--dump", help="容器内 dump 路径；给出时先还原隔离库")
    ap.add_argument("--steps", default="1,2,4,8")
    ap.add_argument("--step-seconds", type=int, default=180)
    ap.add_argument("--idle-seconds", type=int, default=120)
    ap.add_argument("--interval-ms", type=int, default=1000)
    ap.add_argument("--spacing", type=int, default=256, help="窗口中心间距（m）；< 186 为重叠窗口")
    ap.add_argument("--activity", action="store_true", help="每窗口装一次水与有限热源（load.ex activity）")
    ap.add_argument("--circuit", action="store_true", help="每窗口装一个热电石 8 格环与热源（load.ex circuit）")
    a = ap.parse_args()
    deploy, out = Path(a.deploy), Path(a.out)
    out.mkdir(parents=True, exist_ok=False)
    cfg = m0.config(deploy)
    # 内存看门狗（系统可用 < 20 GB 时只杀本脚本启动之后出现的 erl），与 equiv.py 同一实现；函数内导入避免与 equiv 循环导入。
    from equiv import erl_pids, watchdog
    baseline, guard, tripped = erl_pids(), threading.Event(), threading.Event()
    threading.Thread(target=watchdog, args=(baseline, guard, tripped), daemon=True).start()
    meta = {"args": vars(a), "started_utc": time.time(),
            "git": subprocess.run(["git", "rev-parse", "HEAD"], cwd=HERE, capture_output=True, text=True).stdout.strip(),
            "git_dirty": subprocess.run(["git", "status", "--porcelain"], cwd=HERE, capture_output=True,
                                        text=True).stdout.strip().splitlines()}
    if a.dump:
        meta["restored"] = restore(cfg, a.dump)
    (out / "meta.json").write_text(json.dumps(meta, indent=2))

    started = m0.start(deploy)
    startup = Path(started["log"]).with_suffix(".startup.json")
    (out / "startup.json").write_text(startup.read_text())
    stop = threading.Event()
    threading.Thread(target=osmon_thread, args=(deploy, out / "os.jsonl", stop), daemon=True).start()
    log = started["log"]
    try:
        probe_dir = (out / "probe").as_posix()
        total = a.idle_seconds + len(a.steps.split(",")) * (a.step_seconds + 60) + 600
        m0.rpc(deploy, f'Code.compile_file("{(HERE / "probe.ex").as_posix()}")\n'
                       f'Code.compile_file("{(HERE / "load.ex").as_posix()}")\n'
                       f'VoxelRegion.Bench.M0Probe.start("{probe_dir}", duration_s: {total})')
        _, offset = log_lines(log, 0)
        time.sleep(a.idle_seconds)
        lines, offset = log_lines(log, offset)
        idle = {"turns": rpc_json(deploy, "VoxelRegion.Bench.M0Probe.snapshot()"), "stages": stage_summary(lines),
                "field_heap": rpc_json(deploy, "VoxelRegion.Bench.M0Probe.field_heap()"), "pg": pg_counters(cfg)}
        (out / "idle.json").write_text(json.dumps(idle, indent=2))

        for n in [int(x) for x in a.steps.split(",")]:
            m0.rpc(deploy, "VoxelRegion.Bench.M0Probe.reset()")
            pg0 = pg_counters(cfg)
            _, offset = log_lines(log, offset)
            spec = {"windows": windows(n, a.spacing), "interval_ms": a.interval_ms, "duration_s": a.step_seconds}
            t0 = time.time()
            start = rpc_json(deploy, "VoxelRegion.Bench.M0Load.start(%{windows: [" +
                             ", ".join(f"%{{id: {w['id']}, x: {w['x']}, z: {w['z']}}}" for w in spec["windows"]) +
                             f"], interval_ms: {a.interval_ms}, duration_s: {a.step_seconds}, activity: {str(a.activity).lower()}, circuit: {str(a.circuit).lower()}}})")
            t_load = time.time()
            time.sleep(max(a.step_seconds + 3 - (time.time() - t_load), 0))
            report = rpc_json(deploy, "VoxelRegion.Bench.M0Load.report()")
            circuit = rpc_json(deploy, "VoxelRegion.Bench.M0Load.circuit_totals()") if a.circuit else None
            turns = rpc_json(deploy, "VoxelRegion.Bench.M0Probe.snapshot()")
            m0.rpc(deploy, "VoxelRegion.Bench.M0Load.stop()")
            lines, offset = log_lines(log, offset)
            pg1 = pg_counters(cfg)
            step = {"n": n, "spec": spec, "start": start, "snapshot_phase_s": round(t_load - t0, 1),
                    "report": report, "circuit": circuit, "turns": turns, "stages": stage_summary(lines),
                    "pg_delta": {k: pg1[k] - pg0[k] for k in pg0}}
            (out / f"step-{n:02d}.json").write_text(json.dumps(step, indent=2))
            print(json.dumps({"n": n, "commits": report["commits"], "commit_us": report["commit_us"],
                              "errors": report["error_count"]}), flush=True)
            time.sleep(10)
        (out / "field-heap-end.json").write_text(m0.rpc(deploy, "VoxelRegion.Bench.M0Probe.field_heap()"))
        m0.rpc(deploy, "VoxelRegion.Bench.M0Probe.stop()")
    finally:
        stop.set()
        guard.set()
        if tripped.is_set():
            (out / "memory_watchdog_tripped").write_text("1")
        if m0.status(deploy)["running"]:
            (out / "stop.json").write_text(json.dumps(m0.stop(deploy), default=str))


if __name__ == "__main__":
    main()
