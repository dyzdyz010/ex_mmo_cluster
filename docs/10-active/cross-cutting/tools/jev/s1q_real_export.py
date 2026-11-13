#!/usr/bin/env python
"""S1-Q 在 S1-N 真实实跑导出上的离线重测：召回方案（R）、各栏对选择的作用（J）、mission（M）。探索性，不是验收。

计划与期望（由统筹会话持有，本脚本不判定成立 / 落空）：.demo/observe/npc-slice1-20261112/s1q/plan.md。
只发 HTTP：Hindsight（本线容器，默认 http://127.0.0.1:18933，API 前缀 /v1/default）与 Jev（HTTPS）。
不编译、不起节点 / 容器 / 后台进程；不改 apps/ 下任何文件。

用法（Git Bash 下 python -I -B -X utf8）
    python -I -B -X utf8 s1q_real_export.py recall [--probe] [--repeats 5] [--situations N,T,V] [--schemes OLD,OLD+obs,NEW3]
    python -I -B -X utf8 s1q_real_export.py jev [--dryrun]
    python -I -B -X utf8 s1q_real_export.py mission [--readings-only]
  recall   只对真实 bank npc-life-312999940097 发 recall（不 retain、不改配置）。--probe 只发 1 次 OLD/N 验证请求体被接受。
  jev      先由基准 state 与 recall 第 1 次的返回组变体，写 s1q/variants/；--dryrun 只写变体不发问。
           每变体 4 次，并发 <= 3，超时 60 s，失败不补问（计为失败）。凭据只从主检出 .env 读 TYPESAFE_* 进本进程环境，
           值不打印、不写文件；只记录模型名。
  mission  新建 bank s1q-nomission-20261113（先 GET /banks 列表确认不存在，存在就停下）；建法同产品 Life.Hindsight.ensure/2
           的 PUT（name + bank mission），不做 PATCH /config、不建四份认识文档。133 份文档的正文取 s1n/states 里
           What just happened 的原句（按 `At <UTC>` 时刻与文档 event_date 对上，并核对长度 = text_length），document_id /
           timestamp / tags 取 hindsight-documents-list.json；按实跑的 6 批（created_at 的分钟簇）串行 retain
           （async: false，同产品）；然后轮询 /stats（间隔 5 s，上限 25 分钟）到 pending_operations 与 pending_consolidation
           都为 0；导出事实列表到 s1q/nomission-memories-list.json 并算两库对照读数。--readings-only 只用已导出的列表重算读数。
  全脚本：Hindsight 同时在途 <= 3（信号量），Jev 同时在途 <= 3；单请求超时 60 s，不重试。

读数定义（plan.md；关键词判定逐条原文落 results.json）
  wrecker   正文提到 Corvin / 3494090117122 且含 remov* / destroy*。
  calm      (nobody|no one) 后隔 0-3 个词接 came|approached（plan 写作 “nobody / no one … came|approached”）。
  visitor_T 正文提到 Tobin / 15002635341827。
  stale     正文含 `no longer exists`。
  dup       正文去掉日期、时刻、数字后相同或 difflib >= 0.85 算同簇（并查集），1 - 簇数 / n。
  first_person（M，同 S1-N E7 的较宽判法）前 80 字内有 \\bI\\b 或 \\b[Mm]y\\b，且全文不含 the user / the assistant。
  counted   （M）认识类事实（fact_type = observation）里带次数：`<数字或数词> times` / once / twice / thrice。
"""

import argparse
import datetime
import difflib
import json
import os
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
S1N = S1 / "s1n"
OUT = S1 / "s1q"
RAW = OUT / "raw"
VARIANTS_DIR = OUT / "variants"
RESULTS = OUT / "results.json"
STATES = S1N / "states"
TEMPLATE = S1N / "export/request-template.json"
DOCS_LIST = S1N / "export/hindsight-documents-list.json"
REAL_MEMORIES = S1N / "export/hindsight-memories-list.json"
NEW_MEMORIES = OUT / "nomission-memories-list.json"
MAIN_ENV = Path("D:/hemifuture/ex_mmo_cluster/.env")

BASE = "http://127.0.0.1:18933"
PREFIX = "/v1/default"
REAL_BANK = "npc-life-312999940097"
NEW_BANK = "s1q-nomission-20261113"
HTTP_TIMEOUT = 60
MAX_INFLIGHT = 3
JEV_REPEATS = 4
QUOTA = 4
WAIT_CAP_S = 25 * 60
POLL_S = 5

V_CID, T_CID = "3494090117122", "15002635341827"
V_NAME, T_NAME = f"Corvin (actor {V_CID})", f"Tobin (actor {T_CID})"

# 处境 -> (基准 state 文件, 附近的人 [(名字写法, cid)])；query_timestamp = 文件名里的时刻
SITUATIONS = {
    "N": ("asked-20261113T083347.051Z.txt", []),
    "T": ("asked-20261113T083234.182Z.txt", [(T_NAME, T_CID)]),
    "V": ("asked-20261113T081603.768Z.txt", [(V_NAME, V_CID)]),
    "V2": ("asked-20261113T081701.957Z.txt", [(V_NAME, V_CID)]),
}

# 产品 Life.Hindsight 的 bank mission（ensure/2 的 PUT 随带）；原文照抄 apps/npc_server/lib/npc_server/life/hindsight.ex
BANK_MISSION = ("My first-person builder journal. Preserve event history and evolving subjective beliefs. "
                "Subjective memory; not current numeric world truth.")

WRECK_WHO = re.compile(rf"corvin|{V_CID}", re.I)
WRECK_DID = re.compile(r"remov|destroy", re.I)
CALM = re.compile(r"\b(nobody|no one)\b(\W+\w+){0,3}?\W+(came|approached)\b", re.I)
VISITOR_T = re.compile(rf"tobin|{T_CID}", re.I)
STALE = "no longer exists"
GUARD_COUNT = re.compile(r"guard", re.I)
NUMWORD = (r"two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|"
           r"eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|several|many|multiple")
COUNTED = re.compile(rf"\b(\d[\d,]*|(?:{NUMWORD})(?:-\w+)?)\s+times\b|\bonce\b|\btwice\b|\bthrice\b", re.I)
FP_SUBJ = re.compile(r"\bI\b|\b[Mm]y\b")
FP_NOT = re.compile(r"the user|the assistant", re.I)

DATE_RES = [
    re.compile(r"\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d+)?)?Z?)?"),
    re.compile(r"\b(January|February|March|April|May|June|July|August|September|October|November|December)"
               r"\s+\d{1,2}(,\s*\d{4})?", re.I),
    re.compile(r"\d{1,2}:\d{2}(:\d{2}(\.\d+)?)?\s*(Z|UTC|am|pm)?", re.I),
]
STAMP = r"At \d{4}-\d{2}-\d{2}T[\d:.]+Z \(UTC\), "
TITLES = ("Character", "Feelings and relationships", "What just happened", "What I remember",
          "Current situation", "Recent activities")
WJH, MEM = "What just happened", "What I remember"


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def perf_ms():
    return time.perf_counter() * 1000.0


def asked_at(situation):
    m = re.search(r"asked-(\d{8})T(\d{6})\.(\d{3})Z", SITUATIONS[situation][0])
    d, t, ms = m.groups()
    return f"{d[:4]}-{d[4:6]}-{d[6:]}T{t[:2]}:{t[2:4]}:{t[4:]}.{ms}Z"


def state_text(situation):
    return (STATES / SITUATIONS[situation][0]).read_text(encoding="utf8")


# ---------------------------------------------------------------- 结果文件（各子命令只替换自己的键）

def save_section(key, value):
    lock = OUT / ".results.lock"
    deadline = time.time() + 60
    while True:
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            break
        except FileExistsError:
            if time.time() > deadline:
                raise SystemExit(f"results lock held for 60 s: {lock}")
            time.sleep(0.5)
    try:
        data = json.loads(RESULTS.read_text(encoding="utf8")) if RESULTS.exists() else {}
        data[key] = value
        tmp = RESULTS.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf8")
        os.replace(tmp, RESULTS)
    finally:
        os.close(fd)
        os.remove(lock)


def load_section(key):
    if not RESULTS.exists():
        return None
    return json.loads(RESULTS.read_text(encoding="utf8")).get(key)


# ---------------------------------------------------------------- Hindsight HTTP

class Hindsight:
    """标准库 HTTP；同时在途 <= MAX_INFLIGHT；单请求超时 60 s，不重试。"""

    def __init__(self, base, log_path):
        self.base = base.rstrip("/")
        self.log_path = log_path
        self.lock = threading.Lock()
        self.sem = threading.Semaphore(MAX_INFLIGHT)

    def log(self, line):
        with self.lock:
            with open(self.log_path, "a", encoding="utf8") as f:
                f.write(f"{now_iso()} {line}\n")

    def call(self, method, path, body=None, raw_name=None, timeout=HTTP_TIMEOUT):
        url = f"{self.base}{PREFIX}{path}"
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf8")
        headers = {"Content-Type": "application/json"} if body is not None else {}
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        status, payload, error = None, None, None
        with self.sem:
            t0 = perf_ms()
            try:
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    status, payload = r.status, r.read()
            except urllib.error.HTTPError as e:
                status, payload = e.code, e.read()
                error = f"HTTP {e.code}: {payload[:500].decode('utf8', 'replace')}"
            except Exception as e:  # 超时、连接错误
                error = f"{type(e).__name__}: {e}"
            ms = perf_ms() - t0
        parsed = None
        if payload:
            try:
                parsed = json.loads(payload.decode("utf8"))
            except Exception:
                parsed = None
            if raw_name:
                (RAW / raw_name).write_bytes(payload)
        self.log(f"{method} {path} status={status} ms={ms:.0f}" + (f" ERROR {error}" if error else ""))
        return dict(ok=error is None, status=status, ms=ms, json=parsed, error=error)


# ---------------------------------------------------------------- 判定

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


def judge(text):
    text = text or ""
    return dict(wrecker=bool(WRECK_WHO.search(text) and WRECK_DID.search(text)), calm=bool(CALM.search(text)),
                visitor_T=bool(VISITOR_T.search(text)), stale=STALE in text)


def type_dist(items):
    d = {}
    for it in items:
        d[it["type"]] = d.get(it["type"], 0) + 1
    return d


def med_max(values):
    return dict(median=statistics.median(values), max=max(values)) if values else dict(median=None, max=None)


def metrics(items):
    texts = [it["text"] or "" for it in items]
    js = [judge(t) for t in texts]
    dup, clusters = dup_rate(texts)
    return dict(n=len(items), chars=sum(len(t) for t in texts),
                wrecker=sum(j["wrecker"] for j in js), calm=sum(j["calm"] for j in js),
                visitor_T=sum(j["visitor_T"] for j in js), stale=sum(j["stale"] for j in js),
                dup=dup, clusters=clusters, types=type_dist(items),
                guard_count_calm_observation=sum(
                    1 for it, j in zip(items, js) if it["type"] == "observation" and GUARD_COUNT.search(it["text"] or "")
                    and COUNTED.search(it["text"] or "") and j["calm"]))


# ---------------------------------------------------------------- state 解析

def sections(text):
    """[(栏名, [行])]：一栏从 `<栏名>: ` 开头的行起，到下一栏开头之前。"""
    out = []
    for line in text.split("\n"):
        title = next((t for t in TITLES if line.startswith(t + ": ")), None)
        if title and title not in [s[0] for s in out]:
            out.append((title, [line]))
        else:
            assert out, "text before the first section"
            out[-1][1].append(line)
    return out


def memory_parts(lines):
    """What I remember 栏的行 -> (栏头行, 认识块的行, 召回行, 认识块之后召回行之间的其它行)。断言召回行连续地在认识块之后。"""
    header = lines[0]
    rest = lines[1:]
    rec_ix = [i for i, l in enumerate(rest) if l.startswith("- Recalled: ")]
    if rec_ix:
        assert rec_ix == list(range(rec_ix[0], rec_ix[0] + len(rec_ix))), "recalled lines not contiguous"
        assert rec_ix[-1] == len(rest) - 1, "lines after the recalled lines inside What I remember"
        beliefs = rest[:rec_ix[0]]
    else:
        beliefs = rest
    assert not beliefs or beliefs[0].startswith("- Belief ("), "belief block does not start with - Belief ("
    return header, beliefs, [rest[i] for i in rec_ix]


def join(secs):
    return "\n".join(l for _, lines in secs for l in lines)


# ---------------------------------------------------------------- R：召回

def criteria():
    tpl = json.loads(TEMPLATE.read_text(encoding="utf8"))
    return " ".join(c["criterion"] for c in tpl["candidates"])


def old_query(situation, crit):
    people = SITUATIONS[situation][1]
    who = "Nobody is nearby." if not people else "Nearby: " + ", ".join(n for n, _ in people) + "."
    return f"I am deciding what to do next. {who} What I could do: {crit} What do I remember about these people, places and tasks?"


def plan_bodies(scheme, situation, crit):
    ts = asked_at(situation)
    if scheme in ("OLD", "OLD+obs"):
        body = dict(query=old_query(situation, crit), budget="mid", max_tokens=2048, query_timestamp=ts)
        if scheme == "OLD+obs":
            body["prefer_observations"] = True
        return [("OLD", 0, body)]
    out = []
    for k, (name, cid) in enumerate(SITUATIONS[situation][1][:2]):
        out.append((f"R1{'ab'[k]}" if len(SITUATIONS[situation][1]) > 1 else "R1", 1,
                    dict(query=f"What has happened between me and {name}? Did they help, harm, or promise me anything?",
                         budget="mid", prefer_observations=True, tags=[f"actor:{cid}"], tags_match="any_strict",
                         max_tokens=700, query_timestamp=ts)))
    out.append(("R2", 2, dict(query='What has happened at my building "small hut"?', budget="mid",
                              prefer_observations=True, tags=["place:small hut"], tags_match="any_strict",
                              max_tokens=700, query_timestamp=ts)))
    out.append(("R3", 3, dict(query="What am I looking forward to, worried about, or have promised to do?",
                              budget="mid", prefer_observations=True, max_tokens=600, query_timestamp=ts)))
    return out


def slim(item, route):
    at = item.get("occurred_start") or item.get("mentioned_at")
    return dict(id=item.get("id"), type=item.get("type"), text=item.get("text"), tags=item.get("tags"),
                at=at, occurred_start=item.get("occurred_start"), mentioned_at=item.get("mentioned_at"), route=route)


def merge_new3(plan, per_route):
    """去重（同一 id 归优先级高的路；R1 内按人的次序），每路按时间新的在前（无时间排最后），每路配额 QUOTA。
    返回 (合并清单, 去重后未加配额的全量 {路: [条目]}, 被配额截掉的条目)。"""
    seen, by_route = set(), {}
    for name, _, _ in sorted(plan, key=lambda p: (p[1], p[0])):
        rows = []
        for it in per_route.get(name, []):
            if it["id"] in seen:
                continue
            seen.add(it["id"])
            rows.append(it)
        rows.sort(key=lambda it: (it["at"] is None, 0 if it["at"] is None else -_iso_key(it["at"])))
        by_route[name] = rows
    merged, cut = [], []
    for name, _, _ in sorted(plan, key=lambda p: (p[1], p[0])):
        merged += by_route[name][:QUOTA]
        cut += by_route[name][QUOTA:]
    return merged, by_route, cut


def run_cell(hs, situation, scheme, repeats, crit):
    plan = plan_bodies(scheme, situation, crit)
    tag = f"R_{situation}_{scheme.replace('+', 'plus')}"
    runs = []
    for k in range(1, repeats + 1):
        t0 = perf_ms()
        if len(plan) == 1:
            outs = [hs.call("POST", f"/banks/{REAL_BANK}/memories/recall", plan[0][2], f"{tag}_{plan[0][0]}_run{k}.json")]
        else:
            with ThreadPoolExecutor(max_workers=MAX_INFLIGHT) as pool:
                futs = [pool.submit(hs.call, "POST", f"/banks/{REAL_BANK}/memories/recall", body,
                                    f"{tag}_{name}_run{k}.json") for name, _, body in plan]
                outs = [f.result() for f in futs]
        wall = perf_ms() - t0
        per_route, errors = {}, {}
        for (name, _, _), out in zip(plan, outs):
            res = (out["json"] or {}).get("results") if out["ok"] else None
            if out["ok"] and not isinstance(res, list):
                out["error"] = "invalid response (no results list)"
            if out["error"]:
                errors[name] = out["error"]
                res = []
            per_route[name] = [slim(it, name) for it in res]
        if scheme == "NEW3":
            merged, full, cut = merge_new3(plan, per_route)
        else:
            merged, full, cut = per_route["OLD"], None, []
        runs.append(dict(run=k, wall_ms=wall, route_ms={name: o["ms"] for (name, _, _), o in zip(plan, outs)},
                         sum_ms=sum(o["ms"] for o in outs), errors=errors,
                         route_ids={n: sorted(it["id"] for it in v) for n, v in per_route.items()},
                         merged_ids=[it["id"] for it in merged], per_route=per_route, merged=merged, full=full, cut=cut))
    first = runs[0]
    describe = lambda items: [dict(it, **judge(it["text"])) for it in items]
    cell = dict(
        situation=situation, scheme=scheme, base_state=SITUATIONS[situation][0], query_timestamp=asked_at(situation),
        request_bodies={name: body for name, _, body in plan},
        first_run_routes={n: describe(v) for n, v in first["per_route"].items()},
        first_run_route_counts={n: len(v) for n, v in first["per_route"].items()},
        first_run_route_types={n: type_dist(v) for n, v in first["per_route"].items()},
        first_run_route_metrics={n: metrics(v) for n, v in first["per_route"].items()},
        merged=describe(first["merged"]), metrics=metrics(first["merged"]),
        unquota_full={n: describe(v) for n, v in first["full"].items()} if first["full"] else None,
        quota_cut=describe(first["cut"]),
        quota_cut_counts=dict(n=len(first["cut"]), wrecker=sum(judge(i["text"])["wrecker"] for i in first["cut"]),
                              visitor_T=sum(judge(i["text"])["visitor_T"] for i in first["cut"])),
        latency=dict(wall_ms=[r["wall_ms"] for r in runs], sum_ms=[r["sum_ms"] for r in runs],
                     route_ms={n: [r["route_ms"][n] for r in runs] for n, _, _ in plan},
                     wall=med_max([r["wall_ms"] for r in runs]), sum=med_max([r["sum_ms"] for r in runs])),
        stability=dict(
            routes_same_ids={n: len({tuple(r["route_ids"][n]) for r in runs}) == 1 for n, _, _ in plan},
            merged_same_ids=len({tuple(sorted(r["merged_ids"])) for r in runs}) == 1,
            merged_same_order=len({tuple(r["merged_ids"]) for r in runs}) == 1,
            distinct_merged_sets=len({tuple(sorted(r["merged_ids"])) for r in runs}),
            merged_ids_per_run=[r["merged_ids"] for r in runs],
            route_counts_per_run=[{n: len(v) for n, v in r["per_route"].items()} for r in runs]),
        errors=[dict(run=r["run"], errors=r["errors"]) for r in runs if r["errors"]],
    )
    return cell


def base_overlap(situation, items):
    _, lines = next(s for s in sections(state_text(situation)) if s[0] == MEM)
    _, _, rec = memory_parts(lines)
    base = {l[len("- Recalled: "):] for l in rec}
    got = {it["text"] for it in items}
    inter = base & got
    return dict(base_recalled_lines=len(rec), base_distinct_texts=len(base), got_distinct_texts=len(got),
                intersection=len(inter), overlap_of_base=len(inter) / len(base) if base else None,
                jaccard=len(inter) / len(base | got) if base | got else None)


def cmd_recall(a):
    RAW.mkdir(parents=True, exist_ok=True)
    hs = Hindsight(a.base, OUT / "recall.log")
    crit = criteria()
    if a.probe:
        name, _, body = plan_bodies("OLD", "N", crit)[0]
        out = hs.call("POST", f"/banks/{REAL_BANK}/memories/recall", body, "R_probe.json")
        res = (out["json"] or {}).get("results") if out["ok"] else None
        print(f"probe status={out['status']} ms={out['ms']:.0f} n={len(res) if isinstance(res, list) else None} "
              f"error={out['error']}")
        if isinstance(res, list) and res:
            print("result keys:", sorted(res[0].keys()))
        return
    hs.log(f"START recall repeats={a.repeats} situations={a.situations} schemes={a.schemes}")
    cells = []
    for situation in a.situations.split(","):
        for scheme in a.schemes.split(","):
            cell = run_cell(hs, situation, scheme, a.repeats, crit)
            if scheme == "OLD":
                cell["base_overlap"] = base_overlap(situation, cell["merged"])
            cells.append(cell)
            m, lat = cell["metrics"], cell["latency"]
            hs.log(f"DONE {situation} {scheme} n={m['n']} chars={m['chars']} wrecker={m['wrecker']} calm={m['calm']} "
                   f"visitor_T={m['visitor_T']} dup={m['dup']:.2f} stale={m['stale']} wall_med={lat['wall']['median']:.0f}")
            print(f"{situation} {scheme}: n={m['n']} chars={m['chars']} wrecker={m['wrecker']} calm={m['calm']} "
                  f"visitor_T={m['visitor_T']} dup={m['dup']:.2f} stale={m['stale']} types={m['types']} "
                  f"wall med/max={lat['wall']['median']:.0f}/{lat['wall']['max']:.0f} sum med={lat['sum']['median']:.0f} "
                  f"stable={cell['stability']['merged_same_ids']} errors={len(cell['errors'])}", flush=True)
    save_section("recall", dict(started_with=dict(base=a.base, bank=REAL_BANK, repeats=a.repeats, quota=QUOTA),
                                candidates_criteria=crit, finished=now_iso(), cells=cells))
    print(f"results: {RESULTS} [recall]")


# ---------------------------------------------------------------- J：变体与 Jev

def recalled_lines(items):
    for it in items:
        assert "\n" not in (it["text"] or ""), "recalled text contains a newline: %r" % it["text"][:80]
    return ["- Recalled: " + it["text"] for it in items]


def with_memory(text, new_mem_lines):
    secs = sections(text)
    return join([(t, new_mem_lines if t == MEM else lines) for t, lines in secs])


def build_variants(recall):
    cell = {(c["situation"], c["scheme"]): c for c in recall["cells"]}
    texts = {s: state_text(s) for s in ("N", "T", "V", "V2")}
    parts = {}
    for s, t in texts.items():
        mem = next(lines for title, lines in sections(t) if title == MEM)
        parts[s] = memory_parts(mem)
    out, notes = {}, {}
    for s in ("N", "T", "V"):
        out[f"{s}_orig"] = texts[s]
    # N_no_during：What just happened 里删掉每条经历的 ` During it: ….`
    secs = sections(texts["N"])
    wjh = next(lines for title, lines in secs if title == WJH)
    assert len(wjh) == 1
    rx = re.compile(r" During it: .*?(?= " + STAMP + r"|$)")
    removed = rx.findall(wjh[0])
    out["N_no_during"] = join([(t, [rx.sub("", wjh[0])] if t == WJH else lines) for t, lines in secs])
    notes["N_no_during"] = dict(removed_count=len(removed), removed=removed)
    h, b, r = parts["N"]
    out["N_no_recall"] = with_memory(texts["N"], [h] + b)
    out["N_no_beliefs"] = with_memory(texts["N"], [h] + r)
    out["N_memory_blank"] = with_memory(texts["N"], [h])
    notes["N_no_recall"] = dict(removed_recalled_lines=len(r))
    notes["N_no_beliefs"] = dict(removed_belief_lines=len(b), belief_heads=[l for l in b if l.startswith("- Belief (")])
    notes["N_memory_blank"] = dict(removed_lines=len(b) + len(r))
    for s in ("N", "T"):
        items = cell[(s, "NEW3")]["merged"]
        h, b, r = parts[s]
        out[f"{s}_recall_new3"] = with_memory(texts[s], [h] + b + recalled_lines(items))
        notes[f"{s}_recall_new3"] = dict(replaced_recalled_lines=len(r), new_lines=len(items))
    # V_recall_new3：时刻晚于基准 state 的条目先剔除（无时刻的保留并列出）
    v_asked = asked_at("V")
    items = cell[("V", "NEW3")]["merged"]
    later = [it for it in items if it["at"] and _iso_key(it["at"]) > _iso_key(v_asked)]
    undated = [it for it in items if not it["at"]]
    kept = [it for it in items if it not in later]
    h, b, r = parts["V"]
    out["V_recall_new3"] = with_memory(texts["V"], [h] + b + recalled_lines(kept))
    notes["V_recall_new3"] = dict(asked=v_asked, dropped_later=[dict(id=i["id"], at=i["at"], type=i["type"], text=i["text"])
                                                               for i in later],
                                  kept_undated=[dict(id=i["id"], type=i["type"], text=i["text"]) for i in undated],
                                  replaced_recalled_lines=len(r), new_lines=len(kept))
    items = cell[("N", "OLD+obs")]["merged"]
    h, b, r = parts["N"]
    out["N_recall_oldobs"] = with_memory(texts["N"], [h] + b + recalled_lines(items))
    notes["N_recall_oldobs"] = dict(replaced_recalled_lines=len(r), new_lines=len(items))
    out["V2_orig"] = texts["V2"]
    # 自检：声明栏之外逐字节不变；What I remember 栏头保留
    declared = {"N_no_during": {WJH}}
    for name, text in out.items():
        src = name.split("_")[0]
        a, b2 = dict(sections(texts[src])), dict(sections(text))
        changed = {t for t in TITLES if a.get(t) != b2.get(t)}
        allowed = declared.get(name, set() if name.endswith("_orig") else {MEM})
        assert changed <= allowed, f"{name}: changed sections {changed} outside {allowed}"
        assert b2[MEM][0] == a[MEM][0], f"{name}: What I remember header changed"
        if name.endswith("_orig"):
            assert text == texts[src]
    return out, notes


def _iso_key(iso):
    # 规范成 UTC 的可比较串：'2026-11-13T08:16:03.768000+00:00' 与 '...Z' 都转成微秒整数
    s = iso.replace("Z", "+00:00")
    return datetime.datetime.fromisoformat(s).astimezone(datetime.timezone.utc).timestamp()


ORDER = ["N_orig", "T_orig", "V_orig", "N_no_during", "N_no_recall", "N_no_beliefs", "N_memory_blank",
         "N_recall_new3", "T_recall_new3", "V_recall_new3", "N_recall_oldobs", "V2_orig"]


def load_env():
    for line in MAIN_ENV.read_text(encoding="utf8").splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            if k.startswith("TYPESAFE_"):
                os.environ[k] = v.strip()


def jev_ask(state, questions, timeout=HTTP_TIMEOUT):
    """同 tools/jev/jev.py 的 ask（读进程环境的凭据）。返回 (answers, seconds)；HTTP 错误返回 ({'error': code, 'body'}, s)。"""
    body = json.dumps({"state": state, "model": os.environ["TYPESAFE_MODEL"], "questions": questions}).encode()
    req = urllib.request.Request(os.environ["TYPESAFE_API_URL"], data=body, headers={
        "authorization": "Bearer " + os.environ["TYPESAFE_API_KEY"], "content-type": "application/json",
        "user-agent": "voxim-npc-eval/1"})
    t = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.load(r)
        return data["answers"], time.perf_counter() - t
    except urllib.error.HTTPError as e:
        return {"error": e.code, "body": e.read().decode("utf8", "replace")[:300]}, time.perf_counter() - t


def run_jev(texts, order, notes):
    """每变体 JEV_REPEATS 次、并发 <= MAX_INFLIGHT 地问 Jev；返回读数 dict（jev 与 jev-addendum 共用）。"""
    tpl = json.loads(TEMPLATE.read_text(encoding="utf8"))
    q = {"activity": {"criteria": {c["name"]: c["criterion"] for c in tpl["candidates"]},
                      "instructions": tpl["instructions"], "type": "choice"}}
    load_env()
    model = os.environ["TYPESAFE_MODEL"]
    cells = [(n, r + 1) for n in order for r in range(JEV_REPEATS)]
    started = now_iso()

    def one(cell):
        name, rep = cell
        row = dict(repeat=rep, ok=False, top1=None, probs=None, latency_ms=None, error=None)
        try:
            answers, seconds = jev_ask(texts[name], q)
            row["latency_ms"] = round(seconds * 1000)
            (RAW / f"J_{name}_r{rep}.json").write_text(json.dumps(answers, ensure_ascii=False), encoding="utf8")
            if "error" in answers:
                row["error"] = f"http {answers['error']}"
            else:
                ans = answers.get("activity")
                if not isinstance(ans, dict) or "choice" not in ans:
                    row["error"] = "malformed answer"
                else:
                    row.update(ok=True, top1=ans["choice"], probs=ans.get("probabilities"))
        except Exception as ex:  # 网络 / 超时：不补问
            row["error"] = type(ex).__name__
        row["time"] = now_iso()
        print(f"{name} r{rep}: {row['top1']} {row['error'] or ''}", flush=True)
        return name, row

    with ThreadPoolExecutor(MAX_INFLIGHT) as pool:
        got = list(pool.map(one, cells))
    cands = [c["name"] for c in tpl["candidates"]]
    by = {}
    for name, row in got:
        by.setdefault(name, []).append(row)
    variants = []
    for name in order:
        rows = sorted(by[name], key=lambda r: r["repeat"])
        ok = [r for r in rows if r["ok"]]
        top = {}
        for r in ok:
            top[r["top1"]] = top.get(r["top1"], 0) + 1
        avg = {c: (sum((r["probs"] or {}).get(c, 0.0) for r in ok) / len(ok) if ok else None) for c in cands}
        variants.append(dict(variant=name, state_file=f"s1q/variants/{name}.txt", state_chars=len(texts[name]),
                             top1_counts=top, avg_probs=avg, failed=len(rows) - len(ok), requests=rows))
    data = dict(model=model, repeats=JEV_REPEATS, workers=MAX_INFLIGHT, timeout_s=HTTP_TIMEOUT, retries=0,
                candidates=cands, started=started, finished=now_iso(), requests=len(got),
                answered=sum(r["ok"] for _, r in got), failed=sum(not r["ok"] for _, r in got),
                variant_notes=notes, variants=variants)
    return data


def cmd_jev(a):
    recall = load_section("recall")
    if not recall:
        raise SystemExit("run `recall` first")
    VARIANTS_DIR.mkdir(parents=True, exist_ok=True)
    RAW.mkdir(parents=True, exist_ok=True)
    texts, notes = build_variants(recall)
    for name in ORDER:
        (VARIANTS_DIR / f"{name}.txt").write_bytes(texts[name].encode("utf8"))
    (VARIANTS_DIR / "notes.json").write_text(json.dumps(notes, ensure_ascii=False, indent=1), encoding="utf8")
    for name in ORDER:
        print(f"{name}: chars={len(texts[name])}")
    if a.dryrun:
        print("dryrun: variants written to", VARIANTS_DIR)
        return
    data = run_jev(texts, ORDER, notes)
    save_section("jev", data)
    print_jev(data)
    print(f"results: {RESULTS} [jev]")


def print_jev(data):
    for v in data["variants"]:
        print(v["variant"], v["state_chars"], v["top1_counts"], {k: round(x, 3) for k, x in v["avg_probs"].items() if x},
              "failed", v["failed"])


# ---------------------------------------------------------------- J2：plan-addendum 补测（按 Hindsight 返回次序重算的清单）

REMERGE = OUT / "remerge-rank-order.json"
RESULTS_ADDENDUM = OUT / "results-addendum.json"
ADDENDUM_ORDER = ["N_recall_rank", "T_recall_rank", "V_recall_rank",
                  "N_recall_rank_no_stale", "T_recall_rank_no_stale", "V_recall_rank_no_stale"]


def build_addendum_variants(recall):
    merged = json.loads(REMERGE.read_text(encoding="utf8"))["merged"]
    when = {}  # id -> 条目发生时刻（occurred_start，缺则 mentioned_at），取自 recall.cells 的首轮各路返回
    for c in recall["cells"]:
        for items in c["first_run_routes"].values():
            for it in items:
                when.setdefault(it["id"], it.get("occurred_start") or it.get("mentioned_at"))
    v_asked = asked_at("V")
    out, notes = {}, {}
    for s in ("N", "T", "V"):
        text = state_text(s)
        h, b, r = memory_parts(next(lines for title, lines in sections(text) if title == MEM))
        items, dropped = merged[s], []
        if s == "V":  # 同 V_recall_new3：晚于基准 state 的剔除；无时刻的保留并列出
            dropped = [it for it in items if when.get(it["id"]) and _iso_key(when[it["id"]]) > _iso_key(v_asked)]
            items = [it for it in items if it not in dropped]
        stale = [it for it in items if STALE in it["text"]]
        for name, kept in ((f"{s}_recall_rank", items),
                           (f"{s}_recall_rank_no_stale", [it for it in items if it not in stale])):
            out[name] = with_memory(text, [h] + b + recalled_lines(kept))
            notes[name] = dict(replaced_recalled_lines=len(r), new_lines=len(kept),
                               dropped_later=[dict(id=i["id"], at=when.get(i["id"]), text=i["text"]) for i in dropped],
                               undated_kept=[i["id"] for i in kept if not when.get(i["id"])],
                               removed_stale=[dict(id=i["id"], text=i["text"]) for i in stale] if name.endswith("no_stale") else [])
            a, b2 = dict(sections(text)), dict(sections(out[name]))  # 自检：只有 What I remember 栏变，栏头不变
            assert {t for t in TITLES if a.get(t) != b2.get(t)} <= {MEM}, name
            assert b2[MEM][0] == a[MEM][0], f"{name}: What I remember header changed"
    return out, notes


def cmd_jev_addendum(a):
    recall = load_section("recall")
    if not recall:
        raise SystemExit("run `recall` first")
    VARIANTS_DIR.mkdir(parents=True, exist_ok=True)
    RAW.mkdir(parents=True, exist_ok=True)
    texts, notes = build_addendum_variants(recall)
    for name in ADDENDUM_ORDER:
        path = VARIANTS_DIR / f"{name}.txt"
        if path.exists() and path.read_bytes() != texts[name].encode("utf8") and not a.dryrun:
            raise SystemExit(f"refusing to overwrite a different existing variant: {path}")
        path.write_bytes(texts[name].encode("utf8"))
        print(f"{name}: chars={len(texts[name])} recalled={notes[name]['new_lines']}")
    if a.dryrun:
        print("dryrun: variants written to", VARIANTS_DIR)
        return
    data = run_jev(texts, ADDENDUM_ORDER, notes)
    RESULTS_ADDENDUM.write_text(json.dumps(dict(jev=data), ensure_ascii=False, indent=1), encoding="utf8")
    print_jev(data)
    print(f"results: {RESULTS_ADDENDUM}")


# ---------------------------------------------------------------- M：mission

def ms_to_iso(ms):
    return datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + \
        "%03dZ" % (ms % 1000)


def experience_sentences():
    """扫 s1n/states 全部 state 的 What just happened：{时刻串: {原句集合}}。"""
    found = {}
    split = re.compile(r"(?=" + STAMP + ")")
    for p in sorted(STATES.glob("asked-*.txt")):
        secs = dict(sections(p.read_text(encoding="utf8")))
        line = secs[WJH][0]
        body = line[len("What just happened: "):]
        if body.startswith("Oldest first. "):
            body = body[len("Oldest first. "):]
        for piece in split.split(body):
            piece = piece.strip()
            if not piece:
                continue
            m = re.match(r"At (\d{4}-\d{2}-\d{2}T[\d:.]+Z) \(UTC\), ", piece)
            if not m:
                continue
            found.setdefault(m.group(1), set()).add(piece)
    return found


def build_documents():
    docs = json.loads(DOCS_LIST.read_text(encoding="utf8"))["items"]
    sentences = experience_sentences()
    matched, unmatched = [], []
    for d in docs:
        ev = d["retain_params"]["event_date"]  # '2026-11-13T08:15:37.108000+00:00'
        dt = datetime.datetime.fromisoformat(ev).astimezone(datetime.timezone.utc)
        ms = int(dt.timestamp() * 1000 + 0.5)
        if d["id"].startswith("activity:"):
            assert int(d["id"].split(":", 1)[1]) == ms, d["id"]
        key = ms_to_iso(ms)
        cands = sorted(sentences.get(key, ()))
        same_len = [c for c in cands if len(c) == d["text_length"]]
        if len(same_len) == 1:
            matched.append(dict(id=d["id"], timestamp=key, tags=d["tags"], content=same_len[0],
                                created_at=d["created_at"], text_length=d["text_length"]))
        else:
            unmatched.append(dict(id=d["id"], timestamp=key, text_length=d["text_length"],
                                  candidates=[dict(len=len(c), text=c) for c in cands]))
    # 实跑的 6 批：created_at 的分钟簇（批内按 event 时刻旧在前）
    batches = {}
    for m in matched:
        batches.setdefault(m["created_at"][:16], []).append(m)
    order = sorted(batches)
    return [sorted(batches[k], key=lambda m: m["timestamp"]) for k in order], order, unmatched, len(docs)


def first_person(text):
    return bool(FP_SUBJ.search(text[:80])) and not FP_NOT.search(text)


def entity_tokens(items):
    toks = {}
    for it in items:
        ents = it.get("entities") or ""
        if isinstance(ents, list):
            ents = ", ".join(e if isinstance(e, str) else json.dumps(e) for e in ents)
        for e in [x.strip() for x in ents.split(",") if x.strip()]:
            toks[e] = toks.get(e, 0) + 1
    return toks


def bank_readings(items, entity_list=None):
    rows = []
    for it in items:
        t = it["text"] or ""
        rows.append(dict(id=it["id"], fact_type=it["fact_type"], first_person=first_person(t),
                         counted=bool(COUNTED.search(t)) if it["fact_type"] == "observation" else None,
                         counted_match=(COUNTED.search(t).group(0) if COUNTED.search(t) else None)
                         if it["fact_type"] == "observation" else None,
                         entities=it.get("entities"), text=t))
    toks = entity_tokens(items)
    au = {k: v for k, v in toks.items() if re.fullmatch(r"(the )?(assistant|user)", k.strip(), re.I)}
    au_contains = {k: v for k, v in toks.items() if re.search(r"\b(assistant|user)\b", k, re.I)}
    obs = [r for r in rows if r["fact_type"] == "observation"]
    out = dict(n=len(rows), first_person=sum(r["first_person"] for r in rows),
               first_person_ratio=sum(r["first_person"] for r in rows) / len(rows) if rows else None,
               types=type_dist([dict(type=r["fact_type"]) for r in rows]),
               entities_assistant_or_user_exact=au, entities_mentioning_assistant_or_user=au_contains,
               observations=len(obs), observations_counted=sum(1 for r in obs if r["counted"]),
               rows=rows, entity_tokens=toks)
    if entity_list is not None:
        names = [e.get("canonical_name") or e.get("name") for e in entity_list]
        out["entities_endpoint"] = dict(n=len(names), assistant_or_user=[n for n in names if n and
                                                                         re.search(r"\b(assistant|user)\b", n, re.I)],
                                        names=names)
    return out


def list_all(hs, bank, path, field, limit=100, tag="x"):
    rows, offset = [], 0
    for page in range(50):
        sep = "&" if "?" in path else "?"
        out = hs.call("GET", f"/banks/{bank}{path}{sep}limit={limit}&offset={offset}", raw_name=f"M_{tag}_p{page}.json")
        if not out["ok"]:
            raise SystemExit(f"list {bank}{path} failed: {out['error']}")
        got = out["json"].get(field) or []
        rows += got
        total = out["json"].get("total")
        offset += len(got)
        if not got or (total is not None and offset >= total) or (total is None and len(got) < limit):
            return rows, total
    raise SystemExit("too many pages")


def cmd_mission(a):
    RAW.mkdir(parents=True, exist_ok=True)
    hs = Hindsight(a.base, OUT / "mission.log")
    info = {}
    if not a.readings_only:
        batches, keys, unmatched, total_docs = build_documents()
        info["documents"] = dict(total=total_docs, matched=sum(len(b) for b in batches), unmatched=unmatched,
                                 batches=[dict(created_minute=k, n=len(b)) for k, b in zip(keys, batches)])
        print("docs total", total_docs, "matched", info["documents"]["matched"], "unmatched", len(unmatched),
              "batches", [len(b) for b in batches], flush=True)
        if a.dryrun:
            (RAW / "M_dryrun_documents.json").write_text(json.dumps(dict(batches=batches, unmatched=unmatched),
                                                                    ensure_ascii=False, indent=1), encoding="utf8")
            return
        banks = hs.call("GET", "/banks", raw_name="M_banks_before.json")
        if not banks["ok"]:
            raise SystemExit(f"GET /banks failed: {banks['error']}")
        ids = [b.get("bank_id") for b in (banks["json"].get("banks") or [])]
        if NEW_BANK in ids:
            raise SystemExit(f"bank {NEW_BANK} already exists; stopping")
        info["banks_before"] = ids
        put = hs.call("PUT", f"/banks/{NEW_BANK}", dict(name=NEW_BANK, mission=BANK_MISSION), raw_name="M_put.json")
        if not put["ok"]:
            raise SystemExit(f"PUT bank failed: {put['error']}")
        cfg = hs.call("GET", f"/banks/{NEW_BANK}/config", raw_name="M_config_new.json")
        c = (cfg["json"] or {}).get("config", {})
        info["new_bank_config_missions"] = {k: c.get(k) for k in ("retain_mission", "observations_mission",
                                                                   "reflect_mission", "retain_extraction_mode")}
        t_start = time.time()
        retains = []
        for i, batch in enumerate(batches):
            items = [dict(document_id=m["id"], content=m["content"], timestamp=m["timestamp"], tags=m["tags"])
                     for m in batch]
            t0 = time.time()
            out = hs.call("POST", f"/banks/{NEW_BANK}/memories", dict(items=items, **{"async": False}),
                          raw_name=f"M_retain_b{i + 1}.json")
            row = dict(batch=i + 1, created_minute=keys[i], n=len(items), ok=out["ok"], status=out["status"],
                       seconds=time.time() - t0, error=out["error"],
                       success=(out["json"] or {}).get("success") if out["json"] else None)
            retains.append(row)
            print("retain", row, flush=True)
            if not out["ok"]:
                # 不重试：超时的话等后台把这一批做完再继续（与下面同一轮询，上限计入总 25 分钟）
                if "timeout" not in (out["error"] or "").lower():
                    info["retains"] = retains
                    save_section("mission", info)
                    raise SystemExit(f"retain batch {i + 1} failed: {out['error']}")
        t_retained = time.time()
        info["retains"] = retains
        info["retain_seconds"] = t_retained - t_start
        polls = []
        status = "timeout"
        while time.time() - t_retained < WAIT_CAP_S:
            st = hs.call("GET", f"/banks/{NEW_BANK}/stats")
            j = st["json"] or {}
            polls.append(dict(t=round(time.time() - t_retained, 1), pending_operations=j.get("pending_operations"),
                              pending_consolidation=j.get("pending_consolidation"), total_nodes=j.get("total_nodes"),
                              total_documents=j.get("total_documents"), failed_operations=j.get("failed_operations"),
                              failed_consolidation=j.get("failed_consolidation")))
            if st["ok"] and j.get("pending_operations") == 0 and j.get("pending_consolidation") == 0:
                status = "drained"
                break
            time.sleep(POLL_S)
        info["wait"] = dict(status=status, seconds=time.time() - t_retained, polls=len(polls), last=polls[-1] if polls
                            else None, cap_s=WAIT_CAP_S, interval_s=POLL_S)
        (RAW / "M_stats_polls.json").write_text(json.dumps(polls, ensure_ascii=False, indent=1), encoding="utf8")
        print("wait", info["wait"], flush=True)
        hs.call("GET", f"/banks/{NEW_BANK}/stats", raw_name="M_stats_new_final.json")
        rows, total = list_all(hs, NEW_BANK, "/memories/list", "items", tag="list_new")
        NEW_MEMORIES.write_text(json.dumps(dict(total=total, items=rows), ensure_ascii=False, indent=1), encoding="utf8")
        ents_new, _ = list_all(hs, NEW_BANK, "/entities", "items", tag="entities_new")
        ents_real, _ = list_all(hs, REAL_BANK, "/entities", "items", tag="entities_real")
        (RAW / "M_entities.json").write_text(json.dumps(dict(new=ents_new, real=ents_real), ensure_ascii=False),
                                             encoding="utf8")
        hs.call("GET", f"/banks/{REAL_BANK}/stats", raw_name="M_stats_real_now.json")
    else:
        prev = load_section("mission") or {}
        info = {k: v for k, v in prev.items() if k not in ("readings",)}
    ents = json.loads((RAW / "M_entities.json").read_text(encoding="utf8"))
    new_items = json.loads(NEW_MEMORIES.read_text(encoding="utf8"))["items"]
    real_items = json.loads(REAL_MEMORIES.read_text(encoding="utf8"))["items"]
    info["readings"] = dict(nomission=bank_readings(new_items, ents["new"]), real=bank_readings(real_items, ents["real"]))
    save_section("mission", info)
    for k, r in info["readings"].items():
        print(k, "n", r["n"], "fp", r["first_person"], f"{r['first_person_ratio']:.2f}", "types", r["types"],
              "obs", r["observations"], "counted", r["observations_counted"], "assistant/user",
              r["entities_assistant_or_user_exact"], r["entities_mentioning_assistant_or_user"],
              r.get("entities_endpoint", {}).get("assistant_or_user"))
    print(f"results: {RESULTS} [mission]")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("recall")
    r.add_argument("--base", default=BASE)
    r.add_argument("--probe", action="store_true")
    r.add_argument("--repeats", type=int, default=5)
    r.add_argument("--situations", default="N,T,V")
    r.add_argument("--schemes", default="OLD,OLD+obs,NEW3")
    r.set_defaults(fn=cmd_recall)
    j = sub.add_parser("jev")
    j.add_argument("--dryrun", action="store_true")
    j.set_defaults(fn=cmd_jev)
    ja = sub.add_parser("jev-addendum")
    ja.add_argument("--dryrun", action="store_true")
    ja.set_defaults(fn=cmd_jev_addendum)
    m = sub.add_parser("mission")
    m.add_argument("--base", default=BASE)
    m.add_argument("--dryrun", action="store_true", help="只对上文档、分批，不发请求")
    m.add_argument("--readings-only", action="store_true")
    m.set_defaults(fn=cmd_mission)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
