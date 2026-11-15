#!/usr/bin/env python
"""S1-R8：日计划层的规划提示词与检查的离线测量。探索性，不是验收；只给读数，不判 P1–P5，不分类 cannot_yet。

是什么
  按 .demo/observe/npc-slice1-20261112/s1r8/plan.md（唯一规格；提示词、检查、记录项一字不改）实现：
  6 份材料 x 3 次 = 18 次规划调用，每次应答按产品式检查 1–5 逐条记，另记容量估计、by 分布、条数、耗时、usage。
为什么
  决策稿 D-1 定了“代码判为主”（意图 = 活动名 + 次数 + 时限，词表写不出的记 cannot_yet）。本轮只回答：规划 LLM 能不能
  用我们的词表写出合规意图、cannot_yet 占多少、次数与时限能不能用来判完成。不调措辞。
输入（全部是真实导出）
  - 材料：S1-R7 转发器存下的“自己”一问请求（pick_requests，沿用 s1r7c_rewrite 的取法与断言：第 1、2、3、4、5、7 轮各恰好一份），
    取用户消息里 `To think over now: ` 之前的三块（Right now / What happened / What I thought before …）原文，逐字不改。
  - 词表：s1r7/export/request-template.json 的 candidates（名字 + 判据原文）。
  - 人格：请求系统提示词第一行 `You are this person: ` 之后的原文。
  - 提示词：plan.md “系统提示词”一节的代码块原文（运行时从 plan.md 读，断言占位符各恰好一次）；用户消息 = 材料三块 + `\\n\\n`
    + `Plan the rest of today now.`。
落盘（只写 s1r8/；s1r7/ 只读，运行前后各算一次全部文件的哈希，必须相同）
  requests/（18 份请求体）、raw/（每次应答原字节）、results.json、run.log。不写任何判定或报告文件。
怎么运行（Git Bash；仓库根下）
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r8_plan.py --dry-run
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r8_plan.py run
纪律（同 s1r7c_rewrite 的 write）
  key 用 docker exec 现读进进程内存，不打印、不写文件；一个 httpx.Client、并发 <= 3、超时 120 s、不重试；
  401 / 403 / 429 / 正文含 quota / 连接错误即停，未发的不再发；任何退出路径都关闭客户端。
"""

import argparse
import hashlib
import json
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s1r7c_rewrite as r7c  # noqa: E402  导入时它把落盘常量指到 s1r7/rewrite/；下面立刻全部改指到 s1r8/，之前不调任何写函数

r7b, x2, x3, s1v, s1q = r7c.r7b, r7c.x2, r7c.x3, r7c.s1v, r7c.s1q

# ---------------------------------------------------------------- 路径

S1, R7 = r7c.S1, r7c.R7
R8 = S1 / "s1r8"
PLAN_MD = R8 / "plan.md"
TEMPLATE = R7 / "export" / "request-template.json"
READ_ONLY = (R7,)                                  # 整个 s1r7/，前后各算一次哈希

OUT = R8
REQUESTS, RAW = OUT / "requests", OUT / "raw"
RESULTS, LOG = OUT / "results.json", OUT / "run.log"
s1v.configure(x2.COPY_BANK, str(OUT))              # 本脚本不调 s1v 的写函数，只防误写
x2.OUT, x2.RAW, x2.LOG = OUT, RAW, LOG
x2.VARIANTS_DIR, x2.RESULTS, x2.DRYRUN = OUT / "variants", RESULTS, OUT / "dryrun"
x3.OUT, x3.VARIANTS_DIR, x3.RESULTS = OUT, x2.VARIANTS_DIR, RESULTS
r7b.OUT, r7b.VARIANTS_DIR, r7b.RESULTS, r7b.RAW = OUT, x2.VARIANTS_DIR, RESULTS, RAW
r7c.OUT, r7c.REQUESTS, r7c.RAW, r7c.RESULTS, r7c.LOG = OUT, REQUESTS, RAW, RESULTS, LOG

# ---------------------------------------------------------------- 计划原文的常量

ROUNDS = r7c.ROUNDS                                # (1, 2, 3, 4, 5, 7)
REPEATS = 3
EXPECTED_CALLS = len(ROUNDS) * REPEATS             # 18
LLM_URL, LLM_MODEL = r7c.LLM_URL, r7c.LLM_MODEL
LLM_WORKERS, LLM_TIMEOUT_S = r7c.LLM_WORKERS, r7c.LLM_TIMEOUT_S
MAX_TOKENS = 2000
MAX_ITEMS = 5
CHOICES_PER_DAY = 38                               # 现实 20 分钟 / 选择器一轮约 31 秒（借鉴稿 §4；估计值，不是实测）
CHARACTER_PREFIX = "You are this person: "
CHARACTER_TOKEN, ACTIVITIES_TOKEN = "<character>", "<activities>"
PLAN_REQUEST = "Plan the rest of today now."
QUESTION_MARK = "\n\nTo think over now: "
HEADS = ("Right now:\n", "\n\nWhat happened:\n", "\n\nWhat I thought before ")
NOW_RE = re.compile(r"^It is ([^,\n]+), (\d{2}):(\d{2})\.", re.M)
BY_RE = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")
FENCE_RE = re.compile(r"^```[A-Za-z0-9_-]*[ \t]*\n?(.*?)\n?```$", re.S)
INTENT_KEYS = {"activity", "times", "by", "why"}
CANNOT_KEYS = {"want", "why"}


# ---------------------------------------------------------------- 规格输入

def plan_system_template():
    """plan.md “系统提示词：”之后的第一个代码块原文。"""
    md = PLAN_MD.read_text(encoding="utf8")
    m = re.search(r"系统提示词：\s*\n\s*```\n(.*?)\n```", md, re.S)
    assert m, "plan.md 里找不到系统提示词代码块"
    t = m.group(1)
    assert t.count(CHARACTER_TOKEN) == 1 and t.count(ACTIVITIES_TOKEN) == 1, "系统提示词里占位符不是各恰好一次"
    assert t.startswith(CHARACTER_PREFIX + CHARACTER_TOKEN + "\n\n"), "系统提示词不是以 You are this person: <character> 起"
    return t


def load_candidates():
    cands = x2.read_json(TEMPLATE)["candidates"]
    names = [c["name"] for c in cands]
    assert tuple(names) == r7b.CANDS and len(names) == 6, f"词表不是预期的六个候选：{names}"
    assert all(set(c) == {"name", "criterion"} for c in cands)
    return cands


def activities_block(cands):
    return "\n".join(f"- {c['name']}: {c['criterion']}" for c in cands)


# ---------------------------------------------------------------- 材料 / 人格 / 请求体

def parse_material(user, real_system):
    """真实“自己”一问请求 -> (材料三块原文, 此刻分钟数, 此刻钟点文字, 人格原文)。"""
    assert user.count(QUESTION_MARK) == 1, "用户消息里 To think over now 不是恰好一处"
    material = user[:user.index(QUESTION_MARK)]
    pos = 0
    for h in HEADS:
        assert material.count(h) == 1, f"材料里 {h!r} 不是恰好一处"
        i = material.index(h)
        assert i >= pos, "三块次序不对"
        pos = i
    assert material.startswith("Right now:\n"), "材料不是以 Right now: 开头"
    right_now = material[:material.index(HEADS[1])]
    ms = NOW_RE.findall(right_now)
    assert len(ms) == 1, f"Right now 里 It is <时段>, HH:MM. 有 {len(ms)} 处"
    period, hh, mm = ms[0]
    assert int(hh) <= 23 and int(mm) <= 59
    first = real_system.split("\n", 1)[0]
    assert first.startswith(CHARACTER_PREFIX), "真实系统提示词第一行不是 You are this person: 起"
    return material, int(hh) * 60 + int(mm), f"{period}, {hh}:{mm}", first[len(CHARACTER_PREFIX):]


def build_requests(prod):
    picked = r7c.pick_requests(prod)[0]
    template = plan_system_template()
    cands = load_candidates()
    acts = activities_block(cands)
    reqs, mats = {}, {}
    for k in ROUNDS:
        c = picked[k]
        real = json.loads(c["req"].read_bytes().decode("utf8"))
        user = r7c.user_text(real)
        material, now_min, now_text, character = parse_material(user, real["system"])
        assert character.strip() == character and "\n" not in character and character
        system = template.replace(CHARACTER_TOKEN, character).replace(ACTIVITIES_TOKEN, acts)
        assert CHARACTER_TOKEN not in system and ACTIVITIES_TOKEN not in system
        assert system.count(character) >= 1 and all(f"- {c_['name']}: {c_['criterion']}" in system for c_ in cands)
        user_msg = material + "\n\n" + PLAN_REQUEST
        body = dict(model=LLM_MODEL, max_tokens=MAX_TOKENS, system=system,
                    messages=[dict(role="user", content=user_msg)])
        assert real["model"] == LLM_MODEL
        raw = json.dumps(body, ensure_ascii=False).encode("utf8")
        assert json.loads(raw.decode("utf8")) == body
        assert set(body) == {"model", "max_tokens", "system", "messages"} and len(body["messages"]) == 1
        remaining = 1440 - now_min
        mats[k] = dict(name=f"R{k}", round=k, source_request=c["req"].name, now_minutes=now_min, now=now_text,
                       remaining_minutes=remaining, capacity=round(remaining / 1440 * CHOICES_PER_DAY, 2),
                       material_chars=len(material), system_chars=len(system), user_chars=len(user_msg),
                       request_bytes=len(raw), body=body)
        reqs[k] = raw
    return reqs, mats, template, cands


def save_requests(reqs):
    REQUESTS.mkdir(parents=True, exist_ok=True)
    for k in ROUNDS:
        for rep in range(1, REPEATS + 1):
            (REQUESTS / f"R{k}-r{rep}.json").write_bytes(reqs[k])


# ---------------------------------------------------------------- 产品式检查 1–5

def strip_fence(text):
    s = text.strip()
    m = FENCE_RE.match(s)
    if m:
        return m.group(1).strip(), True
    return s, False


def sentence_count(s):
    return len([p for p in re.split(r"(?<=[.!?])\s+", s.strip()) if p])


def nonempty_str(v):
    return isinstance(v, str) and v.strip() != ""


def check_intent(it, now_min):
    """检查 3：一条意图。返回 dict(ok, reasons, activity_ok, by_ok, times_ok, by_minutes)。"""
    r = dict(ok=False, reasons=[], keys_ok=False, activity_ok=False, times_ok=False, by_ok=False, why_ok=False, by=None)
    if not isinstance(it, dict):
        r["reasons"].append("not_object")
        return r
    r["keys_ok"] = set(it) == INTENT_KEYS
    if not r["keys_ok"]:
        r["reasons"].append(f"keys {sorted(it)}")
    act = it.get("activity")
    r["activity_ok"] = isinstance(act, str) and act in r7b.CANDS
    if not r["activity_ok"]:
        r["reasons"].append(f"activity {act!r}")
    t = it.get("times")
    r["times_ok"] = isinstance(t, int) and not isinstance(t, bool) and t >= 1
    if not r["times_ok"]:
        r["reasons"].append(f"times {t!r}")
    by = it.get("by")
    r["by"] = by if isinstance(by, str) else None
    m = BY_RE.match(by) if isinstance(by, str) else None
    if not m:
        r["reasons"].append(f"by_format {by!r}")
    else:
        mins = int(m.group(1)) * 60 + int(m.group(2))
        r["by_ok"] = mins > now_min and mins <= 23 * 60 + 59
        if not r["by_ok"]:
            r["reasons"].append(f"by_not_after_now {by}")
    r["why_ok"] = nonempty_str(it.get("why"))
    if not r["why_ok"]:
        r["reasons"].append("why_empty")
    r["ok"] = r["keys_ok"] and r["activity_ok"] and r["times_ok"] and r["by_ok"] and r["why_ok"]
    return r


def check_cannot(it):
    """检查 4：一条 cannot_yet。"""
    r = dict(ok=False, reasons=[])
    if not isinstance(it, dict):
        r["reasons"].append("not_object")
        return r
    if set(it) != CANNOT_KEYS:
        r["reasons"].append(f"keys {sorted(it)}")
    for f in ("want", "why"):
        if not nonempty_str(it.get(f)):
            r["reasons"].append(f"{f}_empty")
    r["ok"] = not r["reasons"]
    return r


def check_response(js, now_min, capacity):
    """检查 1–5 + 读数。js = 解析后的应答 JSON。"""
    out = dict(check1=False, check1_reason=None, fenced=False, check2=False, check2_reason=None, check3=None, check4=None,
               check5=None, all_pass=False, intent_results=[], cannot_results=[], intents=None, cannot_yet=None,
               text=None, intents_n=None, cannot_n=None, intent_compliant=None, times_sum=None, capacity=capacity,
               over_capacity=None, by_values=None, why_sentences=None)
    text, why = r7c.writer_read(js)                                  # 检查 1
    if text is None:
        out["check1_reason"] = why
        return out
    out["check1"], out["text"] = True, text
    body, out["fenced"] = strip_fence(text)                          # 检查 2
    try:
        obj = json.loads(body)
    except ValueError as e:
        out["check2_reason"] = f"not_json: {e}"
        return out
    if not isinstance(obj, dict):
        out["check2_reason"] = f"not_object: {type(obj).__name__}"
        return out
    ints, cans = obj.get("intents"), obj.get("cannot_yet")
    if isinstance(ints, list):
        out["intents"] = ints
    if isinstance(cans, list):
        out["cannot_yet"] = cans
    if set(obj) != {"intents", "cannot_yet"}:
        out["check2_reason"] = f"keys {sorted(obj)}"
    elif not isinstance(ints, list) or not isinstance(cans, list):
        out["check2_reason"] = "intents/cannot_yet 不都是列表"
    else:
        out["check2"] = True
    if isinstance(ints, list):                                       # 检查 3：只要是列表就逐条评，便于记哪条哪项不过
        out["intent_results"] = [check_intent(it, now_min) for it in ints]
        out["check3"] = all(r["ok"] for r in out["intent_results"])
        out["intents_n"] = len(ints)
        out["intent_compliant"] = sum(r["ok"] for r in out["intent_results"])
        ts = [it["times"] for it in ints if isinstance(it, dict) and isinstance(it.get("times"), int)
              and not isinstance(it.get("times"), bool)]
        out["times_sum"] = sum(ts)
        out["over_capacity"] = out["times_sum"] > capacity
        out["by_values"] = [it.get("by") if isinstance(it, dict) else None for it in ints]
        out["why_sentences"] = [sentence_count(it["why"]) if isinstance(it, dict) and isinstance(it.get("why"), str)
                                else None for it in ints]
    if isinstance(cans, list):                                       # 检查 4
        out["cannot_results"] = [check_cannot(it) for it in cans]
        out["check4"] = all(r["ok"] for r in out["cannot_results"])
        out["cannot_n"] = len(cans)
    if isinstance(ints, list) and isinstance(cans, list):            # 检查 5
        out["check5"] = len(ints) + len(cans) <= MAX_ITEMS
    out["all_pass"] = bool(out["check1"] and out["check2"] and out["check3"] and out["check4"] and out["check5"])
    return out


# ---------------------------------------------------------------- 发请求

def run_calls(reqs, mats, key):
    cells = [(k, rep) for rep in range(1, REPEATS + 1) for k in ROUNDS]
    assert len(cells) == EXPECTED_CALLS
    halt, halted = threading.Event(), []

    with r7c.WriterClient(key) as w:
        def one(cell):
            k, rep = cell
            name = f"R{k}-r{rep}"
            row = dict(name=name, material=f"R{k}", round=k, repeat=rep, sent=False, status=None, error=None,
                       latency_ms=None, input_tokens=None, output_tokens=None, thinking_tokens=None, stop_reason=None,
                       raw_file=None, now=mats[k]["now"], capacity=mats[k]["capacity"], checks=None)
            if halt.is_set():
                row["error"] = "not sent (stopped)"
                return row
            row["sent"] = True
            try:
                status, content, seconds = w.post(reqs[k])
            except Exception as ex:                                  # 连接 / 超时
                halt.set()
                halted.append(f"{name}: {type(ex).__name__}")
                row["error"] = type(ex).__name__
                print(f"{name}: {row['error']}", flush=True)
                return row
            row.update(status=status, latency_ms=round(seconds * 1000), raw_file=f"W_{name}.json")
            (RAW / row["raw_file"]).write_bytes(content)
            lowered = content.decode("utf8", "replace").lower()
            if status != 200:
                body = content[:300].decode("utf8", "replace")
                row["error"] = f"http {status}: {body}"
                if status in (401, 403, 429) or "quota" in lowered:
                    halt.set()
                    halted.append(f"{name}: HTTP {status} {body}")
                print(f"{name}: {row['error']}", flush=True)
                return row
            if "quota" in lowered:                                   # 200 但正文含 quota：同样即停
                halt.set()
                halted.append(f"{name}: body mentions quota")
            try:
                js = json.loads(content.decode("utf8"))
            except ValueError:
                row["error"] = "invalid_json"
                return row
            usage = (js.get("usage") or {}) if isinstance(js, dict) else {}
            row.update(input_tokens=usage.get("input_tokens"), output_tokens=usage.get("output_tokens"),
                       thinking_tokens=(usage.get("output_tokens_details") or {}).get("thinking_tokens"),
                       stop_reason=js.get("stop_reason") if isinstance(js, dict) else None)
            row["checks"] = check_response(js, mats[k]["now_minutes"], mats[k]["capacity"])
            c = row["checks"]
            print(f"{name}: {'pass' if c['all_pass'] else 'not-pass'} {row['latency_ms']} ms in={row['input_tokens']} "
                  f"out={row['output_tokens']} intents={c['intents_n']} cannot_yet={c['cannot_n']}", flush=True)
            return row

        RAW.mkdir(parents=True, exist_ok=True)
        with ThreadPoolExecutor(LLM_WORKERS) as pool:
            got = list(pool.map(one, cells))
    return got, "; ".join(halted) or None


# ---------------------------------------------------------------- 主流程

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("stage", nargs="?", choices=["run"], help="run：正式 18 次；不给则只能配 --dry-run")
    ap.add_argument("--dry-run", action="store_true", help="只生成 18 份请求体、做断言、打印一份完整请求体；不读 key、不发请求")
    a = ap.parse_args()
    if a.dry_run == (a.stage == "run"):
        ap.error("二选一：--dry-run 或 run")

    before = r7b.tree_digest(READ_ONLY)
    prod = r7c.product_source()
    reqs, mats, template, cands = build_requests(prod)
    save_requests(reqs)
    assert len(list(REQUESTS.glob("R*-r*.json"))) == EXPECTED_CALLS
    x2.log(f"s1r8 {'dry-run' if a.dry_run else 'run'}: 材料 {[m['name'] for m in mats.values()]}，"
           f"此刻 {[m['now'] for m in mats.values()]}，容量估计 {[m['capacity'] for m in mats.values()]}；"
           f"s1r7 哈希 {before}")

    if a.dry_run:
        k = ROUNDS[0]
        body = mats[k]["body"]
        print(f"\n===== 一份完整请求体：R{k}（model={body['model']} max_tokens={body['max_tokens']}，"
              f"消息数 {len(body['messages'])}，role={body['messages'][0]['role']}）=====")
        print("----- system -----")
        print(body["system"])
        print("----- user -----")
        print(body["messages"][0]["content"])
        print("=====")
        after = r7b.tree_digest(READ_ONLY)
        assert after == before, f"s1r7 哈希前后不同：{before} {after}"
        x2.log(f"dry-run 完成：18 份请求体已存 requests/，不读 key、不发请求；s1r7 哈希前后相同 {after}")
        return

    key = r7c.read_key()
    x2.log(f"s1r8 run start: {EXPECTED_CALLS} 次，并发 <= {LLM_WORKERS}，超时 {LLM_TIMEOUT_S} s，不重试")
    started = s1q.now_iso()
    try:
        rows, stopped = run_calls(reqs, mats, key)
    finally:
        del key
    after = r7b.tree_digest(READ_ONLY)
    answered = [r for r in rows if r["status"] == 200]
    data = dict(
        model=LLM_MODEL, url=LLM_URL, workers=LLM_WORKERS, timeout_s=LLM_TIMEOUT_S, retries=0, max_tokens=MAX_TOKENS,
        key_source=f"docker exec {r7c.CONTAINER} printenv {r7c.KEY_VAR}（只在进程内存）",
        started=started, finished=s1q.now_iso(), stopped=stopped,
        system_template_sha256=hashlib.sha256(template.encode("utf8")).hexdigest(),
        candidates=cands,
        materials={m["name"]: {f: v for f, v in m.items() if f != "body"} for m in mats.values()},
        counts=dict(requests=len(rows), sent=sum(r["sent"] for r in rows), answered=len(answered),
                    all_pass=sum(bool(r["checks"] and r["checks"]["all_pass"]) for r in rows),
                    intents=sum((r["checks"] or {}).get("intents_n") or 0 for r in rows),
                    cannot_yet=sum((r["checks"] or {}).get("cannot_n") or 0 for r in rows),
                    input_tokens=sum(r["input_tokens"] or 0 for r in rows),
                    output_tokens=sum(r["output_tokens"] or 0 for r in rows)),
        rows=rows, s1r7_digest=dict(before=before, after=after, same=before == after))
    x2.write_json(RESULTS, data)
    for r in rows:
        c = r["checks"] or {}
        x2.log(f"{r['name']} sent={r['sent']} status={r['status']} err={r['error']} ms={r['latency_ms']} "
               f"in={r['input_tokens']} out={r['output_tokens']} all_pass={c.get('all_pass')} "
               f"c1={c.get('check1')} c2={c.get('check2')} c3={c.get('check3')} c4={c.get('check4')} c5={c.get('check5')} "
               f"fenced={c.get('fenced')} intents={c.get('intents_n')} cannot_yet={c.get('cannot_n')} "
               f"times_sum={c.get('times_sum')} capacity={c.get('capacity')}")
    x2.log(f"counts={data['counts']} stopped={stopped}")
    x2.log(f"s1r7 哈希 after {after} same={before == after}")
    if before != after:
        x2.stop("s1r7 的哈希运行前后不同")
    if stopped:
        x2.stop(stopped)


if __name__ == "__main__":
    main()
