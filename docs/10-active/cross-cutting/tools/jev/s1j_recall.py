#!/usr/bin/env python
"""S1-J 召回对照：旧单路召回（OLD）对三路召回（NEW / NEW+），只读、离线。

用途
    按 .demo/observe/npc-slice1-20261112/s1j/plan.md，对本线 Hindsight 容器（默认 http://127.0.0.1:18933，
    API 前缀 /v1/default）里 S1-I 建好的 s1i-m1、s1i-m2 两个库做 recall，比较三种方案在两种处境
    （N：附近没人；V：Corvin 在附近）下召回的内容与延迟。
    只调用 POST /v1/default/banks/<bank>/memories/recall；不 retain、不改配置、不删库、不起子进程 / 后台进程；
    不需要凭据。材料里“靠近又离开”的三条 id 从 s1i/materials/s1i-m2-memories.json 按正文 “came within 6 m” 找。
    “期望是否成立”不由本脚本判定，只落盘读数与逐条原文。

用法（Git Bash 下 Python 用 -I -B -X utf8）
    python -I -B -X utf8 s1j_recall.py run
    选项：--base <url>、--out <dir，默认 .demo/observe/npc-slice1-20261112/s1j>、--repeats <次数，默认 5>、
          --banks s1i-m1,s1i-m2、--situations N,V、--schemes OLD,NEW,NEW+（后三项用于小规模验证）

方案
    OLD   一次召回：问句按 Mind.recall_query/2 重建（"I am deciding what to do next. <Nobody is nearby. |
          Nearby: Corvin (actor 920628760578).> What I could do: <六个候选的判据，空格连接> What do I remember
          about these people, places and tasks?"），budget mid、max_tokens 2048、query_timestamp（同 Life.Hindsight.recall/3）。
    NEW   最多三路并行（R1 人，仅 V；R2 地点与物；R3 未了与感受），请求体见 ROUTES。合并：按 id 去重（同一条
          归先返回它的路，优先级 R1 > R2 > R3），排序 = (路的优先级, occurred_start 旧在前，缺省排最后)，上限 12。
    NEW+  同 NEW，R1、R2 也加 prefer_observations: true。
    每个（库 × 处境 × 方案）串行跑 --repeats 次（格与格、次与次之间都不并行）；一次内 NEW / NEW+ 的各路用线程池并行，
    全脚本同时在途请求 <= 3。召回内容取第 1 次；其余次只核对 id 集合（各路、合并后）与计时。

读数（均由第 1 次的合并后清单算；逐条判定与原文落盘）
    n            合并后（OLD 即原样）的条数。
    chars        正文总字符数。
    wrecker      正文提到 Corvin / 920628760578 且含 remov* / destroy*（removed、removal、destroyed ...）的条数。
    calm         正文带“守屋期间事实”的条数：(nobody|no one) 后接 came|approached；或 Corvin / 920628760578 ...
                 "came within 6 m" ... "walked away"（正则见 CALM_*）。
    approach_cov （仅 M2）三条 id（两条 experience + 一条 observation，正文含 “came within 6 m”）被召回了几条；
                 >= 1 记为覆盖（approach_covered）。
    dup          1 - 不同簇数 / n（n = 0 记 0）。两条正文去掉日期、时刻、数字后相同，或 difflib.SequenceMatcher
                 相似度 >= 0.85，算同一簇；簇按传递闭包（并查集）合并。
    延迟         OLD = 单次请求耗时；NEW / NEW+ = 并行各路的墙钟（从提交到全部返回）与各路耗时之和；
                 都取各次的中位数与最大值（毫秒）。
    truncated    合并后排序在第 12 条之后被截掉的条目（含其 wrecker / calm 判定与是否 approach 三条之一）。
    HTTP 错误 / 参数被拒不重试，原样记在该次的 errors 里（状态码与响应体前 500 字），该路按 0 条算，继续下一次。

落盘（--out）
    results.json  每格的请求体、第 1 次各路返回条目（id / type / text / tags / occurred_start / 所属路）、合并清单、
                  各次耗时、各次 id 集合是否相同、读数、逐条判定、被截条目。
    raw/          每次每路的原始响应（<库>_<处境>_<方案>_<路>_run<k>.json）。
    run.log       每个请求一行。
"""

import argparse
import difflib
import json
import re
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[5]
S1 = REPO / ".demo/observe/npc-slice1-20261112"
DEFAULT_OUT = S1 / "s1j"
TEMPLATE = S1 / "s1c3/export/request-template.json"
M2_MEMORIES = S1 / "s1i/materials/s1i-m2-memories.json"

BASE = "http://127.0.0.1:18933"
PREFIX = "/v1/default"
BANKS = ("s1i-m1", "s1i-m2")
ACTOR = "920628760578"
ACTOR_NAME = f"Corvin (actor {ACTOR})"
QUERY_TIMESTAMP = "2026-11-13T01:13:00Z"
CAP = 12
MAX_INFLIGHT = 3
HTTP_TIMEOUT = 60  # 秒；单请求，不重试

SITUATIONS = {
    "N": "Nobody is nearby.",
    "V": f"Nearby: {ACTOR_NAME}.",
}

# 路：名 -> (优先级, 问句, tags, prefer_observations 对 NEW 是否开, 对 NEW+ 是否开, max_tokens, 仅 V)
ROUTES = {
    "R1": dict(
        priority=1,
        query=f"What has happened between me and {ACTOR_NAME}? Did they help, harm, or promise me anything?",
        tags=[f"actor:{ACTOR}"], max_tokens=700, only_v=True, prefer_new=False, prefer_plus=True),
    "R2": dict(
        priority=2,
        query="What has happened at my small hut since I rebuilt it?",
        tags=["place:small hut"], max_tokens=700, only_v=False, prefer_new=False, prefer_plus=True),
    "R3": dict(
        priority=3,
        query="What am I looking forward to, worried about, or have promised to do?",
        tags=None, max_tokens=600, only_v=False, prefer_new=True, prefer_plus=True),
}

CALM_NOBODY = re.compile(r"\b(nobody|no one)\s+(came|approached)\b", re.I)
CALM_CAME = re.compile(rf"(corvin|{ACTOR}).{{0,120}}came within 6 m.{{0,120}}walked away", re.I | re.S)
WRECK_WHO = re.compile(rf"corvin|{ACTOR}", re.I)
WRECK_DID = re.compile(r"remov|destroy", re.I)

DATE_RES = [
    re.compile(r"\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d+)?)?Z?)?"),
    re.compile(r"\b(January|February|March|April|May|June|July|August|September|October|November|December)"
               r"\s+\d{1,2}(,\s*\d{4})?", re.I),
    re.compile(r"\d{1,2}:\d{2}(:\d{2}(\.\d+)?)?\s*(Z|UTC|am|pm)?", re.I),
]


def now_ms():
    return time.perf_counter() * 1000.0


class Http:
    """标准库 HTTP 小工具；总在途请求 <= MAX_INFLIGHT（信号量兜底）。"""

    def __init__(self, base, log_path, raw_dir):
        self.base = base.rstrip("/")
        self.log_path = log_path
        self.raw_dir = raw_dir
        self.lock = threading.Lock()
        self.sem = threading.Semaphore(MAX_INFLIGHT)

    def log(self, line):
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        with self.lock:
            with open(self.log_path, "a", encoding="utf8") as f:
                f.write(f"{stamp} {line}\n")

    def recall(self, bank, body, raw_name):
        """POST recall；返回 dict(ok, status, ms, results, error)。不重试。"""
        url = f"{self.base}{PREFIX}/banks/{bank}/memories/recall"
        data = json.dumps(body, ensure_ascii=False).encode("utf8")
        req = urllib.request.Request(url, data=data, method="POST",
                                     headers={"Content-Type": "application/json"})
        status, payload, error = None, None, None
        with self.sem:
            t0 = now_ms()
            try:
                with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
                    status = r.status
                    payload = r.read()
            except urllib.error.HTTPError as e:
                status = e.code
                payload = e.read()
                error = f"HTTP {e.code}: {payload[:500].decode('utf8', 'replace')}"
            except Exception as e:  # 超时、连接错误
                error = f"{type(e).__name__}: {e}"
            ms = now_ms() - t0
        parsed = None
        if payload:
            try:
                parsed = json.loads(payload.decode("utf8"))
            except Exception:
                parsed = None
            (self.raw_dir / raw_name).write_bytes(payload)
        results = []
        if error is None:
            if isinstance(parsed, dict) and isinstance(parsed.get("results"), list):
                results = parsed["results"]
            else:
                error = f"invalid response: {payload[:300].decode('utf8', 'replace') if payload else ''}"
        self.log(f"POST {bank} {raw_name} status={status} ms={ms:.0f} n={len(results)}"
                 + (f" ERROR {error}" if error else ""))
        return dict(ok=error is None, status=status, ms=ms, results=results, error=error)


def load_candidates():
    tpl = json.loads(TEMPLATE.read_text(encoding="utf8"))
    return " ".join(c["criterion"] for c in tpl["candidates"])


def old_query(situation, criteria):
    return (f"I am deciding what to do next. {SITUATIONS[situation]} What I could do: {criteria} "
            "What do I remember about these people, places and tasks?")


def approach_ids():
    data = json.loads(M2_MEMORIES.read_text(encoding="utf8"))
    found = {i["id"]: i.get("fact_type") for i in data["items"] if "came within 6 m" in i["text"]}
    kinds = sorted(found.values())
    if kinds != ["experience", "experience", "observation"]:
        print(f"WARNING: approach 三条的类型是 {kinds}，不是 2 experience + 1 observation", file=sys.stderr)
    return found


def request_bodies(scheme, situation, criteria):
    """返回 [(路名, 请求体)]。OLD 只有一路 'OLD'。"""
    base = dict(budget="mid", query_timestamp=QUERY_TIMESTAMP)
    if scheme == "OLD":
        return [("OLD", dict(query=old_query(situation, criteria), budget="mid", max_tokens=2048,
                             query_timestamp=QUERY_TIMESTAMP))]
    out = []
    for name, r in ROUTES.items():
        if r["only_v"] and situation != "V":
            continue
        body = dict(query=r["query"], **base, max_tokens=r["max_tokens"])
        if r["tags"]:
            body["tags"] = r["tags"]
            body["tags_match"] = "any_strict"
        if r["prefer_plus" if scheme == "NEW+" else "prefer_new"]:
            body["prefer_observations"] = True
        out.append((name, body))
    return out


def slim(item, route):
    return dict(id=item.get("id"), type=item.get("type"), text=item.get("text"), tags=item.get("tags"),
                occurred_start=item.get("occurred_start"), route=route)


def merge(per_route):
    """per_route: {路名: [slim 条目]}。返回 (排序后的全部条目, 保留的前 CAP 条, 被截的)。"""
    seen, rows = set(), []
    for name in ("R1", "R2", "R3"):
        for it in per_route.get(name, []):
            if it["id"] in seen:
                continue
            seen.add(it["id"])
            rows.append(it)
    rows.sort(key=lambda it: (ROUTES[it["route"]]["priority"], it["occurred_start"] is None,
                              it["occurred_start"] or ""))
    return rows[:CAP], rows[CAP:]


def normalize(text):
    for rx in DATE_RES:
        text = rx.sub(" ", text)
    text = re.sub(r"\d+", " ", text)
    return re.sub(r"\s+", " ", text).strip().lower()


def dup_rate(texts):
    n = len(texts)
    if n == 0:
        return 0.0, 0
    norm = [normalize(t) for t in texts]
    parent = list(range(n))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for i in range(n):
        for j in range(i + 1, n):
            if norm[i] == norm[j] or difflib.SequenceMatcher(None, norm[i], norm[j]).ratio() >= 0.85:
                parent[find(i)] = find(j)
    clusters = len({find(i) for i in range(n)})
    return 1 - clusters / n, clusters


def judge(item, approach):
    text = item["text"] or ""
    return dict(
        wrecker=bool(WRECK_WHO.search(text) and WRECK_DID.search(text)),
        calm=bool(CALM_NOBODY.search(text) or CALM_CAME.search(text)),
        approach=item["id"] in approach,
    )


def describe(items, approach):
    return [dict(item, **judge(item, approach)) for item in items]


def med_max(values):
    return dict(median=statistics.median(values), max=max(values)) if values else dict(median=None, max=None)


def type_dist(items):
    d = {}
    for it in items:
        d[it["type"]] = d.get(it["type"], 0) + 1
    return d


def run_cell(http, bank, situation, scheme, repeats, criteria, approach, tag):
    plan = request_bodies(scheme, situation, criteria)
    runs = []
    for k in range(1, repeats + 1):
        t0 = now_ms()
        if len(plan) == 1:
            outs = [http.recall(bank, plan[0][1], f"{tag}_{plan[0][0]}_run{k}.json")]
        else:
            with ThreadPoolExecutor(max_workers=MAX_INFLIGHT) as pool:
                futs = [pool.submit(http.recall, bank, body, f"{tag}_{name}_run{k}.json") for name, body in plan]
                outs = [f.result() for f in futs]
        wall = now_ms() - t0
        per_route = {name: [slim(it, name) for it in out["results"]] for (name, _), out in zip(plan, outs)}
        kept, cut = merge(per_route) if scheme != "OLD" else (per_route["OLD"], [])
        runs.append(dict(
            run=k, wall_ms=wall, route_ms={name: out["ms"] for (name, _), out in zip(plan, outs)},
            sum_ms=sum(out["ms"] for out in outs),
            errors={name: out["error"] for (name, _), out in zip(plan, outs) if out["error"]},
            route_ids={name: [it["id"] for it in items] for name, items in per_route.items()},
            merged_ids=[it["id"] for it in kept], per_route=per_route, kept=kept, cut=cut))
    first = runs[0]
    kept, cut = first["kept"], first["cut"]
    texts = [it["text"] or "" for it in kept]
    dup, clusters = dup_rate(texts)
    judged, judged_cut = describe(kept, approach), describe(cut, approach)
    covered = [it["id"] for it in judged if it["approach"]]
    stable_routes = {name: len({frozenset(r["route_ids"][name]) for r in runs}) == 1 for name, _ in plan}
    stable_merged = len({frozenset(r["merged_ids"]) for r in runs}) == 1
    cell = dict(
        bank=bank, situation=situation, scheme=scheme,
        request_bodies={name: body for name, body in plan},
        first_run_routes={name: describe(items, approach) for name, items in first["per_route"].items()},
        first_run_route_counts={name: len(items) for name, items in first["per_route"].items()},
        first_run_route_types={name: type_dist(items) for name, items in first["per_route"].items()},
        merged=judged, truncated=judged_cut,
        metrics=dict(
            n=len(kept), chars=sum(len(t) for t in texts),
            wrecker=sum(1 for it in judged if it["wrecker"]), calm=sum(1 for it in judged if it["calm"]),
            approach_cov=len(covered) if bank == "s1i-m2" else None,
            approach_covered=(covered if bank == "s1i-m2" else None),
            dup=dup, clusters=clusters),
        truncated_counts=dict(n=len(judged_cut), wrecker=sum(1 for it in judged_cut if it["wrecker"]),
                              calm=sum(1 for it in judged_cut if it["calm"]),
                              approach=sum(1 for it in judged_cut if it["approach"])),
        latency=dict(
            wall_ms=[r["wall_ms"] for r in runs],
            route_ms={name: [r["route_ms"][name] for r in runs] for name, _ in plan},
            sum_ms=[r["sum_ms"] for r in runs],
            wall=med_max([r["wall_ms"] for r in runs]), sum=med_max([r["sum_ms"] for r in runs])),
        stability=dict(routes_same_ids=stable_routes, merged_same_ids=stable_merged,
                       distinct_merged_sets=len({frozenset(r["merged_ids"]) for r in runs}),
                       merged_ids_per_run=[r["merged_ids"] for r in runs]),
        errors=[dict(run=r["run"], **{"errors": r["errors"]}) for r in runs if r["errors"]],
    )
    return cell


def cmd_run(args):
    out = Path(args.out)
    raw = out / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    log_path = out / "run.log"
    http = Http(args.base, log_path, raw)
    criteria = load_candidates()
    approach = approach_ids()
    http.log(f"START base={args.base} repeats={args.repeats} banks={args.banks} situations={args.situations} "
             f"schemes={args.schemes} approach_ids={sorted(approach)}")
    cells = []
    for bank in args.banks.split(","):
        for situation in args.situations.split(","):
            for scheme in args.schemes.split(","):
                tag = f"{bank}_{situation}_{scheme.replace('+', 'plus')}"
                http.log(f"CELL {bank} {situation} {scheme}")
                cell = run_cell(http, bank, situation, scheme, args.repeats, criteria, approach, tag)
                cells.append(cell)
                m = cell["metrics"]
                http.log(f"DONE {bank} {situation} {scheme} n={m['n']} chars={m['chars']} wrecker={m['wrecker']} "
                         f"calm={m['calm']} approach_cov={m['approach_cov']} dup={m['dup']:.2f} "
                         f"wall_median={cell['latency']['wall']['median']:.0f}ms")
    result = dict(
        started_with=dict(base=args.base, repeats=args.repeats, query_timestamp=QUERY_TIMESTAMP, cap=CAP),
        approach_ids=approach, candidates_criteria=criteria, cells=cells)
    (out / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf8")
    http.log("END results.json written")
    print(f"results: {out / 'results.json'}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    run = sub.add_parser("run", help="跑全部格（串行），落盘")
    run.add_argument("--base", default=BASE)
    run.add_argument("--out", default=str(DEFAULT_OUT))
    run.add_argument("--repeats", type=int, default=5)
    run.add_argument("--banks", default=",".join(BANKS))
    run.add_argument("--situations", default="N,V")
    run.add_argument("--schemes", default="OLD,NEW,NEW+")
    run.set_defaults(fn=cmd_run)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
