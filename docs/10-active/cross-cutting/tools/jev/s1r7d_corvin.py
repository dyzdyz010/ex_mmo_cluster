#!/usr/bin/env python
"""S1-R7d：Corvin 再来时为什么不对质——“最近做过的事”只留 5 件，是不是它在管。只问 Jev 的离线对照。探索性，不是验收。

是什么
  按 .demo/observe/npc-slice1-20261112/s1r7/corvin-plan.md（唯一规格；期望与变体一条不改）的变体表，
  用 R6、R7 实跑里 Corvin 在场的 12 份真实 state（R6 6 份、R7 6 份），生成 21 个变体：
  12 个 real（原样）+ C+ 9 份各一个 delra（只从 `Recent activities` 删掉 `confront_wrecker: completed.` 那一项），
  每变体问 Jev 6 次（126 个请求），每个变体记全六个候选的逐次与平均概率。只给读数，不判 D1–D4。
为什么
  不花额度的核对显示：`Recent activities`（产品 Selector 的 `@recent 5`）里没有 confront_wrecker 的 3 份实跑都对质，
  有的 9 份都没对质；但同一份 state 的 `What just happened` 也写着那次对质，所以只是相关。本轮删掉窗口里那一项看变不变。
输入（全部是真实导出或对它的删减，不生造）
  - 基准 state：s1r6/states、s1r7/states 下计划写的 12 个文件，一字不改。实跑选择以各自 states/index.tsv 为准，
    再按服务端日志（s1r6/server-s1r6.log、s1r7/server-s1r7.log；时刻是 UTC-8，由 voxel_source_prepare 的 at_us
    定出整小时差）的 npc_select 行核一遍（时刻 ±5 s 且 recall_ms 相同的恰一行），与计划写的实跑核对，不符只报告。
  - 分组：`Recent activities` 一行含 `confront_wrecker` = C+，不含 = C−；断言与计划写的 C− 3 份相同。
  - 问法 / 候选：各自那一场的 export/request-template.json；断言两场候选逐字相同。
怎么构造
  - delra：只在 `Recent activities` 一行里删掉 `confront_wrecker: completed.` 这一项和与它相邻的一个空格
    （在行中间时删它后面的空格；在行末时它后面没有空格，删它前面的那个），让项间仍是单个空格；
    断言每份 C+ 恰有一项；其余逐字不动（`What just happened` 里的对质不动）。
自检（--dry-run 里做，全过才发请求）
  ① 12 个 real 与原 state 逐字节相同；② 每个 delra 与它的 real 只差 `Recent activities` 一行，且差的恰是那一项
  （加一个空格）；③ 变体总数 21。
落盘
  只写 s1r7/corvin/（variants/、raw/、results.json、run.log）。s1r6/states、s1r6/export、s1r7/states、s1r7/export
  只读：运行前后各算一次全部文件的哈希汇总，必须相同（不同就停）。
凭据
  Jev 的 TYPESAFE_API_URL / TYPESAFE_API_KEY / TYPESAFE_MODEL：进程环境里没有时，用 s1q.load_env 只从主检出
  D:/hemifuture/ex_mmo_cluster/.env 读 TYPESAFE_* 进本进程环境；值不打印、不写文件（results.json 不记 model 名，
  只记它是否等于实跑日志里的 jev-latest）。
发问
  并发 <= 3，单请求超时 60 s；401 / 403 / 429 / 正文含 quota / 连接错误（含超时）即停，未发的不再发，不重试、不补问。
  请求体与请求头同 s1q.jev_ask；整个运行只用一个 httpx.Client（连接池上限 3、不重试），任何退出路径都关闭它。
  top1 = 6 次里出现最多且 >= 4 次的那个，否则无 top1。

怎么运行（Git Bash；仓库根下）
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r7d_corvin.py --dry-run   # 只取基准、生成变体与自检，不发请求
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r7d_corvin.py             # 自检全过才发请求
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
import s1x3_variants as x3  # noqa: E402  导入时它把 s1x2_reflect / s1v 的落盘常量指到 s1x3/；下面再改指到 s1r7/corvin/

x2 = x3.x2
s1x, s1v, s1q = x2.s1x, x2.s1v, x2.s1q

# ---------------------------------------------------------------- 路径：只读输入与落盘目录

S1 = x2.S1
RUNS = {
    "R6": dict(dir=S1 / "s1r6", log=S1 / "s1r6" / "server-s1r6.log"),
    "R7": dict(dir=S1 / "s1r7", log=S1 / "s1r7" / "server-s1r7.log"),
}
READ_ONLY = (S1 / "s1r6" / "states", S1 / "s1r6" / "export", S1 / "s1r7" / "states", S1 / "s1r7" / "export")

OUT = S1 / "s1r7" / "corvin"
s1v.configure(x2.COPY_BANK, str(OUT))    # s1v 的落盘常量与 s1q.RAW 都指到 s1r7/corvin/（本脚本不调 s1v 的写函数，只防误写）
x2.OUT, x2.RAW, x2.LOG = OUT, OUT / "raw", OUT / "run.log"
x2.VARIANTS_DIR, x2.RESULTS, x2.DRYRUN = OUT / "variants", OUT / "results.json", OUT / "dryrun"
x3.OUT, x3.VARIANTS_DIR, x3.RESULTS = OUT, x2.VARIANTS_DIR, x2.RESULTS   # 本脚本不调 x3.build，只防误写
VARIANTS_DIR, RESULTS, RAW = x2.VARIANTS_DIR, x2.RESULTS, x2.RAW

# ---------------------------------------------------------------- 计划原文的常量

RA = "Recent activities"
RA_PREFIX = RA + ": "
CONFRONT = "confront_wrecker"
ITEM = "confront_wrecker: completed."
COLUMN_PREFIX = x3.COLUMN_PREFIX                    # "What I have come to think: "
NEARBY_CORVIN = re.compile(r"Nearby: [^.]*?Corvin \(NPC, actor \d+, [\d.]+ m away\)[^.]*?\.(?= |$)")

# 计划“输入”一节：标签 -> (场次, 时间戳, 计划写的实跑选择, 计划写的置信度)
GIVEN = {
    "R6_125724": ("R6", "20261114T125724.890Z", "confront_wrecker", 0.87),
    "R6_125800": ("R6", "20261114T125800.050Z", "guard_hut", 0.52),
    "R6_125855": ("R6", "20261114T125855.818Z", "guard_hut", 0.45),
    "R6_125929": ("R6", "20261114T125929.473Z", "guard_hut", 0.59),
    "R6_130001": ("R6", "20261114T130001.616Z", "guard_hut", 0.59),
    "R6_130034": ("R6", "20261114T130034.260Z", "guard_hut", 0.46),
    "R7_171005": ("R7", "20261114T171005.061Z", "confront_wrecker", 0.82),
    "R7_171039": ("R7", "20261114T171039.721Z", "guard_hut", 0.27),
    "R7_171113": ("R7", "20261114T171113.369Z", "visit_plaza", 0.24),
    "R7_171258": ("R7", "20261114T171258.830Z", "guard_hut", 0.23),
    "R7_171333": ("R7", "20261114T171333.989Z", "confront_wrecker", 0.36),
    "R7_171409": ("R7", "20261114T171409.150Z", "guard_hut", 0.32),
}
BASE_ORDER = tuple(GIVEN)
PLAN_C_MINUS = ("R6_125724", "R7_171005", "R7_171333")
EXPECTED_VARIANTS = 21
REPEATS = 6
TOP1_MIN = 4

CANDS = ("build_hut", "gather_stone", "gather_limestone", "guard_hut", "visit_plaza", "confront_wrecker")


def ms(iso):
    return x2.iso_ms(iso)


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


# ---------------------------------------------------------------- 一份 state

class CorvinState:
    """一份实跑 state：原文字节、各栏、`Recent activities` 那一行。"""

    def __init__(self, run, path):
        self.run = run
        self.path = path
        self.raw = path.read_bytes()
        self.text = self.raw.decode("utf8")
        self.lines = self.text.split("\n")
        self.ms = x2.file_ms(path.name)
        self.sections = dict(x2.state_sections(self.text))
        ra = [i for i, l in enumerate(self.lines) if l.startswith(RA_PREFIX)]
        assert len(ra) == 1, f"{path.name} 的 Recent activities 行有 {len(ra)} 行"
        self.ra_i = ra[0]
        assert self.sections[RA] == [self.lines[self.ra_i]], f"{path.name} 的 Recent activities 栏不止一行"
        col = [l for l in self.lines if l.startswith(COLUMN_PREFIX)]
        assert len(col) <= 1, f"{path.name} 新栏不止一行"
        self.column = col[0] if col else None

    @property
    def ra_line(self):
        return self.lines[self.ra_i]

    def body(self, title):
        return "\n".join(self.sections[title])[len(title) + 2:]

    def situation_line(self):
        (line,) = [l for l in self.lines if l.startswith(x2.SITUATION + ": ")]
        return line

    def corvin_nearby(self):
        m = NEARBY_CORVIN.search(self.situation_line())
        return m.group(0) if m else None

    def wjh_confront_items(self):
        """`What just happened` 按“多久以前”切成条，返回提到 confront_wrecker 的条：[(多久以前, 全文)]。"""
        body = self.body(x2.WJH)
        starts = [m.start() for m in x2.AGO_PREFIX.finditer(body)]
        items = [body[a:b].strip() for a, b in zip(starts, starts[1:] + [len(body)])]
        return [(x2.AGO_PREFIX.match(it).group(1).rstrip(", "), it) for it in items if CONFRONT in it]


# ---------------------------------------------------------------- index.tsv 与服务端日志

def load_index(run):
    lines = (RUNS[run]["dir"] / "states" / "index.tsv").read_text(encoding="utf8").splitlines()
    head = lines[0].split("\t")
    return [dict(zip(head, l.split("\t"))) for l in lines[1:]]


SELECT_RE = re.compile(r"(\d{2}):(\d{2}):(\d{2})\.(\d{3}) \[info\] npc_select cid=\d+ trigger=(\w+) candidates=\S+ "
                       r"chosen=(\w+) confidence=([\d.]+) latency_ms=(\d+) recall_ms=(\d+) model=(\S+)")
PREPARE_RE = re.compile(r"(\d{2}):(\d{2}):(\d{2})\.(\d{3}) \[info\] voxel_source_prepare caller=\S+ at_us=(\d+)")
LOG_DAY = "2026-11-14"   # 两场日志的本地日期（UTC-8 的凌晨 / 上午，都是同一天）


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


def load_selects(run):
    text = RUNS[run]["log"].read_text(encoding="utf8", errors="replace")
    off = log_offset_ms(text)
    out = []
    for m in SELECT_RE.finditer(text):
        hh, mm, ss, fr, trig, chosen, conf, lat, rec, model = m.groups()
        out.append(dict(utc_ms=ms(f"{LOG_DAY}T{hh}:{mm}:{ss}.{fr}Z") + off, trigger=trig, chosen=chosen,
                        confidence=float(conf), latency_ms=int(lat), recall_ms=int(rec), model=model))
    return out, off


def actual_choice(fname, index, selects):
    """一份 state 实跑选了什么：index.tsv 里 file 列恰是它的行；服务端日志里在文件时刻 ±5 s 内、
    recall_ms 相同的 npc_select 行必须恰好一行。"""
    rows = [r for r in index if r["file"] == fname]
    assert len(rows) == 1, f"index.tsv 里 file 列是 {fname} 的行有 {len(rows)} 行"
    row = rows[0]
    t = x2.file_ms(fname)
    hits = [s for s in selects if abs(s["utc_ms"] - t) <= 5000 and s["recall_ms"] == int(row["asked_recall_ms"])]
    assert len(hits) == 1, f"{fname}：服务端日志里对上的 npc_select 行有 {len(hits)} 行"
    s = hits[0]
    return dict(index_top1=row["top1"], index_confidence=float(row["confidence"]), index_trigger=row["trigger"],
                log_chosen=s["chosen"], log_confidence=s["confidence"], recall_ms=s["recall_ms"],
                log_trigger=s["trigger"], model_is_jev_latest=s["model"] == "jev-latest", log_utc=utc(s["utc_ms"]),
                log_minus_file_ms=s["utc_ms"] - t,
                index_agrees_log=row["top1"] == s["chosen"] and abs(float(row["confidence"]) - s["confidence"]) < 1e-9)


# ---------------------------------------------------------------- 取基准、分组、核对

def pick_bases():
    """返回 ({标签: dict(state, group, actual, ...)}, 日志信息)。"""
    logs, picked = {}, {}
    for run in RUNS:
        selects, off = load_selects(run)
        logs[run] = dict(index=load_index(run), selects=selects, off=off)
    for label, (run, stamp, plan_choice, plan_conf) in GIVEN.items():
        s = CorvinState(run, RUNS[run]["dir"] / "states" / f"asked-{stamp}.txt")
        assert s.corvin_nearby(), f"{label} 的 Current situation 里附近没有 Corvin"
        group = "C+" if CONFRONT in s.ra_line else "C-"
        act = actual_choice(s.path.name, logs[run]["index"], logs[run]["selects"])
        picked[label] = dict(state=s, run=run, group=group, actual=act, plan_actual=plan_choice,
                             plan_confidence=plan_conf,
                             index_matches_plan=act["index_top1"] == plan_choice
                             and abs(act["index_confidence"] - plan_conf) < 1e-9,
                             log_matches_plan=act["log_chosen"] == plan_choice
                             and abs(act["log_confidence"] - plan_conf) < 1e-9)
    got_minus = tuple(l for l in BASE_ORDER if picked[l]["group"] == "C-")
    assert got_minus == PLAN_C_MINUS, f"C− 分组 {got_minus} 与计划 {PLAN_C_MINUS} 不同"
    info = {run: dict(log_offset_h=v["off"] // 3_600_000, npc_select_lines=len(v["selects"])) for run, v in logs.items()}
    return picked, info


def questions():
    """各场的问法与候选；断言两场候选逐字相同、名单与 CANDS 相同。"""
    tpls = {run: x2.read_json(v["dir"] / "export" / "request-template.json") for run, v in RUNS.items()}
    assert tpls["R6"]["candidates"] == tpls["R7"]["candidates"], "R6、R7 模板的候选不逐字相同"
    out = {}
    for run, tpl in tpls.items():
        names = [c["name"] for c in tpl["candidates"]]
        assert names == list(CANDS), f"{run} 模板的候选与预期不同"
        out[run] = {"activity": {"criteria": {c["name"]: c["criterion"] for c in tpl["candidates"]},
                                 "instructions": tpl["instructions"], "type": "choice"}}
    same_instr = tpls["R6"]["instructions"] == tpls["R7"]["instructions"]
    return out, dict(candidates_identical=True, instructions_identical=same_instr)


# ---------------------------------------------------------------- 变体

def delete_item(line):
    """在 `Recent activities` 一行里删掉 ITEM 和相邻的一个空格；返回 (新行, 删掉的子串, 删的是哪边的空格)。"""
    assert line.count(ITEM) == 1, f"Recent activities 里 `{ITEM}` 有 {line.count(ITEM)} 项"
    assert line.count(CONFRONT) == 1, f"Recent activities 里 {CONFRONT} 出现 {line.count(CONFRONT)} 次"
    i = line.index(ITEM)
    assert line[i - 1] == " ", "该项前面不是空格"
    j = i + len(ITEM)
    if j < len(line):
        assert line[j] == " ", "该项后面不是空格"
        removed, side = line[i:j + 1], "after"
        new = line[:i] + line[j + 1:]
    else:
        removed, side = line[i - 1:j], "before (item is last)"
        new = line[:i - 1]
    assert "  " not in new and not new.endswith(" ") and new.startswith(RA_PREFIX), "删后空格不对"
    return new, removed, side


def changed_lines(a, b):
    rem, add = [], []
    for op in difflib.ndiff(a.split("\n"), b.split("\n")):
        if op.startswith("- "):
            rem.append(op[2:])
        elif op.startswith("+ "):
            add.append(op[2:])
    return rem, add


def build(bases):
    """生成 21 个变体并做自检 ① ② ③；返回 (texts, notes, order, selfcheck)。"""
    texts, notes, order = {}, {}, []
    selfcheck = {"①": [], "②": [], "③": None}
    table = (("real", BASE_ORDER), ("delra", tuple(l for l in BASE_ORDER if bases[l]["group"] == "C+")))
    for variant, labels in table:
        for label in labels:
            base = bases[label]["state"]
            name = f"{label}_{variant}"
            note = dict(base=label, base_state=f"{base.path.parent.parent.name}/states/{base.path.name}",
                        run=base.run, group=bases[label]["group"], kind=variant)
            if variant == "real":
                text = base.text
                assert text.encode("utf8") == base.raw, f"{name} 与原 state 不逐字节相同"
                selfcheck["①"].append(name)
            else:
                new_line, removed, side = delete_item(base.ra_line)
                lines = list(base.lines)
                lines[base.ra_i] = new_line
                text = "\n".join(lines)
                rem, addl = changed_lines(base.text, text)
                assert rem == [base.ra_line] and addl == [new_line], f"{name} 改动的不止 Recent activities 一行"
                assert len(lines) == len(base.lines), f"{name} 行数不对"
                # 差的恰好是那一项：旧行 = 新行在删点插回删掉的子串
                k = base.ra_line.index(removed)
                assert new_line[:k] + removed + new_line[k:] == base.ra_line and removed.strip() == ITEM \
                    and len(removed) == len(ITEM) + 1, f"{name} 差的不是恰好那一项加一个空格"
                assert len(base.raw) - len(text.encode("utf8")) == len(ITEM) + 1, f"{name} 字节差不对"
                note.update(removed=removed, space_side=side, ra_after=new_line)
                selfcheck["②"].append((name, side))
            note.update(state_chars=len(text), ra=next(l for l in text.split("\n") if l.startswith(RA_PREFIX)))
            texts[name] = text
            notes[name] = note
            order.append(name)
            x2.write_text(VARIANTS_DIR / f"{name}.txt", text)
            assert (VARIANTS_DIR / f"{name}.txt").read_bytes() == text.encode("utf8"), f"{name} 落盘不一致"
    assert len(order) == EXPECTED_VARIANTS, f"变体数 {len(order)} != {EXPECTED_VARIANTS}"
    selfcheck["③"] = len(order)
    x2.write_json(VARIANTS_DIR / "notes.json", notes)
    return texts, notes, order, selfcheck


# ---------------------------------------------------------------- 只记录项

def record_only(bases):
    out = {}
    for label in BASE_ORDER:
        s = bases[label]["state"]
        wjh = s.wjh_confront_items()
        out[label] = dict(state=s.path.name, group=bases[label]["group"], chars=len(s.text),
                          current_situation=s.situation_line(), corvin_nearby=s.corvin_nearby(),
                          recent_activities=s.ra_line,
                          wjh_confront_count=len(wjh), wjh_confront_ago=[a for a, _ in wjh],
                          wjh_confront_items=[t for _, t in wjh],
                          new_column_exists=s.column is not None, new_column=s.column)
    return out


# ---------------------------------------------------------------- 发问

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

    def ask(self, state, questions_):
        """返回 (answers, seconds)；HTTP 错误返回 ({'error': code, 'body'}, s)；连接 / 超时 / 坏正文抛异常。"""
        body = json.dumps({"state": state, "model": os.environ["TYPESAFE_MODEL"], "questions": questions_}).encode()
        t = time.perf_counter()
        r = self.client.post(self.url, content=body, headers=self.headers)
        if r.status_code >= 400:
            return {"error": r.status_code, "body": r.text[:300]}, time.perf_counter() - t
        return r.json()["answers"], time.perf_counter() - t


def run_jev(texts, order, qs, notes):
    """并发 <= 3；401 / 403 / 429 / quota / 连接错误即停，未发的不再发；其它失败记下不补问。返回值不含 model 名。"""
    for k in ("TYPESAFE_API_URL", "TYPESAFE_API_KEY", "TYPESAFE_MODEL"):
        if not os.environ.get(k):
            x2.stop(f"环境变量 {k} 没有设置")
    halt, halted = threading.Event(), []
    cells = [(n, r + 1) for n in order for r in range(REPEATS)]
    started = s1q.now_iso()

    with JevClient(x2.JEV_WORKERS, x2.JEV_TIMEOUT_S) as jev:
        def one(cell):
            name, rep = cell
            row = dict(repeat=rep, ok=False, top1=None, probs=None, latency_ms=None, error=None)
            if halt.is_set():
                row["error"] = "not sent (stopped)"
                return name, row
            try:
                answers, seconds = jev.ask(texts[name], qs[notes[name]["run"]])
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
        per_ask = [{c: (r["probs"] or {}).get(c) for c in CANDS} if r["ok"] else None for r in rows]
        lead = [c for c, n in top.items() if n >= TOP1_MIN]   # 计划：6 次里出现最多且 >= 4 次
        argmax = max(CANDS, key=lambda c: avg[c]) if ok else None
        variants.append(dict(variant=name, base=notes[name]["base"], group=notes[name]["group"],
                             kind=notes[name]["kind"], state_chars=len(texts[name]), top1_counts=top,
                             top1=lead[0] if lead else None, avg_probs=avg, argmax_avg=argmax,
                             per_ask_probs=per_ask, failed=len(rows) - len(ok), requests=rows))
    sent = sum(r["error"] != "not sent (stopped)" for _, r in got)
    return dict(model_is_jev_latest=os.environ["TYPESAFE_MODEL"] == "jev-latest", repeats=REPEATS,
                top1_min=TOP1_MIN, workers=x2.JEV_WORKERS, timeout_s=x2.JEV_TIMEOUT_S, retries=0,
                candidates=list(CANDS), started=started, finished=s1q.now_iso(), requests=len(got), sent=sent,
                answered=sum(r["ok"] for _, r in got), stopped="; ".join(halted) or None, variants=variants)


def confront_ranges(variants):
    """只记录：对质平均概率在 C− real / C+ real / delra 三组的范围。"""
    groups = {"C- real": [], "C+ real": [], "delra": []}
    for v in variants:
        p = v["avg_probs"]["confront_wrecker"]
        if p is None:
            continue
        key = "delra" if v["kind"] == "delra" else f"{v['group']} real"
        groups[key].append(p)
    return {k: (dict(min=min(v), max=max(v), n=len(v)) if v else None) for k, v in groups.items()}


# ---------------------------------------------------------------- 主流程

def fmt_probs(avg):
    return "/".join("—" if avg[c] is None else f"{avg[c]:.3f}".lstrip("0") if avg[c] else "0" for c in CANDS)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="不发请求：只取基准、生成变体、做三项自检、打印")
    a = ap.parse_args()
    before = tree_digest(READ_ONLY)

    bases, log_info = pick_bases()
    qs, tpl_info = questions()
    texts, notes, order, selfcheck = build(bases)
    record = record_only(bases)

    for run, li in log_info.items():
        print(f"{run} 服务端日志与 UTC 相差 {li['log_offset_h']} 小时（日志 + 该值 = UTC）；npc_select {li['npc_select_lines']} 行")
    print(f"模板：候选逐字相同 {tpl_info['candidates_identical']}；instructions 相同 {tpl_info['instructions_identical']}")
    print("基准（分组按 Recent activities 是否含 confront_wrecker；实跑 index.tsv / 服务端日志）：")
    for label in BASE_ORDER:
        b = bases[label]
        act = b["actual"]
        flag = "与计划一致" if b["index_matches_plan"] and b["log_matches_plan"] else \
            f"≠ 计划写的 {b['plan_actual']} {b['plan_confidence']}"
        print(f"  {label} {b['group']}: index {act['index_top1']} {act['index_confidence']} | 日志 {act['log_chosen']} "
              f"{act['log_confidence']} recall_ms={act['recall_ms']} trigger={act['log_trigger']} {act['log_utc']}Z "
              f"日志-文件={act['log_minus_file_ms']} ms jev-latest={act['model_is_jev_latest']} "
              f"index=日志 {act['index_agrees_log']} | {flag}")
    print(f"自检 ① real 逐字节同原 state：{len(selfcheck['①'])} 个；② delra 只差 Recent activities 一行且恰为那一项："
          f"{len(selfcheck['②'])} 个 {selfcheck['②']}；③ 变体数 {selfcheck['③']}")
    for name in order:
        n = notes[name]
        print(f"  {name:16} {n['group']} state={n['state_chars']:5}  {n['ra'][len(RA_PREFIX):]}")
    print("只记录（基准）：")
    for k, r in record.items():
        print(f"  {k} {r['group']}: {r['corvin_nearby']}")
        print(f"       What just happened 提到对质 {r['wjh_confront_count']} 条：{r['wjh_confront_ago']}")
        print(f"       新栏：{r['new_column'] if r['new_column_exists'] else '(无)'}")
    if a.dry_run:
        assert tree_digest(READ_ONLY) == before, "只读目录在 dry-run 中被改动"
        print(f"只读目录哈希（前后相同）：{before}")
        return

    if not os.environ.get("TYPESAFE_API_KEY"):
        s1q.load_env()   # 只读主检出 .env 的 TYPESAFE_* 进本进程环境，不打印
    x2.log(f"s1r7d jev start: {len(order)} 变体 x {REPEATS} 次，并发 <= {x2.JEV_WORKERS}，"
           f"超时 {x2.JEV_TIMEOUT_S} s；只读目录哈希 {before}")
    data = run_jev(texts, order, qs, notes)
    after = tree_digest(READ_ONLY)
    data.update(variant_notes=notes, template=tpl_info, server_log=log_info,
                bases={k: dict(state=b["state"].path.name, run=b["run"], group=b["group"], actual=b["actual"],
                               plan_actual=b["plan_actual"], plan_confidence=b["plan_confidence"],
                               index_matches_plan=b["index_matches_plan"], log_matches_plan=b["log_matches_plan"])
                       for k, b in bases.items()},
                record_only=record, confront_avg_ranges=confront_ranges(data["variants"]),
                selfcheck={k: v for k, v in selfcheck.items()},
                read_only_digest=dict(before=before, after=after, same=before == after))
    x2.write_json(RESULTS, data)
    for v in data["variants"]:
        x2.log(f"jev {v['variant']} top1={v['top1']} counts={v['top1_counts']} "
               f"avg(build/stone/lime/guard/plaza/confront)={fmt_probs(v['avg_probs'])} failed={v['failed']}")
    x2.log(f"confront avg ranges {data['confront_avg_ranges']}")
    x2.log(f"requests={data['requests']} sent={data['sent']} answered={data['answered']} stopped={data['stopped']}")
    x2.log(f"只读目录哈希 after {after} same={before == after}")
    if before != after:
        x2.stop("只读目录的哈希运行前后不同")
    if data.get("stopped"):
        x2.stop(data["stopped"])


if __name__ == "__main__":
    main()
