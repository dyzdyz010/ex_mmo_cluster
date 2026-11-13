#!/usr/bin/env python
"""S1-L bank mission 离线测量：建 s1l-m1 / s1l-m2（带 mission），与已有无 mission 的 s1i-m1 / s1i-m2 对照。

用途
    按 .demo/observe/npc-slice1-20261112/s1l/plan.md，在本线 Hindsight 容器（默认 http://127.0.0.1:18933，
    API 前缀 /v1/default）里新建 s1l-m1、s1l-m2 两个 bank：
      1. PUT 建库 -> PATCH /config（body {"updates": {...}}）写 retain_mission 与 observations_mission
         （英文逐字取自 plan.md）-> GET /config 读回，字段不相等则报错退出（不 retain）；
      2. retain 20 条：直接 import s1i_materials.build_items / load_common，内容、时间戳、tags 与 s1i-m1 / s1i-m2
         逐字相同，document_id 前缀由 s1i- 变为 s1l-（build_items 用 bank 名作前缀，bank 名即 s1l-m1 / s1l-m2）；
      3. 轮询 operations 与 memories，等 retain 与巩固全部完成（上限 --wait-limit 秒，默认 900，超时如实记录不无限等）；
      4. 导出 memories/list 全量；四库（s1l-m1、s1l-m2、s1i-m1、s1i-m2）用同一段代码算读数，写 metrics.json；
         四库各存一份实体列表（GET /entities；s1i-* 只读）；
      5. 在 s1l-m2 上按 S1-J 的 NEW+ 方案、V 处境召回一次（import s1j_recall 的请求体构造与合并规则），存合并清单。
    只写 s1l-m1 / s1l-m2；s1i-* 仅 GET；不碰别的 bank；不起子进程 / 后台进程；不需要凭据；同时在途请求 <= 3。
    “期望是否成立”不由本脚本判定，只落盘读数与逐条原文。

用法（Git Bash 下 Python 用 -I -B -X utf8）
    python -I -B -X utf8 s1l_mission.py build [--recreate]   # 建库 + mission + 读回 + retain + 等待 + 导出 memories
    python -I -B -X utf8 s1l_mission.py metrics              # 四库实体列表 + metrics.json
    python -I -B -X utf8 s1l_mission.py recall               # s1l-m2 的 NEW+ / V 召回一次
    python -I -B -X utf8 s1l_mission.py all [--recreate]     # 依次 build / metrics / recall
    选项：--base <url>、--out <dir，默认 .demo/observe/npc-slice1-20261112/s1l>、--wait-limit <秒>
    bank 已存在则报错退出（退出码 2）；--recreate 只会删除 s1l-m1 / s1l-m2。

读数定义（本脚本 judge_text 函数，对每条正文判定；plan.md 的读数一节）
    first_person   正文含 \\bI\\b（区分大小写）或 \\bmy\\b（不分大小写），且不含 "the user" / "the assistant" /
                   "user's" / "assistant's"（不分大小写）/ 句首 "User " / "Assistant "。比例 = 条数 / 总条数，
                   总体与按 fact_type 分列。
    calm_exp / calm_obs     fact_type = experience / observation 且正文匹配 (nobody|no one) (came|approached)
                   （同 S1-J 的 CALM_NOBODY）的条数。另在逐条判定里记 calm_broad（nobody|no one|no-one ... near|came|
                   approach|visit 的宽松匹配，仅供核对，不进汇总）。
    approach_exp / approach_obs     正文匹配 “Corvin|920628760578 ... came within 6 m ... walked away”
                   （同 S1-J 的 CALM_CAME）的 experience / observation 条数。
    count_in_obs   存在一条 observation，正文含 guard（不分大小写）且匹配 “数字（>=2 的阿拉伯数字，或 two..twenty）+
                   至多两个词 + times|watches|guards”。逐条记匹配片段。
    twice_in_obs   存在一条 observation，正文提到 Corvin / 920628760578 且含 came within|came near|came close|approach|
                   within 6 m，并且含 \\btwice\\b / \\btwo\\b / \\b2\\b。逐条记匹配片段；同时列出“关于 Corvin 靠近的
                   observation”条数。
    non_english    含 CJK 字符（汉字 / 假名 / 谚文）的条数。
    实体           名为 assistant / user（不分大小写，完全相等）的实体是否存在；同时存全部实体名。
    NEW+ 合并清单   条数、first_person 比例、是否含“被拆”（Corvin/id 且 remov*|destroy*）与“靠近过”（Corvin/id 且
                   came within|came near|came close|approach|within 6 m）。
"""

import argparse
import json
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # python -I 不带脚本目录，显式加上以便 import 同目录模块

import s1i_materials as mat  # noqa: E402
import s1j_recall as rec  # noqa: E402

REPO = Path(__file__).resolve().parents[5]
S1 = REPO / ".demo/observe/npc-slice1-20261112"
S1L = S1 / "s1l"
S1I_MAT = S1 / "s1i/materials"

BANKS_L = ("s1l-m1", "s1l-m2")  # 唯一允许写 / 删的两个 bank
BANKS_I = ("s1i-m1", "s1i-m2")  # 只读对照
ALL_BANKS = BANKS_L + BANKS_I
P = "/v1/default"

# 与 plan.md 逐字一致。
RETAIN_MISSION = (
    'These are the first-person memories of Garen, a character in a game world. Write every fact in the first '
    'person ("I"), never as "the user" or "the assistant". Keep people\'s names together with their actor id '
    'exactly as written, for example "Corvin (actor 920628760578)". Keep counts and times. Keep statements that '
    'something did not happen (for example "nobody came near the hut") as facts in their own right. Do not treat '
    'me as a separate entity called "assistant" or "user". Write in English.')
OBSERVATIONS_MISSION = (
    'Consolidate my memories into first-person observations ("I"). When several memories repeat the same '
    'activity, say how many times it happened and what did or did not happen during them. Keep an event that '
    'happened only once or twice as its own observation; do not fold it into the majority. Keep names with '
    'their actor ids. Write in English.')
MISSIONS = {"retain_mission": RETAIN_MISSION, "observations_mission": OBSERVATIONS_MISSION}

# ---- 读数用的正则 ----
FP_I = re.compile(r"\bI\b")
FP_MY = re.compile(r"\bmy\b", re.I)
FP_BAD = re.compile(r"the user|the assistant|user's|assistant's", re.I)
FP_BAD_START = re.compile(r"^\s*(User|Assistant)\s")
CALM = rec.CALM_NOBODY
CALM_BROAD = re.compile(r"\b(nobody|no one|no-one)\b.{0,60}\b(near|came|approach\w*|visit\w*)\b", re.I | re.S)
APPROACH = rec.CALM_CAME
NUMWORD = ("two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|"
           "seventeen|eighteen|nineteen|twenty")
COUNT = re.compile(rf"\b(\d+|{NUMWORD})\s+(?:\w+\s+){{0,2}}?(times|watches|guards)\b", re.I)
CORVIN = re.compile(rf"corvin|{mat.ACTOR}", re.I)
CAME_NEAR = re.compile(r"came within|came near|came close|approach|within 6 m", re.I)
TWICE = re.compile(r"\btwice\b|\btwo\b|\b2\b", re.I)
WRECK = re.compile(r"remov|destroy", re.I)
CJK = re.compile(r"[㐀-䶿一-鿿぀-ヿ가-힯]")


def first_person(text):
    return bool((FP_I.search(text) or FP_MY.search(text)) and not FP_BAD.search(text)
                and not FP_BAD_START.search(text))


def count_match(text):
    if "guard" not in text.lower():
        return None
    m = COUNT.search(text)
    if not m:
        return None
    n = m.group(1).lower()
    if n.isdigit() and int(n) < 2:
        return None
    return m.group(0)


def twice_match(text):
    if not (CORVIN.search(text) and CAME_NEAR.search(text)):
        return None, False
    m = TWICE.search(text)
    return (m.group(0) if m else None), True


def judge_text(item):
    text = item.get("text") or ""
    twice, about_approach = twice_match(text)
    return dict(
        id=item.get("id"), fact_type=item.get("fact_type"), text=text,
        first_person=first_person(text),
        calm=bool(CALM.search(text)), calm_broad=bool(CALM_BROAD.search(text)),
        approach=bool(APPROACH.search(text)),
        count_match=count_match(text) if item.get("fact_type") == "observation" else None,
        about_corvin_approach=about_approach, twice_match=twice if item.get("fact_type") == "observation" else None,
        non_english=bool(CJK.search(text)),
        wrecker=bool(CORVIN.search(text) and WRECK.search(text)),
        near_past=bool(CORVIN.search(text) and CAME_NEAR.search(text)))


def ratio(num, den):
    return None if den == 0 else num / den


def bank_metrics(items):
    rows = [judge_text(i) for i in items]
    types = {}
    for r in rows:
        types[r["fact_type"]] = types.get(r["fact_type"], 0) + 1
    fp_by_type = {}
    for t in types:
        sub = [r for r in rows if r["fact_type"] == t]
        fp_by_type[t] = dict(n=len(sub), first_person=sum(r["first_person"] for r in sub),
                             ratio=ratio(sum(r["first_person"] for r in sub), len(sub)))
    obs = [r for r in rows if r["fact_type"] == "observation"]
    exp = [r for r in rows if r["fact_type"] == "experience"]
    corvin_obs = [r for r in obs if r["about_corvin_approach"]]
    m = dict(
        total=len(rows), by_fact_type=types,
        first_person=sum(r["first_person"] for r in rows), first_person_ratio=ratio(
            sum(r["first_person"] for r in rows), len(rows)),
        first_person_by_type=fp_by_type,
        calm_exp=sum(r["calm"] for r in exp), calm_obs=sum(r["calm"] for r in obs),
        approach_exp=sum(r["approach"] for r in exp), approach_obs=sum(r["approach"] for r in obs),
        count_in_obs=any(r["count_match"] for r in obs), twice_in_obs=any(r["twice_match"] for r in corvin_obs),
        obs_about_corvin_approach=len(corvin_obs),
        non_english=sum(r["non_english"] for r in rows))
    return m, rows


def load_memories(bank, out):
    path = (out / f"{bank}-memories.json") if bank in BANKS_L else (S1I_MAT / f"{bank}-memories.json")
    return json.loads(path.read_text(encoding="utf8"))["items"], path


# ---- build ----
def patch_missions(http, bank):
    st, js, _, txt = http.call("PATCH", f"{P}/banks/{bank}/config", body={"updates": MISSIONS})
    if st != 200:
        raise SystemExit(f"PATCH /config {bank} 失败 HTTP {st}: {txt[:500]}")
    st, js, _, txt = http.call("GET", f"{P}/banks/{bank}/config")
    if st != 200:
        raise SystemExit(f"GET /config {bank} 失败 HTTP {st}: {txt[:500]}")
    cfg = js.get("config", {})
    ok = {k: cfg.get(k) == v for k, v in MISSIONS.items()}
    http.log(f"config readback {bank}: effective={ok} overrides_keys={sorted((js.get('overrides') or {}))}")
    if not all(ok.values()):
        raise SystemExit(f"读回的 config 与写入不一致 {bank}: {ok}")
    return dict(effective=ok, overrides=js.get("overrides"))


def setup_bank(http, bank, common):
    assert bank in BANKS_L
    st, _, _, txt = http.call("PUT", f"{P}/banks/{bank}", body={})
    if st not in (200, 201):
        raise SystemExit(f"建库 {bank} 失败 HTTP {st}: {txt[:300]}")
    cfg = patch_missions(http, bank)
    items = mat.build_items(bank, common)
    assert all(it["document_id"].startswith("s1l-") for it in items)
    st, js, _, txt = http.call("POST", f"{P}/banks/{bank}/memories", body={"items": items, "async": True})
    if st not in (200, 202):
        raise SystemExit(f"retain {bank} 失败 HTTP {st}: {txt[:300]}")
    http.log(f"retain submitted bank={bank} items={len(items)} resp={json.dumps(js, ensure_ascii=False)[:300]}")
    return dict(items=len(items), config=cfg)


def cmd_build(args, http, out):
    existing = set(mat.list_bank_ids(http))
    clash = [b for b in BANKS_L if b in existing]
    if clash and not args.recreate:
        print(f"bank 已存在：{clash}；不改动，退出（--recreate 只删除 s1l-m1 / s1l-m2 后重建）", file=sys.stderr)
        return 2
    for b in clash:
        assert b in BANKS_L
        st, _, _, txt = http.call("DELETE", f"{P}/banks/{b}")
        if st not in (200, 204):
            print(f"删除 {b} 失败 HTTP {st}: {txt[:200]}", file=sys.stderr)
            return 3
    common = mat.load_common()
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=2) as ex:
        setup = dict(zip(BANKS_L, ex.map(lambda b: setup_bank(http, b, common), BANKS_L)))
    print(f"mission 已写入并读回，retain 已提交：{ {b: v['items'] for b, v in setup.items()} }")
    deadline = t0 + args.wait_limit
    with ThreadPoolExecutor(max_workers=2) as ex:
        results = list(ex.map(lambda b: _timed_wait(http, b, t0, deadline), BANKS_L))
    rc = 0
    info = dict(wait_limit_s=args.wait_limit, banks={})
    for b, (done, last, secs) in zip(BANKS_L, results):
        print(f"{b}: {'完成' if done else '超时/未完成'} 用时 {secs:.0f}s {json.dumps(last, ensure_ascii=False)}")
        rc = rc or (0 if done else 4)
        mat.list_memories(http, b, raw_out=out / f"{b}-memories.json")
        info["banks"][b] = dict(done=done, elapsed_s=round(secs, 1), last=last, config=setup[b]["config"])
    info["total_elapsed_s"] = round(time.time() - t0, 1)
    (out / "build.json").write_text(json.dumps(info, ensure_ascii=False, indent=1), encoding="utf8")
    http.log(f"build finished rc={rc} elapsed={info['total_elapsed_s']}s")
    return rc


def _timed_wait(http, bank, t0, deadline):
    done, last = mat.wait_done(http, bank, deadline)
    return done, last, time.time() - t0


# ---- metrics ----
def fetch_entities(http, bank, out):
    st, js, _, txt = http.call("GET", f"{P}/banks/{bank}/entities?limit=500&offset=0",
                               raw_out=out / f"{bank}-entities.json")
    if st != 200:
        return dict(error=f"HTTP {st}: {txt[:300]}")
    items = js.get("items", js if isinstance(js, list) else [])
    names = [e.get("canonical_name") or e.get("name") for e in items]
    return dict(count=len(names), names=names,
                assistant_or_user=[n for n in names if n and n.strip().lower() in ("assistant", "user")])


def cmd_metrics(args, http, out):
    result = dict(banks={})
    for bank in ALL_BANKS:
        items, path = load_memories(bank, out)
        m, rows = bank_metrics(items)
        ents = fetch_entities(http, bank, out)
        result["banks"][bank] = dict(source=str(path), metrics=m, entities=ents, items=rows)
    (out / "metrics.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf8")
    http.log("metrics.json written")
    print(f"metrics: {out / 'metrics.json'}")
    return 0


# ---- recall (NEW+ / V) ----
def cmd_recall(args, http, out):
    bank, scheme, situation = "s1l-m2", "NEW+", "V"
    items, _ = load_memories(bank, out)
    near_ids = {i["id"]: i["fact_type"] for i in items if CORVIN.search(i["text"]) and CAME_NEAR.search(i["text"])}
    raw = out / "raw-recall"
    raw.mkdir(exist_ok=True)
    rh = rec.Http(args.base, out / "run.log", raw)
    plan = rec.request_bodies(scheme, situation, "")
    rh.log(f"RECALL {bank} {scheme} {situation} routes={[n for n, _ in plan]}")
    with ThreadPoolExecutor(max_workers=3) as pool:
        futs = [pool.submit(rh.recall, bank, body, f"{bank}_{situation}_NEWplus_{name}.json") for name, body in plan]
        outs = [f.result() for f in futs]
    per_route = {name: [rec.slim(it, name) for it in o["results"]] for (name, _), o in zip(plan, outs)}
    kept, cut = rec.merge(per_route)
    merged = []
    for it in kept:
        j = judge_text(dict(it, fact_type=it["type"]))
        merged.append(dict(it, first_person=j["first_person"], wrecker=j["wrecker"], near_past=j["near_past"]))
    summary = dict(
        n=len(merged), n_truncated=len(cut), first_person=sum(r["first_person"] for r in merged),
        first_person_ratio=ratio(sum(r["first_person"] for r in merged), len(merged)),
        has_wrecker=any(r["wrecker"] for r in merged), has_near_past=any(r["near_past"] for r in merged),
        by_type={t: sum(1 for r in merged if r["type"] == t) for t in {r["type"] for r in merged}})
    doc = dict(bank=bank, scheme=scheme, situation=situation,
               request_bodies={n: b for n, b in plan}, route_counts={n: len(v) for n, v in per_route.items()},
               errors={n: o["error"] for (n, _), o in zip(plan, outs) if o["error"]},
               route_ms={n: round(o["ms"]) for (n, _), o in zip(plan, outs)},
               near_past_ids_in_bank=near_ids, summary=summary, merged=merged, truncated=cut)
    (out / "recall-newplus-m2-V.json").write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf8")
    print(f"recall: {out / 'recall-newplus-m2-V.json'} {json.dumps(summary, ensure_ascii=False)}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("build", "metrics", "recall", "all"))
    ap.add_argument("--base", default="http://127.0.0.1:18933")
    ap.add_argument("--out", default=str(S1L))
    ap.add_argument("--recreate", action="store_true")
    ap.add_argument("--wait-limit", type=int, default=900)
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    http = mat.Http(args.base, out / "run.log")
    http.log(f"start cmd={args.cmd} argv={sys.argv[1:]}")
    steps = {"build": [cmd_build], "metrics": [cmd_metrics], "recall": [cmd_recall],
             "all": [cmd_build, cmd_metrics, cmd_recall]}[args.cmd]
    for fn in steps:
        rc = fn(args, http, out)
        if rc:
            return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())
