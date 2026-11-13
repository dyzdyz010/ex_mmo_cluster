#!/usr/bin/env python
"""S1-X：我们自己写的反思（取材料 -> 写 -> 核对 -> 存 -> 进 prompt）的离线测量。探索性，不是验收。

计划、提示词、期望（由统筹会话持有，本脚本不判定成立 / 落空）：.demo/observe/npc-slice1-20261112/s1x/plan.md。
复用 s1v_reflect.py（建库 / 重放 / 刷新认识 / 三路召回与合并 / 换 Belief 与召回行 / 429 即停）与 s1q_real_export.py
（state 分栏、Jev 发问）；经 s1v_reflect.configure 把副本库与落盘目录指到 s1x-copy-20261113 与 s1x/，不改它们的行为。
本轮不调 Hindsight 的 /reflect。写反思走本机 magpie 网关 /v1/messages；key 只从环境变量 MAGPIE_KEY 读进进程。

用法（Git Bash 下）：MAGPIE_KEY=... python -I -B -X utf8 s1x_reflect.py <stage>
  setup      步骤 1：s1v 的 setup（确认库不存在、建库、重放、巩固、B0）+ 写回前三路召回（N、V）。
  materials  步骤 2 的取材料：每问两次 recall（原始经历 / 认识），去重合并、渲染编号行，落 materials/。
  write      步骤 2–3：每问写 3 次（串行），再综合写 3 次；代码检查；落 reflections/。
  check      只用落盘的应答重算代码检查。
  writeback  步骤 4：三条（各问第 1 条）retain、等巩固、按 id 差数新增、写回后三路召回（N、V）。
  jev        步骤 5：组 9 个变体、自检、每变体 4 次问 Jev。--dryrun 只写变体。
  forced     只读：本轮开始以来容器日志里 `Forced step` + `returned no tool call` 的行数。
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s1v_reflect as s1v  # noqa: E402

s1q = s1v.s1q
BANK = "s1x-copy-20261113"
s1v.configure(BANK, "s1x")  # s1v 的 OUT / RAW / BELIEFS / RECALL_DIR / RESULTS / LOG 都指到 s1x/
OUT = s1v.OUT
MATERIALS = OUT / "materials"
REFLECTIONS = OUT / "reflections"
VARIANTS_DIR = OUT / "variants"

LLM_URL = "http://127.0.0.1:3425/v1/messages"
LLM_MODEL = "claude/claude-sonnet-5-5"
LLM_MAX_TOKENS = 400
LLM_TIMEOUT_S = 120
REPEATS = 3
HOUR_US = 3600 * 10 ** 6
DAY_US = 24 * HOUR_US
RATE = 72  # MmoContracts.WorldTime 的 rate；game0 在相减时抵消
CONTAINER = "npc-s1g-hindsight-20261113"

# ---------------------------------------------------------------- 提示词（plan.md 定稿原文，不改）

SYSTEM_TEMPLATE = """You are this person: <character>

Tonight you are alone, writing a few lines in your own journal. Nobody else will ever read it. You write to get your own thinking straight, and you will read these lines again later when you decide what to do with your days.

You will be given things you remember: what you did, what you saw, what others did to you or said to you, each with roughly how long ago it was. They are your own memories, not a file and not a report. Then you will be given one thing to think over.

Write what you now think about it, in your own voice, in the first person, in plain connected sentences, the way you would mutter to yourself. Say what you believe and what you mean to do about it. Four sentences at most.

Stay with what you actually remember. Do not add events, people, numbers or times that are not among your memories. Where you do not know something, say so the way a person would, for example: "I don't know whether he came back after that."

Write only the journal lines: no headings, no lists, nothing about memories, records, data, notes or summaries as such, and no account of how you reasoned.

Here are three journal entries written by other people, only to show the kind of voice. Their lives are not yours; take nothing from what they say.
<example>The nets came up half empty again, three mornings now. I think the shoal has moved past the point, and I would rather row an hour further than sit here hoping. Tomorrow I try the north bank.</example>
<example>Mira paid back the flour she owed, and a day early. I was wrong to grumble about her. Next time she asks I will lend without making her wait.</example>
<example>The beam I set last week has not shifted. Good. I still do not trust the east wall, and I will hang nothing heavy on it until I have seen it through a storm.</example>"""

USER_TEMPLATE = """What I remember:
{lines}

What I wrote last time about this: {last}

To think over tonight: {question}

After the journal lines, add one last line that starts with "Used:" and lists the numbers of the memories you drew on."""

SYNTH_QUESTION = "Putting these together: what do I mean to do with my days from here?"
QUESTIONS = {q: v[0] for q, v in s1v.QUESTIONS.items()}  # 原文同 S1-V
MATERIAL_TAGS = {"Q_place": ["place:small hut"], "Q_person": [f"actor:{s1q.V_CID}"], "Q_self": None}


def log(line):
    s1v.log(line)


def iso_ms(iso):
    return int(round(s1q._iso_key(iso) * 1000))


def now_ms():
    return iso_ms(s1q.asked_at("N"))


def ago(at_ms, now):
    """产品 Mind.ago/2：真实毫秒换游戏时间后相减（整数），按游戏小时换词。"""
    elapsed = (now - at_ms) * 1000 * RATE
    if 4 * elapsed < HOUR_US:
        return "Just now, "
    if elapsed >= 48 * HOUR_US:
        n = (2 * elapsed + DAY_US) // (2 * DAY_US)
        return f"About {n} day{'s' if n != 1 else ''} ago, "
    halves = (4 * elapsed + HOUR_US) // (2 * HOUR_US)
    if halves % 2 == 0:
        n = halves // 2
        return f"About {n} hour{'s' if n != 1 else ''} ago, "
    return f"About {halves // 2}.5 hours ago, "


def character():
    first = s1q.state_text("N").split("\n")[0]
    assert first.startswith("Character: ")
    return first[len("Character: "):]


# ---------------------------------------------------------------- 步骤 1

def cmd_setup(a):
    s1v.cmd_setup(a)
    s1v.do_recall("before")


# ---------------------------------------------------------------- 步骤 2：材料

def cmd_materials(a):
    h = s1v.hs()
    MATERIALS.mkdir(parents=True, exist_ok=True)
    ts, now = s1q.asked_at("N"), now_ms()
    out = {}
    for q, question in QUESTIONS.items():
        bodies = []
        for kind, types, mt in (("raw", ["experience", "world"], 1500), ("observation", ["observation"], 800)):
            body = dict(query=question, budget="mid", types=types, max_tokens=mt, query_timestamp=ts)
            if MATERIAL_TAGS[q]:
                body.update(tags=MATERIAL_TAGS[q], tags_match="any_strict")
            bodies.append((kind, body))
        with ThreadPoolExecutor(max_workers=2) as pool:
            res = list(pool.map(lambda kb: h.call("POST", s1v.bank("/memories/recall"), kb[1],
                                                  f"MAT_{q}_{kb[0]}.json"), bodies))
        seen, items = set(), []
        counts = {}
        for (kind, _), r in zip(bodies, res):
            rows = (r["json"] or {}).get("results") if r["ok"] else None
            if not isinstance(rows, list):
                raise SystemExit(f"materials {q} {kind} failed: {r['error']}")
            counts[kind] = len(rows)
            for it in rows:
                if it["id"] in seen:
                    continue
                seen.add(it["id"])
                plain = (it.get("text") or "").split(" | When:", 1)[0]
                at = it.get("occurred_start") or it.get("mentioned_at")
                prefix = ago(iso_ms(at), now) if at else ""
                items.append(dict(n=len(items) + 1, id=it["id"], type=it.get("type"), kind=kind, at=at,
                                  tags=it.get("tags"), line=f"[{len(items) + 1}] {prefix}{plain}", text=it.get("text")))
        cell = dict(question=question, request_bodies={k: b for k, b in bodies}, returned=counts, n=len(items),
                    raw=sum(i["kind"] == "raw" for i in items), observation=sum(i["kind"] == "observation" for i in items),
                    chars=sum(len(i["line"]) for i in items), items=items)
        (MATERIALS / f"{q}.json").write_text(json.dumps(cell, ensure_ascii=False, indent=1), encoding="utf8")
        (MATERIALS / f"{q}.txt").write_bytes("\n".join(i["line"] for i in items).encode("utf8"))
        out[q] = {k: v for k, v in cell.items() if k != "items"}
        log(f"materials {q}: returned {counts} n={cell['n']} raw={cell['raw']} obs={cell['observation']} chars={cell['chars']}")
    s1v.save("materials", out)


# ---------------------------------------------------------------- 步骤 2–3：写

class LlmStop(SystemExit):
    pass


def llm(system, user, raw_name):
    key = os.environ.get("MAGPIE_KEY")
    if not key:
        raise SystemExit("MAGPIE_KEY not set")
    body = dict(model=LLM_MODEL, max_tokens=LLM_MAX_TOKENS, system=system,
                messages=[dict(role="user", content=user)])
    req = urllib.request.Request(LLM_URL, data=json.dumps(body, ensure_ascii=False).encode("utf8"), method="POST",
                                 headers={"x-api-key": key, "anthropic-version": "2023-06-01",
                                          "content-type": "application/json"})
    t0 = time.perf_counter()
    status, js, error = None, None, None
    try:
        with urllib.request.urlopen(req, timeout=LLM_TIMEOUT_S) as r:
            status, js = r.status, json.loads(r.read().decode("utf8"))
    except urllib.error.HTTPError as e:
        status, error = e.code, f"HTTP {e.code}: {e.read()[:300].decode('utf8', 'replace')}"
    except Exception as e:  # 超时 / 连接
        error = f"{type(e).__name__}: {e}"
    seconds = time.perf_counter() - t0
    if js is not None:
        (s1v.RAW / raw_name).write_text(json.dumps(js, ensure_ascii=False, indent=1), encoding="utf8")
    log(f"llm {raw_name} status={status} s={seconds:.1f} err={error}")
    if status in (401, 403, 429):
        raise LlmStop(f"STOP llm status={status} at={s1q.now_iso()} error={error}")
    text = "".join(b.get("text", "") for b in (js or {}).get("content") or [] if b.get("type") == "text") if js else None
    return dict(ok=bool(text), status=status, error=error, seconds=round(seconds, 2), text=text,
                usage=(js or {}).get("usage"), stop_reason=(js or {}).get("stop_reason"), raw_file=raw_name)


MARKDOWN = re.compile(r"^\s*(#|-|\*|\d+\.)", re.M)
META = re.compile(r"record|data|note|summar|memor|file|report|synthes", re.I)
FIRST = re.compile(r"\b(I|my|me)\b")
NOT_FIRST = re.compile(r"you are|the user", re.I)


def split_used(text):
    lines = text.strip().split("\n")
    idx = [i for i, l in enumerate(lines) if l.strip().startswith("Used:")]
    if not idx:
        return text.strip(), None, None
    i = idx[-1]
    journal = "\n".join(lines[:i]).strip()
    used_line = lines[i].strip()
    return journal, used_line, [int(x) for x in re.findall(r"\d+", used_line[len("Used:"):])]


def checks(text, materials):
    journal, used_line, used = split_used(text)
    sents = [s for s in re.split(r"(?<=[.!?])[\"')\]]*\s+", journal.strip()) if s.strip()]
    valid_nums = {m["n"]: m for m in materials}
    used_valid = bool(used) and all(u in valid_nums for u in used)
    return dict(
        journal=journal, used_line=used_line, used=used, used_present=used_line is not None, used_valid=used_valid,
        used_invalid_numbers=[u for u in (used or []) if u not in valid_nums],
        used_raw=sum(1 for u in set(used or []) if u in valid_nums and valid_nums[u].get("kind") == "raw"),
        used_observation=sum(1 for u in set(used or []) if u in valid_nums and valid_nums[u].get("kind") == "observation"),
        markdown=len(MARKDOWN.findall(journal)) + journal.count("**"),
        markdown_hits=MARKDOWN.findall(journal) + (["**"] * journal.count("**")),
        meta=len(META.findall(journal)), meta_hits=[m.group(0) for m in META.finditer(journal)],
        sentences=len(sents), first_person=bool(FIRST.search(journal)) and not NOT_FIRST.search(journal),
        lines_after_used=None)


def load_materials(q):
    return json.loads((MATERIALS / f"{q}.json").read_text(encoding="utf8"))["items"]


def cmd_write(a):
    REFLECTIONS.mkdir(parents=True, exist_ok=True)
    system = SYSTEM_TEMPLATE.replace("<character>", character())
    (OUT / "system-prompt.txt").write_bytes(system.encode("utf8"))
    rows = []

    def record(name, kind, q, run, user, mats):
        (REFLECTIONS / f"{name}.user.txt").write_bytes(user.encode("utf8"))
        r = llm(system, user, f"L_{name}.json")
        row = dict(name=name, kind=kind, question=q, run=run, **{k: r[k] for k in ("ok", "status", "error", "seconds",
                                                                                     "usage", "stop_reason", "raw_file")},
                   response_text=r["text"])
        if r["ok"]:
            row["check"] = checks(r["text"], mats)
            (REFLECTIONS / f"{name}.txt").write_bytes(row["check"]["journal"].encode("utf8"))
        rows.append(row)
        return row

    try:
        for q, question in QUESTIONS.items():
            mats = load_materials(q)
            user = USER_TEMPLATE.format(lines="\n".join(m["line"] for m in mats), last="nothing yet", question=question)
            for k in range(1, REPEATS + 1):  # 串行
                record(f"{q}-{k}", "journal", q, k, user, mats)
        firsts = {r["question"]: r for r in rows if r["run"] == 1}
        if all(firsts.get(q, {}).get("ok") for q in QUESTIONS):
            mats = [dict(n=i + 1, kind="journal", question=q) for i, q in enumerate(QUESTIONS)]
            lines = "\n".join(f"[{i + 1}] {firsts[q]['check']['journal']}" for i, q in enumerate(QUESTIONS))
            user = USER_TEMPLATE.format(lines=lines, last="nothing yet", question=SYNTH_QUESTION)
            for k in range(1, REPEATS + 1):
                record(f"synth-{k}", "synthesis", "synth", k, user, mats)
        else:
            log("synthesis skipped: a first journal failed")
    finally:
        save_index(rows)


def save_index(rows):
    (REFLECTIONS / "index.json").write_text(json.dumps(dict(rows=rows), ensure_ascii=False, indent=1), encoding="utf8")
    s1v.save("write", dict(model=LLM_MODEL, max_tokens=LLM_MAX_TOKENS, timeout_s=LLM_TIMEOUT_S, finished=s1q.now_iso(),
                           rows=[{k: v for k, v in r.items() if k != "response_text"} for r in rows]))
    for r in rows:
        c = r.get("check") or {}
        log(f"{r['name']}: ok={r['ok']} s={r['seconds']} usage={r['usage']} md={c.get('markdown')} meta={c.get('meta')} "
            f"sent={c.get('sentences')} fp={c.get('first_person')} used={c.get('used')} valid={c.get('used_valid')} "
            f"raw={c.get('used_raw')} obs={c.get('used_observation')}")


def cmd_check(a):
    rows = json.loads((REFLECTIONS / "index.json").read_text(encoding="utf8"))["rows"]
    for r in rows:
        if r["ok"]:
            mats = load_materials(r["question"]) if r["kind"] == "journal" else \
                [dict(n=i + 1, kind="journal") for i in range(len(QUESTIONS))]
            r["check"] = checks(r["response_text"], mats)
    save_index(rows)


# ---------------------------------------------------------------- 步骤 4：写回

def journals():
    rows = json.loads((REFLECTIONS / "index.json").read_text(encoding="utf8"))["rows"]
    return {(r["question"], r["run"]): r for r in rows}


def cmd_writeback(a):
    h = s1v.hs()
    at = s1v.writeback_at()
    js = journals()
    items = []
    for q, (_, tags) in s1v.QUESTIONS.items():
        r = js[(q, 1)]
        if not r["ok"]:
            raise SystemExit(f"{q} run 1 failed; not substituting")
        items.append(dict(document_id=f"reflection:{q}", content=f"At {at} (UTC), I thought it over: {r['check']['journal']}",
                          timestamp=at, tags=tags))
    (OUT / "writeback-documents.json").write_text(json.dumps(items, ensure_ascii=False, indent=1), encoding="utf8")
    before = json.loads((OUT / "memories-replay.json").read_text(encoding="utf8"))["items"]
    t0 = time.time()
    out = h.call("POST", s1v.bank("/memories"), dict(items=items, **{"async": False}), raw_name="W_retain.json")
    info = dict(at=at, documents=[dict(document_id=i["document_id"], tags=i["tags"], chars=len(i["content"])) for i in items],
                retain=dict(ok=out["ok"], status=out["status"], seconds=time.time() - t0, error=out["error"]))
    log(f"writeback retain {info['retain']}")
    if not out["ok"] and "timeout" not in (out["error"] or "").lower():
        s1v.save("writeback", info)
        raise SystemExit("writeback retain failed")
    info["wait"] = s1v.wait_drained(h, s1v.WRITEBACK_CAP_S, "W")
    log(f"writeback wait {info['wait']}")
    after, info["memories_after_writeback"] = s1v.export_memories(h, "writeback")
    bids = {m["id"] for m in before}
    refl_ids = {m["id"] for m in after if str(m.get("document_id") or "").startswith("reflection:")}
    new = []
    for m in after:
        if m["id"] in bids:
            continue
        tags = m.get("tags") or []
        src = set(m.get("source_memory_ids") or [])
        new.append(dict(id=m["id"], fact_type=m["fact_type"], document_id=m.get("document_id"), tags=tags,
                        by_tag="kind:reflection" in tags,
                        by_document=str(m.get("document_id") or "").startswith("reflection:"),
                        by_source_facts=bool(src & refl_ids), text=m["text"]))
    for n in new:
        n["from_reflection"] = n["by_tag"] or n["by_document"]
    obs = [n for n in new if n["fact_type"] == "observation"]
    facts = [n for n in new if n["fact_type"] != "observation"]
    amap = {m["id"]: m for m in after}
    bmap = {m["id"]: m for m in before}
    changed = [dict(id=i, before=bmap[i]["text"], after=amap[i]["text"]) for i in bids & set(amap)
               if bmap[i]["fact_type"] == "observation" and bmap[i]["text"] != amap[i]["text"]]
    info["new"] = dict(facts=len(facts), facts_from_reflection=sum(n["from_reflection"] for n in facts),
                       observations=len(obs), observations_from_reflection=sum(n["from_reflection"] for n in obs),
                       observations_by_source_facts=sum(n["by_source_facts"] for n in obs),
                       removed=len(bids - set(amap)), changed_observations=changed, rows=new)
    log(f"writeback new facts={len(facts)} (refl {info['new']['facts_from_reflection']}) observations={len(obs)} "
        f"(refl {info['new']['observations_from_reflection']}, src {info['new']['observations_by_source_facts']}) "
        f"removed={info['new']['removed']} changed_obs={len(changed)}")
    s1v.save("writeback", info)
    s1v.do_recall("after")


# ---------------------------------------------------------------- 步骤 5：变体与 Jev

ORDER = ["N_R0", "V_R0", "N_col", "V_col", "N_syn", "V_syn", "N_top", "V_top", "N_col_recall1"]


def one_line(text):
    return re.sub(r"\s+", " ", text).strip()


def base_variant(sit, rtag):
    base = s1q.state_text(sit)
    h, b, r = s1q.memory_parts(next(lines for t, lines in s1q.sections(base) if t == s1q.MEM))
    items = s1v.recall_items(rtag, sit)
    text = s1q.with_memory(base, [h] + s1v.belief_lines("B0") + s1q.recalled_lines(items))
    return base, text, dict(replaced_belief_lines=len(b), replaced_recalled_lines=len(r), new_recalled_lines=len(items),
                            recalled_from_reflection=[i["rank"] for i in items if i["reflection_doc"] or i["from_reflection"]])


def insert_column(text, entries):
    if not entries:
        return text
    line = "What I have come to think: " + " ".join(one_line(e) for e in entries)
    lines = text.split("\n")
    i = next(k for k, l in enumerate(lines) if l.startswith("Current situation: "))
    return "\n".join(lines[:i] + [line] + lines[i:])


def build_variants():
    js = journals()
    firsts = [js[(q, 1)]["check"]["journal"] for q in QUESTIONS]
    synth = js[("synth", 1)]["check"]["journal"]
    used_n = [(len(set(js[(q, 1)]["check"]["used"] or [])), -k, q) for k, q in enumerate(QUESTIONS)]
    top_q = max(used_n)[2]  # Used 编号最多；并列取次序在前的（Q_place 最前）
    top = js[(top_q, 1)]["check"]["journal"]
    spec = {"R0": [], "col": firsts, "syn": [synth], "top": [top]}
    texts, notes = {}, {}
    for name in ORDER:
        parts = name.split("_")
        sit, kind = parts[0], parts[1]
        rtag = "after" if name.endswith("recall1") else "before"
        base, r0, note = base_variant(sit, rtag)
        text = insert_column(r0, spec[kind])
        # 自检：去掉新增那一行后，除 What I remember 栏外与基准逐行相同；栏头不变；四份 Belief 为 B0
        stripped = "\n".join(l for l in text.split("\n") if not l.startswith("What I have come to think: "))
        assert stripped == r0, name
        a_, b_ = dict(s1q.sections(base)), dict(s1q.sections(r0))
        assert {t for t in s1q.TITLES if a_.get(t) != b_.get(t)} <= {s1q.MEM}, name
        assert b_[s1q.MEM][0] == a_[s1q.MEM][0], name
        assert s1q.memory_parts(b_[s1q.MEM])[1] == s1v.belief_lines("B0"), name
        texts[name] = text
        notes[name] = dict(situation=sit, column=kind, recall=rtag, base_state=s1q.SITUATIONS[sit][0],
                           column_entries=len(spec[kind]), top_question=top_q if kind == "top" else None,
                           used_counts={q: n for n, _, q in used_n} if kind == "top" else None, **note)
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
        v["state_file"] = f"s1x/variants/{v['variant']}.txt"
    s1v.save("jev", data)
    for v in data["variants"]:
        log(f"jev {v['variant']} chars={v['state_chars']} top1={v['top1_counts']} "
            f"avg={ {k: round(x, 3) for k, x in v['avg_probs'].items() if x} } failed={v['failed']}")


# ---------------------------------------------------------------- 只读：容器日志

def cmd_forced(a):
    start = s1v.load().get("round_start")
    if not start:
        raise SystemExit("round_start missing")
    p = subprocess.run(["docker", "logs", "--since", start, CONTAINER], capture_output=True, timeout=120)
    text = (p.stdout + p.stderr).decode("utf8", "replace")
    forced = [l for l in text.splitlines() if "Forced step" in l]
    both = [l for l in forced if "returned no tool call" in l]
    info = dict(since=start, read_at=s1q.now_iso(), docker_exit=p.returncode, total_lines=len(text.splitlines()),
                forced_step_lines=len(forced), forced_and_no_tool_call=len(both))
    (s1v.RAW / "forced-step-lines.txt").write_text("\n".join(forced), encoding="utf8")
    s1v.save("forced_step", info)
    log(f"forced {info}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stage", choices=["setup", "materials", "write", "check", "writeback", "jev", "forced"])
    ap.add_argument("--dryrun", action="store_true")
    a = ap.parse_args()
    for d in (OUT, s1v.RAW):
        d.mkdir(parents=True, exist_ok=True)
    if a.stage == "setup" and not s1v.load().get("round_start"):
        s1v.save("round_start", datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    log(f"START {a.stage}")
    dict(setup=cmd_setup, materials=cmd_materials, write=cmd_write, check=cmd_check, writeback=cmd_writeback,
         jev=cmd_jev, forced=cmd_forced)[a.stage](a)
    log(f"END {a.stage}")


if __name__ == "__main__":
    main()
