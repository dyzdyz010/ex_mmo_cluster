#!/usr/bin/env python
"""S1-I 反思离线测量：三个材料库（s1i-m0 / s1i-m1 / s1i-m2）的建库、retain、等待巩固、导出，以及 reflect 最小冒烟。

用途
    按 .demo/observe/npc-slice1-20261112/s1i/plan.md “材料”一节，在本线 Hindsight 容器
    （默认 http://127.0.0.1:18933，API 前缀 /v1/default）里各建一个新 bank，retain：
      * 10 条共同事实（来自 s1c3/export/hindsight-memories-list.json，去掉 " | When: … | Involving: …" 之后的
        补充，"Actor 920628760578" 写成 "Corvin (actor 920628760578)"，timestamp = occurred_start）；
      * 10 条守屋活动（时间为 N3 state 的 10 句原始 UTC），M0 无期间事实、M1 “没人来”、M2 第 4/8 条“Corvin 靠近又离开”。
    bank 不配置 mission 等任何配置（保持缺省，属变量固定的一部分）。
    只用标准库 urllib；只访问 --base 指定的地址；不起任何子进程 / 后台进程；不需要任何凭据。

用法（Git Bash 下 Python 用 -I -B -X utf8）
    python -I -B -X utf8 s1i_materials.py                 # 建库 + retain + 等待 + 导出 memories/list + 日志
    python -I -B -X utf8 s1i_materials.py --recreate      # 先删除本脚本创建的 s1i-* bank（仅这三个名字）再建
    python -I -B -X utf8 s1i_materials.py --smoke 2       # 在 s1i-m1 上做最多 2 次 reflect 冒烟（不建库）
    选项：--out <dir>（默认 .demo/observe/npc-slice1-20261112/s1i/materials）、--wait-limit <秒，默认 900>

幂等：目标 bank 已存在则报错退出（退出码 2），不改动任何东西；--recreate 只会删除 s1i-m0/m1/m2。
并发：三个 bank 各一个线程，同时在途请求 ≤ 3。

共同 10 条的 tags 取舍（脚本里写死，见 COMMON_FACTS）：
    kind:event    = 建造 / 被拆 / 重建（含“重建后守了很多次”那条以 rebuilt 为主语的经历）；
    kind:activity = "I completed guard_hut / visit_plaza" 一类的活动记录；
    place:<名>    = small hut | plaza；actor:920628760578 = 去掉补充后的正文里出现了他。
"""

import argparse
import json
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[5]
S1I = REPO / ".demo/observe/npc-slice1-20261112/s1i"
SOURCE_LIST = REPO / ".demo/observe/npc-slice1-20261112/s1c3/export/hindsight-memories-list.json"

BANKS = ("s1i-m0", "s1i-m1", "s1i-m2")
ACTOR = "920628760578"
ACTOR_TAG = f"actor:{ACTOR}"
ACTOR_NAME = f"Corvin (actor {ACTOR})"

GUARD_TIMES = [
    "01:08:09.911Z", "01:08:41.008Z", "01:09:12.308Z", "01:09:43.454Z", "01:10:14.504Z",
    "01:10:45.551Z", "01:11:16.601Z", "01:11:47.898Z", "01:12:18.998Z", "01:12:50.095Z",
]
GUARD_DATE = "2026-11-13"
GUARD_BASE = ('At {t} (UTC), I did "guard_hut": stood beside the small hut and kept an eye on it. '
              "Result: completed.")
SUFFIX_M1 = " During it nobody came near the hut."
SUFFIX_M2_CAME = f" During it {ACTOR_NAME} came within 6 m of the hut and then walked away."
M2_CAME_INDEXES = (4, 8)  # 1-based

# 与 plan.md 逐字一致（R 产出者的聚焦问题 + 回答规则）。
ANSWER_RULES = ("Answer in the first person, in at most 3 sentences. Use only what the memories say; "
                "if they do not settle something, say so. Mention the evidence (how many times, "
                "what happened or did not happen).")
FOCUS_QUESTION = (f"Since {ACTOR_NAME} removed my hut and I rebuilt it, I have guarded it 10 times. "
                  "What do I make of that, and what should I conclude about my hut and about him?")
REFLECT_QUERY = FOCUS_QUESTION + " " + ANSWER_RULES

# (kind, place) 按 occurred_start 升序、同一时间 observation 在前 experience 在后（与源文件 id 顺序无关，只看文本）。
# 键 = 源文件里 text 去掉后缀后的开头，用于校验顺序没错位。
COMMON_KIND = {
    "I built a small hut on my plot at (25, 510, 36) in world 4ecf1f7864707144 using stone and limestone; Actor":
        ("event", "small hut"),
    "I built a small hut on my plot at (25, 510, 36) in world 4ecf1f7864707144 using stone and limestone.":
        ("event", "small hut"),
    "Actor 920628760578 removed my small hut": ("event", "small hut"),
    "Actor 920628760578 removed the entire small hut": ("event", "small hut"),
    'I completed "guard_hut" on November 13, 2026 by standing': ("activity", "small hut"),
    "After gathering additional stone, I rebuilt the small hut": ("event", "small hut"),
    'I completed "guard_hut" by standing beside': ("activity", "small hut"),
    'I completed "guard_hut", standing beside': ("activity", "small hut"),
    'I completed "visit_plaza" three times on November 13, 2026': ("activity", "plaza"),
    'I completed "visit_plaza" three times, walking': ("activity", "plaza"),
}


class Http:
    """极小的 urllib 封装：串行/并行都安全（日志加锁）；信号量限制同时在途请求 ≤ 3。"""

    def __init__(self, base, log_path):
        self.base = base.rstrip("/")
        self.log_path = log_path
        self._lock = threading.Lock()
        self._sem = threading.Semaphore(3)

    def log(self, line):
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        with self._lock:
            with open(self.log_path, "a", encoding="utf8") as f:
                f.write(f"{stamp} {line}\n")

    def call(self, method, path, body=None, timeout=600, raw_out=None):
        url = self.base + path
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf8")
        req = urllib.request.Request(url, data=data, method=method,
                                     headers={"Content-Type": "application/json"} if data else {})
        t0 = time.time()
        status, text = 0, ""
        with self._sem:
            try:
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    status, text = r.status, r.read().decode("utf8")
            except urllib.error.HTTPError as e:
                status, text = e.code, e.read().decode("utf8", "replace")
            except Exception as e:  # 连接 / 超时：如实记录后抛出
                self.log(f"{method} {path} ERROR {type(e).__name__}: {e} ({time.time() - t0:.2f}s)")
                raise
        dt = time.time() - t0
        size = len(data) if data else 0
        self.log(f"{method} {path} -> {status} req_bytes={size} resp_bytes={len(text)} {dt:.2f}s")
        if raw_out is not None:
            raw_out.write_text(text, encoding="utf8")
        try:
            return status, json.loads(text) if text else None, dt, text
        except json.JSONDecodeError:
            return status, None, dt, text


def clean_common_text(text):
    head = text.split(" | When:")[0].strip()
    return head.replace(f"Actor {ACTOR}", ACTOR_NAME)


def load_common():
    items = json.loads(SOURCE_LIST.read_text(encoding="utf8"))["items"]
    # 同一 occurred_start 的 observation 排前：源文件里即如此；稳定排序保持源顺序。
    items = sorted(items, key=lambda x: (x["occurred_start"], 0 if x["fact_type"] == "observation" else 1))
    out = []
    for it in items:
        raw_head = it["text"].split(" | When:")[0].strip()
        key = next((k for k in COMMON_KIND if raw_head.startswith(k)), None)
        if key is None:
            raise SystemExit(f"共同事实没有对应的 kind/place 规则：{raw_head!r}")
        kind, place = COMMON_KIND[key]
        text = clean_common_text(it["text"])
        tags = [f"kind:{kind}", f"place:{place}"]
        if ACTOR in text:
            tags.append(ACTOR_TAG)
        out.append({"content": text, "timestamp": it["occurred_start"], "tags": tags})
    return out


def guard_items(bank):
    m = bank[-2:]  # m0 / m1 / m2
    out = []
    for i, t in enumerate(GUARD_TIMES, 1):
        stamp = f"{GUARD_DATE}T{t}"
        text = GUARD_BASE.format(t=f"{GUARD_DATE}T{t}")
        tags = ["kind:activity", "place:small hut"]
        if m in ("m1", "m2"):
            text += SUFFIX_M1
        if m == "m2" and i in M2_CAME_INDEXES:
            text = text[: -len(SUFFIX_M1)] + SUFFIX_M2_CAME
            tags.append(ACTOR_TAG)
        out.append({"content": text, "timestamp": stamp, "tags": tags,
                    "document_id": f"{bank}-guard-{i:02d}"})
    return out


def build_items(bank, common):
    items = []
    for i, c in enumerate(common, 1):
        items.append({**c, "document_id": f"{bank}-common-{i:02d}"})
    return items + guard_items(bank)


def list_bank_ids(http):
    st, js, _, _ = http.call("GET", "/v1/default/banks")
    if st != 200:
        raise SystemExit(f"列 bank 失败：HTTP {st}")
    return [b["bank_id"] for b in js["banks"]]


def ops(http, bank, status=None):
    q = f"?limit=100" + (f"&status={status}" if status else "")
    st, js, _, _ = http.call("GET", f"/v1/default/banks/{bank}/operations{q}")
    return js["operations"] if st == 200 else None


def list_memories(http, bank, raw_out=None):
    st, js, _, _ = http.call("GET", f"/v1/default/banks/{bank}/memories/list?limit=1000&offset=0", raw_out=raw_out)
    if st != 200:
        raise RuntimeError(f"memories/list {bank}: HTTP {st}")
    return js


def setup_bank(http, bank, common):
    st, js, _, txt = http.call("PUT", f"/v1/default/banks/{bank}", body={})
    if st not in (200, 201):
        raise RuntimeError(f"建库 {bank} 失败 HTTP {st}: {txt[:300]}")
    items = build_items(bank, common)
    st, js, dt, txt = http.call("POST", f"/v1/default/banks/{bank}/memories", body={"items": items, "async": True})
    if st not in (200, 202):
        raise RuntimeError(f"retain {bank} 失败 HTTP {st}: {txt[:300]}")
    http.log(f"retain submitted bank={bank} items={len(items)} resp={json.dumps(js, ensure_ascii=False)[:300]}")
    return len(items)


def wait_done(http, bank, deadline):
    """没有 pending/processing 的操作，且所有 world/experience 记忆已巩固或巩固失败，连续 3 次轮询成立。"""
    ok_streak, last = 0, None
    while time.time() < deadline:
        busy = []
        for s in ("pending", "processing"):
            r = ops(http, bank, s)
            busy += r or []
        mems = list_memories(http, bank)["items"]
        unconsolidated = [m for m in mems if m["fact_type"] in ("world", "experience")
                          and not m.get("consolidated_at") and not m.get("consolidation_failed_at")]
        counts = {}
        for m in mems:
            counts[m["fact_type"]] = counts.get(m["fact_type"], 0) + 1
        last = {"busy_ops": [(o["task_type"], o["status"]) for o in busy],
                "unconsolidated": len(unconsolidated), "counts": counts}
        http.log(f"wait {bank}: {json.dumps(last, ensure_ascii=False)}")
        if not busy and not unconsolidated and mems:
            ok_streak += 1
            if ok_streak >= 3:
                return True, last
        else:
            ok_streak = 0
        time.sleep(10)
    return False, last


def cmd_build(args, http, out):
    existing = set(list_bank_ids(http))
    clash = [b for b in BANKS if b in existing]
    if clash and not args.recreate:
        print(f"bank 已存在：{clash}；不改动，退出（用 --recreate 仅删除 s1i-m0/m1/m2 后重建）", file=sys.stderr)
        return 2
    for b in clash:
        assert b in BANKS
        st, _, _, txt = http.call("DELETE", f"/v1/default/banks/{b}")
        if st not in (200, 204):
            print(f"删除 {b} 失败 HTTP {st}: {txt[:200]}", file=sys.stderr)
            return 3
    common = load_common()
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=3) as ex:
        n = list(ex.map(lambda b: setup_bank(http, b, common), BANKS))
    print(f"retain 已提交：{dict(zip(BANKS, n))}")
    deadline = t0 + args.wait_limit
    with ThreadPoolExecutor(max_workers=3) as ex:
        results = list(ex.map(lambda b: wait_done(http, b, deadline), BANKS))
    rc = 0
    for b, (done, last) in zip(BANKS, results):
        print(f"{b}: {'完成' if done else '超时/未完成'} {json.dumps(last, ensure_ascii=False)}")
        if not done:
            rc = 4
        list_memories(http, b, raw_out=out / f"{b}-memories.json")  # 原始 JSON，不加工
    http.log(f"build finished rc={rc} elapsed={time.time() - t0:.1f}s")
    return rc


def cmd_smoke(args, http, out):
    body = {"query": REFLECT_QUERY, "include": {"facts": {}}}
    for i in range(1, args.smoke + 1):
        st, js, dt, _ = http.call("POST", "/v1/default/banks/s1i-m1/reflect", body=body, timeout=600,
                                  raw_out=out / f"smoke-reflect-{i}.json")
        print(f"smoke {i}: HTTP {st} {dt:.2f}s")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="http://127.0.0.1:18933")
    ap.add_argument("--out", default=str(S1I / "materials"))
    ap.add_argument("--recreate", action="store_true")
    ap.add_argument("--smoke", type=int, default=0, help="只在 s1i-m1 上做 N 次 reflect 冒烟（N<=2）")
    ap.add_argument("--wait-limit", type=int, default=900)
    args = ap.parse_args()
    if args.smoke > 2:
        ap.error("--smoke 最多 2 次")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    http = Http(args.base, out / "materials.log")
    http.log(f"start argv={sys.argv[1:]}")
    return cmd_smoke(args, http, out) if args.smoke else cmd_build(args, http, out)


if __name__ == "__main__":
    sys.exit(main())
