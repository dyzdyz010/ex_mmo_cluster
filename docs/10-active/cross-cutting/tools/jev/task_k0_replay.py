#!/usr/bin/env python
"""K-0（任务层离线探索）：把产品渲染好的回顾 / 推进请求发给生产写作位置的真实模型，存原始应答。只发请求，不判。

是什么
  规格是 .demo/observe/npc-task-k0-20261119/plan.md（发问前写定）。请求的 system / user 由产品代码渲染
  （同目录 task_k0.exs render-review / render-advance，写在 <out>/requests/<段>/，发送次序在 manifest.json）；
  本脚本只按产品 Writer 的 :openai 形状（apps/npc_server/lib/npc_server/life/reflection/writer.ex 的 write/4 :openai 子句：
  model、max_tokens 8192、messages [system, user]、reasoning_effort）包成请求体，发给 .env 里 NPC_REFLECT_* 指的端点。
  判定在 task_k0.exs judge-*（产品 Tasks.check/3），本脚本不写任何判定。
纪律（plan.md “请求数、用量与停止条件”）
  - 两段合计请求数硬上限 40：review 段 <= 18；advance 段 <= 40 - review 段实际发出数（manifest 超出即拒绝运行）。
    复测用 --out <目录> --cap <两段合计上限> 指到别的目录与更小的上限（如 retest-1：--cap 24），--cap 不得超过 40。
  - key 只从主检出 D:/hemifuture/ex_mmo_cluster/.env 读进本进程内存，不打印、不写文件、不进命令行；--dry-run 不读 key。
  - 一个 httpx.Client（复用连接，TCP，不涉及 UDP）、并发 <= 2、单次超时 120 s、不重试；任何退出路径都关闭客户端。
  - 401 / 402 / 403 / 429、正文含 quota / insufficient / balance、连接错误：立即停，未发的不再发。
    其他错误（5xx、读超时等）记下、不重发，其余照发。两段累计 token > 400,000 停。
落盘（只写 <out>/）
  bodies/<段>/（请求体，--dry-run 生成）、raw/<段>/<id>.json（应答原字节）、sent-<段>.json、run.log。
怎么运行（Git Bash；仓库根下）
  /c/ProgramData/miniconda3/python.exe -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/task_k0_replay.py review --dry-run
  /c/ProgramData/miniconda3/python.exe -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/task_k0_replay.py review
  （advance 同理；复测加 --out .demo/observe/npc-task-k0-20261119/retest-1 --cap 24）
"""

import argparse
import json
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[5]
OUT = ROOT / ".demo" / "observe" / "npc-task-k0-20261119"
ENV = Path("D:/hemifuture/ex_mmo_cluster/.env")

CAP = 40
REVIEW_CAP = 18
WORKERS = 2
TIMEOUT_S = 120.0
TOKEN_STOP = 400_000
# 产品 Writer :openai 入口的 max_tokens（writer.ex 的 @openai_max_tokens）。
MAX_TOKENS = 8192

# 生产写作位置：断言 .env 与它一致，不一致就停，不猜。
EXPECTED = {
    "NPC_REFLECT_API": "openai",
    "NPC_REFLECT_URL": "https://api.deepseek.com/chat/completions",
    "NPC_REFLECT_MODEL": "deepseek-flash",
}
STOP_STATUS = {401, 402, 403, 429}
STOP_WORDS = ("quota", "insufficient", "balance")


def set_run(out, cap):
    """本次运行的目录与两段合计上限（复测用新目录，不覆盖 K-0 的原始结果）。"""
    global OUT, CAP
    OUT, CAP = out, cap


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


def sent_count(rows):
    return sum(1 for r in rows if not str(r.get("error") or "").startswith("not_sent"))


def plan_calls(phase):
    """manifest 的次序与本段上限；advance 段的上限按 review 段实际发出数算。"""
    manifest = json.loads((OUT / "requests" / phase / "manifest.json").read_text(encoding="utf-8"))
    calls = manifest["calls"]
    prior_tokens = 0
    if phase == "review":
        limit = REVIEW_CAP
    else:
        review = json.loads((OUT / "sent-review.json").read_text(encoding="utf-8"))
        limit = CAP - sent_count(review["calls"])
        prior_tokens = review["total_tokens"]
    if len(calls) > limit:
        sys.exit(f"{phase}: manifest {len(calls)} 次超过本段上限 {limit}，停")
    return calls, limit, prior_tokens


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


def load_request(phase, name):
    return json.loads((OUT / "requests" / phase / f"{name}.json").read_text(encoding="utf-8"))


def dry_run(phase):
    env = read_env(with_key=False)
    calls, limit, _ = plan_calls(phase)
    (OUT / "bodies" / phase).mkdir(parents=True, exist_ok=True)
    chars = []
    for call in calls:
        body = body_for(load_request(phase, call["request"]), env)
        (OUT / "bodies" / phase / f"{call['id']}.json").write_text(
            json.dumps(body, ensure_ascii=False, indent=2), encoding="utf-8")
        chars.append(sum(len(m["content"]) for m in body["messages"]))
    print(f"{phase}: bodies {len(calls)}（本段上限 {limit}，两段合计上限 {CAP}）; url={env['NPC_REFLECT_URL']} "
          f"model={env['NPC_REFLECT_MODEL']} effort={env['NPC_REFLECT_EFFORT']} max_tokens={MAX_TOKENS}")
    print(f"输入字符：min={min(chars)} max={max(chars)} 合计={sum(chars)}；按 ~3.6 字符/token 估 ≈ {sum(chars) / 3.6:,.0f} token")


def run(phase):
    import httpx  # 只在正式运行时需要

    sent_path = OUT / f"sent-{phase}.json"
    if sent_path.exists():
        sys.exit(f"{sent_path.name} 已存在：新运行用新目录，不覆盖原始结果")
    env = read_env(with_key=True)
    key = env.pop("NPC_REFLECT_KEY")
    calls, limit, prior_tokens = plan_calls(phase)
    requests = {c["request"]: load_request(phase, c["request"]) for c in calls}
    (OUT / "raw" / phase).mkdir(parents=True, exist_ok=True)
    log_lock, state_lock = threading.Lock(), threading.Lock()
    state = {"stop": None, "tokens": prior_tokens}
    rows = []
    log = open(OUT / "run.log", "a", encoding="utf-8")

    def note(text):
        with log_lock:
            line = f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {phase} {text}"
            log.write(line + "\n")
            log.flush()
            print(line, flush=True)

    def one(client, call):
        cid = call["id"]
        row = {"id": cid, "request": call["request"], "status": None, "elapsed_ms": None,
               "usage": None, "error": None}
        with state_lock:
            if state["stop"]:
                row["error"] = f"not_sent: {state['stop']}"
                return row
        body = body_for(requests[call["request"]], env)
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
        (OUT / "raw" / phase / f"{cid}.json").write_bytes(resp.content)
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
         f"calls={len(calls)} limit={limit} workers={WORKERS} timeout_s={TIMEOUT_S}")
    client = httpx.Client(timeout=TIMEOUT_S)
    try:
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            rows = list(pool.map(lambda c: one(client, c), calls))
    finally:
        client.close()
        del key
        sent = {"url": env["NPC_REFLECT_URL"], "model": env["NPC_REFLECT_MODEL"],
                "reasoning_effort": env["NPC_REFLECT_EFFORT"], "max_tokens": MAX_TOKENS,
                "workers": WORKERS, "timeout_s": TIMEOUT_S, "retries": 0, "limit": limit,
                "stopped": state["stop"], "total_tokens": state["tokens"], "calls": rows}
        sent_path.write_text(json.dumps(sent, ensure_ascii=False, indent=2), encoding="utf-8")
        note(f"end sent={sent_count(rows)} stopped={state['stop']} total_tokens={state['tokens']}")
        log.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=["review", "advance"])
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--out", type=Path, default=OUT, help="运行目录（缺省 K-0 本轮目录）")
    parser.add_argument("--cap", type=int, default=CAP, help="两段合计请求数上限（<= 40）")
    args = parser.parse_args()
    if args.cap > 40 or args.cap < 1:
        sys.exit("--cap 须在 1..40")
    set_run(args.out.resolve(), args.cap)
    if args.dry_run:
        dry_run(args.phase)
    else:
        run(args.phase)


if __name__ == "__main__":
    main()
