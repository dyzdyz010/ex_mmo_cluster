#!/usr/bin/env python
"""S1-R6b：新栏在闭环里为什么推不动选择——只问 Jev 的离线对照（2 × 2 交换）。探索性，不是验收。

是什么
  按 .demo/observe/npc-slice1-20261112/s1r6/why-plan.md（唯一规格；期望与判定口径一条不改）的变体表，
  用 R6 实跑的 8 份真实 state（L2f / L2o / L3f / L4f / L6f / L8f / LVa / LVb）与 S1-T 的 N3，
  生成 28 个变体（real / nocol / sx / s3 / now / N3_s2 / N3_s8 / N3_s4 / N3_R0 / N3_sx），每变体问 Jev 4 次（112 个请求）。
  只给读数与按计划口径的机械比较，不替统筹会话下结论。
为什么
  R6 闭环里新栏写着“去采石 / 去广场”，无人时仍 87% 守屋；离线 S1-R6a / S1-X3 同样形态的一句却能把 N3 翻成采石。
  本轮把“句子本身的写法”与“句子所在的 state”交换开来看，顺带看句首“多久以前”。
输入（全部是真实导出或对它的删减 / 交换，不生造）
  - R6 基准 state：s1r6/states/asked-*.txt，一字不改。给了文件名的直接用；L2o、L6f 按计划文字从 state 全文挑
    （“无人” = Current situation 含 `Nobody else is nearby.`；“小屋立着” = 含 `is standing`）。
    每份基准实跑选了什么以服务端日志 s1r6/server-s1r6.log 的 npc_select 行为准（按时刻与 recall_ms 对上 index.tsv），
    与计划写的“实跑选了什么”核对，不符只报告、不改计划。
  - 句子：s2 / s3 / s4 / s8 = s1r6/export/rows/ 第 k 轮行的 reflection.latest.self.closing（逐字），并断言它等于
    该轮落栏后第一份 state 新栏里 `I thought: ` 之后的部分；sx = S1-X3 / S1-R6a 在 N3 上用的同一句
    （s1x3_variants.entries_for("selfplan", 3)，并断言与 s1r6/label/variants/N3_label_now.txt 里的逐字相同）。
  - 问法 / 候选：R6 基准用 s1r6/export/request-template.json，N3 用 s1t/export/request-template.json（同 S1-R6a）。
怎么构造
  - 交换：只换新栏 `I thought: ` 之后的句子，栏名、位置、句首“多久以前”不动；now：只把句首换成 `Just now, `。
  - 去掉：删掉新栏那一行。产品 Mind.text/1 是各栏以 "\n" 相连、没有这一栏时整栏不出现（mind.ex thought/1），
    所以删行后的结果就是“从没有这一栏”的写法；另对照一份实跑里不含新栏的 state 的栏间格式。
  - N3 的各变体：沿用 s1x2_reflect.insert_column（与 S1-R6a 同一函数），新栏正文 `Just now, I thought: <句>`。
自检（--dry-run 里做，全过才发请求）
  ① 8 个 real 与原 state 逐字节相同；② N3_R0、N3_sx 与 s1r6/label/variants/ 的 N3_R0、N3_label_now 逐字节相同；
  ③ 每个交换 / 去掉 / now / 插入的变体与其基准只差新栏那一行；④ 变体总数 28。
落盘
  只写 s1r6/why/（variants/、raw/、results.json、run.log）。s1r6/states/、s1r6/export/、s1r6/label/、s1x2/、s1x3/、s1t/
  只读：运行前后各算一次全部文件的哈希汇总，必须相同（不同就停）。
凭据
  Jev 的 TYPESAFE_API_URL / TYPESAFE_API_KEY / TYPESAFE_MODEL：进程环境里没有时，用 s1q.load_env 只从主检出
  D:/hemifuture/ex_mmo_cluster/.env 读这三个键进本进程环境；值不打印、不写文件（results.json 不记 model 名，
  只记它是否等于实跑日志里的 jev-latest）。
发问
  并发 <= 3，单请求超时 60 s；401 / 403 / 429 / 正文含 quota / 连接错误（含超时）即停，未发的不再发，不重试、不补问。

怎么运行（Git Bash；仓库根下）
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r6b_why.py --dry-run   # 只选基准、生成变体与自检，不发请求
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r6b_why.py             # 自检全过才发请求
"""

import argparse
import difflib
import hashlib
import json
import os
import re
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s1x3_variants as x3  # noqa: E402  导入时它把 s1x2_reflect / s1v 的落盘常量指到 s1x3/；下面再改指到 s1r6/why/

x2 = x3.x2
s1x, s1v, s1q = x2.s1x, x2.s1v, x2.s1q

# ---------------------------------------------------------------- 路径：只读输入与落盘目录

S1 = x2.S1
R6 = S1 / "s1r6"
R6_STATES = R6 / "states"
R6_INDEX = R6_STATES / "index.tsv"
R6_ROWS = R6 / "export" / "rows"
R6_TEMPLATE = R6 / "export" / "request-template.json"
S1T_TEMPLATE = x2.TEMPLATE                         # s1t/export/request-template.json（S1-R6a 的 N3 用的）
SERVER_LOG = R6 / "server-s1r6.log"
LABEL_VARIANTS = R6 / "label" / "variants"         # 自检 ②：N3_R0 / N3_label_now
READ_ONLY = (R6 / "states", R6 / "export", R6 / "label", S1 / "s1x2", S1 / "s1x3", S1 / "s1t")

OUT = R6 / "why"
s1v.configure(x2.COPY_BANK, str(OUT))    # s1v 的落盘常量与 s1q.RAW 都指到 s1r6/why/（本脚本不调 s1v 的写函数，只防误写）
x2.OUT, x2.RAW, x2.LOG = OUT, OUT / "raw", OUT / "run.log"
x2.VARIANTS_DIR, x2.RESULTS, x2.DRYRUN = OUT / "variants", OUT / "results.json", OUT / "dryrun"
x3.OUT, x3.VARIANTS_DIR, x3.RESULTS = OUT, x2.VARIANTS_DIR, x2.RESULTS   # 本脚本不调 x3.build，只防误写
VARIANTS_DIR, RESULTS, RAW = x2.VARIANTS_DIR, x2.RESULTS, x2.RAW

# ---------------------------------------------------------------- 计划原文的常量

COLUMN_PREFIX = x3.COLUMN_PREFIX                    # "What I have come to think: "
THOUGHT = "I thought: "                             # 产品 Life.Reflection / Mind.thought/1 的固定词
JUST_NOW = "Just now, "
NOBODY = "Nobody else is nearby."
STANDING = "is standing"
COLUMN_RE = re.compile("^" + re.escape(COLUMN_PREFIX) + x2.AGO_PREFIX.pattern + re.escape(THOUGHT) + "(.*)$")

# 各轮落栏 / 起槽时刻（UTC，任务说明给出）
LAND_R2 = "2026-11-14T12:27:42.288Z"
SLOT_R3 = "2026-11-14T12:37:52.201Z"
LAND_R6 = "2026-11-14T13:03:57.012Z"

# 计划“输入”一节：给了文件名（时间戳）的基准；值 = (计划写的时间戳, 对应句子的轮, 计划写的实跑选择, 计划写的处境)
GIVEN = {
    "L2f": ("20261114T122759.890Z", 2, "guard_hut", "nobody"),
    "L3f": ("20261114T123854.341Z", 3, "gather_stone", "nobody"),
    "L4f": ("20261114T124925.734Z", 4, "visit_plaza", "nobody"),
    "L8f": ("20261114T131822.190Z", 8, "guard_hut", "nobody"),
    "LVa": ("20261114T125724.896Z", None, "confront_wrecker", "corvin"),
    "LVb": ("20261114T125929.478Z", None, "guard_hut", "corvin"),
}
PLAN_ACTUAL = {"L2o": "guard_hut", "L6f": "guard_hut", **{k: v[2] for k, v in GIVEN.items()}}
BASE_ORDER = ("L2f", "L2o", "L3f", "L4f", "L6f", "L8f", "LVa", "LVb")

# 计划“变体”表：变体 -> 用在哪些基准
R6_TABLE = {
    "real": BASE_ORDER,
    "nocol": BASE_ORDER,
    "sx": ("L2f", "L2o", "L8f", "LVb"),
    "s3": ("L2f", "L8f"),
    "now": ("L2o",),
}
N3_TABLE = ("N3_R0", "N3_sx", "N3_s2", "N3_s8", "N3_s4")
N3_FILE = x3.BASES["N3"][0]                         # s1t/states/asked-20261113T164216.874Z.txt
EXPECTED_VARIANTS = 28

CANDS = ("build_hut", "gather_stone", "gather_limestone", "guard_hut", "visit_plaza", "confront_wrecker")
SHORT = {"build_hut": "build", "gather_stone": "stone", "gather_limestone": "lime", "guard_hut": "guard",
         "visit_plaza": "plaza", "confront_wrecker": "confront"}


def ms(iso):
    return x2.iso_ms(iso)


def stamp_ms(stamp):
    """'20261114T122759.890Z' -> Unix 毫秒。"""
    return x2.file_ms(stamp)


def state_file(stamp):
    return R6_STATES / f"asked-{stamp}.txt"


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


# ---------------------------------------------------------------- R6 的 state 与它的新栏

class R6State:
    """一份 R6 实跑 state：原文字节、各栏、新栏（多久以前, 句子）。"""

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
            m = COLUMN_RE.match(self.lines[col[0]])
            assert m, f"{path.name} 新栏不是 `<多久以前>I thought: <句>` 的写法"
            self.ago, self.sentence = m.group(1), m.group(2)
            assert self.lines[col[0] + 1].startswith("Current situation: "), f"{path.name} 新栏之后不是 Current situation"
        else:
            self.ago = self.sentence = None

    def body(self, title):
        return "\n".join(self.sections[title])[len(title) + 2:]

    def nobody(self):
        return NOBODY in self.body(x2.SITUATION)

    def standing(self):
        return STANDING in self.body(x2.SITUATION)

    def corvin_near(self):
        return "Nearby: Corvin (" in self.body(x2.SITUATION)


def load_r6_states():
    return sorted((R6State(p) for p in R6_STATES.glob("asked-*.txt")), key=lambda s: s.ms)


# ---------------------------------------------------------------- 句子

def round_row(k):
    """第 k 轮的行（只认 `-round<k>-row.json`，不认 archived / aborted），并断言 counts.rounds == k。"""
    (p,) = sorted(R6_ROWS.glob(f"*-round{k}-row.json"))
    refl = x2.read_json(p)["reflection"]
    assert refl["counts"]["rounds"] == k, f"{p.name} 的 counts.rounds 不是 {k}"
    return p, refl


def round_sentence(k):
    """第 k 轮“自己”一问的收尾一句（逐字）与该轮起槽时刻。"""
    p, refl = round_row(k)
    s = refl["latest"]["self"]
    assert s1x.one_line(s["closing"]) == s["closing"], f"第 {k} 轮收尾句含换行等"
    return dict(row=p.name, closing=s["closing"], at_ms=s["at_ms"], slot_ms=refl["round"]["at_ms"])


def sx_sentence():
    """sx：S1-X3 / S1-R6a 在 N3 上用的同一句（同一函数取），并核对 S1-R6a 落盘的 N3_label_now 里是同一句。"""
    (entry,) = x3.entries_for("selfplan", x3.BASES["N3"][1])
    s = entry[3]
    line = next(l for l in (LABEL_VARIANTS / "N3_label_now.txt").read_text(encoding="utf8").split("\n")
                if l.startswith(COLUMN_PREFIX))
    assert line == COLUMN_PREFIX + JUST_NOW + THOUGHT + s, "sx 与 S1-R6a 的 N3_label_now 新栏不逐字相同"
    return s


# ---------------------------------------------------------------- index.tsv 与服务端日志

def load_index():
    """index.tsv 的每行：dict(utc, top1, confidence, recall_ms, file, asked_recall_ms)。"""
    lines = R6_INDEX.read_text(encoding="utf8").splitlines()
    head = lines[0].split("\t")
    return [dict(zip(head, l.split("\t"))) for l in lines[1:]]


SELECT_RE = re.compile(r"(\d{2}):(\d{2}):(\d{2})\.(\d{3}) \[info\] npc_select cid=\d+ trigger=(\w+) candidates=\S+ "
                       r"chosen=(\w+) confidence=([\d.]+) latency_ms=(\d+) recall_ms=(\d+)")
PREPARE_RE = re.compile(r"(\d{2}):(\d{2}):(\d{2})\.(\d{3}) \[info\] voxel_source_prepare caller=\S+ at_us=(\d+)")
RUN_DAY = "2026-11-14"


def log_offset_ms(text):
    """服务端日志的时刻只有时分秒：用一行 voxel_source_prepare 的 at_us（Unix 微秒）定出它与 UTC 的整小时差。"""
    m = PREPARE_RE.search(text)
    hh, mm, ss, fr, at_us = m.groups()
    local = ms(f"{RUN_DAY}T{hh}:{mm}:{ss}.{fr}Z")
    diff = int(at_us) // 1000 - local
    hours = round(diff / 3_600_000)
    assert abs(diff - hours * 3_600_000) < 1000, "日志时刻与 at_us 的差不是整小时"
    return hours * 3_600_000


def load_selects():
    """服务端日志的 npc_select 行：[dict(utc_ms, trigger, chosen, confidence, latency_ms, recall_ms)]。"""
    text = SERVER_LOG.read_text(encoding="utf8", errors="replace")
    off = log_offset_ms(text)
    out = []
    for m in SELECT_RE.finditer(text):
        hh, mm, ss, fr, trig, chosen, conf, lat, rec = m.groups()
        out.append(dict(utc_ms=ms(f"{RUN_DAY}T{hh}:{mm}:{ss}.{fr}Z") + off, trigger=trig, chosen=chosen,
                        confidence=float(conf), latency_ms=int(lat), recall_ms=int(rec)))
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
                log_minus_file_ms=s["utc_ms"] - t, index_top1=row["top1"], index_agrees=row["top1"] == s["chosen"])


# ---------------------------------------------------------------- 选基准

def pick_bases(states, sentences):
    """返回 {标签: dict(state, how, ...)}。给了时间戳的直接用（不存在时按 index.tsv 的 utc 列对到 file 列，并报告）；
    L2o、L6f 按计划文字挑。每份都核对计划写的处境与新栏来源。"""
    by_name = {s.path.name: s for s in states}
    index = load_index()
    picked = {}
    for label, (stamp, k, _, situ) in GIVEN.items():
        how = "计划给的文件名"
        if not state_file(stamp).exists():
            iso = f"{stamp[:4]}-{stamp[4:6]}-{stamp[6:8]}T{stamp[9:11]}:{stamp[11:13]}:{stamp[13:]}"
            rows = [r for r in index if r["utc"] == iso and not r["file"].startswith(("MISMATCH", "-"))]
            assert len(rows) == 1, f"{label}：计划写的 {stamp} 既不是 state 文件名也对不上 index.tsv 的 utc 列"
            how = f"计划写的 …{stamp[9:]} 不是文件名，是 index.tsv 的 utc 列；同一行 file 列 = {rows[0]['file']}"
            fname = rows[0]["file"]
            assert abs(x2.file_ms(fname) - stamp_ms(stamp)) < 50, f"{label} 的 utc 与 file 相差过大"
        else:
            fname = state_file(stamp).name
        picked[label] = dict(state=by_name[fname], how=how, round=k, situation=situ)
    # L2o：第 2 轮落栏之后、第 3 轮起槽之前最后一份“无人、小屋立着、含第 2 轮新栏”的 state
    l2o = [s for s in states if ms(LAND_R2) < s.ms < ms(SLOT_R3) and s.nobody() and s.standing()
           and s.sentence == sentences["s2"]]
    picked["L2o"] = dict(state=l2o[-1], round=2, situation="nobody",
                         how=f"{LAND_R2[11:]} < t < {SLOT_R3[11:]}、无人、小屋立着、新栏是第 2 轮那句的最后一份（共 {len(l2o)} 份合格）")
    # L6f：第 6 轮落栏之后第一份“无人、小屋立着、含第 6 轮新栏”的 state
    l6f = [s for s in states if s.ms > ms(LAND_R6) and s.nobody() and s.standing() and s.sentence == sentences["s6"]]
    first_after = next(s for s in states if s.ms > ms(LAND_R6))
    picked["L6f"] = dict(state=l6f[0], round=6, situation="nobody",
                         how=f"t > {LAND_R6[11:]} 且无人、小屋立着、新栏是第 6 轮那句的第一份（落栏后第一份 state 是 {first_after.path.name}）")
    # 核对：处境、小屋立着、都含新栏；“第 k 轮落栏后第一份”= 含第 k 轮那句的第一份 state
    checks = []
    for label in BASE_ORDER:
        p = picked[label]
        s = p["state"]
        assert s.col_i is not None and s.standing(), f"{label} {s.path.name} 没有新栏或小屋不是立着"
        if p["situation"] == "nobody":
            assert s.nobody(), f"{label} {s.path.name} 不是无人"
        else:
            assert s.corvin_near(), f"{label} {s.path.name} 附近没有 Corvin"
        k = p["round"]
        if k is not None and label.endswith("f"):
            first = next(t for t in states if t.sentence == sentences[f"s{k}"])
            first_nobody = next(t for t in states if t.sentence == sentences[f"s{k}"] and t.nobody())
            checks.append(f"{label}: 含第 {k} 轮那句的第一份 = {first.path.name}，其中第一份无人的 = {first_nobody.path.name}")
            assert first_nobody is s, f"{label} 不是第 {k} 轮落栏后第一份无人的 state"
            if label != "L6f":
                assert first is s, f"{label} 不是第 {k} 轮落栏后第一份 state"
    # 第 2 轮落栏时刻核对：L2f 在落栏之后，且落栏前最后一份 state 不含第 2 轮那句
    last_before = [s for s in states if s.ms < ms(LAND_R2)][-1]
    assert picked["L2f"]["state"].ms > ms(LAND_R2) and last_before.sentence != sentences["s2"]
    # 实跑选了什么：以服务端日志为准
    selects, off = load_selects()
    for label in BASE_ORDER:
        p = picked[label]
        p["actual"] = actual_choice(p["state"].path.name, index, selects)
        p["plan_actual"] = PLAN_ACTUAL[label]
    return picked, checks, dict(log_offset_h=off // 3_600_000, npc_select_lines=len(selects))


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
    """生成 28 个变体并做自检 ① ② ③ ④；返回 (texts, notes, order)。"""
    texts, notes, order = {}, {}, []
    selfcheck = {"①": [], "②": [], "③": [], "④": None}

    def add(name, text, note):
        texts[name] = text
        order.append(name)
        notes[name] = dict(note, state_chars=len(text))
        x2.write_text(VARIANTS_DIR / f"{name}.txt", text)

    for variant, labels in R6_TABLE.items():
        for label in labels:
            base = bases[label]["state"]
            name = f"{label}_{variant}"
            if variant == "real":
                text = base.text
            elif variant == "nocol":
                text = replace_column(base, None)
            elif variant == "now":
                text = replace_column(base, COLUMN_PREFIX + JUST_NOW + THOUGHT + base.sentence)
            else:   # sx / s3：只换句子，句首“多久以前”不动
                text = replace_column(base, COLUMN_PREFIX + base.ago + THOUGHT + sentences[variant])
            col = next((l for l in text.split("\n") if l.startswith(COLUMN_PREFIX)), None)
            add(name, text, dict(base=label, base_state=base.path.name, kind=variant, template="R6",
                                 column=col[len(COLUMN_PREFIX):] if col else None))
            if variant == "real":
                assert text.encode("utf8") == base.raw, f"{name} 与原 state 不逐字节相同"
                selfcheck["①"].append(name)
            else:
                rem, addl = changed_lines(base.text, text)
                assert rem == [base.lines[base.col_i]], f"{name} 删掉的行不是恰好新栏那一行：{len(rem)}"
                assert len(addl) == (0 if variant == "nocol" else 1), f"{name} 加上的行数不对：{len(addl)}"
                selfcheck["③"].append((name, max(len(rem), len(addl))))

    n3_raw = (x2.STATES_DIR / N3_FILE).read_bytes()
    n3 = n3_raw.decode("utf8")
    assert COLUMN_PREFIX not in n3, "N3 基准里已有新栏"
    for name in N3_TABLE:
        key = name.split("_", 1)[1]
        if key == "R0":
            text = n3
        else:
            text, _ = x2.insert_column(n3, [JUST_NOW + THOUGHT + sentences[key]])   # 同 S1-R6a 的 label_now
        col = next((l for l in text.split("\n") if l.startswith(COLUMN_PREFIX)), None)
        add(name, text, dict(base="N3", base_state=N3_FILE, kind=key, template="S1-T",
                             column=col[len(COLUMN_PREFIX):] if col else None))
        if key == "R0":
            assert text.encode("utf8") == n3_raw, "N3_R0 与 S1-T 原 state 不逐字节相同"
        else:
            rem, addl = changed_lines(n3, text)
            assert rem == [] and addl == [col], f"{name} 与 N3 不是只多新栏那一行"
            selfcheck["③"].append((name, 1))
        if key in ("R0", "sx"):
            want = (LABEL_VARIANTS / {"R0": "N3_R0.txt", "sx": "N3_label_now.txt"}[key]).read_bytes()
            assert text.encode("utf8") == want, f"{name} 与 s1r6/label/variants/ 不逐字节相同"
            selfcheck["②"].append(name)

    assert len(order) == EXPECTED_VARIANTS, f"变体数 {len(order)} != {EXPECTED_VARIANTS}"
    selfcheck["④"] = len(order)
    x2.write_json(VARIANTS_DIR / "notes.json", notes)
    return texts, notes, order, selfcheck


def nocol_format(states, bases):
    """“去掉”与“从没有这一栏”的写法一致：对照实跑里不含新栏的最后一份 state（与 L8f 同一段之前），
    看 Current situation 前一行的形态与其后是否紧接、全文有无空行。"""
    ref = [s for s in states if s.col_i is None][-1]

    def around(text):
        lines = text.split("\n")
        i = next(n for n, l in enumerate(lines) if l.startswith("Current situation: "))
        return lines[i - 1], "" in lines, lines.count("")

    r_prev, r_blank, r_n = around(ref.text)
    rows = []
    for label in BASE_ORDER:
        base = bases[label]["state"]
        text = replace_column(base, None)
        prev, blank, n = around(text)
        assert prev == base.lines[base.col_i - 1] and prev.strip() and prev[:2] == r_prev[:2], f"{label}_nocol 栏间形态不对"
        assert n == base.text.split("\n").count(""), f"{label}_nocol 空行数变了"
        rows.append((label, prev[:24], n))
    return dict(reference=ref.path.name, reference_prev=r_prev[:24], reference_blank_lines=r_n, nocol=rows)


# ---------------------------------------------------------------- 只记录项

def record_only(bases, sentences):
    out = {}
    for label in BASE_ORDER:
        s = bases[label]["state"]
        mem = [l for i, l in enumerate(s.sections[x2.MEM]) if not l.startswith(COLUMN_PREFIX)]   # 不含新栏那一行
        out[label] = dict(state=s.path.name, chars=len(s.text), ago=s.ago,
                          remember_guard_lines=sum("guard" in l for l in mem),
                          remember_guard_lines_ci=sum("guard" in l.lower() for l in mem),
                          recent_activities=s.body("Recent activities"))
    n3 = (x2.STATES_DIR / N3_FILE).read_text(encoding="utf8")
    sec = dict(x2.state_sections(n3))
    out["N3"] = dict(state=N3_FILE, chars=len(n3), ago=None,
                     remember_guard_lines=sum("guard" in l for l in sec[x2.MEM]),
                     remember_guard_lines_ci=sum("guard" in l.lower() for l in sec[x2.MEM]),
                     recent_activities="\n".join(sec["Recent activities"])[len("Recent activities: "):])
    return out, {k: len(v) for k, v in sentences.items()}


# ---------------------------------------------------------------- 发问

def question(path):
    tpl = x2.read_json(path)
    return ({"activity": {"criteria": {c["name"]: c["criterion"] for c in tpl["candidates"]},
                          "instructions": tpl["instructions"], "type": "choice"}},
            [c["name"] for c in tpl["candidates"]])


def run_jev(texts, notes, order):
    """同 s1x2_reflect.run_jev 的语义（并发 <= 3；401 / 403 / 429 / quota / 连接错误即停，未发的不再发；其它失败记下不补问），
    区别只有两处：每个变体按 notes 的 template 用 R6 或 S1-T 的问法；返回值不含 model 名。"""
    for k in ("TYPESAFE_API_URL", "TYPESAFE_API_KEY", "TYPESAFE_MODEL"):
        if not os.environ.get(k):
            x2.stop(f"环境变量 {k} 没有设置")
    qs = {"R6": question(R6_TEMPLATE), "S1-T": question(S1T_TEMPLATE)}
    assert qs["R6"][1] == qs["S1-T"][1] == list(CANDS), "两份模板的候选与预期不同"
    halt, halted = threading.Event(), []

    def one(cell):
        name, rep = cell
        row = dict(repeat=rep, ok=False, top1=None, probs=None, latency_ms=None, error=None)
        if halt.is_set():
            row["error"] = "not sent (stopped)"
            return name, row
        try:
            answers, seconds = s1q.jev_ask(texts[name], qs[notes[name]["template"]][0], timeout=x2.JEV_TIMEOUT_S)
        except Exception as ex:  # 连接 / 超时
            halt.set()
            halted.append(f"Jev {name} r{rep}: {type(ex).__name__}: {ex}")
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

    cells = [(n, r + 1) for n in order for r in range(x2.JEV_REPEATS)]
    started = s1q.now_iso()
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
        variants.append(dict(variant=name, template=notes[name]["template"], state_chars=len(texts[name]),
                             top1_counts=top, top1=lead[0] if lead else None, avg_probs=avg,
                             failed=len(rows) - len(ok), requests=rows))
    return dict(model_is_jev_latest=os.environ["TYPESAFE_MODEL"] == "jev-latest", repeats=x2.JEV_REPEATS,
                workers=x2.JEV_WORKERS, timeout_s=x2.JEV_TIMEOUT_S, retries=0, candidates=list(CANDS),
                started=started, finished=s1q.now_iso(), requests=len(got), answered=sum(r["ok"] for _, r in got),
                stopped="; ".join(halted) or None, variants=variants)


# ---------------------------------------------------------------- 按计划口径的机械读数（不下结论）

def w_readings(v, bases, prior):
    """W1–W9 的读数与按口径的机械比较；口径有歧义处两种读法都给。v = {变体: 读数}；prior = S1-R6a 的 N3 读数。"""
    top = lambda n: v[n]["top1"]                                       # noqa: E731  >= 3/4 的那个，否则 None
    p = lambda n, c: v[n]["avg_probs"][c]                              # noqa: E731
    gather = lambda n: p(n, "gather_stone") + p(n, "gather_limestone")  # noqa: E731
    w = {}
    hits = [(b, top(f"{b}_real"), bases[b]["actual"]["chosen"]) for b in BASE_ORDER]
    w["W1"] = dict(rows=hits, n_match=sum(t == a for _, t, a in hits), holds=sum(t == a for _, t, a in hits) >= 7)
    d_r0 = abs(p("N3_R0", "guard_hut") - prior["N3_R0"]["guard_hut"])
    d_sx = abs(p("N3_sx", "gather_stone") - prior["N3_label_now"]["gather_stone"])
    w["W2"] = dict(N3_R0=(top("N3_R0"), round(d_r0, 3)), N3_sx=(top("N3_sx"), round(d_sx, 3)),
                   holds=top("N3_R0") == "guard_hut" and top("N3_sx") == "gather_stone" and d_r0 < .10 and d_sx < .10)
    w3 = [(b, top(f"{b}_real"), top(f"{b}_nocol"), round(abs(p(f"{b}_real", "guard_hut") - p(f"{b}_nocol", "guard_hut")), 3))
          for b in ("L2f", "L2o", "L6f", "L8f")]
    w["W3"] = dict(rows=w3, holds=all(r == n == "guard_hut" and d < .20 for _, r, n, d in w3))
    w["W4"] = dict(real=top("L3f_real"), nocol=top("L3f_nocol"),
                   holds=top("L3f_real") == "gather_stone" and top("L3f_nocol") == "guard_hut")
    w5a = [(n, top(n)) for n in ("L2f_sx", "L8f_sx")]
    w5b = [(n, top(n), round(p(n, "gather_stone"), 3)) for n in ("N3_s2", "N3_s8")]
    w["W5"] = dict(sx=w5a, n3=w5b, holds=all(t == "gather_stone" for _, t in w5a)
                   and all(t == "guard_hut" or s < .50 for _, t, s in w5b))
    w6 = [(n, top(n), round(gather(n), 3)) for n in ("L2f_s3", "L8f_s3")]
    w["W6"] = dict(rows=w6, holds_sum_only=all(g >= .50 for _, _, g in w6),
                   holds_top1_and_sum=all(t in ("gather_stone", "gather_limestone") and g >= .50 for _, t, g in w6))
    dg = gather("L2o_now") - gather("L2o_real")
    w["W7"] = dict(gather_real=round(gather("L2o_real"), 3), gather_now=round(gather("L2o_now"), 3), delta=round(dg, 3),
                   top1_now=top("L2o_now"), holds=dg >= .10 and top("L2o_now") == "guard_hut")
    w["W8"] = dict(LVb_nocol=top("LVb_nocol"), LVa_real=top("LVa_real"), LVa_nocol=top("LVa_nocol"),
                   holds=top("LVb_nocol") == top("LVa_real") == top("LVa_nocol") == "confront_wrecker")
    w["W9"] = dict(N3_s4=top("N3_s4"), holds=top("N3_s4") == "visit_plaza")
    return w


# ---------------------------------------------------------------- 主流程

def fmt_probs(avg):
    return "/".join("—" if avg[c] is None else f"{avg[c]:.3f}".lstrip("0") if avg[c] else "0" for c in CANDS)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="不发请求：只选基准、生成变体、做四项自检、打印")
    a = ap.parse_args()
    before = tree_digest(READ_ONLY)

    states = load_r6_states()
    sents = {f"s{k}": round_sentence(k) for k in (2, 3, 4, 6, 8)}
    assert sents["s3"]["slot_ms"] == ms(SLOT_R3), "第 3 轮起槽时刻与任务说明不同"
    sentences = {k: v["closing"] for k, v in sents.items()}
    sentences["sx"] = sx_sentence()
    bases, pick_checks, log_info = pick_bases(states, sentences)
    # 句子断言：第 k 轮那句等于该轮落栏后第一份 state 新栏里 I thought: 之后的部分（L2f/L3f/L4f/L8f；L6f 同理）
    for label, k in (("L2f", 2), ("L3f", 3), ("L4f", 4), ("L6f", 6), ("L8f", 8)):
        assert bases[label]["state"].sentence == sentences[f"s{k}"], f"{label} 新栏句子不等于第 {k} 轮收尾句"
    texts, notes, order, selfcheck = build(bases, sentences)
    fmt = nocol_format(states, bases)
    record, sent_chars = record_only(bases, sentences)
    tpl_same = R6_TEMPLATE.read_bytes() == S1T_TEMPLATE.read_bytes()

    print(f"服务端日志与 UTC 相差 {log_info['log_offset_h']} 小时（由 voxel_source_prepare 的 at_us 定）；npc_select {log_info['npc_select_lines']} 行")
    print("基准：")
    for label in BASE_ORDER:
        b = bases[label]
        act = b["actual"]
        flag = "" if act["chosen"] == b["plan_actual"] else f"  ≠ 计划写的 {b['plan_actual']}"
        idx = "" if act["index_agrees"] else f"  （index.tsv 写 {act['index_top1']}）"
        print(f"  {label}: {b['state'].path.name}  句首 {b['state'].ago!r}  实跑 {act['chosen']} {act['confidence']} "
              f"recall_ms={act['recall_ms']} trigger={act['trigger']} 日志-文件={act['log_minus_file_ms']} ms{idx}{flag}")
        print(f"       依据：{b['how']}")
    for c in pick_checks:
        print(f"  核对 {c}")
    print(f"去栏格式：对照无新栏的 {fmt['reference']}（Current situation 前一行 {fmt['reference_prev']!r}…，空行 "
          f"{fmt['reference_blank_lines']}）；各 nocol 前一行 / 空行 {fmt['nocol']}")
    print(f"两份模板逐字节相同：{tpl_same}")
    print("句子（字数）：")
    for k in ("s2", "s3", "s4", "s8", "sx"):
        print(f"  {k} ({sent_chars[k]}): {sentences[k]}")
    print(f"自检 ① real 逐字节同原 state：{len(selfcheck['①'])} 个；② 同 S1-R6a：{selfcheck['②']}；"
          f"③ 只差新栏一行：{len(selfcheck['③'])} 个，diff 行数 {sorted(set(n for _, n in selfcheck['③']))}；④ 变体数 {selfcheck['④']}")
    for name in order:
        n = notes[name]
        print(f"  {name:10} [{n['template']:4}] state={n['state_chars']:5}  {(n['column'] or '(无新栏)')[:70]}")
    print("只记录（基准）：")
    for k, r in record.items():
        print(f"  {k}: {r['chars']} 字，What I remember 含 guard {r['remember_guard_lines']} 行（不分大小写 "
              f"{r['remember_guard_lines_ci']}），Recent activities: {r['recent_activities']}")
    if a.dry_run:
        assert tree_digest(READ_ONLY) == before, "只读目录在 dry-run 中被改动"
        print(f"只读目录哈希（前后相同）：{before}")
        return

    if not os.environ.get("TYPESAFE_API_KEY"):
        s1q.load_env()   # 只读主检出 .env 的 TYPESAFE_* 进本进程环境，不打印
    x2.log(f"s1r6b jev start: {len(order)} 变体 x {x2.JEV_REPEATS} 次，并发 <= {x2.JEV_WORKERS}，"
           f"超时 {x2.JEV_TIMEOUT_S} s；只读目录哈希 {before}")
    data = run_jev(texts, notes, order)
    after = tree_digest(READ_ONLY)
    prior = {v["variant"]: v["avg_probs"] for v in x2.read_json(R6 / "label" / "results.json")["variants"]}
    by = {v["variant"]: v for v in data["variants"]}
    complete = not data["stopped"] and all(v["failed"] == 0 for v in data["variants"])
    data.update(variant_notes=notes, sentences=sentences, sentence_chars=sent_chars,
                bases={k: dict(state=b["state"].path.name, how=b["how"], ago=b["state"].ago, actual=b["actual"],
                               plan_actual=b["plan_actual"]) for k, b in bases.items()},
                pick_checks=pick_checks, server_log=log_info, nocol_format=fmt, record_only=record,
                templates_byte_identical=tpl_same, selfcheck={k: v for k, v in selfcheck.items()},
                w_readings=w_readings(by, bases, prior) if complete else None,
                read_only_digest=dict(before=before, after=after, same=before == after))
    x2.write_json(RESULTS, data)
    for v in data["variants"]:
        x2.log(f"jev {v['variant']} top1={v['top1_counts']} avg={fmt_probs(v['avg_probs'])} failed={v['failed']}")
    if complete:
        for k, r in data["w_readings"].items():
            x2.log(f"{k} {json.dumps(r, ensure_ascii=False)}")
    x2.log(f"只读目录哈希 after {after} same={before == after}")
    if before != after:
        x2.stop("只读目录的哈希运行前后不同")
    if data.get("stopped"):
        x2.stop(data["stopped"])


if __name__ == "__main__":
    main()
