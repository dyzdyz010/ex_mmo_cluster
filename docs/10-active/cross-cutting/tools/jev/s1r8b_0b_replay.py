#!/usr/bin/env python
"""S1-R8b（稿 A 批 0b 的离线重放）：把产品渲染好的规划请求发给生产写作位置的真实模型，存原始应答。只发请求，不判。

是什么
  规格是 .demo/observe/npc-slice1-20261112/s1r8b-0b/plan.md（发问前写定）。请求的 system / user 由产品代码渲染
  （同目录 s1r8b_0b.exs render，写在 <out>/requests/<材料>.json）；本脚本只按产品 Writer 的 :openai 形状
  （apps/npc_server/lib/npc_server/life/reflection/writer.ex 的 write/4 :openai 子句：model、max_tokens 8192、
  messages [system, user]、reasoning_effort）包成请求体，发给 .env 里 NPC_REFLECT_* 指的端点。判定在 s1r8b_0b.exs judge
  （产品 DayPlan.check/3），本脚本不写任何判定。
纪律（plan.md “请求数与停止条件”）
  - 请求总数封顶 18（6 份材料 x 3 次），次序：先每份第 1 次，再第 2 次，再第 3 次。
  - key 只从主检出 D:/hemifuture/ex_mmo_cluster/.env 读进本进程内存，不打印、不写文件、不进命令行；--dry-run 不读 key。
  - 一个 httpx.Client（复用连接，TCP，不涉及 UDP）、并发 <= 2、单次超时 120 s、不重试；任何退出路径都关闭客户端。
  - 401 / 402 / 403 / 429、正文含 quota / insufficient / balance、连接错误：立即停，未发的不再发。
    其他错误（5xx、读超时等）记下、不重发，其余照发。累计 token > 300,000 停。
落盘（只写 <out>/）
  bodies/（18 份请求体，--dry-run 生成）、raw/<id>.json（应答原字节）、sent.json（每次的状态、耗时、usage、错误）、run.log。
怎么运行（Git Bash；仓库根下）
  /c/ProgramData/miniconda3/python.exe -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r8b_0b_replay.py --dry-run
  /c/ProgramData/miniconda3/python.exe -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r8b_0b_replay.py run
"""

import argparse
import json
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[5]
OUT = ROOT / ".demo" / "observe" / "npc-slice1-20261112" / "s1r8b-0b"
ENV = Path("D:/hemifuture/ex_mmo_cluster/.env")

MATERIALS = ["R1", "R2", "R3", "R4", "R5", "R7"]
ATTEMPTS = 3
CAP = 18
WORKERS = 2
TIMEOUT_S = 120.0
TOKEN_STOP = 300_000
# 产品 Writer :openai 入口的 max_tokens（writer.ex 的 @openai_max_tokens）。
MAX_TOKENS = 8192

# 生产写作位置（deploy 2026-11-18 起）：断言 .env 与它一致，不一致就停，不猜。
EXPECTED = {
    "NPC_REFLECT_API": "openai",
    "NPC_REFLECT_URL": "https://api.deepseek.com/chat/completions",
    "NPC_REFLECT_MODEL": "deepseek-flash",
}
STOP_STATUS = {401, 402, 403, 429}
STOP_WORDS = ("quota", "insufficient", "balance")


def read_env(with_key):
    """只取 NPC_REFLECT_*；with_key 为假时不读 key 那一行的值。"""
    values = {}
    for line in ENV.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        name = name.strip()
        if not name.startswith("NPC_REFLECT_"):
            continue
        if name == "NPC_REFLECT_KEY" and not with_key:
            continue
        values[name] = value.strip().strip('"').strip("'")
    for name, expected in EXPECTED.items():
        if values.get(name) != expected:
            sys.exit(f"{name} 不是生产写作位置的值（期望 {expected!r}），停")
    values.setdefault("NPC_REFLECT_EFFORT", "medium")
    if with_key and not values.get("NPC_REFLECT_KEY"):
        sys.exit("NPC_REFLECT_KEY 缺失，停")
    return values


def calls():
    """18 次的次序：先每份第 1 次，再第 2 次，再第 3 次。"""
    order = [(m, k) for k in range(1, ATTEMPTS + 1) for m in MATERIALS]
    assert len(order) <= CAP, "请求数超过封顶"
    return order


def body_for(request, env):
    """同 Writer.write/4 的 :openai 子句。"""
    return {
        "model": env["NPC_REFLECT_MODEL"],
        "max_tokens": MAX_TOKENS,
        "messages": [
            {"role": "system", "content": request["system"]},
            {"role": "user", "content": request["user"]},
        ],
        "reasoning_effort": env["NPC_REFLECT_EFFORT"],
    }


def load_requests():
    requests = {}
    for m in MATERIALS:
        r = json.loads((OUT / "requests" / f"{m}.json").read_text(encoding="utf-8"))
        assert r["material"] == m
        assert all(r["checks"].values()), f"{m}: 渲染断言没有全部为真"
        assert r["speak_line"].startswith("- speak_to: "), m
        requests[m] = r
    return requests


def dry_run():
    env = read_env(with_key=False)
    requests = load_requests()
    (OUT / "bodies").mkdir(exist_ok=True)
    for m, k in calls():
        body = body_for(requests[m], env)
        (OUT / "bodies" / f"{m}-r{k}.json").write_text(
            json.dumps(body, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"bodies: {len(calls())}（封顶 {CAP}）; url={env['NPC_REFLECT_URL']} model={env['NPC_REFLECT_MODEL']} "
          f"effort={env['NPC_REFLECT_EFFORT']} max_tokens={MAX_TOKENS}")
    sample = body_for(requests["R1"], env)
    print("----- R1 system -----")
    print(sample["messages"][0]["content"])
    print("----- R1 user -----")
    print(sample["messages"][1]["content"])


def run():
    import httpx  # 只在正式运行时需要

    if (OUT / "sent.json").exists():
        sys.exit("sent.json 已存在：新运行用新目录，不覆盖原始结果")
    env = read_env(with_key=True)
    key = env.pop("NPC_REFLECT_KEY")
    requests = load_requests()
    (OUT / "raw").mkdir(exist_ok=True)
    log_lock, state_lock = threading.Lock(), threading.Lock()
    state = {"stop": None, "tokens": 0}
    rows = []
    log = open(OUT / "run.log", "a", encoding="utf-8")

    def note(text):
        with log_lock:
            line = f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {text}"
            log.write(line + "\n")
            log.flush()
            print(line, flush=True)

    def one(client, m, k):
        cid = f"{m}-r{k}"
        row = {"id": cid, "material": m, "attempt": k, "status": None, "elapsed_ms": None,
               "usage": None, "error": None}
        with state_lock:
            if state["stop"]:
                row["error"] = f"not_sent: {state['stop']}"
                return row
        body = body_for(requests[m], env)
        started = time.monotonic()
        try:
            resp = client.post(env["NPC_REFLECT_URL"], json=body,
                               headers={"authorization": f"Bearer {key}"})
        except (httpx.ConnectError, httpx.ConnectTimeout) as e:
            row["error"] = f"connect: {type(e).__name__}"
            with state_lock:
                state["stop"] = row["error"]
            note(f"{cid} {row['error']} -> stop")
            return row
        except httpx.HTTPError as e:
            row["elapsed_ms"] = int((time.monotonic() - started) * 1000)
            row["error"] = f"transport: {type(e).__name__}"
            note(f"{cid} {row['error']} elapsed_ms={row['elapsed_ms']}（不重发）")
            return row
        row["elapsed_ms"] = int((time.monotonic() - started) * 1000)
        row["status"] = resp.status_code
        (OUT / "raw" / f"{cid}.json").write_bytes(resp.content)
        text = resp.text.lower()
        if resp.status_code in STOP_STATUS or (resp.status_code != 200 and any(w in text for w in STOP_WORDS)):
            row["error"] = f"http {resp.status_code}"
            with state_lock:
                state["stop"] = row["error"]
            note(f"{cid} {row['error']} -> stop")
            return row
        if resp.status_code != 200:
            row["error"] = f"http {resp.status_code}"
            note(f"{cid} {row['error']} elapsed_ms={row['elapsed_ms']}（不重发）")
            return row
        try:
            payload = resp.json()
        except ValueError:
            row["error"] = "invalid_json"
            note(f"{cid} 200 invalid_json elapsed_ms={row['elapsed_ms']}")
            return row
        usage = payload.get("usage") or {}
        row["usage"] = usage
        with state_lock:
            state["tokens"] += int(usage.get("total_tokens") or 0)
            if state["tokens"] > TOKEN_STOP:
                state["stop"] = f"tokens {state['tokens']} > {TOKEN_STOP}"
        finish = (payload.get("choices") or [{}])[0].get("finish_reason")
        note(f"{cid} 200 finish={finish} elapsed_ms={row['elapsed_ms']} prompt={usage.get('prompt_tokens')} "
             f"completion={usage.get('completion_tokens')} total_so_far={state['tokens']}")
        return row

    note(f"start url={env['NPC_REFLECT_URL']} model={env['NPC_REFLECT_MODEL']} effort={env['NPC_REFLECT_EFFORT']} "
         f"cap={CAP} workers={WORKERS} timeout_s={TIMEOUT_S}")
    client = httpx.Client(timeout=TIMEOUT_S)
    try:
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            rows = list(pool.map(lambda mk: one(client, *mk), calls()))
    finally:
        client.close()
        del key
        sent = {"url": env["NPC_REFLECT_URL"], "model": env["NPC_REFLECT_MODEL"],
                "reasoning_effort": env["NPC_REFLECT_EFFORT"], "max_tokens": MAX_TOKENS,
                "workers": WORKERS, "timeout_s": TIMEOUT_S, "retries": 0, "cap": CAP,
                "stopped": state["stop"], "total_tokens": state["tokens"], "calls": rows}
        (OUT / "sent.json").write_text(json.dumps(sent, ensure_ascii=False, indent=2), encoding="utf-8")
        note(f"end sent={sum(1 for r in rows if r['status'] is not None)} stopped={state['stop']} "
             f"total_tokens={state['tokens']}")
        log.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", nargs="?", choices=["run"])
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.dry_run:
        dry_run()
    elif args.mode == "run":
        run()
    else:
        parser.error("给 --dry-run 或 run")


if __name__ == "__main__":
    main()
