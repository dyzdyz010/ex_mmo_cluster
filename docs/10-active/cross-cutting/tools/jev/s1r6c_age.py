#!/usr/bin/env python
"""S1-R6c：新栏句首“多久以前”的剂量与去掉它之后——只问 Jev 的离线对照。探索性，不是验收。

是什么
  按 .demo/observe/npc-slice1-20261112/s1r6/age-plan.md（唯一规格；期望与判定口径一条不改）的变体表，
  用 R6 实跑的 4 份真实 state（O2 / O3 / O4 / OV），只换新栏那一行里 `I thought: ` 之前的句首，
  生成 22 个变体（real / now / h2 / h5 / notime / bare），每变体问 Jev 4 次（88 个请求）。
  只给读数与按计划 C1–C6 口径的机械比较，不替统筹会话下结论。
为什么
  S1-R6b（why-results.md）只在 L2o 一份 state 上测过改年龄：`About 12 hours ago` → `Just now`，采集合计 .085 → .792。
  本轮看三件：别的轮、别的打算（去广场）上是否一样；作用随年龄怎样衰减；不写年龄时怎样（给用户定写法用）。
输入（全部是真实导出或只换句首，不生造）
  - 基准 state：s1r6/states/asked-*.txt，一字不改。
    O2 = S1-R6b 的 L2o（asked-20261114T123721.885Z.txt），OV = S1-R6b 的 LVa（asked-20261114T125724.890Z.txt）。
    O3、O4 按计划文字从 state 全文挑（“无人” = Current situation 含 `Nobody else is nearby.`；“小屋立着” = 含 `is standing`；
    新栏须是该轮那句 = s1r6/export/rows/ 第 k 轮行的 reflection.latest.self.closing）：
      O3：第 4 轮起槽（12:48:43.311Z）之前最后一份无人、小屋立着、新栏是第 3 轮那句的；
      O4：Corvin 到场 A（12:56:55Z）之前最后一份无人、小屋立着、新栏是第 4 轮那句的。
    每份基准实跑选了什么以服务端日志 s1r6/server-s1r6.log 的 npc_select 行为准（沿用 s1r6b 的对法），
    与计划写的核对，不符只报告、不改计划。
  - 问法 / 候选：s1r6/export/request-template.json。
怎么构造
  只换新栏那一行 `What I have come to think: <句首>I thought: <句>` 里的 <句首>；栏名与位置不动：
    now = `Just now, `；h2 = `About 2 hours ago, `；h5 = `About 5 hours ago, `（写法同产品的 AGO_PREFIX）；
    notime = 去掉句首只留 `I thought: <句>`；bare = 连 `I thought: ` 也去掉，只留 `<句>`（S1-X3 的 selfplan 形态）。
自检（--dry-run 里做，全过才发请求）
  ① 4 个 real 与原 state 逐字节相同；② 每个其它变体与基准只差新栏那一行；
  ③ O2_now 与 s1r6/why/variants/L2o_now.txt 逐字节相同；④ 变体共 22 个。
落盘
  只写 s1r6/age/（variants/、raw/、results.json、run.log）。s1r6/states/、s1r6/export/、s1r6/why/、s1r6/label/、
  s1x2/、s1x3/、s1t/ 只读：运行前后各算一次全部文件的哈希汇总，必须相同（不同就停）。
凭据
  同 s1r6b：进程环境里没有 TYPESAFE_API_KEY 时，用 s1q.load_env 只从主检出 D:/hemifuture/ex_mmo_cluster/.env
  读 TYPESAFE_* 进本进程环境；值不打印、不写文件（results.json 不记 model 名，只记它是否等于 jev-latest）。
发问
  沿用 s1r6b.run_jev：并发 <= 3，单请求超时 60 s；401 / 403 / 429 / 正文含 quota / 连接错误（含超时）即停，
  未发的不再发，不重试、不补问。

怎么运行（Git Bash；仓库根下）
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r6c_age.py --dry-run   # 只选基准、生成变体与自检，不发请求
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r6c_age.py             # 自检全过才发请求
"""

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s1r6b_why as b  # noqa: E402  导入时它把各模块的落盘常量指到 s1r6/why/（只改变量、不写文件）；下面全部改指到 s1r6/age/

x2, s1v, s1q = b.x2, b.s1v, b.s1q

# ---------------------------------------------------------------- 路径：只读输入与落盘目录

S1, R6 = b.S1, b.R6
WHY_VARIANTS = R6 / "why" / "variants"             # 自检 ③：L2o_now
READ_ONLY = (R6 / "states", R6 / "export", R6 / "why", R6 / "label", S1 / "s1x2", S1 / "s1x3", S1 / "s1t")

OUT = R6 / "age"
s1v.configure(x2.COPY_BANK, str(OUT))    # s1v 的落盘常量与 s1q.RAW 指到 s1r6/age/（本脚本不调 s1v 的写函数，只防误写）
x2.OUT, x2.RAW, x2.LOG = OUT, OUT / "raw", OUT / "run.log"
x2.VARIANTS_DIR, x2.RESULTS, x2.DRYRUN = OUT / "variants", OUT / "results.json", OUT / "dryrun"
b.x3.OUT, b.x3.VARIANTS_DIR, b.x3.RESULTS = OUT, x2.VARIANTS_DIR, x2.RESULTS
b.OUT, b.VARIANTS_DIR, b.RESULTS, b.RAW = OUT, x2.VARIANTS_DIR, x2.RESULTS, x2.RAW   # b.run_jev 把原始应答写到 b.RAW
VARIANTS_DIR, RESULTS = x2.VARIANTS_DIR, x2.RESULTS

# ---------------------------------------------------------------- 计划原文的常量

COLUMN_PREFIX, THOUGHT, ms = b.COLUMN_PREFIX, b.THOUGHT, b.ms
SLOT_R3 = "2026-11-14T12:37:52.201Z"
SLOT_R4 = "2026-11-14T12:48:43.311Z"
SLOT_R5 = "2026-11-14T12:57:57.376Z"
CORVIN_A = "2026-11-14T12:56:55.000Z"               # 计划：Corvin 到场 A 之前、即 12:56:55 之前

# 计划“输入”一节：值 = (给定文件名或 None, 新栏应是第几轮那句, 计划写的实跑选择, 处境)
BASES = {
    "O2": ("asked-20261114T123721.885Z.txt", 2, "guard_hut", "nobody"),
    "O3": (None, 3, "guard_hut", "nobody"),
    "O4": (None, 4, "guard_hut", "nobody"),
    "OV": ("asked-20261114T125724.890Z.txt", None, "confront_wrecker", "corvin"),
}
BASE_ORDER = ("O2", "O3", "O4", "OV")
NOBODY_BASES = ("O2", "O3", "O4")

# 计划“变体”表：变体 -> (新栏正文里 `<句>` 之前的部分；None = 原样, 用在哪些基准)
HEADS = {
    "real": (None, BASE_ORDER),
    "now": ("Just now, " + THOUGHT, BASE_ORDER),
    "h2": ("About 2 hours ago, " + THOUGHT, NOBODY_BASES),
    "h5": ("About 5 hours ago, " + THOUGHT, NOBODY_BASES),
    "notime": (THOUGHT, BASE_ORDER),
    "bare": ("", BASE_ORDER),
}
EXPECTED_VARIANTS = 22
GATHER = ("gather_stone", "gather_limestone")
# “打算的活动”：O2、O3 = 采集（两者合计；top1 是两者之一即算）；O4 = visit_plaza。OV 计划未定义，表里给对质只作参考。
INTENDED = {"O2": GATHER, "O3": GATHER, "O4": ("visit_plaza",), "OV": ("confront_wrecker",)}
CANDS = b.CANDS


# ---------------------------------------------------------------- 选基准

def pick_bases(states, sentences):
    """返回 {标签: dict(state, how, round, situation, actual, plan_actual)}，并打印依据用的核对信息。"""
    by_name = {s.path.name: s for s in states}
    picked = {}
    for label, (fname, k, plan_actual, situ) in BASES.items():
        if fname:
            picked[label] = dict(state=by_name[fname], how="计划给的文件名", round=k, situation=situ)
    ok = lambda s, k: s.nobody() and s.standing() and s.sentence == sentences[k]   # noqa: E731
    # O3：第 4 轮起槽之前最后一份无人、小屋立着、新栏是第 3 轮那句的
    o3 = [s for s in states if s.ms < ms(SLOT_R4) and ok(s, 3)]
    picked["O3"] = dict(state=o3[-1], round=3, situation="nobody",
                        how=f"t < {SLOT_R4[11:]}（第 4 轮起槽）、无人、小屋立着、新栏是第 3 轮那句的最后一份（共 {len(o3)} 份合格）")
    # O4：Corvin 到场 A（12:56:55）之前最后一份无人、小屋立着、新栏是第 4 轮那句的
    o4 = [s for s in states if s.ms < ms(CORVIN_A) and ok(s, 4)]
    picked["O4"] = dict(state=o4[-1], round=4, situation="nobody",
                        how=f"t < {CORVIN_A[11:19]}（Corvin 到场 A）、无人、小屋立着、新栏是第 4 轮那句的最后一份（共 {len(o4)} 份合格）")
    # 核对：O2 也按同一文字口径挑一次（第 3 轮起槽之前最后一份无人、含第 2 轮那句的），应当就是计划给的文件
    o2 = [s for s in states if s.ms < ms(SLOT_R3) and ok(s, 2)]
    checks = [f"O2 按文字口径挑 = {o2[-1].path.name}（与计划给的文件{'相同' if o2[-1] is picked['O2']['state'] else '不同'}）"]
    # 核对：O3 之后到第 4 轮起槽之间、O4 之后到第 5 轮起槽之间各有哪些 state（看清边界）
    for label, end in (("O3", SLOT_R4), ("O4", SLOT_R5)):
        s0 = picked[label]["state"]
        tail = [s for s in states if s0.ms < s.ms < ms(end)]
        desc = [f"{s.path.name[6:-4]}({'无人' if s.nobody() else 'Corvin' if s.corvin_near() else '有人'},"
                f"{'立着' if s.standing() else '非立着'},{'同句' if s.sentence == s0.sentence else '他句'})" for s in tail]
        checks.append(f"{label} 之后到 {end[11:]} 之间的 state：{desc or '无'}")
    for label in BASE_ORDER:
        p = picked[label]
        s = p["state"]
        assert s.col_i is not None and s.standing(), f"{label} {s.path.name} 没有新栏或小屋不是立着"
        if p["situation"] == "nobody":
            assert s.nobody(), f"{label} {s.path.name} 不是无人"
        else:
            assert s.corvin_near(), f"{label} {s.path.name} 附近没有 Corvin"
        if p["round"] is not None:
            assert s.sentence == sentences[p["round"]], f"{label} 新栏不是第 {p['round']} 轮那句"
    # 实跑选了什么：以服务端日志为准
    index = b.load_index()
    selects, off = b.load_selects()
    for label in BASE_ORDER:
        p = picked[label]
        p["actual"] = b.actual_choice(p["state"].path.name, index, selects)
        p["plan_actual"] = BASES[label][2]
    return picked, checks, dict(log_offset_h=off // 3_600_000, npc_select_lines=len(selects))


# ---------------------------------------------------------------- 变体与自检

def build(bases):
    """生成 22 个变体并做自检 ① ② ③ ④；返回 (texts, notes, order, selfcheck)。"""
    texts, notes, order = {}, {}, []
    selfcheck = {"①": [], "②": [], "③": None, "④": None}
    for variant, (head, labels) in HEADS.items():
        for label in labels:
            base = bases[label]["state"]
            name = f"{label}_{variant}"
            text = base.text if head is None else b.replace_column(base, COLUMN_PREFIX + head + base.sentence)
            texts[name] = text
            order.append(name)
            col = next(l for l in text.split("\n") if l.startswith(COLUMN_PREFIX))
            notes[name] = dict(base=label, base_state=base.path.name, kind=variant, template="R6",
                               column=col[len(COLUMN_PREFIX):], state_chars=len(text))
            x2.write_text(VARIANTS_DIR / f"{name}.txt", text)
            if head is None:
                assert text.encode("utf8") == base.raw, f"{name} 与原 state 不逐字节相同"
                selfcheck["①"].append(name)
            else:
                rem, addl = b.changed_lines(base.text, text)
                assert rem == [base.lines[base.col_i]] and addl == [col], f"{name} 与基准不是只差新栏那一行"
                assert text.split("\n").index(col) == base.col_i, f"{name} 新栏位置变了"
                selfcheck["②"].append(name)
    want = (WHY_VARIANTS / "L2o_now.txt").read_bytes()
    assert texts["O2_now"].encode("utf8") == want, "O2_now 与 s1r6/why/variants/L2o_now.txt 不逐字节相同"
    selfcheck["③"] = True
    assert len(order) == EXPECTED_VARIANTS, f"变体数 {len(order)} != {EXPECTED_VARIANTS}"
    selfcheck["④"] = len(order)
    x2.write_json(VARIANTS_DIR / "notes.json", notes)
    return texts, notes, order, selfcheck


# ---------------------------------------------------------------- 按计划口径的机械读数（不下结论）

def c_readings(v, bases):
    """C1–C6 的读数与按口径的机械比较；口径有歧义处两种读法都给。v = {变体: 读数}。"""
    p = lambda n, c: v[n]["avg_probs"][c]                                    # noqa: E731
    ip = lambda base, n: sum(p(n, c) for c in INTENDED[base])                 # noqa: E731  打算的活动的概率（采集取合计）
    top = lambda n: v[n]["top1"]                                             # noqa: E731  单个候选 >= 3/4，否则 None

    def hit(base, n):
        """top1 是打算的活动：strict = 单个候选 >= 3/4 且属打算；pooled = 4 次里 top1 落在打算集合的 >= 3 次。"""
        strict = top(n) in INTENDED[base]
        pooled = sum(v[n]["top1_counts"].get(c, 0) for c in INTENDED[base]) >= 3
        return strict, pooled

    c = {}
    rows = [(k, top(f"{k}_real"), bases[k]["actual"]["chosen"]) for k in BASE_ORDER]
    c["C1"] = dict(rows=rows, holds=all(t == a for _, t, a in rows))
    rows = [(k, top(f"{k}_now"), *hit(k, f"{k}_now"), round(ip(k, f"{k}_now"), 3)) for k in NOBODY_BASES]
    c["C2"] = dict(rows=rows, holds_strict=all(r[2] for r in rows), holds_pooled=all(r[3] for r in rows))
    rows = [(k, top(f"{k}_notime"), *hit(k, f"{k}_notime"), round(ip(k, f"{k}_notime"), 3)) for k in NOBODY_BASES]
    c["C3"] = dict(rows=rows, holds_strict=sum(r[2] for r in rows) >= 2, holds_pooled=sum(r[3] for r in rows) >= 2)
    rows = [(k, top(f"{k}_bare"), top(f"{k}_notime"),
             round(abs(ip(k, f"{k}_bare") - ip(k, f"{k}_notime")), 3)) for k in NOBODY_BASES]
    c["C4"] = dict(rows=rows, holds=all(a == n and d < .15 for _, a, n, d in rows))
    mono = []
    for k in NOBODY_BASES:
        seq = [round(ip(k, f"{k}_{x}"), 3) for x in ("now", "h2", "h5", "real")]
        mono.append((k, seq, all(seq[i] >= seq[i + 1] - .03 for i in range(3))))
    h2 = [(k, top(f"{k}_h2"), *hit(k, f"{k}_h2")) for k in NOBODY_BASES]
    h5 = [(k, top(f"{k}_h5")) for k in NOBODY_BASES]
    c["C5"] = dict(monotone=mono, h2=h2, h5=h5,
                   monotone_all=all(m for _, _, m in mono),
                   h2_ok_strict=sum(r[2] for r in h2) >= 2, h2_ok_pooled=sum(r[3] for r in h2) >= 2,
                   h5_ok=sum(t == "guard_hut" for _, t in h5) >= 2)
    c["C5"]["holds_strict"] = c["C5"]["monotone_all"] and c["C5"]["h2_ok_strict"] and c["C5"]["h5_ok"]
    c["C5"]["holds_pooled"] = c["C5"]["monotone_all"] and c["C5"]["h2_ok_pooled"] and c["C5"]["h5_ok"]
    rows = [(n, top(f"OV_{n}"), round(p(f"OV_{n}", "confront_wrecker"), 3)) for n in ("real", "now", "notime", "bare")]
    c["C6"] = dict(rows=rows, holds=all(t == "confront_wrecker" for _, t, _ in rows)
                   and all(pc >= .65 for n, _, pc in rows if n != "real"))
    return c


# ---------------------------------------------------------------- 主流程

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="不发请求：只选基准、生成变体、做四项自检、打印")
    a = ap.parse_args()
    before = b.tree_digest(READ_ONLY)

    states = b.load_r6_states()
    sents = {k: b.round_sentence(k) for k in (2, 3, 4, 5)}
    for k, slot in ((3, SLOT_R3), (4, SLOT_R4), (5, SLOT_R5)):
        assert sents[k]["slot_ms"] == ms(slot), f"第 {k} 轮起槽时刻与计划不同"
    sentences = {k: v["closing"] for k, v in sents.items()}
    first_corvin = next(s for s in states if s.ms > ms(SLOT_R4) and s.corvin_near())
    bases, checks, log_info = pick_bases(states, sentences)
    texts, notes, order, selfcheck = build(bases)

    print(f"服务端日志与 UTC 相差 {log_info['log_offset_h']} 小时；npc_select {log_info['npc_select_lines']} 行")
    print(f"第 4 轮起槽之后第一份 Corvin 在场的 state：{first_corvin.path.name}")
    print("基准：")
    for label in BASE_ORDER:
        bb = bases[label]
        act = bb["actual"]
        flag = "" if act["chosen"] == bb["plan_actual"] else f"  ≠ 计划写的 {bb['plan_actual']}"
        idx = "" if act["index_agrees"] else f"  （index.tsv 写 {act['index_top1']}）"
        print(f"  {label}: {bb['state'].path.name}  句首 {bb['state'].ago!r}  实跑 {act['chosen']} {act['confidence']} "
              f"recall_ms={act['recall_ms']} trigger={act['trigger']} 日志-文件={act['log_minus_file_ms']} ms{idx}{flag}")
        print(f"       依据：{bb['how']}")
        print(f"       新栏：{bb['state'].lines[bb['state'].col_i][len(COLUMN_PREFIX):][:110]}…")
    for line in checks:
        print(f"  核对 {line}")
    print(f"自检 ① real 逐字节同原 state：{len(selfcheck['①'])} 个；② 只差新栏一行：{len(selfcheck['②'])} 个；"
          f"③ O2_now == why/L2o_now：{selfcheck['③']}；④ 变体数 {selfcheck['④']}")
    for name in order:
        n = notes[name]
        print(f"  {name:10} state={n['state_chars']:5}  {n['column'][:60]}")
    if a.dry_run:
        assert b.tree_digest(READ_ONLY) == before, "只读目录在 dry-run 中被改动"
        print(f"只读目录哈希（前后相同）：{before}")
        return

    if not os.environ.get("TYPESAFE_API_KEY"):
        s1q.load_env()   # 只读主检出 .env 的 TYPESAFE_* 进本进程环境，不打印
    x2.log(f"s1r6c jev start: {len(order)} 变体 x {x2.JEV_REPEATS} 次，并发 <= {x2.JEV_WORKERS}，"
           f"超时 {x2.JEV_TIMEOUT_S} s；只读目录哈希 {before}")
    data = b.run_jev(texts, notes, order)
    after = b.tree_digest(READ_ONLY)
    by = {v["variant"]: v for v in data["variants"]}
    complete = not data["stopped"] and all(v["failed"] == 0 for v in data["variants"])
    data.update(variant_notes=notes, sentences={f"s{k}": v for k, v in sentences.items()},
                bases={k: dict(state=bb["state"].path.name, how=bb["how"], ago=bb["state"].ago, actual=bb["actual"],
                               plan_actual=bb["plan_actual"]) for k, bb in bases.items()},
                pick_checks=checks, server_log=log_info, selfcheck=selfcheck,
                c_readings=c_readings(by, bases) if complete else None,
                read_only_digest=dict(before=before, after=after, same=before == after))
    x2.write_json(RESULTS, data)
    for v in data["variants"]:
        x2.log(f"jev {v['variant']} top1={v['top1_counts']} avg={b.fmt_probs(v['avg_probs'])} failed={v['failed']}")
    if complete:
        for k, r in data["c_readings"].items():
            x2.log(f"{k} {json.dumps(r, ensure_ascii=False)}")
    x2.log(f"只读目录哈希 after {after} same={before == after}")
    if before != after:
        x2.stop("只读目录的哈希运行前后不同")
    if data.get("stopped"):
        x2.stop(data["stopped"])


if __name__ == "__main__":
    main()
