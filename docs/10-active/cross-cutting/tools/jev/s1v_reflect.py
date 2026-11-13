#!/usr/bin/env python
"""S1-V：在 S1-N 真实实跑导出上重做“反思写回”的离线测量。探索性，不是验收。

计划与期望（由统筹会话持有，本脚本不判定成立 / 落空）：.demo/observe/npc-slice1-20261112/s1v/plan.md。
只发 HTTP：Hindsight（本线容器 http://127.0.0.1:18933，前缀 /v1/default）与 Jev。不编译、不起节点 / 容器。
复用 s1q_real_export.py 的函数（文档对上与分批、三路请求体、state 分栏、Jev 发问）；import 后只把它的
RAW 目录指到 s1v/raw，不改它的行为。

用法（Git Bash 下 python -I -B -X utf8）
    python -I -B -X utf8 s1v_reflect.py <stage>
  stage 依次为（每步读 results.json 里前面各步的读数，可分开跑）：
    setup     步骤 1：GET /banks 确认 s1v-copy-20261113 不存在（存在就停下）；照产品 Life.Hindsight.ensure/2 建库
              （PUT name + bank mission、PATCH /config 两条 mission、逐份 GET -> 404 -> POST 四份认识并等 operation）；
              按实跑 6 批串行 retain（async: false）；轮询 /stats（5 s，上限 25 分钟）；照产品 refresh/1 逐份刷新四份
              认识并等 operation（5 s，每份上限 10 分钟）-> B0；导出事实列表。
    recall0   步骤 5 第一次（写回之前）：N、V 两处境三路召回 + 合并。
    reflect   步骤 2：三个问题各 3 次 reflect，串行，超时 180 s，不重试。
    writeback 步骤 4：每问第 1 次的原文 retain 进副本库；轮询 /stats（上限 10 分钟）；导出事实列表并与写回前对照；
              刷新四份认识 -> B1。
    recall1   步骤 5 第二次（写回并巩固之后）。
    jev       步骤 6：组 5 个变体写 s1v/variants/，自检后每变体 4 次问 Jev（并发 <= 3）。--dryrun 只写变体。
    judge     步骤 3 的关键词粗判（只读本地文件），写 reflections/index.json 与 results.json[judge]。
"""

import argparse
import datetime
import json
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s1q_real_export as s1q  # noqa: E402

OUT = s1q.S1 / "s1v"
RAW = OUT / "raw"
VARIANTS_DIR = OUT / "variants"
REFLECTIONS = OUT / "reflections"
BELIEFS = OUT / "beliefs"
RECALL_DIR = OUT / "recall"
RESULTS = OUT / "results.json"
LOG = OUT / "run.log"
s1q.RAW = RAW  # Hindsight.call / list_all / run_jev 的原始返回落 s1v/raw

COPY_BANK = "s1v-copy-20261113"
REAL_BANK = s1q.REAL_BANK  # 本脚本对真实 bank 不发任何请求
POLL_S = 5
REPLAY_CAP_S = 25 * 60
WRITEBACK_CAP_S = 10 * 60
REFRESH_CAP_S = 10 * 60
REFLECT_TIMEOUT_S = 180
REPEATS = 3

# ---------------------------------------------------------------- 产品 Life.Hindsight 的原文
# 逐字取自 apps/npc_server/lib/npc_server/life/hindsight.ex（@truth / @bank_mission / @retain_mission /
# @observations_mission / @queries / ensure_model 的请求体）。

TRUTH = "Subjective memory; not current numeric world truth."
BANK_MISSION = "My first-person builder journal. Preserve event history and evolving subjective beliefs. " + TRUTH
RETAIN_MISSION = ("These are the first-person memories of a character in a game world. "
                  "Write every fact in the first person (\"I\"), never as \"the user\" or \"the assistant\". "
                  "Keep people's names together with their actor id exactly as written, "
                  "for example \"Corvin (actor 920628760578)\". "
                  "Keep counts and times. "
                  "Keep statements that something did not happen (for example \"nobody came near the hut\") as facts in their own right. "
                  "Do not treat me as a separate entity called \"assistant\" or \"user\". "
                  "Write in English.")
OBSERVATIONS_MISSION = ("Consolidate my memories into first-person observations (\"I\"). "
                        "When several memories repeat the same activity, say how many times it happened and what did or did not happen during them. "
                        "Keep an event that happened only once or twice as its own observation; do not fold it into the majority. "
                        "Keep names with their actor ids. "
                        "Write in English.")
QUERIES = [
    ("self", "What kind of builder am I, and what lessons have I learned from my experiences?"),
    ("relationships", "Who helped or harmed me, how has my trust in each person changed, and why?"),
    ("world", "What do I remember about places and construction sites I depend on? "
              "Historical coordinates are memories, not current world truth."),
    ("commitments", "What promises have I made or received, and which are open or fulfilled?"),
]
assert BANK_MISSION == s1q.BANK_MISSION

# ---------------------------------------------------------------- 反思问题（plan.md 原文）

QUESTIONS = {
    "Q_place": ('Thinking over everything that has happened at my building "small hut": what do I now believe about it, '
                "and what follows for how I spend my time?", ["kind:reflection", "place:small hut"]),
    "Q_person": ("Thinking over everything that has happened between me and Corvin (actor 3494090117122): what do I now "
                 "believe about them, and what follows for how I act around them?",
                 ["kind:reflection", "actor:3494090117122"]),
    "Q_self": ("Looking back over what I have been doing lately and what came of it: is this how I want to keep spending "
               "my time?", ["kind:reflection"]),
}

SITS = ("N", "V")


def now_iso():
    return s1q.now_iso()


def log(line):
    with open(LOG, "a", encoding="utf8") as f:
        f.write(f"{now_iso()} {line}\n")
    print(line, flush=True)


def load():
    return json.loads(RESULTS.read_text(encoding="utf8")) if RESULTS.exists() else {}


def save(key, value):
    data = load()
    data[key] = value
    tmp = RESULTS.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf8")
    os.replace(tmp, RESULTS)


def hs():
    return s1q.Hindsight(s1q.BASE, LOG)


def must(out, what):
    if not out["ok"]:
        raise SystemExit(f"{what} failed: {out['error']}")
    return out["json"]


def bank(path=""):
    return f"/banks/{COPY_BANK}{path}"


# ---------------------------------------------------------------- 等待

def wait_operation(h, op_id, cap_s, tag):
    """同产品 completion/poll：GET /operations/<id> 直到 completed；失败态 / 到点如实返回。间隔 5 s。"""
    t0 = time.time()
    polls = 0
    while True:
        out = h.call("GET", f"{bank('/operations/')}{op_id}")
        polls += 1
        st = (out["json"] or {}).get("status") if out["ok"] else None
        if st == "completed":
            return dict(status="completed", seconds=time.time() - t0, polls=polls)
        if st in ("failed", "cancelled", "not_found"):
            return dict(status=st, seconds=time.time() - t0, polls=polls, error=(out["json"] or {}).get("error_message"))
        if not out["ok"]:
            return dict(status="poll_error", seconds=time.time() - t0, polls=polls, error=out["error"])
        if time.time() - t0 >= cap_s:
            return dict(status="timeout", seconds=time.time() - t0, polls=polls, last=st)
        time.sleep(POLL_S)


def wait_drained(h, cap_s, tag):
    t0 = time.time()
    polls = []
    status = "timeout"
    while time.time() - t0 < cap_s:
        st = h.call("GET", bank("/stats"))
        j = st["json"] or {}
        polls.append(dict(t=round(time.time() - t0, 1), **{k: j.get(k) for k in (
            "pending_operations", "pending_consolidation", "total_nodes", "total_documents", "failed_operations",
            "failed_consolidation")}))
        if st["ok"] and j.get("pending_operations") == 0 and j.get("pending_consolidation") == 0:
            status = "drained"
            break
        time.sleep(POLL_S)
    (RAW / f"{tag}_stats_polls.json").write_text(json.dumps(polls, ensure_ascii=False, indent=1), encoding="utf8")
    return dict(status=status, seconds=time.time() - t0, polls=len(polls), last=polls[-1] if polls else None,
                cap_s=cap_s, interval_s=POLL_S)


# ---------------------------------------------------------------- 认识（ensure_model / refresh / models）

def ensure_models(h):
    rows = []
    for mid, query in QUERIES:
        got = h.call("GET", f"{bank('/mental-models/')}{mid}?detail=content", raw_name=f"S_model_get_{mid}.json")
        if got["status"] != 404:
            raise SystemExit(f"mental model {mid} unexpectedly present or GET failed: {got['status']} {got['error']}")
        body = dict(id=mid, name=mid, source_query=query + " " + TRUTH, max_tokens=800,
                    trigger=dict(refresh_after_consolidation=False))
        resp = must(h.call("POST", bank("/mental-models"), body, raw_name=f"S_model_post_{mid}.json"), f"create {mid}")
        w = wait_operation(h, resp.get("operation_id"), REFRESH_CAP_S, f"create_{mid}")
        rows.append(dict(id=mid, operation_id=resp.get("operation_id"), **w))
        log(f"ensure model {mid}: {w}")
        if w["status"] != "completed":
            raise SystemExit(f"create {mid}: {w}")
    return rows


def refresh_models(h, tag):
    """同产品 refresh/1：逐份 POST /mental-models/<id>/refresh 并等 operation；然后读四份 content。"""
    ops = []
    for mid, _ in QUERIES:
        t0 = time.time()
        resp = h.call("POST", f"{bank('/mental-models/')}{mid}/refresh", {}, raw_name=f"{tag}_refresh_{mid}.json")
        if not resp["ok"]:
            ops.append(dict(id=mid, status="request_error", error=resp["error"]))
            log(f"{tag} refresh {mid}: request error {resp['error']}")
            continue
        w = wait_operation(h, (resp["json"] or {}).get("operation_id"), REFRESH_CAP_S, f"{tag}_{mid}")
        ops.append(dict(id=mid, operation_id=(resp["json"] or {}).get("operation_id"), wall_s=time.time() - t0, **w))
        log(f"{tag} refresh {mid}: {w}")
    models, meta = {}, {}
    BELIEFS.mkdir(parents=True, exist_ok=True)
    for mid, _ in QUERIES:
        row = must(h.call("GET", f"{bank('/mental-models/')}{mid}?detail=content", raw_name=f"{tag}_model_{mid}.json"),
                   f"read {mid}")
        models[mid] = row.get("content") or ""
        meta[mid] = {k: row.get(k) for k in ("is_stale", "last_refreshed_at", "last_refresh_failed_at",
                                             "last_memory_seen_at")}
        (BELIEFS / f"{tag}-{mid}.txt").write_bytes(models[mid].encode("utf8"))
    return dict(operations=ops, chars={m: len(t) for m, t in models.items()}, metadata=meta, content=models)


def export_memories(h, tag):
    rows, total = s1q.list_all(h, COPY_BANK, "/memories/list", "items", tag=f"{tag}_list")
    (OUT / f"memories-{tag}.json").write_text(json.dumps(dict(total=total, items=rows), ensure_ascii=False, indent=1),
                                              encoding="utf8")
    types = {}
    for r in rows:
        types[r["fact_type"]] = types.get(r["fact_type"], 0) + 1
    return rows, dict(total=total, n=len(rows), types=types, observations=types.get("observation", 0))


# ---------------------------------------------------------------- 步骤 1

def cmd_setup(a):
    h = hs()
    banks = must(h.call("GET", "/banks", raw_name="S_banks_before.json"), "GET /banks")
    ids = [b.get("bank_id") for b in banks.get("banks") or []]
    if COPY_BANK in ids:
        raise SystemExit(f"bank {COPY_BANK} already exists; stopping")
    batches, keys, unmatched, total_docs = s1q.build_documents()
    info = dict(banks_before=ids, documents=dict(total=total_docs, matched=sum(len(b) for b in batches),
                                                 unmatched=unmatched,
                                                 batches=[dict(created_minute=k, n=len(b)) for k, b in zip(keys, batches)]))
    log(f"docs total {total_docs} matched {info['documents']['matched']} unmatched {len(unmatched)}")
    if unmatched:
        save("setup", info)
        raise SystemExit("unmatched documents; stopping before creating the bank")
    # ensure/2：PUT、PATCH /config、四份认识
    must(h.call("PUT", bank(), dict(name=COPY_BANK, mission=BANK_MISSION), raw_name="S_put.json"), "PUT bank")
    must(h.call("PATCH", bank("/config"), dict(updates=dict(retain_mission=RETAIN_MISSION,
                                                              observations_mission=OBSERVATIONS_MISSION)),
                raw_name="S_patch_config.json"), "PATCH /config")
    cfg = must(h.call("GET", bank("/config"), raw_name="S_config.json"), "GET /config").get("config", {})
    info["config_check"] = dict(retain_mission_equal=cfg.get("retain_mission") == RETAIN_MISSION,
                                observations_mission_equal=cfg.get("observations_mission") == OBSERVATIONS_MISSION)
    info["ensure_models"] = ensure_models(h)
    save("setup", info)
    # 重放：6 批串行
    t_start = time.time()
    retains = []
    for i, batch in enumerate(batches):
        items = [dict(document_id=m["id"], content=m["content"], timestamp=m["timestamp"], tags=m["tags"]) for m in batch]
        t0 = time.time()
        out = h.call("POST", bank("/memories"), dict(items=items, **{"async": False}), raw_name=f"S_retain_b{i + 1}.json")
        row = dict(batch=i + 1, created_minute=keys[i], n=len(items), ok=out["ok"], status=out["status"],
                   seconds=time.time() - t0, error=out["error"],
                   success=(out["json"] or {}).get("success") if out["json"] else None)
        retains.append(row)
        log(f"retain {row}")
        if not out["ok"] and "timeout" not in (out["error"] or "").lower():
            info["retains"] = retains
            save("setup", info)
            raise SystemExit(f"retain batch {i + 1} failed: {out['error']}")
    info["retains"] = retains
    info["retain_seconds"] = time.time() - t_start
    info["replay_wait"] = wait_drained(h, REPLAY_CAP_S, "S_replay")
    log(f"replay wait {info['replay_wait']}")
    save("setup", info)
    _, info["memories_after_replay"] = export_memories(h, "replay")
    b0 = refresh_models(h, "B0")
    info["B0"] = {k: v for k, v in b0.items() if k != "content"}
    log(f"B0 chars {b0['chars']}")
    save("setup", info)


# ---------------------------------------------------------------- 步骤 5：召回

def merge_rank_order(plan, per_route):
    """S1-Q remerge-rank-order.json 的 rule：路的优先级 R1 > R2 > R3，各路保持 Hindsight 返回的次序，
    每路取前 QUOTA 条未被更高优先级的路取走的（按 id 去重）。"""
    seen, merged = set(), []
    for name, _, _ in sorted(plan, key=lambda p: (p[1], p[0])):
        taken = 0
        for it in per_route.get(name, []):
            if taken >= s1q.QUOTA:
                break
            if it["id"] in seen:
                continue
            seen.add(it["id"])
            merged.append(it)
            taken += 1
    return merged


def reflection_links(memories):
    """副本库事实里，来自反思文档的事实 id，及 source_memory_ids 含这些事实的 observation id。"""
    direct = {m["id"]: m["document_id"] for m in memories if str(m.get("document_id") or "").startswith("reflection:")}
    derived = {}
    for m in memories:
        if m["fact_type"] == "observation":
            src = set(m.get("source_memory_ids") or [])
            hit = sorted(direct[s] for s in src if s in direct)
            if hit:
                derived[m["id"]] = hit
    return direct, derived


def do_recall(tag):
    h = hs()
    crit = s1q.criteria()
    RECALL_DIR.mkdir(parents=True, exist_ok=True)
    mem_file = OUT / ("memories-writeback.json" if tag == "after" else "memories-replay.json")
    memories = json.loads(mem_file.read_text(encoding="utf8"))["items"]
    direct, derived = reflection_links(memories)
    cells = {}
    for sit in SITS:
        plan = s1q.plan_bodies("NEW3", sit, crit)
        with ThreadPoolExecutor(max_workers=s1q.MAX_INFLIGHT) as pool:
            futs = [pool.submit(h.call, "POST", bank("/memories/recall"), body, f"R_{tag}_{sit}_{name}.json")
                    for name, _, body in plan]
            outs = [f.result() for f in futs]
        per_route, errors = {}, {}
        for (name, _, _), out in zip(plan, outs):
            res = (out["json"] or {}).get("results") if out["ok"] else None
            if out["ok"] and not isinstance(res, list):
                out["error"] = "invalid response (no results list)"
            if out["error"]:
                errors[name] = out["error"]
                res = []
            per_route[name] = [s1q.slim(it, name) for it in res]
        merged = merge_rank_order(plan, per_route)
        asked = s1q.asked_at(sit)
        dropped = []
        if sit == "V":  # 同 S1-Q：晚于基准 state 的条目剔除，无时刻的保留并列出
            dropped = [it for it in merged if it["at"] and s1q._iso_key(it["at"]) > s1q._iso_key(asked)]
        kept = [it for it in merged if it not in dropped]

        def mark(items):
            out = []
            for rank, it in enumerate(items, 1):
                out.append(dict(rank=rank, id=it["id"], route=it["route"], type=it["type"], at=it["at"],
                                reflection_doc=direct.get(it["id"]), from_reflection=derived.get(it["id"]),
                                text=it["text"]))
            return out
        cell = dict(situation=sit, base_state=s1q.SITUATIONS[sit][0], query_timestamp=asked,
                    request_bodies={n: b for n, _, b in plan}, errors=errors,
                    route_counts={n: len(v) for n, v in per_route.items()},
                    routes={n: mark(v) for n, v in per_route.items()},
                    merged=mark(merged), dropped_later=mark(dropped),
                    kept_undated=[it["id"] for it in kept if not it["at"]], kept=mark(kept),
                    reflection_in_routes={n: [r for r in mark(v) if r["reflection_doc"] or r["from_reflection"]]
                                          for n, v in per_route.items()},
                    reflection_in_kept=[r for r in mark(kept) if r["reflection_doc"] or r["from_reflection"]])
        (RECALL_DIR / f"{tag}-{sit}.json").write_text(json.dumps(cell, ensure_ascii=False, indent=1), encoding="utf8")
        cells[sit] = cell
        log(f"recall {tag} {sit}: routes {cell['route_counts']} merged {len(merged)} kept {len(kept)} "
            f"dropped {len(dropped)} reflection_in_kept {len(cell['reflection_in_kept'])} errors {errors}")
    save(f"recall_{tag}", dict(finished=now_iso(), reflection_fact_ids=direct, reflection_derived_observations=derived,
                               cells={s: {k: v for k, v in c.items() if k != "routes"} for s, c in cells.items()}))


def cmd_recall0(a):
    do_recall("before")


def cmd_recall1(a):
    do_recall("after")


# ---------------------------------------------------------------- 步骤 2：reflect

def cmd_reflect(a):
    h = hs()
    REFLECTIONS.mkdir(parents=True, exist_ok=True)
    rows = []
    for qname, (question, _) in QUESTIONS.items():
        for k in range(1, REPEATS + 1):  # 串行：一次一个
            out = h.call("POST", bank("/reflect"), dict(query=question, include=dict(facts={})),
                         raw_name=f"F_{qname}_{k}.json", timeout=REFLECT_TIMEOUT_S)
            j = out["json"] or {}
            bo = j.get("based_on") or {}
            text = j.get("text") if out["ok"] else None
            row = dict(question=qname, run=k, ok=bool(out["ok"] and isinstance(text, str) and text.strip()),
                       error=out["error"], seconds=round(out["ms"] / 1000, 2), usage=j.get("usage"),
                       based_on_counts={kk: len(v) for kk, v in bo.items() if isinstance(v, list)},
                       based_on_memory_ids=[m.get("id") for m in bo.get("memories") or []],
                       based_on_mental_models=[m.get("id") for m in bo.get("mental_models") or []],
                       chars=len(text) if text else 0, file=f"reflections/{qname}-{k}.txt" if text else None)
            if text:
                (REFLECTIONS / f"{qname}-{k}.txt").write_bytes(text.encode("utf8"))
            rows.append(row)
            log(f"reflect {qname} {k}: ok={row['ok']} s={row['seconds']} usage={row['usage']} "
                f"based_on={row['based_on_counts']} err={row['error']}")
    save("reflect", dict(questions={q: v[0] for q, v in QUESTIONS.items()}, request_shape="query + include.facts={}",
                         timeout_s=REFLECT_TIMEOUT_S, finished=now_iso(), runs=rows))


# ---------------------------------------------------------------- 步骤 4：写回

def writeback_at():
    n_asked = datetime.datetime.fromisoformat(s1q.asked_at("N").replace("Z", "+00:00"))
    t = n_asked - datetime.timedelta(minutes=1)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (t.microsecond // 1000)


def cmd_writeback(a):
    h = hs()
    at = writeback_at()
    runs = {(r["question"], r["run"]): r for r in load()["reflect"]["runs"]}
    items = []
    for qname, (_, tags) in QUESTIONS.items():
        r = runs[(qname, 1)]
        if not r["ok"]:
            raise SystemExit(f"{qname} run 1 failed; plan takes run 1 only, not substituting")
        text = (REFLECTIONS / f"{qname}-1.txt").read_text(encoding="utf8")
        items.append(dict(document_id=f"reflection:{qname}:1", content=f"At {at} (UTC), I thought it over: {text}",
                          timestamp=at, tags=tags))
    (OUT / "writeback-documents.json").write_text(json.dumps(items, ensure_ascii=False, indent=1), encoding="utf8")
    before = json.loads((OUT / "memories-replay.json").read_text(encoding="utf8"))["items"]
    t0 = time.time()
    out = h.call("POST", bank("/memories"), dict(items=items, **{"async": False}), raw_name="W_retain.json")
    info = dict(at=at, documents=[dict(document_id=i["document_id"], tags=i["tags"], chars=len(i["content"]))
                                  for i in items],
                retain=dict(ok=out["ok"], status=out["status"], seconds=time.time() - t0, error=out["error"],
                            success=(out["json"] or {}).get("success") if out["json"] else None,
                            usage=(out["json"] or {}).get("usage") if out["json"] else None))
    log(f"writeback retain {info['retain']}")
    if not out["ok"] and "timeout" not in (out["error"] or "").lower():
        save("writeback", info)
        raise SystemExit("writeback retain failed")
    for d in info["documents"]:
        got = h.call("GET", f"{bank('/documents/')}{d['document_id']}", raw_name=f"W_doc_{d['document_id'].replace(':', '_')}.json")
        d["memory_unit_count"] = (got["json"] or {}).get("memory_unit_count") if got["ok"] else got["error"]
    info["wait"] = wait_drained(h, WRITEBACK_CAP_S, "W")
    log(f"writeback wait {info['wait']}")
    after, info["memories_after_writeback"] = export_memories(h, "writeback")
    bmap = {m["id"]: m for m in before}
    amap = {m["id"]: m for m in after}
    direct, derived = reflection_links(after)
    obs_b = {i for i, m in bmap.items() if m["fact_type"] == "observation"}
    obs_a = {i for i, m in amap.items() if m["fact_type"] == "observation"}
    info["diff"] = dict(
        reflection_facts=[dict(id=i, document_id=d, fact_type=amap[i]["fact_type"], text=amap[i]["text"])
                          for i, d in direct.items()],
        new_observations=[dict(id=i, text=amap[i]["text"], from_reflection=derived.get(i),
                               proof_count=amap[i].get("proof_count")) for i in sorted(obs_a - obs_b)],
        removed_observations=[dict(id=i, text=bmap[i]["text"]) for i in sorted(obs_b - obs_a)],
        changed_observations=[dict(id=i, before=bmap[i]["text"], after=amap[i]["text"], from_reflection=derived.get(i))
                              for i in sorted(obs_a & obs_b) if bmap[i]["text"] != amap[i]["text"]
                              or set(bmap[i].get("source_memory_ids") or []) != set(amap[i].get("source_memory_ids") or [])],
        observations_with_reflection_source={i: v for i, v in derived.items()})
    save("writeback", info)
    b1 = refresh_models(h, "B1")
    info["B1"] = {k: v for k, v in b1.items() if k != "content"}
    log(f"B1 chars {b1['chars']}")
    save("writeback", info)


# ---------------------------------------------------------------- 步骤 6：变体与 Jev

ORDER = ["N_B0", "V_B0", "N_B1", "V_B1", "N_B0_recall1"]


def belief_lines(tag):
    blocks = [f"- Belief ({mid}): " + (BELIEFS / f"{tag}-{mid}.txt").read_text(encoding="utf8") for mid, _ in QUERIES]
    return "\n".join(blocks).split("\n")


def recall_items(tag, sit):
    cell = json.loads((RECALL_DIR / f"{tag}-{sit}.json").read_text(encoding="utf8"))
    return cell["kept"]


def build_variants():
    spec = {"N_B0": ("N", "B0", "before"), "V_B0": ("V", "B0", "before"), "N_B1": ("N", "B1", "after"),
            "V_B1": ("V", "B1", "after"), "N_B0_recall1": ("N", "B0", "after")}
    texts, notes = {}, {}
    for name in ORDER:
        sit, btag, rtag = spec[name]
        base = s1q.state_text(sit)
        h, b, r = s1q.memory_parts(next(lines for t, lines in s1q.sections(base) if t == s1q.MEM))
        assert [l.split(":")[0] for l in b if l.startswith("- Belief (")] == \
            [f"- Belief ({m})" for m, _ in QUERIES], f"{name}: base belief heads"
        items = recall_items(rtag, sit)
        text = s1q.with_memory(base, [h] + belief_lines(btag) + s1q.recalled_lines(items))
        # 自检：只有 What I remember 栏变；栏头不变；新栏 = 栏头 + 四份 Belief + Recalled 行
        a_, b_ = dict(s1q.sections(base)), dict(s1q.sections(text))
        assert {t for t in s1q.TITLES if a_.get(t) != b_.get(t)} <= {s1q.MEM}, name
        assert b_[s1q.MEM][0] == a_[s1q.MEM][0], name
        h2, b2, r2 = s1q.memory_parts(b_[s1q.MEM])
        assert b2 == belief_lines(btag) and len(r2) == len(items), name
        texts[name] = text
        notes[name] = dict(situation=sit, beliefs=btag, recall=rtag, base_state=s1q.SITUATIONS[sit][0],
                           replaced_belief_lines=len(b), new_belief_lines=len(b2), replaced_recalled_lines=len(r),
                           new_recalled_lines=len(items), recalled_ids=[i["id"] for i in items],
                           recalled_from_reflection=[i["rank"] for i in items if i["reflection_doc"] or i["from_reflection"]],
                           other_sections_identical=True)
    return texts, notes


def cmd_jev(a):
    VARIANTS_DIR.mkdir(parents=True, exist_ok=True)
    texts, notes = build_variants()
    for name in ORDER:
        (VARIANTS_DIR / f"{name}.txt").write_bytes(texts[name].encode("utf8"))
        log(f"variant {name}: chars={len(texts[name])} recalled={notes[name]['new_recalled_lines']}")
    (VARIANTS_DIR / "notes.json").write_text(json.dumps(notes, ensure_ascii=False, indent=1), encoding="utf8")
    if a.dryrun:
        return
    data = s1q.run_jev(texts, ORDER, notes)
    for v in data["variants"]:
        v["state_file"] = f"s1v/variants/{v['variant']}.txt"
    save("jev", data)
    for v in data["variants"]:
        log(f"jev {v['variant']} chars={v['state_chars']} top1={v['top1_counts']} "
            f"avg={ {k: round(x, 3) for k, x in v['avg_probs'].items() if x} } failed={v['failed']}")


# ---------------------------------------------------------------- 步骤 3：关键词粗判

KW = {
    "house": {
        "safe": r"\b(is|seems|feels|appears|now|currently|remains?|stays?|looks?)\s+(\w+\s+){0,2}(safe|secure|unthreatened)\b"
                r"|\bno (longer|immediate|current|present|active|ongoing) (\w+ )?(threat|danger|risk)\b"
                r"|\bnot (currently |now )?(under|in) (threat|danger)\b|\bthreat (has|seems to have) (passed|faded|eased)\b",
        "risk": r"\b(still|remains?|stays?) (\w+ ){0,2}(at risk|vulnerable|in danger|threatened|exposed)\b"
                r"|\bcould (\w+ ){0,3}(again|be removed|be destroyed|be taken)\b|\bhappen again\b|\bvulnerab\w*"
                r"|\b(real|ongoing|continuing|lingering|remaining) (\w+ )?(risk|threat|danger)\b",
    },
    "person": {
        "distrust": r"\bdistrust\w*|\b(don't|do not|cannot|can't|no longer) trust\b|\bwary\b|\bsuspicio\w*|\bguarded\b"
                    r"|\bcaution\w*|\bcareful (around|with)\b|\bkeep (my )?distance\b",
        "soften": r"\b(rebuild|restore|regain|repair)\w* (\w+ ){0,2}(trust|relationship)\b|\bsecond chance\b|\bforgiv\w*"
                  r"|\breconcil\w*|\bbenefit of the doubt\b|\bsoften\w*|\bless (wary|suspicious|guarded)\b|\bopen to\b",
    },
    "time": {
        "other": r"\b(return|go back|get back|resume|spend (more )?time|rejoin|balance|reconnect)\w* (\w+ ){0,6}"
                 r"(plaza|neighbo\w*|gather\w*|other|building|projects?|work)\b|\b(guard|watch)\w* less\b"
                 r"|\bless time (guarding|watching)\b|\bstop (guarding|watching)\b|\bno (longer )?need to (keep )?(guard|watch)\w*"
                 r"|\bnot (\w+ ){0,3}(all|every|entire) (my |of my )?(time|day)\b",
        "keep": r"\bkeep (guarding|watching|watch|an eye)\b|\bcontinue (to )?(guard|watch)\w*\b"
                r"|\bstay (near|by|close to|beside|with) (the |my )?hut\b|\bremain (vigilant|watchful|alert)\b"
                r"|\bkeep (the hut|it) (protected|guarded|safe)\b",
    },
    "evidence": {
        "guard_many_nobody": None,  # 见 evidence_guard
        "corvin_came_back_near": r"(corvin|3494090117122)[^.]{0,120}\b(came|come|returned|back|approach\w*|near|nearby|within \d+)"
                                 r"|\b(came|returned|approach\w*)[^.]{0,40}(corvin|3494090117122)",
        "was_removed": r"\b(remov\w*|destroy\w*|demolish\w*|tore down|torn down|wreck\w*|knocked down)\b",
    },
}
GUARD = re.compile(r"\b(guard\w*|watch\w*|stood|standing)\b", re.I)
NOBODY = re.compile(r"\b(nobody|no one|no-one|no visitors?|no threat|no one else)\b|\bwithout (incident|anyone)\b|\buneventful\b",
                    re.I)
MANY = re.compile(rf"\b\d+\b\s*(\w+\s+){{0,2}}(times|watches|guard|shifts|sessions|occasions)|\b(repeated\w*|many|several|"
                  rf"multiple|dozens|numerous|again and again|over and over|countless)\b|{s1q.COUNTED.pattern}", re.I)


def hits(rx, text):
    return [m.group(0) for m in re.finditer(rx, text, re.I)]


def evidence_guard(text):
    # 同一句里：守 + 多次 + 没人来
    out = []
    for sent in re.split(r"(?<=[.!?])\s+|\n+", text):
        if GUARD.search(sent) and NOBODY.search(sent) and MANY.search(sent):
            out.append(sent.strip()[:200])
    return out


def stance(group, text):
    h = {k: hits(rx, text) for k, rx in KW[group].items()}
    on = [k for k, v in h.items() if v]
    label = on[0] if len(on) == 1 else ("mixed" if on else "none")
    return label, h


def cmd_judge(a):
    runs = load()["reflect"]["runs"]
    rows = []
    for r in runs:
        row = {k: r[k] for k in ("question", "run", "ok", "error", "seconds", "usage", "based_on_counts", "chars", "file")}
        if r["ok"]:
            text = (REFLECTIONS / f"{r['question']}-{r['run']}.txt").read_text(encoding="utf8")
            kw = {}
            for g, names in (("house", ("safe", "risk")), ("person", ("distrust", "soften")), ("time", ("other", "keep"))):
                label, h = stance(g, text)
                kw[g] = dict(label=label, hits=h)
            kw["evidence"] = dict(guard_many_nobody=evidence_guard(text),
                                  corvin_came_back_near=hits(KW["evidence"]["corvin_came_back_near"], text),
                                  was_removed=hits(KW["evidence"]["was_removed"], text))
            kw["unsupported_claims"] = "not judged by keywords (left to the blind judge)"
            row["keyword"] = kw
        rows.append(row)
    rules = {g: {k: v for k, v in d.items() if v} for g, d in KW.items()}
    rules["evidence"]["guard_many_nobody"] = dict(guard=GUARD.pattern, nobody=NOBODY.pattern, many=MANY.pattern,
                                                  note="all three in one sentence")
    rules["label"] = "one side hit -> that side; both -> mixed; neither -> none (= no stance by keywords)"
    REFLECTIONS.mkdir(parents=True, exist_ok=True)
    (REFLECTIONS / "index.json").write_text(json.dumps(dict(rules=rules, rows=rows), ensure_ascii=False, indent=1),
                                            encoding="utf8")
    save("judge", dict(rules=rules, rows=rows))
    for r in rows:
        kw = r.get("keyword") or {}
        print(r["question"], r["run"], {g: kw[g]["label"] for g in ("house", "person", "time")} if kw else r["error"],
              {k: len(v) for k, v in kw.get("evidence", {}).items()})


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stage", choices=["setup", "recall0", "reflect", "writeback", "recall1", "jev", "judge"])
    ap.add_argument("--dryrun", action="store_true")
    a = ap.parse_args()
    for d in (OUT, RAW):
        d.mkdir(parents=True, exist_ok=True)
    log(f"START {a.stage}")
    dict(setup=cmd_setup, recall0=cmd_recall0, reflect=cmd_reflect, writeback=cmd_writeback, recall1=cmd_recall1,
         jev=cmd_jev, judge=cmd_judge)[a.stage](a)
    log(f"END {a.stage}")


if __name__ == "__main__":
    main()
