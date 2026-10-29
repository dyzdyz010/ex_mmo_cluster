"""只测试（Test-only）：区域分页 M0 基准的 Windows 原生部署控制端。

用法（部署目录含 m0-env.json，私有，不提交）：
  python m0.py start  <deploy>        后台启动并等待真实就绪；记录启动期 OS 内存曲线
  python m0.py stop   <deploy>        经 Erlang RPC 正常停机
  python m0.py status <deploy>
  python m0.py rpc    <deploy> < expr 在节点上 Code.eval_string 一次；只调用一次、失败不重试
  python m0.py osmon  <deploy> <out.jsonl> <seconds>  采样节点 OS 进程树内存（rss / peak_wset）

RPC 约定：表达式求值结果若是 binary 原样打印（探针返回 JSON 文本）；否则打印 inspect。
非零退出即失败，调用方不得循环重试（2026-10-23 曾因重试在节点上堆出数百个采样进程）。
"""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import time

import psutil

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]


def config(deploy):
    return json.loads((Path(deploy) / "m0-env.json").read_text(encoding="utf-8"))


def environ(cfg):
    env = dict(os.environ)
    env.update(cfg["env"])
    return env


def tree(pid):
    try:
        root = psutil.Process(pid)
        return [root] + root.children(recursive=True)
    except psutil.NoSuchProcess:
        return []


def beams(pid):
    return [p for p in tree(pid) if p.name().lower().startswith("erl")]


def mem(pid):
    rows = []
    for p in beams(pid):
        try:
            m = p.memory_info()
            rows.append({"pid": p.pid, "rss": m.rss, "peak_wset": m.peak_wset, "private": m.private})
        except psutil.NoSuchProcess:
            pass
    return rows


def record(deploy):
    path = Path(deploy) / "m0-process.json"
    return json.loads(path.read_text()) if path.exists() else None


def status(deploy):
    r = record(deploy)
    if not r:
        return {"running": False}
    try:
        p = psutil.Process(r["pid"])
        running = p.create_time() == r["create_time"] and p.is_running()
    except psutil.NoSuchProcess:
        running = False
    return dict(r, running=running, beams=mem(r["pid"]) if running else [])


def rpc(deploy, expression, timeout_ms=600_000):
    cfg = config(deploy)
    with tempfile.TemporaryDirectory() as tmp:
        expr = Path(tmp) / "expr.exs"
        expr.write_text(expression, encoding="utf-8")
        ctl = Path(tmp) / "ctl.exs"
        ctl.write_text(
            'node = String.to_atom(System.fetch_env!("M0_NODE"))\n'
            'true = Node.connect(node)\n'
            'code = File.read!(System.fetch_env!("M0_EXPR"))\n'
            # 求值进程（及其派生的探针 / 负载进程）的日志归节点自己的 :user，不回流到控制端。
            'code = "Process.group_leader(self(), Process.whereis(:user))\\n" <> code\n'
            f'result = :rpc.call(node, Code, :eval_string, [code], {timeout_ms})\n'
            'case result do\n'
            '  {:badrpc, reason} -> IO.puts(:stderr, inspect(reason, limit: :infinity)); System.halt(2)\n'
            '  {value, _binding} when is_binary(value) -> IO.puts(value)\n'
            '  {value, _binding} -> IO.puts(inspect(value, limit: :infinity, printable_limit: :infinity))\n'
            'end\n', encoding="utf-8")
        env = environ(cfg)
        env.update(M0_NODE=cfg["node"], M0_EXPR=str(expr))
        name = f"m0ctl_{os.getpid()}_{int(time.time() * 1000) % 100000}@127.0.0.1"
        out = subprocess.run(["elixir.bat", "--erl", "+S 1:1", "--name", name, "--cookie", cfg["cookie"], str(ctl)],
                             env=env, capture_output=True, text=True, encoding="utf-8", timeout=timeout_ms / 1000 + 60)
        if out.returncode != 0:
            raise RuntimeError(f"rpc failed ({out.returncode}): {out.stderr.strip()[-2000:]}")
        return out.stdout


def validate_ready(ready, expected_node):
    """在控制端 JSON 信任边界接纳新启动报告；不从本机重建应用 manifest。"""
    def require(condition, field):
        if not condition:
            raise RuntimeError(f"M0 readiness rejected: invalid or missing {field}")

    profile = "m0_manifest_ready_v1"
    require(isinstance(ready, dict) and ready.get("startup_profile") == profile, "startup_profile")
    require(ready.get("code_mode") in ("interactive", "embedded"), "code_mode")
    require(ready.get("node") == expected_node, "node")
    require(type(ready.get("os_pid")) is int and ready["os_pid"] > 0, "os_pid")
    require(isinstance(ready.get("ready_utc"), str) and bool(ready["ready_utc"]), "ready_utc")
    facts = ready.get("code_ready")
    require(isinstance(facts, dict), "code_ready")
    require(facts.get("profile") == profile and facts.get("status") == "ready", "code_ready.profile/status")
    require(facts.get("code_mode") == ready["code_mode"], "code_ready.code_mode")
    require(facts.get("ensure_modules_loaded_result") == "ok", "code_ready.ensure_modules_loaded_result")
    count = facts.get("module_count")
    require(type(count) is int and count > 0 and facts.get("loaded_count") == count, "code_ready.loaded_count")
    manifests = facts.get("app_manifests")
    require(isinstance(manifests, list) and len(manifests) == 3, "code_ready.app_manifests")
    for app in manifests:
        require(isinstance(app, dict) and isinstance(app.get("app"), str) and bool(app["app"]), "manifest.app")
        require(isinstance(app.get("vsn"), str) and bool(app["vsn"]), "manifest.vsn")
        require(isinstance(app.get("modules"), list) and bool(app["modules"]), "manifest.modules")
        require(app.get("application_load_result") in ("loaded", "already_loaded"), "manifest.application_load_result")
    for name in ("loaded_before", "loaded_after"):
        require(isinstance(facts.get(name), list) and len(facts[name]) == count, f"code_ready.{name}")
    require(all(isinstance(row, dict) and row.get("status") == "loaded" and bool(row.get("beam"))
                for row in facts["loaded_after"]), "code_ready.loaded_after.results")
    for name in ("started_utc", "completed_utc"):
        require(isinstance(facts.get(name), str) and bool(facts[name]), f"code_ready.{name}")
    phases = facts.get("phases")
    require(isinstance(phases, dict), "code_ready.phases")
    times = [phases.get(key) for key in ("started_us", "manifest_completed_us", "load_started_us", "load_completed_us", "completed_us")]
    require(all(type(value) is int for value in times) and times == sorted(times), "code_ready.phases.order")
    startup = ready.get("startup_phases")
    require(isinstance(startup, dict), "startup_phases")
    migration = [startup.get("migration_started_us"), startup.get("migration_completed_us")]
    require(all(type(value) is int for value in migration) and migration[0] <= migration[1] <= times[0], "startup_phases.migration")
    apps = startup.get("application_starts")
    require(isinstance(apps, list) and bool(apps), "startup_phases.application_starts")
    last = times[-1]
    for app in apps:
        require(isinstance(app, dict) and isinstance(app.get("app"), str), "application_starts.app")
        began, ended = app.get("started_us"), app.get("completed_us")
        require(type(began) is int and type(ended) is int and last <= began <= ended, "application_starts.order")
        last = ended
    require(sum(app["app"] == "voxel_region" for app in apps) == 1, "application_starts.voxel_region")
    require(type(startup.get("ready_us")) is int and last <= startup["ready_us"], "startup_phases.ready_us")
    return ready


def start(deploy):
    deploy = Path(deploy)
    assert not status(deploy)["running"], "M0 node already running"
    cfg = config(deploy)
    ready = deploy / "m0-ready.json"
    ready.unlink(missing_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    logs = deploy / "logs"
    logs.mkdir(exist_ok=True)
    logpath = logs / f"{stamp}.log"
    env = environ(cfg)
    env["M0_READY_FILE"] = str(ready)
    began = time.monotonic()
    with logpath.open("wb") as log:
        child = subprocess.Popen(
            ["elixir.bat", "--erl", f"+S {cfg['schedulers']}", "--name", cfg["node"], "--cookie", cfg["cookie"],
             "-S", "mix", "run", "--no-start", "--no-halt", str(HERE / "boot.exs")],
            cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)
    rec = {"pid": child.pid, "create_time": psutil.Process(child.pid).create_time(), "log": str(logpath),
           "started_utc": stamp}
    (deploy / "m0-process.json").write_text(json.dumps(rec, indent=2))
    samples = []
    while child.poll() is None:
        rows = mem(child.pid)
        samples.append({"t": round(time.monotonic() - began, 2), "rss": sum(r["rss"] for r in rows),
                        "beams": rows})
        if ready.exists():
            try:
                r = json.loads(ready.read_text(encoding="utf-8"))
            except (ValueError, UnicodeError) as error:
                raise RuntimeError(f"M0 readiness rejected: unreadable JSON; inspect {logpath}") from error
            validate_ready(r, expected_node=cfg["node"])
            result = dict(rec, ready=r, ready_seconds=round(time.monotonic() - began, 1),
                          startup_profile=r["startup_profile"], code_mode=r["code_mode"],
                          startup_peak_rss_sum=max(s["rss"] for s in samples),
                          peak_wset=[{"pid": b["pid"], "peak_wset": b["peak_wset"]} for b in rows])
            (logpath.with_suffix(".startup.json")).write_text(json.dumps(dict(result, samples=samples)))
            return result
        if time.monotonic() - began > 900:
            raise TimeoutError(f"readiness exceeded 900 s; inspect {logpath}")
        time.sleep(0.5)
    raise RuntimeError(f"node exited {child.returncode}; inspect {logpath}")


def stop(deploy):
    before = status(deploy)
    assert before["running"], "M0 node is not running"
    try:
        rpc(deploy, "System.stop()\n:ok", 60_000)
    except RuntimeError as e:
        # 停机过程中连接被断开属预期；以进程实际退出为准。
        print(f"stop rpc: {e}", file=sys.stderr)
    deadline = time.monotonic() + 180
    while status(deploy)["running"]:
        if time.monotonic() > deadline:
            raise TimeoutError("normal stop did not complete")
        time.sleep(0.5)
    return {"before": before, "after": status(deploy)}


def osmon(deploy, out, seconds):
    r = record(deploy)
    began = time.monotonic()
    with open(out, "a", encoding="utf-8") as f:
        while time.monotonic() - began < float(seconds):
            rows = mem(r["pid"])
            if not rows:
                break
            f.write(json.dumps({"utc": time.time(), "rss_sum": sum(x["rss"] for x in rows), "beams": rows}) + "\n")
            f.flush()
            time.sleep(1)
    return {"samples_until": time.time()}


if __name__ == "__main__":
    op, deploy = sys.argv[1], sys.argv[2]
    if op == "rpc":
        print(rpc(deploy, sys.stdin.read()), end="")
    elif op == "osmon":
        print(json.dumps(osmon(deploy, sys.argv[3], sys.argv[4])))
    else:
        print(json.dumps({"start": start, "stop": stop, "status": status}[op](deploy), default=str))
