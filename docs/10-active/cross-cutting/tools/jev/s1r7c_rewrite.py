#!/usr/bin/env python
"""S1-R7c：新收尾规则的离线重测——用 R7 的真实写作请求重写收尾句，再换进 R7 的真实 state 问 Jev。探索性，不是验收。

是什么
  按 .demo/observe/npc-slice1-20261112/s1r7/rewrite-plan.md（唯一规格；期望、提示词写法、变体一条不改）实现计划里
  执行子会话做的两步：第一步“写”（6 轮 x {P0, P2} x 3 次 = 36 次写作）与第三步“问 Jev”；第二步盲标由统筹会话派，
  本脚本只把盲标要的句子列表打乱写出来（不带提示词版本、不带轮次）。只给读数，不判 Z1–Z6。
为什么
  S1-R7b 判定采集推不动的原因在收尾句的写法；本轮看把写作提示词的收尾规则换成“只说接下来做的一件，并明说不再做什么”
  之后，真实写作写出来的收尾句是什么样子、换进同一批 state 后 Jev 是否照着做。
输入（全部是真实导出，或对它只换一句写法）
  - 写作请求：s1r7/export/bodies/*-POST-req.json（R7 转发器存下的原始字节）。每轮取“自己”一问那一份：用户消息里
    `To think over now: ` 之后的文字 = 产品 Reflection.self_question/0 的原文（从 reflection.ex 源码取，不手抄）。
    请求按时刻对到轮：npc-reflect-lines.log 每轮 event=start / event=end 的时刻（日志是本地时，由同一行的 at_ms 定出
    整小时差）框出窗口，窗口里的请求属于这一轮；轮号与 export/rows/<轮>-row.json 的 reflection.round.at_ms 核对。
    断言：第 1、2、3、4、5、7 轮各恰好一份，第 6 轮没有；该份应答正文经产品切句后最后一句 = 该轮行的
    reflection.latest.self.closing（另核对整条日记 = latest.self.journal、句数 = 日志里该问的 sentences）。
  - P0 = 原请求字节原样；P2 = 同一字节只把系统提示词里 `End with what you will actually do next.` 换成计划写的那句
    （断言旧句在系统提示词里恰好一次、解析后除这一句外逐字段相同）。12 份请求体存 requests/。
  - 产品检查（Reflection.check/2）：`Used:` 行在、列了编号且都在 1..条数（条数 = 用户消息 `What happened:` 一块的条数）、
    正文非空且 <= 5 句；切句与 Used 解析复用 s1x_reflect 的 split_used / checks（与产品同一条正则，运行时核对）。
    应答先按产品 Writer.read/1 取正文：stop_reason 不是 end_turn、没有 text 块都算写作失败。
  - Jev 的 state：s1r7b_why.py 的 8 份基准（M1f M2f M3f M5f M7f M7s MVa MVb）与同一套解析 / 核对（pick_bases），
    只把新栏 `What I have come to think: <句>` 的句子换成本轮写成且过了检查的收尾句（按轮配：R1->M1f；R2->M2f；
    R3->M3f、MVa；R4->MVb；R5->M5f；R7->M7f、M7s）。候选与问法：export/request-template.json。
各阶段
  write       36 次写作（并发 <= 3，单请求 120 s，一个 httpx.Client，任何退出路径都关闭）；401 / 403 / 429 / 正文含
              quota / 连接错误（含超时）即停，未发的不再发，不重试；其它失败照记、不补写。
              key：用 subprocess 执行 `docker exec npc-s1g-hindsight-20261113 printenv HINDSIGHT_API_LLM_API_KEY`
              读进本进程内存（R7 实跑写作用的同一个 key），不打印、不写文件；请求头同产品 Writer（x-api-key、
              anthropic-version: 2023-06-01、content-type: application/json）。
              --dry-run：只取请求、做全部断言、存 requests/，不读 key、不发请求。
  sentences   写 blind/sentences.json（过了检查的收尾句 + 6 句实跑原句，固定种子打乱，只有不透明 id 与句子）与
              blind/key.json（id -> 来源 P0 / P2 / live、轮、第几次；只给统筹会话）。只打印条数。
  jev         变体 = 每份基准 x 它那一轮全部过了检查的收尾句；自检：每个变体与基准只差新栏那一行；计数。
              --dry-run 只生成变体与自检。正式：jev-latest，每变体 4 次，并发 <= 3，60 s，停止规则同上；
              Jev 凭据进程环境里没有时只用 s1q.load_env 从主检出 D:/hemifuture/ex_mmo_cluster/.env 读 TYPESAFE_*。
  join        只读 results.json、blind/key.json、blind/labels.json（盲标由统筹会话存，本脚本不改）：每个变体接上它那一句的
              act / multi / stop，算 kept（top1 >= 3/4 且 = act；采集两候选合并；act = none 为 null 不计）；
              6 句实跑原句的盲标接到各自的轮（它们不问 Jev）。写 joined.json。
落盘
  只写 s1r7/rewrite/（requests/、raw/、variants/、blind/、results.json、run.log）。s1r7/states、s1r7/export、
  s1r7/why 只读：每个阶段前后各算一次全部文件的哈希汇总，必须相同。

怎么运行（Git Bash；仓库根下）
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r7c_rewrite.py write [--dry-run]
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r7c_rewrite.py sentences
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r7c_rewrite.py jev [--dry-run]
"""

import argparse
import hashlib
import json
import os
import random
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s1r7b_why as r7b  # noqa: E402  导入时它把 s1x2 / s1v / s1q 的落盘常量指到 s1r7/why/；下面全部改指到 s1r7/rewrite/

x2, x3, s1x, s1v, s1q = r7b.x2, r7b.x3, r7b.s1x, r7b.s1v, r7b.s1q

# ---------------------------------------------------------------- 路径：只读输入与落盘目录

REPO = Path(__file__).resolve().parents[5]
REFLECTION_EX = REPO / "apps" / "npc_server" / "lib" / "npc_server" / "life" / "reflection.ex"
S1, R7 = r7b.S1, r7b.R7
BODIES = R7 / "export" / "bodies"
ROWS = r7b.R7_ROWS
REFLECT_LOG = R7 / "npc-reflect-lines.log"
READ_ONLY = (R7 / "states", R7 / "export", R7 / "why")

OUT = R7 / "rewrite"
REQUESTS, RAW, VARIANTS_DIR, BLIND = OUT / "requests", OUT / "raw", OUT / "variants", OUT / "blind"
RESULTS, LOG = OUT / "results.json", OUT / "run.log"
s1v.configure(x2.COPY_BANK, str(OUT))     # s1v 的落盘常量与 s1q.RAW 都指到 rewrite/（本脚本不调 s1v 的写函数，只防误写）
x2.OUT, x2.RAW, x2.LOG = OUT, RAW, LOG
x2.VARIANTS_DIR, x2.RESULTS, x2.DRYRUN = VARIANTS_DIR, RESULTS, OUT / "dryrun"
x3.OUT, x3.VARIANTS_DIR, x3.RESULTS = OUT, VARIANTS_DIR, RESULTS
r7b.OUT, r7b.VARIANTS_DIR, r7b.RESULTS, r7b.RAW = OUT, VARIANTS_DIR, RESULTS, RAW   # r7b.run_jev 落 raw/J_*.json

# ---------------------------------------------------------------- 计划原文的常量

OLD_SENTENCE = "End with what you will actually do next."
NEW_SENTENCE = ("End with one sentence about the one thing you will do next, and if that means leaving off something "
                "you have been doing, say plainly that you will stop it.")
PROMPTS = ("P0", "P2")
REPEATS = 3
ROUNDS = r7b.ROUNDS                            # (1, 2, 3, 4, 5, 7)；第 6 轮中止，没有请求
ALL_ROUNDS = tuple(range(1, 8))
ROUND_BASES = {1: ("M1f",), 2: ("M2f",), 3: ("M3f", "MVa"), 4: ("MVb",), 5: ("M5f",), 7: ("M7f", "M7s")}

LLM_URL = "http://127.0.0.1:3425/v1/messages"
LLM_MODEL = "claude/claude-sonnet-5-5"
LLM_WORKERS = 3
LLM_TIMEOUT_S = 120
ANTHROPIC_VERSION = "2023-06-01"
CONTAINER = "npc-s1g-hindsight-20261113"
KEY_VAR = "HINDSIGHT_API_LLM_API_KEY"
MAX_SENTENCES = 5                              # 产品 @max_sentences
BLIND_SEED = 20261114
EXPECTED_WRITES = len(ROUNDS) * len(PROMPTS) * REPEATS   # 36

USED_HEAD = "\n\nWhat happened:\n"
THOUGHTS_HEAD = "\n\nWhat I thought before (my own earlier thoughts, not facts):"
QUESTION_HEAD = "To think over now: "


# ---------------------------------------------------------------- 小工具

def save(key, value):
    data = x2.read_json(RESULTS) if RESULTS.exists() else {}
    data[key] = value
    x2.write_json(RESULTS, data)


def load(key):
    data = x2.read_json(RESULTS) if RESULTS.exists() else {}
    if key not in data:
        x2.stop(f"results.json 里还没有 {key}")
    return data[key]


def check_read_only(before):
    after = r7b.tree_digest(READ_ONLY)
    if after != before:
        x2.stop(f"只读目录的哈希前后不同：before={before} after={after}")
    return after


# ---------------------------------------------------------------- 产品源码里的原文：自己一问、系统提示词、切句正则

def product_source():
    src = REFLECTION_EX.read_text(encoding="utf8")
    m = re.search(r'defp self_question,.*?"text" =>\s*"([^"]*)"', src, re.S)
    assert m, "reflection.ex 里找不到 self_question/0 的原文"
    self_q = m.group(1)
    m = re.search(r'@system_template ~S"""\n(.*?)\n  """', src, re.S)
    assert m, "reflection.ex 里找不到 @system_template"
    template = "\n".join(l[2:] if l.startswith("  ") else l for l in m.group(1).split("\n"))
    m = re.search(r"~r/(.*?)/(\w*)\s*\n\s*\|> Regex\.split\(journal\)", src)
    assert m, "reflection.ex 里找不到切句正则"
    return dict(self_question=self_q, system_template=template, split_regex=m.group(1), split_flags=m.group(2))


def regex_vs_product(prod):
    """s1x.checks 的切句正则（x3.SENTENCE_SPLIT 是它的同一行，x3.last_sentence 运行时断言两者切出的句数相同）与产品
    split_sentences/1 的正则逐字比较。Python 源里引号前多一个反斜杠（字符类里的 \\" 就是 "），比较前去掉。"""
    py = x3.SENTENCE_SPLIT.pattern
    s1x_src = (Path(s1x.__file__)).read_text(encoding="utf8")
    assert 're.split(r"' + py + '", journal.strip())' in s1x_src, "x3.SENTENCE_SPLIT 不是 s1x.checks 里那一行"
    same = py.replace('\\"', '"') == prod["split_regex"]
    return dict(python=py, product=prod["split_regex"], product_flags=prod["split_flags"], same_pattern=same,
                note="产品带 /u（PCRE UTF + UCP：\\s 按 Unicode 空白）；Python str 正则的 \\s 也按 Unicode 空白"
                     "（只有 \\x1c-\\x1f 四个控制字符两边不同）。Used 编号：产品 ~r/\\d+/ 不带 u（只认 ASCII 数字），"
                     "Python \\d 认 Unicode 数字——只在应答里出现非 ASCII 数字时才会不同（运行时逐条核对，见 nonascii_digits）。")


# ---------------------------------------------------------------- 产品检查（Reflection.check/2 + Writer.read/1）

def writer_read(js):
    """产品 Writer.read/1：stop_reason 必须是 end_turn，content 里 text 块按次序连起来。返回 (正文 | None, 失败原因 | None)。"""
    if not isinstance(js, dict) or not isinstance(js.get("content"), list):
        return None, "invalid_response"
    if js.get("stop_reason") != "end_turn":
        return None, f"stop_reason {js.get('stop_reason')}"
    texts = [b["text"] for b in js["content"] if isinstance(b, dict) and b.get("type") == "text" and "text" in b]
    if not texts:
        return None, "no_text"
    return "".join(texts), None


def product_check(text, items):
    """产品 Reflection.check/2 的判定与原因次序；切句与 Used 解析复用 s1x.split_used / s1x.checks（同一条正则）。"""
    journal, used_line, used = s1x.split_used(text)
    c = s1x.checks(text, [dict(n=n, kind="item") for n in range(1, items + 1)])
    out = dict(ok=False, reason=None, journal=journal if used_line is not None else None, used=used,
               sentences=None, closing=None,
               nonascii_digits=any(ch.isdigit() and not ch.isascii() for ch in used_line or ""))
    if used_line is None:
        out["reason"] = "used_line_missing"
        return out
    if not used:
        out["reason"] = "used_line_empty"
        return out
    outside = [u for u in used if not 1 <= u <= items]
    if outside:
        out["reason"] = f"used_out_of_range {outside}"
        return out
    sents = [s for s in x3.SENTENCE_SPLIT.split(journal.strip()) if s.strip()]
    assert len(sents) == c["sentences"], "切句与 s1x.checks 的句数不一致"
    out["sentences"] = len(sents)
    if not sents:
        out["reason"] = "journal_empty"
        return out
    out["closing"] = x3.last_sentence(journal)   # 原文子串；内含与 s1x.checks 句数一致的断言
    if len(sents) > MAX_SENTENCES:
        out["reason"] = f"too_many_sentences {len(sents)}"
        return out
    out["ok"] = True
    return out


# ---------------------------------------------------------------- 请求 <-> 轮

FILE_RE = re.compile(r"^(c\d{4}-r\d{2})-(\d{8}T\d{6}\.\d{3}Z)-(POST|200)-(req|resp)\.json$")
LOG_RE = re.compile(r"(\d{2}):(\d{2}):(\d{2})\.(\d{3}) \[\w+\] npc_reflect cid=\d+ event=(\w+) (.*)$")
LOG_DAY = "2026-11-14"


def parse_reflect_log():
    """npc-reflect-lines.log -> ([{start_ms, end_ms, at_ms, asked, written, self_ms, self_sentences, questions}], 时差小时)。
    日志时刻是本地时：由 event=start 行的 at_ms 与同一行时刻定出整小时差（全部一致才用）。"""
    lines = [m.groups() for m in map(LOG_RE.search, REFLECT_LOG.read_text(encoding="utf8").splitlines()) if m]
    offs = set()
    for hh, mm, ss, fr, ev, rest in lines:
        if ev == "start":
            at = int(re.search(r"\bat_ms=(\d+)", rest).group(1))
            diff = at - x2.iso_ms(f"{LOG_DAY}T{hh}:{mm}:{ss}.{fr}Z")
            h = round(diff / 3_600_000)
            assert abs(diff - h * 3_600_000) < 1000, "日志时刻与 at_ms 的差不是整小时"
            offs.add(h)
    assert len(offs) == 1, f"日志时差不唯一：{offs}"
    off = offs.pop()
    rounds, cur = [], None
    for hh, mm, ss, fr, ev, rest in lines:
        t = x2.iso_ms(f"{LOG_DAY}T{hh}:{mm}:{ss}.{fr}Z") + off * 3_600_000
        if ev == "start":
            assert cur is None, "上一轮没有 event=end 就又 start"
            cur = dict(start_ms=t, at_ms=int(re.search(r"\bat_ms=(\d+)", rest).group(1)), questions=[],
                       self_ms=None, self_sentences=None)
        elif ev == "question":
            key = re.search(r'key="([^"]+)"', rest).group(1)
            sm = re.search(r"\bsentences=(\d+)", rest)
            res = re.search(r"\bresult=(\w+)", rest).group(1)
            cur["questions"].append(dict(key=key, result=res, ms=t, sentences=int(sm.group(1)) if sm else None))
            if key == "self":
                cur["self_ms"], cur["self_sentences"] = t, int(sm.group(1)) if sm else None
        elif ev == "end":
            cur["end_ms"] = t
            cur["written"] = int(re.search(r"\bwritten=(\d+)", rest).group(1))
            rounds.append(cur)
            cur = None
    assert cur is None, "最后一轮没有 event=end"
    return rounds, off


def round_rows():
    """{轮: dict(row 文件名, round.at_ms, self.closing, self.journal, self.at_ms, 是否 aborted)}。"""
    out = {}
    for p in sorted(ROWS.glob("*-round*-row.json")):
        m = re.search(r"-round(\d+)(-aborted)?-row\.json$", p.name)
        k = int(m.group(1))
        refl = x2.read_json(p)["reflection"]
        assert refl["counts"]["rounds"] == k, f"{p.name} counts.rounds != {k}"
        s = refl["latest"]["self"]
        out[k] = dict(row=p.name, row_ms=x2.file_ms(p.name), round_at_ms=refl["round"]["at_ms"],
                      written=refl["round"]["written"], aborted=bool(m.group(2)), closing=s["closing"],
                      journal=s["journal"], self_at_ms=s["at_ms"])
    assert sorted(out) == list(ALL_ROUNDS), f"rows 的轮号 {sorted(out)}"
    return out


def capture_files():
    """[dict(prefix, ms, req 路径, resp 路径)]：POST 请求与它同前缀的 200 应答。"""
    files = {}
    for p in BODIES.iterdir():
        m = FILE_RE.match(p.name)
        if m:
            files.setdefault(m.group(1), {})[m.group(4)] = (p, x2.file_ms(m.group(2)), m.group(3))
    out = []
    for prefix, d in sorted(files.items()):
        if "req" not in d or d["req"][2] != "POST":
            continue
        assert "resp" in d and d["resp"][2] == "200", f"{prefix} 没有 200 应答"
        out.append(dict(prefix=prefix, ms=d["req"][1], req=d["req"][0], resp=d["resp"][0], resp_ms=d["resp"][1]))
    return out


def user_text(body):
    (msg,) = body["messages"]
    assert msg["role"] == "user" and isinstance(msg["content"], str), "用户消息不是单条字符串"
    return msg["content"]


def question_of(user):
    i = user.rindex("\n\n" + QUESTION_HEAD)
    return user[i + 2 + len(QUESTION_HEAD):].split("\n\n", 1)[0]


def items_of(user):
    """用户消息 `What happened:` 一块的条数（产品 check/2 的 items）；断言每条一行、编号 1..n 连续。"""
    i = user.index(USED_HEAD) + len(USED_HEAD)
    j = user.index(THOUGHTS_HEAD, i)
    lines = user[i:j].split("\n")
    nums = [int(re.match(r"^\[(\d+)\] ", l).group(1)) for l in lines]
    assert nums == list(range(1, len(nums) + 1)), "What happened 的编号不是 1..n 连续、每条一行"
    return len(nums)


def pick_requests(prod):
    """每轮“自己”一问的请求：断言第 1、2、3、4、5、7 轮各恰好一份，第 6 轮没有。"""
    log_rounds, off = parse_reflect_log()
    assert len(log_rounds) == len(ALL_ROUNDS), f"日志里有 {len(log_rounds)} 轮"
    rows = round_rows()
    caps = capture_files()
    mapping, picked = [], {}
    for k, lr in zip(ALL_ROUNDS, log_rounds):
        assert rows[k]["round_at_ms"] == lr["at_ms"], f"第 {k} 轮：row 的 round.at_ms 与日志 at_ms 不同"
        nxt = log_rounds[k]["start_ms"] if k < len(log_rounds) else None
        assert lr["end_ms"] <= rows[k]["row_ms"] and (nxt is None or rows[k]["row_ms"] < nxt), \
            f"第 {k} 轮 row 的时刻不在本轮结束与下一轮开始之间"
        inside = [c for c in caps if lr["start_ms"] <= c["ms"] <= lr["end_ms"]]
        for c in inside:
            c["round"] = k
        selfs = [c for c in inside if question_of(user_text(x2.read_json(c["req"]))) == prod["self_question"]]
        mapping.append(dict(round=k, log_start_utc=x2.ms_iso(lr["start_ms"]), log_end_utc=x2.ms_iso(lr["end_ms"]),
                            at_ms=lr["at_ms"], row=rows[k]["row"], requests=[c["prefix"] for c in inside],
                            self_request=[c["req"].name for c in selfs]))
        if k in ROUNDS:
            assert len(selfs) == 1, f"第 {k} 轮“自己”一问的请求有 {len(selfs)} 份"
            assert rows[k]["self_at_ms"] == lr["at_ms"] and "self" in rows[k]["written"], f"第 {k} 轮 row 的 self 不是这一轮写的"
            picked[k] = dict(selfs[0], log_self_ms=lr["self_ms"], log_self_sentences=lr["self_sentences"])
        else:
            assert not selfs and rows[k]["aborted"], f"第 {k} 轮应是中止、没有“自己”请求"
    assert all("round" in c for c in caps), f"有请求不落在任何一轮的窗口里：{[c['prefix'] for c in caps if 'round' not in c]}"
    selfs_all = [c for c in caps if question_of(user_text(x2.read_json(c["req"]))) == prod["self_question"]]
    assert len(selfs_all) == len(ROUNDS), f"全部请求里“自己”一问有 {len(selfs_all)} 份"
    return picked, mapping, rows, off, log_rounds, caps


def verify_live_checks(caps, log_rounds):
    """全部 16 份真实应答：Python 的产品检查给出的句数 = 日志里该问的 sentences（正则与产品是否一致的实证）。"""
    by_round = {k: lr for k, lr in zip(ALL_ROUNDS, log_rounds)}
    out = []
    for c in caps:
        body = x2.read_json(c["req"])
        user = user_text(body)
        text, why = writer_read(x2.read_json(c["resp"]))
        assert text is not None, f"{c['prefix']} 的真实应答不合产品 Writer：{why}"
        chk = product_check(text, items_of(user))
        # 同一轮里按应答时刻对日志的 question 行（日志在写完那一刻打）
        q = min(by_round[c["round"]]["questions"], key=lambda q: abs(q["ms"] - c["resp_ms"]))
        out.append(dict(prefix=c["prefix"], round=c["round"], key=q["key"], ok=chk["ok"], sentences=chk["sentences"],
                        log_sentences=q["sentences"], resp_minus_log_ms=c["resp_ms"] - q["ms"],
                        same=chk["ok"] and chk["sentences"] == q["sentences"]))
    return out


# ---------------------------------------------------------------- 写：P0 / P2 请求体

def build_requests(prod):
    picked, mapping, rows, off, log_rounds, caps = pick_requests(prod)
    live_checks = verify_live_checks(caps, log_rounds)
    assert all(r["same"] for r in live_checks), f"真实应答的产品检查与日志不一致：{[r for r in live_checks if not r['same']]}"
    old_b, new_b = OLD_SENTENCE.encode("utf8"), NEW_SENTENCE.encode("utf8")
    assert json.dumps(OLD_SENTENCE)[1:-1] == OLD_SENTENCE and json.dumps(NEW_SENTENCE)[1:-1] == NEW_SENTENCE, \
        "两句在 JSON 里需要转义（不能直接按字节换）"
    head, tail = prod["system_template"].split("<character>")
    assert prod["system_template"].count(OLD_SENTENCE) == 1, "产品系统提示词里旧句不是恰好一次"
    reqs, info = {}, {}
    for k in ROUNDS:
        c = picked[k]
        raw = c["req"].read_bytes()
        p0 = json.loads(raw.decode("utf8"))
        user = user_text(p0)
        items = items_of(user)
        # 证明找对了请求：应答正文经产品切句后最后一句 = 该轮 row 的 self.closing
        live_text, why = writer_read(x2.read_json(c["resp"]))
        assert live_text is not None, f"第 {k} 轮真实应答不合产品 Writer：{why}"
        live = product_check(live_text, items)
        assert live["ok"], f"第 {k} 轮真实应答不过产品检查：{live['reason']}"
        assert live["closing"] == rows[k]["closing"], f"第 {k} 轮：应答最后一句 != row 的 latest.self.closing"
        assert live["journal"] == rows[k]["journal"], f"第 {k} 轮：应答正文 != row 的 latest.self.journal"
        assert live["sentences"] == c["log_self_sentences"], f"第 {k} 轮：句数与日志不同"
        assert p0["model"] == LLM_MODEL, f"第 {k} 轮请求的 model 不是 {LLM_MODEL}"
        sysp = p0["system"]
        assert sysp.startswith(head) and sysp.endswith(tail), f"第 {k} 轮的系统提示词不是产品 @system_template 的写法"
        # P0：原字节原样；断言解析后就是这份请求体
        p0_raw = raw
        assert json.loads(p0_raw.decode("utf8")) == p0
        # P2：只换那一句
        assert raw.count(old_b) == 1 and sysp.count(OLD_SENTENCE) == 1, f"第 {k} 轮旧句不是恰好一次"
        assert raw.count(new_b) == 0
        p2_raw = raw.replace(old_b, new_b)
        p2 = json.loads(p2_raw.decode("utf8"))
        assert list(p2) == list(p0), "P2 的字段次序变了"
        assert {f: v for f, v in p2.items() if f != "system"} == {f: v for f, v in p0.items() if f != "system"}, \
            f"第 {k} 轮 P2 除系统提示词外有别的字段变了"
        assert p2["system"] == sysp.replace(OLD_SENTENCE, NEW_SENTENCE) and p2["system"].count(NEW_SENTENCE) == 1
        i = sysp.index(OLD_SENTENCE)
        assert p2["system"][:i] == sysp[:i] and p2["system"][i + len(NEW_SENTENCE):] == sysp[i + len(OLD_SENTENCE):], \
            f"第 {k} 轮 P2 的系统提示词除那一句外不同"
        for name, b in (("P0", p0_raw), ("P2", p2_raw)):
            REQUESTS.mkdir(parents=True, exist_ok=True)
            (REQUESTS / f"R{k}-{name}.json").write_bytes(b)
            reqs[(k, name)] = b
        info[k] = dict(request=c["req"].name, response=c["resp"].name, items=items, max_tokens=p0["max_tokens"],
                       model=p0["model"], system_chars=len(sysp), p2_system_chars=len(p2["system"]),
                       user_chars=len(user), live_closing=live["closing"], live_sentences=live["sentences"],
                       live_used=live["used"], request_bytes=dict(P0=len(p0_raw), P2=len(p2_raw)))
    assert len(reqs) == 2 * len(ROUNDS)
    return reqs, info, mapping, off, live_checks


# ---------------------------------------------------------------- 写：发请求

def read_key():
    """R7 实跑写作用的 key：从 Hindsight 容器的环境变量现读，只进本进程内存；不打印、不写文件。"""
    try:
        p = subprocess.run(["docker", "exec", CONTAINER, "printenv", KEY_VAR], capture_output=True, timeout=60)
    except Exception as e:
        x2.stop(f"读 key 失败：{type(e).__name__}")
    key = p.stdout.decode("utf8", "replace").strip()
    if p.returncode != 0 or not key or "\n" in key:
        x2.stop(f"读 key 失败：docker exec 退出码 {p.returncode}，读到的值为空或多行")
    return key


class WriterClient:
    """整个运行共用的一个 httpx.Client（连接池上限 = 并发数，不重试）；请求头同产品 Writer。with 使用，任何退出路径都关闭。"""

    def __init__(self, key):
        import httpx
        self.headers = {"x-api-key": key, "anthropic-version": ANTHROPIC_VERSION, "content-type": "application/json"}
        self.client = httpx.Client(timeout=LLM_TIMEOUT_S, follow_redirects=False,
                                   limits=httpx.Limits(max_connections=LLM_WORKERS,
                                                       max_keepalive_connections=LLM_WORKERS),
                                   transport=httpx.HTTPTransport(retries=0))

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.client.close()
        return False

    def post(self, body):
        t = time.perf_counter()
        r = self.client.post(LLM_URL, content=body, headers=self.headers)
        return r.status_code, r.content, time.perf_counter() - t


def run_writes(reqs, info, key):
    cells = [(k, p, rep) for rep in range(1, REPEATS + 1) for k in ROUNDS for p in PROMPTS]
    assert len(cells) == EXPECTED_WRITES
    halt, halted = threading.Event(), []

    with WriterClient(key) as w:
        def one(cell):
            k, p, rep = cell
            name = f"R{k}-{p}-r{rep}"
            row = dict(name=name, round=k, prompt=p, repeat=rep, sent=False, status=None, error=None, ok=False,
                       reason=None, latency_ms=None, output_tokens=None, thinking_tokens=None, stop_reason=None,
                       journal=None, used=None, sentences=None, closing=None, raw_file=None)
            if halt.is_set():
                row["error"] = "not sent (stopped)"
                return row
            row["sent"] = True
            try:
                status, content, seconds = w.post(reqs[(k, p)])
            except Exception as ex:   # 连接 / 超时
                halt.set()
                halted.append(f"{name}: {type(ex).__name__}")
                row["error"] = type(ex).__name__
                print(f"{name}: {row['error']}", flush=True)
                return row
            row.update(status=status, latency_ms=round(seconds * 1000), raw_file=f"W_{name}.json")
            (RAW / row["raw_file"]).write_bytes(content)
            if status != 200:
                body = content[:300].decode("utf8", "replace")
                row["error"] = f"http {status}: {body}"
                if status in (401, 403, 429) or "quota" in content.decode("utf8", "replace").lower():
                    halt.set()
                    halted.append(f"{name}: HTTP {status} {body}")
                print(f"{name}: {row['error']}", flush=True)
                return row
            try:
                js = json.loads(content.decode("utf8"))
            except ValueError:
                row["error"] = "invalid_json"
                return row
            usage = js.get("usage") or {} if isinstance(js, dict) else {}
            row.update(output_tokens=usage.get("output_tokens"),
                       thinking_tokens=(usage.get("output_tokens_details") or {}).get("thinking_tokens"),
                       stop_reason=js.get("stop_reason") if isinstance(js, dict) else None)
            text, why = writer_read(js)
            if text is None:
                row["error"] = f"writer: {why}"
                print(f"{name}: {row['error']}", flush=True)
                return row
            chk = product_check(text, info[k]["items"])
            row.update(ok=chk["ok"], reason=chk["reason"], journal=chk["journal"], used=chk["used"],
                       sentences=chk["sentences"], closing=chk["closing"], nonascii_digits=chk["nonascii_digits"])
            print(f"{name}: {'pass' if chk['ok'] else 'FAIL ' + chk['reason']} {row['latency_ms']} ms "
                  f"out={row['output_tokens']} | {chk['closing']}", flush=True)
            return row

        RAW.mkdir(parents=True, exist_ok=True)
        with ThreadPoolExecutor(LLM_WORKERS) as pool:
            got = list(pool.map(one, cells))
    return got, "; ".join(halted) or None


def cmd_write(a):
    before = r7b.tree_digest(READ_ONLY)
    prod = product_source()
    rx = regex_vs_product(prod)
    reqs, info, mapping, off, live_checks = build_requests(prod)
    print(f"产品 self_question：{prod['self_question']}")
    print(f"切句正则：Python {rx['python']!r}  产品 {rx['product']!r} /{rx['product_flags']}  同一条（去掉 Python 的转义）：{rx['same_pattern']}")
    print(f"真实应答 {len(live_checks)} 份：Python 产品检查的句数与日志 sentences= 一致 {sum(r['same'] for r in live_checks)} 份")
    print(f"反思日志时差：日志 + {-off} 小时 = UTC" if off < 0 else f"反思日志时差：日志 {off:+d} 小时 = UTC")
    print("轮 <-> 请求：")
    for m in mapping:
        print(f"  第 {m['round']} 轮 [{m['log_start_utc'][11:23]} – {m['log_end_utc'][11:23]}Z] row={m['row']} "
              f"请求 {m['requests']} 自己={m['self_request']}")
    for k in ROUNDS:
        i = info[k]
        print(f"  R{k}: items={i['items']} 实跑收尾句（= row closing，已断言）：{i['live_closing']}")
    if a.dry_run:
        after = check_read_only(before)
        print(f"dry-run：12 份请求体已存 requests/；不读 key、不发请求。只读目录哈希（前后相同）：{after}")
        return
    key = read_key()
    x2.log(f"s1r7c write start: {EXPECTED_WRITES} 次，并发 <= {LLM_WORKERS}，超时 {LLM_TIMEOUT_S} s；只读目录哈希 {before}")
    started = s1q.now_iso()
    try:
        rows, stopped = run_writes(reqs, info, key)
    finally:
        del key
    after = r7b.tree_digest(READ_ONLY)
    data = dict(model=LLM_MODEL, url=LLM_URL, workers=LLM_WORKERS, timeout_s=LLM_TIMEOUT_S, retries=0,
                key_source=f"docker exec {CONTAINER} printenv {KEY_VAR}（只在进程内存）",
                headers=["x-api-key", "anthropic-version: " + ANTHROPIC_VERSION, "content-type: application/json"],
                old_sentence=OLD_SENTENCE, new_sentence=NEW_SENTENCE, started=started, finished=s1q.now_iso(),
                requests=len(rows), sent=sum(r["sent"] for r in rows),
                answered=sum(r["status"] == 200 for r in rows), passed=sum(r["ok"] for r in rows),
                failed_checks=sum(r["status"] == 200 and not r["ok"] for r in rows), stopped=stopped,
                regex_vs_product=rx, self_question=prod["self_question"], mapping=mapping, log_offset_h=off,
                live_checks=live_checks, rounds={str(k): v for k, v in info.items()}, rows=rows,
                read_only_digest=dict(before=before, after=after, same=before == after))
    save("write", data)
    for r in rows:
        x2.log(f"write {r['name']} status={r['status']} ok={r['ok']} reason={r['reason']} err={r['error']} "
               f"ms={r['latency_ms']} out={r['output_tokens']} sent={r['sentences']} used={r['used']} | {r['closing']}")
    x2.log(f"requests={data['requests']} sent={data['sent']} answered={data['answered']} passed={data['passed']} "
           f"failed_checks={data['failed_checks']} stopped={stopped}")
    x2.log(f"只读目录哈希 after {after} same={before == after}")
    if before != after:
        x2.stop("只读目录的哈希运行前后不同")
    if stopped:
        x2.stop(stopped)


# ---------------------------------------------------------------- 盲标句子

def passing(write):
    return [r for r in write["rows"] if r["ok"]]


def cmd_sentences(a):
    before = r7b.tree_digest(READ_ONLY)
    write = load("write")
    rows = round_rows()
    items = [dict(source=r["prompt"], round=r["round"], repeat=r["repeat"], sentence=r["closing"]) for r in passing(write)]
    items += [dict(source="live", round=k, repeat=None, sentence=rows[k]["closing"]) for k in ROUNDS]
    random.Random(BLIND_SEED).shuffle(items)
    width = len(str(len(items)))
    sentences, key = [], {}
    for n, it in enumerate(items, 1):
        sid = f"S{n:0{width}d}"
        sentences.append(dict(id=sid, sentence=it["sentence"]))
        key[sid] = dict(source=it["source"], round=it["round"], repeat=it["repeat"])
    x2.write_json(BLIND / "sentences.json", sentences)
    x2.write_json(BLIND / "key.json", dict(seed=BLIND_SEED, key=key))
    after = check_read_only(before)
    x2.log(f"sentences: {len(sentences)} 句（过了检查的 {len(items) - len(ROUNDS)} + 实跑 {len(ROUNDS)}），种子 {BLIND_SEED}；"
           f"写 blind/sentences.json 与 blind/key.json；只读目录哈希 {after}")


# ---------------------------------------------------------------- 问 Jev

def build_variants(write):
    states = r7b.load_r7_states()
    rounds = {k: r7b.round_sentence(k) for k in ROUNDS}
    bases, pick_checks, log_info = r7b.pick_bases(states, rounds)
    for k, labels in ROUND_BASES.items():
        for label in labels:
            assert bases[label]["round"] == k, f"{label} 在 s1r7b_why 里是第 {bases[label]['round']} 轮，计划写第 {k} 轮"
    assert sorted(l for ls in ROUND_BASES.values() for l in ls) == sorted(r7b.BASE_ORDER)
    good = passing(write)
    texts, notes, order, checks = {}, {}, [], []
    for label in r7b.BASE_ORDER:
        base = bases[label]["state"]
        k = bases[label]["round"]
        for r in sorted((r for r in good if r["round"] == k), key=lambda r: (r["prompt"], r["repeat"])):
            s = r["closing"]
            assert "\n" not in s, f"{r['name']} 的收尾句含换行，换进新栏会多出一行"
            name = f"{label}_{r['prompt']}r{r['repeat']}"
            text = r7b.replace_column(base, r7b.COLUMN_PREFIX + s)
            rem, add = r7b.changed_lines(base.text, text)
            if s == base.sentence:
                assert rem == [] and add == [] and text == base.text, f"{name} 与基准句子相同却有差异"
            else:
                assert rem == [base.lines[base.col_i]] and add == [r7b.COLUMN_PREFIX + s], f"{name} 与基准不是只差新栏一行"
            assert len(text.split("\n")) == len(base.lines), f"{name} 行数变了"
            texts[name] = text
            order.append(name)
            notes[name] = dict(base=label, base_state=base.path.name, round=k, prompt=r["prompt"], repeat=r["repeat"],
                               write=r["name"], sentence=s, same_as_base=s == base.sentence, state_chars=len(text))
            checks.append((name, len(rem), len(add)))
            x2.write_text(VARIANTS_DIR / f"{name}.txt", text)
    expected = sum(len(ROUND_BASES[r["round"]]) for r in good)
    assert len(order) == expected, f"变体数 {len(order)} != {expected}"
    x2.write_json(VARIANTS_DIR / "notes.json", notes)
    return texts, notes, order, checks, bases, pick_checks


def cmd_jev(a):
    before = r7b.tree_digest(READ_ONLY)
    write = load("write")
    texts, notes, order, checks, bases, pick_checks = build_variants(write)
    diff_kinds = sorted(set((r, d) for _, r, d in checks))
    same_as_base = [n for n in order if notes[n]["same_as_base"]]
    print(f"变体 {len(order)} 个（过了检查的收尾句 {len(passing(write))} 句）；自检：每个与基准只差新栏一行，"
          f"(删, 加) 行数 {diff_kinds}；句子与基准原句相同（变体 = 基准）{same_as_base}")
    for label in r7b.BASE_ORDER:
        print(f"  {label}（第 {bases[label]['round']} 轮，{bases[label]['state'].path.name}）："
              f"{[n.split('_', 1)[1] for n in order if notes[n]['base'] == label]}")
    if a.dry_run:
        after = check_read_only(before)
        save("jev_dry_run", dict(variants=len(order), order=order, diff_kinds=diff_kinds, same_as_base=same_as_base,
                                 pick_checks=pick_checks, read_only_digest=dict(before=before, after=after)))
        print(f"dry-run：不发 Jev 请求。只读目录哈希（前后相同）：{after}")
        return
    if not os.environ.get("TYPESAFE_API_KEY"):
        s1q.load_env()   # 只读主检出 .env 的 TYPESAFE_* 进本进程环境，不打印
    x2.log(f"s1r7c jev start: {len(order)} 变体 x {x2.JEV_REPEATS} 次，并发 <= {x2.JEV_WORKERS}，"
           f"超时 {x2.JEV_TIMEOUT_S} s；只读目录哈希 {before}")
    data = r7b.run_jev(texts, order)
    after = r7b.tree_digest(READ_ONLY)
    data.update(variant_notes=notes, pick_checks=pick_checks,
                read_only_digest=dict(before=before, after=after, same=before == after))
    save("jev", data)
    for v in data["variants"]:
        x2.log(f"jev {v['variant']} top1={v['top1_counts']} avg(build/stone/lime/guard/plaza/confront)="
               f"{r7b.fmt_probs(v['avg_probs'])} failed={v['failed']}")
    x2.log(f"requests={data['requests']} sent={data['sent']} answered={data['answered']} stopped={data['stopped']}")
    x2.log(f"只读目录哈希 after {after} same={before == after}")
    if before != after:
        x2.stop("只读目录的哈希运行前后不同")
    if data.get("stopped"):
        x2.stop(data["stopped"])


# ---------------------------------------------------------------- 接上盲标

GATHER = ("gather_stone", "gather_limestone")
JOINED = OUT / "joined.json"


def kept(act, top1):
    """计划“兑现”：top1（4 次里 >= 3 次同一个）= 该句盲标的 act；采集两候选合并算；act = none 不计（返回 None）。"""
    if act == "none":
        return None
    if top1 is None:
        return False
    return top1 == act or (act in GATHER and top1 in GATHER)


def cmd_join(a):
    """只读 results.json、blind/key.json、blind/labels.json；每个变体接上它那一句的盲标，6 句实跑原句接到各自的轮；写 joined.json。"""
    before = r7b.tree_digest(READ_ONLY)
    label_path = BLIND / "labels.json"
    label_hash = hashlib.sha256(label_path.read_bytes()).hexdigest()
    data = x2.read_json(RESULTS)
    key = x2.read_json(BLIND / "key.json")["key"]
    labels = x2.read_json(label_path)
    by_id = {}
    for lab in labels:
        assert lab["id"] not in by_id, f"labels.json 里 {lab['id']} 重复"
        assert lab["act"] in r7b.CANDS + ("none",), f"{lab['id']} 的 act 不是候选或 none：{lab['act']}"
        by_id[lab["id"]] = lab
    assert set(by_id) == set(key), "labels.json 与 key.json 的 id 不一致"
    sid_of = {(v["source"], v["round"], v["repeat"]): sid for sid, v in key.items()}
    assert len(sid_of) == len(key), "key.json 里 (来源, 轮, 第几次) 有重复"
    write_rows = {r["name"]: r for r in data["write"]["rows"]}
    jev = data["jev"]
    notes = jev["variant_notes"]
    out = []
    for v in jev["variants"]:
        n = notes[v["variant"]]
        sid = sid_of[(n["prompt"], n["round"], n["repeat"])]
        assert write_rows[n["write"]]["closing"] == n["sentence"], f"{v['variant']} 的句子与写作记录不同"
        lab = by_id[sid]
        out.append(dict(variant=v["variant"], base=n["base"], round=n["round"], source=n["prompt"], repeat=n["repeat"],
                        sentence_id=sid, sentence=n["sentence"], act=lab["act"], multi=lab["multi"], stop=lab["stop"],
                        top1_counts=v["top1_counts"], top1=v["top1"], avg_probs=v["avg_probs"],
                        failed=v["failed"], kept=kept(lab["act"], v["top1"])))
    live = []
    for sid, k in sorted(key.items(), key=lambda kv: (kv[1]["round"], kv[0])):
        if k["source"] != "live":
            continue
        lab = by_id[sid]
        live.append(dict(round=k["round"], sentence_id=sid, act=lab["act"], multi=lab["multi"], stop=lab["stop"],
                         note=lab.get("note")))
    assert [l["round"] for l in live] == list(ROUNDS), "实跑原句的轮不是 1,2,3,4,5,7"
    after = check_read_only(before)
    x2.write_json(JOINED, dict(kept_rule="top1（>=3/4）= act；gather_stone / gather_limestone 合并；act=none 为 null 不计",
                               variants=out, live=live, labels_sha256=label_hash,
                               read_only_digest=dict(before=before, after=after)))
    x2.log(f"join: {len(out)} 个变体、{len(live)} 句实跑原句接上盲标，写 joined.json；只读目录哈希 {after}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("stage", choices=["write", "sentences", "jev", "join"])
    ap.add_argument("--dry-run", action="store_true", help="write：只取请求、断言、存 requests/；jev：只生成变体与自检")
    a = ap.parse_args()
    dict(write=cmd_write, sentences=cmd_sentences, jev=cmd_jev, join=cmd_join)[a.stage](a)


if __name__ == "__main__":
    main()
