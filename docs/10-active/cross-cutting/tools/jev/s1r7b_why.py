#!/usr/bin/env python
"""S1-R7b：只留句子的新栏为什么推得动“去广场 / 守屋”、推不动“采集”——只问 Jev 的离线对照。探索性，不是验收。

是什么
  按 .demo/observe/npc-slice1-20261112/s1r7/why-plan.md（唯一规格；期望与变体一条不改）的变体表，
  用 R7 实跑的 8 份真实 state（M1f / M2f / M3f / M5f / M7f / M7s / MVa / MVb），
  生成 23 个变体（real / nocol / r1cut / r7cut / rx / r2 / r5 / r1），每变体问 Jev 4 次（92 个请求），
  每个变体记全六个候选的平均概率。只给读数，不判 Y1–Y8，不替统筹会话下结论。
为什么
  R7 里新栏只留句子之后，说“去广场 / 守屋”的轮兑现得多，说“采石 / 采石灰石”的轮兑现得少。
  本轮查 R6b 留下的两条线索：收尾句并列几件事（删减对照），采石与采石灰石两个候选分票（逐候选概率）。
输入（全部是真实导出或对它的删减 / 交换，不生造）
  - R7 基准 state：s1r7/states/asked-<计划写的时间戳>.txt，一字不改。每份实跑选了什么以服务端日志
    s1r7/server-s1r7.log 的 npc_select 行为准（日志时刻是 UTC-8，由 voxel_source_prepare 的 at_us 定出整小时差；
    按时刻与 recall_ms 对上 index.tsv），与计划写的“实跑选了什么”核对，不符只报告、不改计划。
  - 句子：r1 / r2 / r5 / r7 = s1r7/export/rows/ 第 k 轮行的 reflection.latest.self.closing（逐字），并断言它等于
    该轮落栏后第一份 state（= 新栏是这一句的第一份）的新栏正文。R7 的新栏正文就是这一句本身：
    `What I have come to think: <句>`，没有“多久以前”，没有 `I thought: `（解析时断言两者都不出现）。
    rx = S1-X3 / S1-R6a / S1-R6b 在 N3 上用的同一句（s1x3_variants.entries_for("selfplan", 3)），并断言与
    s1r6/label/variants/N3_label_now.txt、s1r6/why/variants/N3_sx.txt 新栏里 `I thought: ` 之后的部分逐字相同。
    r1cut / r7cut = 计划写的字面句子；断言它去掉句末句号后是整句的前缀，且整句在那里接着的是“, ”
    （第一个不在括号里的逗号；R1 句括号坐标里的逗号不算），报告实际切点。
  - 问法 / 候选：s1r7/export/request-template.json。
怎么构造
  - 交换：只把 `What I have come to think: ` 之后的句子换掉，栏名、位置不动。
  - 去掉：删掉新栏那一行（产品 Mind.text/1 没有这一栏时整栏不出现）；另对照一份实跑里不含新栏的 state 的栏间格式。
自检（--dry-run 里做，全过才发请求）
  ① 8 个 real 与原 state 逐字节相同；② 每个交换 / 去掉的变体与其基准只差新栏那一行；③ 变体总数 23。
落盘
  只写 s1r7/why/（variants/、raw/、results.json、run.log）。s1r7/states/、s1r7/export/、s1x2/、s1x3/、s1t/、s1r6/
  只读：运行前后各算一次全部文件的哈希汇总，必须相同（不同就停）。
凭据
  Jev 的 TYPESAFE_API_URL / TYPESAFE_API_KEY / TYPESAFE_MODEL：进程环境里没有时，用 s1q.load_env 只从主检出
  D:/hemifuture/ex_mmo_cluster/.env 读 TYPESAFE_* 进本进程环境；值不打印、不写文件（results.json 不记 model 名，
  只记它是否等于实跑日志里的 jev-latest）。
发问
  并发 <= 3，单请求超时 60 s；401 / 403 / 429 / 正文含 quota / 连接错误（含超时）即停，未发的不再发，不重试、不补问。
  请求体与请求头同 s1q.jev_ask；但整个运行只用一个 httpx.Client（连接池上限 3、不重试），任何退出路径都关闭它。

怎么运行（Git Bash；仓库根下）
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r7b_why.py --dry-run   # 只取基准、生成变体与自检，不发请求
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r7b_why.py             # 自检全过才发请求
"""

import argparse
import difflib
import hashlib
import json
import os
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s1x3_variants as x3  # noqa: E402  导入时它把 s1x2_reflect / s1v 的落盘常量指到 s1x3/；下面再改指到 s1r7/why/

x2 = x3.x2
s1x, s1v, s1q = x2.s1x, x2.s1v, x2.s1q

# ---------------------------------------------------------------- 路径：只读输入与落盘目录

S1 = x2.S1
R7 = S1 / "s1r7"
R7_STATES = R7 / "states"
R7_INDEX = R7_STATES / "index.tsv"
R7_ROWS = R7 / "export" / "rows"
R7_TEMPLATE = R7 / "export" / "request-template.json"
SERVER_LOG = R7 / "server-s1r7.log"
R6_LABEL_NOW = S1 / "s1r6" / "label" / "variants" / "N3_label_now.txt"
R6B_SX = S1 / "s1r6" / "why" / "variants" / "N3_sx.txt"
READ_ONLY = (R7 / "states", R7 / "export", S1 / "s1x2", S1 / "s1x3", S1 / "s1t", S1 / "s1r6")

OUT = R7 / "why"
s1v.configure(x2.COPY_BANK, str(OUT))    # s1v 的落盘常量与 s1q.RAW 都指到 s1r7/why/（本脚本不调 s1v 的写函数，只防误写）
x2.OUT, x2.RAW, x2.LOG = OUT, OUT / "raw", OUT / "run.log"
x2.VARIANTS_DIR, x2.RESULTS, x2.DRYRUN = OUT / "variants", OUT / "results.json", OUT / "dryrun"
x3.OUT, x3.VARIANTS_DIR, x3.RESULTS = OUT, x2.VARIANTS_DIR, x2.RESULTS   # 本脚本不调 x3.build，只防误写
VARIANTS_DIR, RESULTS, RAW = x2.VARIANTS_DIR, x2.RESULTS, x2.RAW

# ---------------------------------------------------------------- 计划原文的常量

COLUMN_PREFIX = x3.COLUMN_PREFIX                    # "What I have come to think: "
THOUGHT = "I thought: "                             # R6 时的固定词；R7 的新栏里不该再出现
NOBODY = "Nobody else is nearby."
STANDING = "is standing"
COLUMN_RE = re.compile("^" + re.escape(COLUMN_PREFIX) + "(.*)$")

# 计划“输入”一节：标签 -> (时间戳, 新栏应是第几轮的句子, 是该句的第几份 state（None = 不核对）, 计划写的实跑选择, 计划写的置信度)
GIVEN = {
    "M1f": ("20261114T164642.383Z", 1, 1, "guard_hut", 0.56),
    "M2f": ("20261114T165419.917Z", 2, 1, "visit_plaza", 0.71),
    "M3f": ("20261114T170543.917Z", 3, 1, "gather_stone", 0.20),
    "M5f": ("20261114T171721.514Z", 5, 1, "guard_hut", 0.93),
    "M7f": ("20261114T173241.273Z", 7, 1, "gather_limestone", 0.65),
    "M7s": ("20261114T173250.335Z", 7, 2, "guard_hut", 0.89),
    "MVa": ("20261114T171039.721Z", 3, None, "guard_hut", 0.27),
    "MVb": ("20261114T171258.830Z", 4, None, "guard_hut", 0.23),
}
CORVIN_BASES = ("MVa", "MVb")
BASE_ORDER = tuple(GIVEN)
ROUNDS = (1, 2, 3, 4, 5, 7)                          # 第 6 轮是 aborted，没有新句

# 计划“删减得到的句子”：字面
CUTS = {
    "r1cut": (1, "I'll go on cutting stone from the pile beside my plot and rebuild at (25, 510, 36)."),
    "r7cut": (7, "Next I'll cut limestone from the pile beside my plot so one knock-down doesn't leave me short."),
}

# 计划“变体”表：变体 -> 用在哪些基准
TABLE = {
    "real": BASE_ORDER,
    "nocol": ("M1f", "M2f", "M5f", "M7f", "M7s", "MVa", "MVb"),
    "r1cut": ("M1f",),
    "r7cut": ("M7f", "M7s"),
    "rx": ("M1f", "M7s"),
    "r2": ("M1f",),
    "r5": ("M2f",),
    "r1": ("M2f",),
}
EXPECTED_VARIANTS = 23

CANDS = ("build_hut", "gather_stone", "gather_limestone", "guard_hut", "visit_plaza", "confront_wrecker")


def ms(iso):
    return x2.iso_ms(iso)


def state_file(stamp):
    return R7_STATES / f"asked-{stamp}.txt"


def utc(ms_):
    return x2.ms_iso(ms_)[11:23]


# ---------------------------------------------------------------- 只读目录的哈希汇总

def tree_digest(roots):
    """各只读目录下全部文件（相对路径 + 内容）的 sha256 汇总；返回 {相对 S1 的目录: [文件数, 摘要]}。"""
    out = {}
    for root in roots:
        h, n = hashlib.sha256(), 0
        for p in sorted(q for q in root.rglob("*") if q.is_file()):
            h.update(p.relative_to(root).as_posix().encode("utf8") + b"\0")
            h.update(hashlib.sha256(p.read_bytes()).digest())
            n += 1
        out[root.relative_to(S1).as_posix()] = [n, h.hexdigest()]
    return out


# ---------------------------------------------------------------- R7 的 state 与它的新栏

class R7State:
    """一份 R7 实跑 state：原文字节、各栏、新栏正文（就是那一句）。"""

    def __init__(self, path):
        self.path = path
        self.raw = path.read_bytes()
        self.text = self.raw.decode("utf8")
        self.lines = self.text.split("\n")
        self.ms = x2.file_ms(path.name)
        self.sections = dict(x2.state_sections(self.text))   # 新栏不是 STATE_TITLES 之一，落在 What I remember 一栏末尾
        col = [i for i, l in enumerate(self.lines) if l.startswith(COLUMN_PREFIX)]
        assert len(col) <= 1, f"{path.name} 新栏不止一行"
        self.col_i = col[0] if col else None
        if col:
            self.sentence = COLUMN_RE.match(self.lines[col[0]]).group(1)
            assert THOUGHT not in self.sentence, f"{path.name} 新栏里还有 `I thought: `"
            assert not x2.AGO_PREFIX.match(self.sentence), f"{path.name} 新栏句首还有“多久以前”"
            assert self.lines[col[0] + 1].startswith("Current situation: "), f"{path.name} 新栏之后不是 Current situation"
        else:
            self.sentence = None

    def body(self, title):
        return "\n".join(self.sections[title])[len(title) + 2:]

    def nobody(self):
        return NOBODY in self.body(x2.SITUATION)

    def standing(self):
        return STANDING in self.body(x2.SITUATION)

    def corvin_near(self):
        return "Nearby: Corvin (" in self.body(x2.SITUATION)

    def inventory(self):
        situ = self.body(x2.SITUATION)
        i = situ.find("Inventory: ")
        return situ[i + len("Inventory: "):] if i >= 0 else None


def load_r7_states():
    return sorted((R7State(p) for p in R7_STATES.glob("asked-*.txt")), key=lambda s: s.ms)


# ---------------------------------------------------------------- 句子

def round_sentence(k):
    """第 k 轮“自己”一问的收尾一句（逐字）；只认 `-round<k>-row.json`（不认 aborted），并断言 counts.rounds == k。"""
    (p,) = sorted(R7_ROWS.glob(f"*-round{k}-row.json"))
    refl = x2.read_json(p)["reflection"]
    assert refl["counts"]["rounds"] == k, f"{p.name} 的 counts.rounds 不是 {k}"
    s = refl["latest"]["self"]
    assert s1x.one_line(s["closing"]) == s["closing"], f"第 {k} 轮收尾句含换行等"
    return dict(row=p.name, closing=s["closing"], at_ms=s["at_ms"])


def rx_sentence():
    """rx：S1-X3 / S1-R6a / S1-R6b 在 N3 上用的同一句（同一函数取），并核对 R6a、R6b 落盘的 N3 变体里是同一句。"""
    (entry,) = x3.entries_for("selfplan", x3.BASES["N3"][1])
    s = entry[3]
    for f in (R6_LABEL_NOW, R6B_SX):
        line = next(l for l in f.read_text(encoding="utf8").split("\n") if l.startswith(COLUMN_PREFIX))
        assert line.endswith(THOUGHT + s) and line.count(THOUGHT) == 1, f"rx 与 {f.name} 的新栏句子不逐字相同"
    return s


def first_unbracketed_comma(text):
    depth = 0
    for i, ch in enumerate(text):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "," and depth == 0:
            return i
    return None


def check_cut(name, full, cut):
    """cut 去掉句末句号后是 full 的前缀，且 full 在那里接着“, ”= 第一个不在括号里的逗号。返回切点说明。"""
    assert cut.endswith(".") and not cut.endswith(".."), f"{name} 句末不是句号"
    head = cut[:-1]
    assert full.startswith(head), f"{name} 不是整句的前缀（只删不加）"
    assert full[len(head):].startswith(", "), f"{name} 的切点之后不是“, ”"
    assert first_unbracketed_comma(full) == len(head), f"{name} 的切点不是整句第一个不在括号里的逗号"
    literal_first_comma = full.index(",")
    return dict(cut_at=len(head), literal_first_comma=literal_first_comma,
                is_literal_first_comma=literal_first_comma == len(head),
                dropped=full[len(head):], kept_and=[m.start() for m in re.finditer(r"\b(and|so|but|or)\b", head)])


# ---------------------------------------------------------------- index.tsv 与服务端日志

def load_index():
    """index.tsv 的每行：dict(utc, top1, confidence, recall_ms, file, trigger, asked_recall_ms, ...)。"""
    lines = R7_INDEX.read_text(encoding="utf8").splitlines()
    head = lines[0].split("\t")
    return [dict(zip(head, l.split("\t"))) for l in lines[1:]]


SELECT_RE = re.compile(r"(\d{2}):(\d{2}):(\d{2})\.(\d{3}) \[info\] npc_select cid=\d+ trigger=(\w+) candidates=\S+ "
                       r"chosen=(\w+) confidence=([\d.]+) latency_ms=(\d+) recall_ms=(\d+) model=(\S+)")
PREPARE_RE = re.compile(r"(\d{2}):(\d{2}):(\d{2})\.(\d{3}) \[info\] voxel_source_prepare caller=\S+ at_us=(\d+)")
LOG_DAY = "2026-11-14"   # 日志本地日期（UTC-8 的 08:44–09:38，同一天）


def log_offset_ms(text):
    """服务端日志的时刻只有时分秒：用每行 voxel_source_prepare 的 at_us（Unix 微秒）定出它与 UTC 的整小时差，并要求全都一致。"""
    offs = set()
    for m in PREPARE_RE.finditer(text):
        hh, mm, ss, fr, at_us = m.groups()
        diff = int(at_us) // 1000 - ms(f"{LOG_DAY}T{hh}:{mm}:{ss}.{fr}Z")
        hours = round(diff / 3_600_000)
        assert abs(diff - hours * 3_600_000) < 1000, "日志时刻与 at_us 的差不是整小时"
        offs.add(hours)
    assert len(offs) == 1, f"日志时刻与 UTC 的差不唯一：{offs}"
    return offs.pop() * 3_600_000


def load_selects():
    """服务端日志的 npc_select 行：[dict(utc_ms, trigger, chosen, confidence, latency_ms, recall_ms, model)]。"""
    text = SERVER_LOG.read_text(encoding="utf8", errors="replace")
    off = log_offset_ms(text)
    out = []
    for m in SELECT_RE.finditer(text):
        hh, mm, ss, fr, trig, chosen, conf, lat, rec, model = m.groups()
        out.append(dict(utc_ms=ms(f"{LOG_DAY}T{hh}:{mm}:{ss}.{fr}Z") + off, trigger=trig, chosen=chosen,
                        confidence=float(conf), latency_ms=int(lat), recall_ms=int(rec), model=model))
    return out, off


def actual_choice(fname, index, selects):
    """一份 state 实跑选了什么：index.tsv 里 file 列恰是它的行给出 asked_recall_ms；服务端日志里在文件时刻 ±5 s 内、
    recall_ms 相同的 npc_select 行必须恰好一行，以它为准。"""
    rows = [r for r in index if r["file"] == fname]
    assert len(rows) == 1, f"index.tsv 里 file 列是 {fname} 的行有 {len(rows)} 行"
    row = rows[0]
    t = x2.file_ms(fname)
    hits = [s for s in selects if abs(s["utc_ms"] - t) <= 5000 and s["recall_ms"] == int(row["asked_recall_ms"])]
    assert len(hits) == 1, f"{fname}：服务端日志里对上的 npc_select 行有 {len(hits)} 行"
    s = hits[0]
    return dict(chosen=s["chosen"], confidence=s["confidence"], recall_ms=s["recall_ms"], trigger=s["trigger"],
                model_is_jev_latest=s["model"] == "jev-latest", log_utc=utc(s["utc_ms"]),
                log_minus_file_ms=s["utc_ms"] - t, index_top1=row["top1"],
                index_confidence=float(row["confidence"]), index_agrees=row["top1"] == s["chosen"])


# ---------------------------------------------------------------- 取基准并核对

def corvin_visits(states):
    """Corvin 在附近的 state 按连续段分组：[[文件名, ...], ...]（中间隔一份不在附近的就算新的一段）。"""
    runs, cur = [], []
    for s in states:
        if s.corvin_near():
            cur.append(s.path.name)
        elif cur:
            runs.append(cur)
            cur = []
    if cur:
        runs.append(cur)
    return runs


def pick_bases(states, rounds):
    """返回 ({标签: dict(state, ...)}, 核对说明, 日志信息)。计划给的文件名直接用；核对新栏句子、第几份、处境与实跑选择。"""
    by_name = {s.path.name: s for s in states}
    index = load_index()
    selects, off = load_selects()
    picked, checks = {}, []
    for label, (stamp, k, nth, plan_choice, plan_conf) in GIVEN.items():
        s = by_name[state_file(stamp).name]
        assert s.col_i is not None, f"{label} 没有新栏"
        assert s.sentence == rounds[k]["closing"], f"{label} 新栏不是第 {k} 轮那句"
        with_k = [t for t in states if t.sentence == rounds[k]["closing"]]
        pos = with_k.index(s) + 1
        if nth is not None:
            assert pos == nth, f"{label} 是含第 {k} 轮那句的第 {pos} 份，计划写第 {nth} 份"
            i = states.index(s)
            before = states[i - nth]
            assert before.sentence != rounds[k]["closing"], f"{label} 之前一份已含第 {k} 轮那句"
        if label in CORVIN_BASES:
            assert s.corvin_near(), f"{label} 附近没有 Corvin"
        else:
            assert s.nobody(), f"{label} 不是无人"
        prev_col = states[states.index(with_k[0]) - 1]
        checks.append(f"{label}: 含第 {k} 轮那句的第 {pos} 份（共 {len(with_k)} 份，第一份 {with_k[0].path.name}；"
                      f"它之前一份 {prev_col.path.name} 的新栏 = "
                      f"{'无' if prev_col.sentence is None else '第 %s 轮那句' % next((j for j in ROUNDS if rounds[j]['closing'] == prev_col.sentence), '?')}）；"
                      f"该轮 self.at_ms = {utc(rounds[k]['at_ms'])} UTC；处境 "
                      f"{'Corvin 在附近' if s.corvin_near() else ('无人' if s.nobody() else '其他')}，小屋立着 {s.standing()}")
        actual = actual_choice(s.path.name, index, selects)
        picked[label] = dict(state=s, round=k, nth=pos, plan_actual=plan_choice, plan_confidence=plan_conf,
                             actual=actual, matches_plan=actual["chosen"] == plan_choice
                             and abs(actual["confidence"] - plan_conf) < 1e-9)
    runs = corvin_visits(states)
    for label in CORVIN_BASES:
        name = picked[label]["state"].path.name
        (ri, pi), = [(ri, run.index(name)) for ri, run in enumerate(runs) if name in run]
        checks.append(f"{label}: Corvin 在附近的第 {ri + 1} 段（共 {len(runs)} 段，每段份数 {[len(r) for r in runs]}）里的第 {pi + 1} 份")
    return picked, checks, dict(log_offset_h=off // 3_600_000, npc_select_lines=len(selects),
                                corvin_runs=runs)


# ---------------------------------------------------------------- 变体

def replace_column(base, line):
    """把基准的新栏那一行换成 line（line 为 None 时删掉）；其余逐行不动。"""
    lines = list(base.lines)
    if line is None:
        del lines[base.col_i]
    else:
        lines[base.col_i] = line
    return "\n".join(lines)


def changed_lines(a, b):
    """两份文本逐行比较：返回 (删掉的行, 加上的行)。"""
    rem, add = [], []
    for op in difflib.ndiff(a.split("\n"), b.split("\n")):
        if op.startswith("- "):
            rem.append(op[2:])
        elif op.startswith("+ "):
            add.append(op[2:])
    return rem, add


def build(bases, sentences):
    """生成 23 个变体并做自检 ① ② ③；返回 (texts, notes, order, selfcheck)。"""
    texts, notes, order = {}, {}, []
    selfcheck = {"①": [], "②": [], "③": None}
    for variant, labels in TABLE.items():
        for label in labels:
            base = bases[label]["state"]
            name = f"{label}_{variant}"
            if variant == "real":
                text = base.text
            elif variant == "nocol":
                text = replace_column(base, None)
            else:   # 交换：只换 `What I have come to think: ` 之后的句子
                assert sentences[variant] != base.sentence, f"{name} 换上的句子与原句相同"
                text = replace_column(base, COLUMN_PREFIX + sentences[variant])
            col = next((l for l in text.split("\n") if l.startswith(COLUMN_PREFIX)), None)
            texts[name] = text
            order.append(name)
            notes[name] = dict(base=label, base_state=base.path.name, kind=variant, state_chars=len(text),
                               column=col[len(COLUMN_PREFIX):] if col else None)
            x2.write_text(VARIANTS_DIR / f"{name}.txt", text)
            if variant == "real":
                assert text.encode("utf8") == base.raw, f"{name} 与原 state 不逐字节相同"
                selfcheck["①"].append(name)
            else:
                rem, addl = changed_lines(base.text, text)
                assert rem == [base.lines[base.col_i]], f"{name} 删掉的行不是恰好新栏那一行：{len(rem)}"
                want_add = [] if variant == "nocol" else [COLUMN_PREFIX + sentences[variant]]
                assert addl == want_add, f"{name} 加上的行不对：{len(addl)}"
                assert len(text.split("\n")) == len(base.lines) - (variant == "nocol"), f"{name} 行数不对"
                selfcheck["②"].append((name, len(rem), len(addl)))
    assert len(order) == EXPECTED_VARIANTS, f"变体数 {len(order)} != {EXPECTED_VARIANTS}"
    selfcheck["③"] = len(order)
    x2.write_json(VARIANTS_DIR / "notes.json", notes)
    return texts, notes, order, selfcheck


def nocol_format(states, bases):
    """“去掉”与“从没有这一栏”的写法一致：对照实跑里第一份新栏出现之前、不含新栏的最后一份 state，
    看 Current situation 前一行的形态、全文空行数。"""
    first_col = next(i for i, s in enumerate(states) if s.col_i is not None)
    ref = [s for s in states[:first_col] if s.col_i is None][-1]

    def around(text):
        lines = text.split("\n")
        i = next(n for n, l in enumerate(lines) if l.startswith("Current situation: "))
        return lines[i - 1], lines.count("")

    r_prev, r_n = around(ref.text)
    rows = []
    for label in TABLE["nocol"]:
        base = bases[label]["state"]
        prev, n = around(replace_column(base, None))
        assert prev == base.lines[base.col_i - 1] and prev.strip() and prev[:2] == r_prev[:2], f"{label}_nocol 栏间形态不对"
        assert n == base.text.split("\n").count(""), f"{label}_nocol 空行数变了"
        rows.append((label, prev[:24], n))
    return dict(reference=ref.path.name, reference_prev=r_prev[:24], reference_blank_lines=r_n, nocol=rows)


# ---------------------------------------------------------------- 只记录项

def record_only(bases, sentences):
    out = {}
    for label in BASE_ORDER:
        s = bases[label]["state"]
        mem = [l for l in s.sections[x2.MEM] if not l.startswith(COLUMN_PREFIX)]   # 不含新栏那一行
        out[label] = dict(state=s.path.name, chars=len(s.text),
                          remember_guard_lines=sum("guard" in l for l in mem),
                          remember_guard_lines_ci=sum("guard" in l.lower() for l in mem),
                          remember_lines=len(mem),
                          inventory=s.inventory(),
                          recent_activities=s.body("Recent activities"))
    words = {k: dict(words=len(v.split()), chars=len(v)) for k, v in sentences.items()}
    return out, words


# ---------------------------------------------------------------- 发问

def question(path):
    tpl = x2.read_json(path)
    return ({"activity": {"criteria": {c["name"]: c["criterion"] for c in tpl["candidates"]},
                          "instructions": tpl["instructions"], "type": "choice"}},
            [c["name"] for c in tpl["candidates"]])


class JevClient:
    """整个运行共用的一个 httpx.Client（连接池上限 = 并发数，不重试）；请求体与请求头同 s1q.jev_ask。
    用 with 使用：任何退出路径（正常、异常、停）都关闭连接池。"""

    def __init__(self, workers, timeout_s):
        import httpx
        self.httpx = httpx
        self.url = os.environ["TYPESAFE_API_URL"]
        self.headers = {"authorization": "Bearer " + os.environ["TYPESAFE_API_KEY"],
                        "content-type": "application/json", "user-agent": "voxim-npc-eval/1"}
        self.client = httpx.Client(timeout=timeout_s, follow_redirects=False,
                                   limits=httpx.Limits(max_connections=workers, max_keepalive_connections=workers),
                                   transport=httpx.HTTPTransport(retries=0))

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.client.close()
        return False

    def ask(self, state, questions):
        """返回 (answers, seconds)；HTTP 错误返回 ({'error': code, 'body'}, s)；连接 / 超时 / 坏正文抛异常。"""
        body = json.dumps({"state": state, "model": os.environ["TYPESAFE_MODEL"], "questions": questions}).encode()
        t = time.perf_counter()
        r = self.client.post(self.url, content=body, headers=self.headers)
        if r.status_code >= 400:
            return {"error": r.status_code, "body": r.text[:300]}, time.perf_counter() - t
        return r.json()["answers"], time.perf_counter() - t


def run_jev(texts, order):
    """同 s1r6b_why.run_jev 的语义（并发 <= 3；401 / 403 / 429 / quota / 连接错误即停，未发的不再发；其它失败记下不补问）；
    返回值不含 model 名。"""
    for k in ("TYPESAFE_API_URL", "TYPESAFE_API_KEY", "TYPESAFE_MODEL"):
        if not os.environ.get(k):
            x2.stop(f"环境变量 {k} 没有设置")
    q, cands = question(R7_TEMPLATE)
    assert cands == list(CANDS), "模板的候选与预期不同"
    halt, halted = threading.Event(), []
    cells = [(n, r + 1) for n in order for r in range(x2.JEV_REPEATS)]
    started = s1q.now_iso()

    with JevClient(x2.JEV_WORKERS, x2.JEV_TIMEOUT_S) as jev:
        def one(cell):
            name, rep = cell
            row = dict(repeat=rep, ok=False, top1=None, probs=None, latency_ms=None, error=None)
            if halt.is_set():
                row["error"] = "not sent (stopped)"
                return name, row
            try:
                answers, seconds = jev.ask(texts[name], q)
            except Exception as ex:  # 连接 / 超时 / 坏正文
                halt.set()
                halted.append(f"Jev {name} r{rep}: {type(ex).__name__}")
                row["error"] = type(ex).__name__
                return name, row
            row["latency_ms"] = round(seconds * 1000)
            x2.write_json(RAW / f"J_{name}_r{rep}.json", answers)
            if "error" in answers:
                row["error"] = f"http {answers['error']}"
                if answers["error"] in (401, 403, 429) or "quota" in str(answers.get("body", "")).lower():
                    halt.set()
                    halted.append(f"Jev {name} r{rep}: HTTP {answers['error']} {answers.get('body')}")
            else:
                ans = answers.get("activity")
                if isinstance(ans, dict) and "choice" in ans:
                    row.update(ok=True, top1=ans["choice"], probs=ans.get("probabilities"))
                else:
                    row["error"] = "malformed answer"
            print(f"{name} r{rep}: {row['top1']} {row['error'] or ''}", flush=True)
            return name, row

        with ThreadPoolExecutor(x2.JEV_WORKERS) as pool:
            got = list(pool.map(one, cells))

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
        avg = {c: (sum((r["probs"] or {}).get(c, 0.0) for r in ok) / len(ok) if ok else None) for c in CANDS}
        lead = [c for c, n in top.items() if n >= 3]   # 计划：top1 >= 3 / 4 算成立
        variants.append(dict(variant=name, state_chars=len(texts[name]), top1_counts=top,
                             top1=lead[0] if lead else None, avg_probs=avg,
                             gather_sum=(avg["gather_stone"] + avg["gather_limestone"]) if ok else None,
                             failed=len(rows) - len(ok), requests=rows))
    sent = sum(r["error"] != "not sent (stopped)" for _, r in got)
    return dict(model_is_jev_latest=os.environ["TYPESAFE_MODEL"] == "jev-latest", repeats=x2.JEV_REPEATS,
                workers=x2.JEV_WORKERS, timeout_s=x2.JEV_TIMEOUT_S, retries=0, candidates=list(CANDS),
                started=started, finished=s1q.now_iso(), requests=len(got), sent=sent,
                answered=sum(r["ok"] for _, r in got), stopped="; ".join(halted) or None, variants=variants)


# ---------------------------------------------------------------- 主流程

def fmt_probs(avg):
    return "/".join("—" if avg[c] is None else f"{avg[c]:.3f}".lstrip("0") if avg[c] else "0" for c in CANDS)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="不发请求：只取基准、生成变体、做三项自检、打印")
    a = ap.parse_args()
    before = tree_digest(READ_ONLY)

    states = load_r7_states()
    rounds = {k: round_sentence(k) for k in ROUNDS}
    sentences = {f"r{k}": rounds[k]["closing"] for k in (1, 2, 5, 7)}
    sentences["rx"] = rx_sentence()
    cut_info = {}
    for name, (k, cut) in CUTS.items():
        cut_info[name] = check_cut(name, rounds[k]["closing"], cut)
        sentences[name] = cut
    bases, pick_checks, log_info = pick_bases(states, rounds)
    texts, notes, order, selfcheck = build(bases, sentences)
    fmt = nocol_format(states, bases)
    record, sent_words = record_only(bases, sentences)

    print(f"服务端日志与 UTC 相差 {log_info['log_offset_h']} 小时（日志 + 该值 = UTC；由 voxel_source_prepare 的 at_us 定）；"
          f"npc_select {log_info['npc_select_lines']} 行")
    print("基准（实跑以服务端日志为准）：")
    for label in BASE_ORDER:
        b = bases[label]
        act = b["actual"]
        flag = "  与计划一致" if b["matches_plan"] else f"  ≠ 计划写的 {b['plan_actual']} {b['plan_confidence']}"
        idx = "" if act["index_agrees"] else f"  （index.tsv 写 {act['index_top1']}）"
        print(f"  {label}: {b['state'].path.name}  实跑 {act['chosen']} {act['confidence']} recall_ms={act['recall_ms']} "
              f"trigger={act['trigger']} 日志 {act['log_utc']}Z 日志-文件={act['log_minus_file_ms']} ms "
              f"jev-latest={act['model_is_jev_latest']}{idx}{flag}")
    for c in pick_checks:
        print(f"  核对 {c}")
    print(f"去栏格式：对照无新栏的 {fmt['reference']}（Current situation 前一行 {fmt['reference_prev']!r}…，空行 "
          f"{fmt['reference_blank_lines']}）；各 nocol 前一行 / 空行 {fmt['nocol']}")
    print("删减句切点：")
    for name, c in cut_info.items():
        print(f"  {name}: 切在第 {c['cut_at']} 字（第一个不在括号里的逗号）；字面第一个逗号在第 {c['literal_first_comma']} 字"
              f"（相同 {c['is_literal_first_comma']}）；保留部分里的 and/so/but/or 位置 {c['kept_and']}；删掉 {c['dropped']!r}")
    print("句子（词数 / 字符数）：")
    for k in ("r1", "r1cut", "r2", "r5", "r7", "r7cut", "rx"):
        print(f"  {k} ({sent_words[k]['words']} 词 / {sent_words[k]['chars']} 字符): {sentences[k]}")
    print(f"自检 ① real 逐字节同原 state：{len(selfcheck['①'])} 个；② 只差新栏一行：{len(selfcheck['②'])} 个，"
          f"(删, 加) 行数 {sorted(set((r, d) for _, r, d in selfcheck['②']))}；③ 变体数 {selfcheck['③']}")
    for name in order:
        n = notes[name]
        print(f"  {name:10} state={n['state_chars']:5}  {(n['column'] or '(无新栏)')[:80]}")
    print("只记录（基准）：")
    for k, r in record.items():
        print(f"  {k}: {r['chars']} 字，What I remember 含 guard {r['remember_guard_lines']} 行（不分大小写 "
              f"{r['remember_guard_lines_ci']}，共 {r['remember_lines']} 行），Inventory: {r['inventory']}")
        print(f"       Recent activities: {r['recent_activities']}")
    if a.dry_run:
        assert tree_digest(READ_ONLY) == before, "只读目录在 dry-run 中被改动"
        print(f"只读目录哈希（前后相同）：{before}")
        return

    if not os.environ.get("TYPESAFE_API_KEY"):
        s1q.load_env()   # 只读主检出 .env 的 TYPESAFE_* 进本进程环境，不打印
    x2.log(f"s1r7b jev start: {len(order)} 变体 x {x2.JEV_REPEATS} 次，并发 <= {x2.JEV_WORKERS}，"
           f"超时 {x2.JEV_TIMEOUT_S} s；只读目录哈希 {before}")
    data = run_jev(texts, order)
    after = tree_digest(READ_ONLY)
    data.update(variant_notes=notes, sentences=sentences, sentence_words=sent_words, cut_check=cut_info,
                rounds={k: dict(row=v["row"], self_at_utc=x2.ms_iso(v["at_ms"])) for k, v in rounds.items()},
                bases={k: dict(state=b["state"].path.name, round=b["round"], nth=b["nth"], actual=b["actual"],
                               plan_actual=b["plan_actual"], plan_confidence=b["plan_confidence"],
                               matches_plan=b["matches_plan"]) for k, b in bases.items()},
                pick_checks=pick_checks, server_log=log_info, nocol_format=fmt, record_only=record,
                selfcheck={k: v for k, v in selfcheck.items()},
                read_only_digest=dict(before=before, after=after, same=before == after))
    x2.write_json(RESULTS, data)
    for v in data["variants"]:
        x2.log(f"jev {v['variant']} top1={v['top1_counts']} avg(build/stone/lime/guard/plaza/confront)="
               f"{fmt_probs(v['avg_probs'])} failed={v['failed']}")
    x2.log(f"requests={data['requests']} sent={data['sent']} answered={data['answered']} stopped={data['stopped']}")
    x2.log(f"只读目录哈希 after {after} same={before == after}")
    if before != after:
        x2.stop("只读目录的哈希运行前后不同")
    if data.get("stopped"):
        x2.stop(data["stopped"])


if __name__ == "__main__":
    main()
