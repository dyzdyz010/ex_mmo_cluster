#!/usr/bin/env python
"""S1-X3：新栏形态的补测——只问 Jev，不新写日记。探索性，不是验收。

是什么
  按 .demo/observe/npc-slice1-20261112/s1x3/plan.md（唯一规格）的变体表，用 S1-X2 的 6 份基准 state 与 S1-X2 存下的
  日记原文生成 39 个变体（R0 / col / fresh / self / place / plans / selfplan / early），每变体问 Jev 4 次。
  只给读数，不判定计划里的期望。
为什么复用 s1x2_reflect
  新栏的栏名、写法与插入位置（insert_column）、“每轮各问题最新一条”（column_entries）、Jev 的问法与发问循环
  （jev_question / run_jev）都与 S1-X2 同一份实现，这样 R0 / col 能与 S1-X2 逐字节对上。
落盘
  只写 s1x3/（variants/、raw/、results.json、run.log）；s1x2/ 只读。导入 s1x2_reflect 后把它与 s1v / s1q 的
  落盘常量全部改指到 s1x3/，读日记用的 REFLECTIONS / STORED 仍指 s1x2/（只读）。

怎么运行（Git Bash；仓库根下）
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1x3_variants.py --dry-run
  TYPESAFE_API_URL=... TYPESAFE_API_KEY=... TYPESAFE_MODEL=... python -I -B -X utf8 .../s1x3_variants.py
  凭据只从进程环境读；401 / 403 / 429 / quota / 连接错误即停，不重试、不补问（run_jev 的行为）。
"""

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s1x2_reflect as x2  # noqa: E402

s1x, s1v, s1q = x2.s1x, x2.s1v, x2.s1q

# ---------------------------------------------------------------- 落盘目录：全部改指到 s1x3/（s1x2/ 只读）

OUT = x2.S1 / "s1x3"
S1X2_VARIANTS = x2.VARIANTS_DIR          # 改指之前记下：col 要与它逐字节对比
s1v.configure(x2.COPY_BANK, str(OUT))    # s1v 的 RAW / RESULTS / LOG 等，并把 s1q.RAW 指到 s1x3/raw
x2.OUT, x2.RAW, x2.LOG = OUT, OUT / "raw", OUT / "run.log"
x2.VARIANTS_DIR, x2.RESULTS, x2.DRYRUN = OUT / "variants", OUT / "results.json", OUT / "dryrun"
VARIANTS_DIR, RESULTS = x2.VARIANTS_DIR, x2.RESULTS

# ---------------------------------------------------------------- 计划原文的输入与变体表

# 基准 state（计划“输入”一节）：标签 -> (文件名, 对应的轮)
BASES = {
    "N2": ("asked-20261113T163633.329Z.txt", 2), "N3": ("asked-20261113T164216.874Z.txt", 3),
    "N4": ("asked-20261113T164745.373Z.txt", 4), "N5": ("asked-20261113T165653.836Z.txt", 5),
    "V": ("asked-20261113T164357.820Z.txt", 3), "T": ("asked-20261113T164608.409Z.txt", 3),
}
# 变体 -> 适用的基准（计划“变体”表）
TABLE = {
    "R0": ("N2", "N3", "N4", "N5", "V", "T"),
    "col": ("N2", "N3", "N4", "N5", "V", "T"),
    "fresh": ("N2", "N3", "V", "T"),
    "self": ("N2", "N3", "N4", "N5", "V", "T"),
    "place": ("N2", "N3", "N4", "V", "T"),
    "plans": ("N3", "N4", "V", "T"),
    "selfplan": ("N3", "N4", "N5", "V", "T"),
    "early": ("N3", "V", "T"),
}
COLUMN_PREFIX = "What I have come to think: "

# 与 s1x_reflect.checks（约第 223 行）同一个切句正则；那里是函数内联写法、没有可导入的函数，
# 所以这里照抄这一行，并对每条日记断言切出的句数等于 s1x.checks 给的 sentences（确保是同一切法）。
SENTENCE_SPLIT = re.compile(r"(?<=[.!?])[\"')\]]*\s+")


def last_sentence(journal):
    """日记最后一句（原文子串，不改写）。"""
    sents = [s for s in SENTENCE_SPLIT.split(journal.strip()) if s.strip()]
    assert len(sents) == s1x.checks(journal, [])["sentences"], "切句与 s1x.checks 不一致"
    return sents[-1]


def fresh_rows(k):
    """第 k 轮存下的各条（问题次序）：[(轮, 问, 日记原文)]。被丢弃的问不在 stored.json 里，自然不算。"""
    rows = {r["key"]: r for r in x2.stored_rows() if r["round"] == k}
    return [(k, q, x2.read_json(x2.REFLECTIONS / f"{k}-{q}.json")["journal"]) for q in x2.QUESTION_ORDER if q in rows]


def col_rows(k):
    """S1-X2 的 col：第 k 轮结束时每个问题最新的一条，带来源轮号；正文必须与 x2.column_entries(k) 相同。"""
    latest = {}
    for r in sorted(x2.stored_rows(), key=lambda r: r["round"]):
        if r["round"] <= k:
            latest[r["key"]] = r["round"]
    rows = [(latest[q], q, x2.read_json(x2.REFLECTIONS / f"{latest[q]}-{q}.json")["journal"])
            for q in x2.QUESTION_ORDER if q in latest][:x2.MAX_COLUMN_ENTRIES]
    assert [j for _, _, j in rows] == x2.column_entries(k), f"第 {k} 轮 col 的来源与 column_entries 不一致"
    return rows


def entries_for(variant, k):
    """[(轮, 问, 取法, 正文)]；取法 whole = 整条，last_sentence = 最后一句。"""
    fresh = fresh_rows(k)
    pick = {
        "R0": [],
        "col": [(r, q, "whole", j) for r, q, j in col_rows(k)],
        "fresh": [(r, q, "whole", j) for r, q, j in fresh],
        "early": [(r, q, "whole", j) for r, q, j in fresh],
        "self": [(r, q, "whole", j) for r, q, j in fresh if q == "Q_self"],
        "place": [(r, q, "whole", j) for r, q, j in fresh if q == "Q_place"],
        "plans": [(r, q, "last_sentence", last_sentence(j)) for r, q, j in fresh],
        "selfplan": [(r, q, "last_sentence", last_sentence(j)) for r, q, j in fresh if q == "Q_self"],
    }[variant]
    if variant not in ("R0", "col"):
        want = {"self": 1, "place": 1, "selfplan": 1}.get(variant)
        assert pick and (want is None or len(pick) == want), f"{variant} 第 {k} 轮的条目数不对：{len(pick)}"
    return pick


def place_early(base, placed):
    """early：把 S1-X2 写法的那一行挪到 What I remember 栏之前（What just happened 栏之后）。"""
    lines = placed.split("\n")
    line = next(l for l in lines if l.startswith(COLUMN_PREFIX))
    base_lines = base.split("\n")
    i = next(n for n, l in enumerate(base_lines) if l.startswith(x2.MEM + ": "))
    out = base_lines[:i] + [line] + base_lines[i:]
    # 自检：去掉新栏后与基准逐字相同；新栏前一行属于 What just happened 栏，后一行是 What I remember 栏开头
    assert out[:i] + out[i + 1:] == base_lines, "early 去掉新栏后与基准不同"
    secs = [t for t, ls in x2.state_sections("\n".join(out)) for _ in ls]
    assert secs[i - 1] == x2.WJH and out[i + 1].startswith(x2.MEM + ": "), "early 新栏位置不对"
    return "\n".join(out)


def build():
    """生成 39 个变体并做全部自检；返回 (texts, notes, order)。"""
    texts, notes, order = {}, {}, []
    for variant, labels in TABLE.items():
        for label in labels:
            fname, k = BASES[label]
            raw = (x2.STATES_DIR / fname).read_bytes()
            base = raw.decode("utf8")
            entries = entries_for(variant, k)
            bodies = [e[3] for e in entries]
            if variant == "R0":
                text = base
                assert text.encode("utf8") == raw, f"{label}_R0 与基准 state 不逐字节相同"
            else:
                text, _ = x2.insert_column(base, bodies)  # 内含自检：去掉新栏与基准相同、位置在 Current situation 之前
                if variant == "early":
                    text = place_early(base, text)
            if variant == "col":
                want = (S1X2_VARIANTS / f"{label}_col.txt").read_bytes()
                assert text.encode("utf8") == want, f"{label}_col 与 s1x2/variants/{label}_col.txt 不逐字节相同"
            name = f"{label}_{variant}"
            col_line = next((l for l in text.split("\n") if l.startswith(COLUMN_PREFIX)), "")
            texts[name] = text
            order.append(name)
            notes[name] = dict(base_state=fname, round=k,
                               entries=[dict(round=r, question=q, taken=how, chars=len(s1x.one_line(b)))
                                        for r, q, how, b in entries],
                               delta_chars=len(text) - len(base), state_chars=len(text),
                               column_head=col_line[len(COLUMN_PREFIX):][:80])
            x2.write_text(VARIANTS_DIR / f"{name}.txt", text)
    assert len(order) == 39, f"变体数 {len(order)} != 39"
    x2.write_json(VARIANTS_DIR / "notes.json", notes)
    return texts, notes, order


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="不发请求：只生成变体、自检、打印字数增量与新栏开头")
    a = ap.parse_args()
    texts, notes, order = build()
    print(f"自检通过：{len(order)} 个变体（R0 逐字节同基准、col 逐字节同 S1-X2、early 去栏同基准、切句同 s1x.checks）")
    for name in order:
        n = notes[name]
        src = ",".join(f"{e['round']}-{e['question']}{'(末句)' if e['taken'] == 'last_sentence' else ''}"
                       for e in n["entries"])
        print(f"  {name:12} +{n['delta_chars']:5} 字  state={n['state_chars']:5}  [{src}]  {n['column_head']}")
    if a.dry_run:
        return
    x2.log(f"s1x3 jev start: {len(order)} 变体 x {x2.JEV_REPEATS} 次，并发 <= {x2.JEV_WORKERS}，超时 {x2.JEV_TIMEOUT_S} s")
    data = x2.run_jev(texts, order)
    data["variant_notes"] = notes
    x2.write_json(RESULTS, data)
    for v in data["variants"]:
        x2.log(f"jev {v['variant']} top1={v['top1_counts']} "
               f"avg={ {c: round(p, 3) for c, p in v['avg_probs'].items() if p} } failed={v['failed']}")
    if data.get("stopped"):
        x2.stop(data["stopped"])


if __name__ == "__main__":
    main()
