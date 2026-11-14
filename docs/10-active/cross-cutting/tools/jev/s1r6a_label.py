#!/usr/bin/env python
"""S1-R6a：新栏“多久以前 + I thought:”标注写法的补测——只问 Jev，不新写日记。探索性，不是验收。

是什么
  按 .demo/observe/npc-slice1-20261112/s1r6/label-plan.md（唯一规格）的变体表，用 S1-X3 的 5 份基准 state（N3、N4、N5、V、T）
  与 S1-X3 selfplan 的同一句收尾句，生成 5 × {R0, selfplan, label_real, label_now, label_12h} 个变体，每变体问 Jev 4 次。
  只给读数，不判定计划里的期望。
为什么
  R4 落地的产品新栏正文是 `<多久以前>I thought: <收尾一句>`（apps/npc_server/lib/npc_server/mind.ex 的 thought/1 与 ago/2），
  S1-X3 只测过不带标注的 selfplan。R6 闭环实跑之前，先知道加上标注后新栏对选择的作用是否与 S1-X3 读到的相同。
怎么复用
  - 收尾句、新栏的栏名与插入位置：直接导入 s1x3_variants（entries_for / last_sentence）与 s1x2_reflect（insert_column），
    所以 R0 / selfplan 能与 s1x3/variants/ 逐字节对上（自检 ①）。
  - 发问循环：s1x2_reflect.run_jev（并发 <= 3；401 / 403 / 429 / quota / 连接错误即停，不重试、不补问）。
  - “多久以前”：把产品 Mind.ago/2 与 MmoContracts.WorldTime.game_us/1 照实移植成整数运算（ago_words），
    并对 apps/npc_server/test/ 里现成的断言样本自检（自检 ②）。注意：label_real 这一行是本脚本拼的，不是产品进程渲染的。
  - label_real 的两个时刻：日记的时刻 = s1x2/moments.json 里该基准对应那一轮的 `now`（即 t′；S1-X2 存反思库时正文与
    timestamp 都用 t′，stored.json 的 `t` 字段与之相同——脚本里断言这一点）；state 的时刻 = 基准 state 文件名里的时间戳。
落盘
  只写 s1r6/label/（variants/、raw/、results.json、run.log）。s1x2/、s1x3/、s1t/ 只读：运行前后各算一次这三个目录
  全部文件的哈希汇总，必须相同（不同就停）。
凭据
  Jev 的 TYPESAFE_API_URL / TYPESAFE_API_KEY / TYPESAFE_MODEL：进程环境里没有时，用 s1q.load_env 只从主检出
  D:/hemifuture/ex_mmo_cluster/.env 读这三个键进本进程环境；值不打印、不落盘。

怎么运行（Git Bash；仓库根下）
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r6a_label.py --dry-run   # 只生成变体与自检，不发请求
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1r6a_label.py             # 自检全过才发请求
"""

import argparse
import datetime
import hashlib
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s1x3_variants as x3  # noqa: E402  导入时它把 s1x2_reflect / s1v 的落盘常量指到 s1x3/；下面再改指到 s1r6/label/

x2 = x3.x2
s1x, s1v, s1q = x2.s1x, x2.s1v, x2.s1q

# ---------------------------------------------------------------- 只读目录与落盘目录

S1 = x2.S1
READ_ONLY = (S1 / "s1x2", S1 / "s1x3", S1 / "s1t")
S1X3_VARIANTS = S1 / "s1x3" / "variants"   # 自检 ①：R0 / selfplan 要与这里逐字节相同
MOMENTS = S1 / "s1x2" / "moments.json"
STORED = S1 / "s1x2" / "stored.json"

OUT = S1 / "s1r6" / "label"
s1v.configure(x2.COPY_BANK, str(OUT))    # s1v 的落盘常量与 s1q.RAW 都指到 s1r6/label/（本脚本不调 s1v 的写函数，只防误写）
x2.OUT, x2.RAW, x2.LOG = OUT, OUT / "raw", OUT / "run.log"
x2.VARIANTS_DIR, x2.RESULTS, x2.DRYRUN = OUT / "variants", OUT / "results.json", OUT / "dryrun"
x3.OUT, x3.VARIANTS_DIR, x3.RESULTS = OUT, x2.VARIANTS_DIR, x2.RESULTS   # 本脚本不调 x3.build，只防误写
VARIANTS_DIR, RESULTS = x2.VARIANTS_DIR, x2.RESULTS

# ---------------------------------------------------------------- 计划原文的输入与变体表

BASE_LABELS = ("N3", "N4", "N5", "V", "T")          # 基准与对应的轮都取 S1-X3 的 BASES（与 s1x3/plan.md 一致）
VARIANTS = ("R0", "selfplan", "label_real", "label_now", "label_12h")
THOUGHT = "I thought: "                             # 产品 Mind.thought/1 的固定词
FIXED_AGO = {"label_now": "Just now, ", "label_12h": "About 12 hours ago, "}   # 计划变体表原文

# ---------------------------------------------------------------- 产品“多久以前”的移植（整数运算）

# MmoContracts.WorldTime（apps/mmo_contracts/lib/mmo_contracts/world_time.ex）的参数三元组
MINUTE_US = 60_000_000
EPOCH_US = 1_792_972_800_000_000      # 2026-10-26T00:00Z
GAME0_US = 6 * 60 * MINUTE_US         # 6 小时
RATE = 72                             # 现实 20 分钟 = 一个昼夜日
# Mind 的 @hour_us / @day_us
HOUR_US = 3_600_000_000
DAY_US = 24 * HOUR_US


def game_us(t_us):
    """WorldTime.game_us/1：game0 + (t - epoch_us) * rate。"""
    return GAME0_US + (t_us - EPOCH_US) * RATE


def ex_div(a, b):
    """Elixir 的 div/2：向零截断（Python 的 // 是向下取整，负数时不同）。"""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def ex_rem(a, b):
    """Elixir 的 rem/2：余数与被除数同号。"""
    return a - b * ex_div(a, b)


def count(n, unit):
    """Mind.count/2：1 用单数，其余加 s。"""
    return f"1 {unit}" if n == 1 else f"{n} {unit}s"


def ago_words(at_ms, now_ms):
    """Mind.ago/2 的逐行移植：不足 0.25 游戏小时 Just now；不足 48 小时四舍五入到 0.5 小时；否则四舍五入到天。"""
    elapsed = game_us(now_ms * 1000) - game_us(at_ms * 1000)
    if 4 * elapsed < HOUR_US:
        return "Just now, "
    if elapsed >= 48 * HOUR_US:
        return f"About {count(ex_div(2 * elapsed + DAY_US, 2 * DAY_US), 'day')} ago, "
    halves = ex_div(4 * elapsed + HOUR_US, 2 * HOUR_US)   # 半小时数 = floor(小时 × 2 + 1/2)
    if ex_rem(halves, 2) == 0:
        return f"About {count(ex_div(halves, 2), 'hour')} ago, "
    return f"About {ex_div(halves, 2)}.5 hours ago, "


def utc_ms(iso):
    """'2026-11-13T07:33:47.438Z' -> Unix 毫秒（整数，不经浮点）。"""
    d = datetime.datetime.strptime(iso, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=datetime.timezone.utc)
    return (d - datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)) // datetime.timedelta(milliseconds=1)


# 自检 ② 的样本：都出自 apps/npc_server/test/npc_server/npc_mind_test.exs 的现成断言（行号是本次读到时的位置）。
TEST_NOW_MS = 1_794_550_000_000                      # @now_ms（第 57 行）
AGO_SAMPLES = [
    # 第 307–329 行 “how long ago” 表：{真实毫秒差, 词}
    *[(TEST_NOW_MS - d, TEST_NOW_MS, w, f"表 {d} ms") for d, w in [
        (-5_000, "Just now, "), (0, "Just now, "), (12_499, "Just now, "), (12_500, "About 0.5 hours ago, "),
        (37_499, "About 0.5 hours ago, "), (37_500, "About 1 hour ago, "), (62_499, "About 1 hour ago, "),
        (62_500, "About 1.5 hours ago, "), (100_000, "About 2 hours ago, "), (2_399_999, "About 48 hours ago, "),
        (2_400_000, "About 2 days ago, "), (2_999_999, "About 2 days ago, "), (3_000_000, "About 3 days ago, "),
        (3_600_000, "About 3 days ago, "), (4_200_000, "About 4 days ago, ")]],
    # 第 93 / 101 / 129 / 134 行：七栏快照里的 125 s、10 s、50 s
    (TEST_NOW_MS - 125_000, TEST_NOW_MS, "About 2.5 hours ago, ", "快照 125 s"),
    (TEST_NOW_MS - 10_000, TEST_NOW_MS, "Just now, ", "快照 10 s"),
    (TEST_NOW_MS - 50_000, TEST_NOW_MS, "About 1 hour ago, ", "快照召回 50 s"),
    # 第 230–246 行：S1-Q 真实召回条目
    (utc_ms("2026-11-13T07:33:47.438Z"), utc_ms("2026-11-13T08:16:03.768Z"), "About 2 days ago, ", "S1-Q 召回"),
    # 第 334–339 行：S1-K 离线原文的两个时刻 × 两条经历
    (utc_ms("2026-11-13T01:01:25.591Z"), utc_ms("2026-11-13T01:12:50.994Z"), "About 13.5 hours ago, ", "S1-K N3 wrecked"),
    (utc_ms("2026-11-13T01:07:04.875Z"), utc_ms("2026-11-13T01:12:50.994Z"), "About 7 hours ago, ", "S1-K N3 social"),
    (utc_ms("2026-11-13T01:01:25.591Z"), utc_ms("2026-11-13T01:13:53.298Z"), "About 15 hours ago, ", "S1-K V3 wrecked"),
    (utc_ms("2026-11-13T01:07:04.875Z"), utc_ms("2026-11-13T01:13:53.298Z"), "About 8 hours ago, ", "S1-K V3 social"),
]
# 第 156–171 行：新栏整句（at_ms 取夹具 s1z/…-round5-reflection.json 的 latest.self，此刻取文件名时刻）
THOUGHT_FIXTURE = s1q.REPO / "apps/npc_server/test/support/fixtures/reflection/s1z/20261114T031005.159Z-round5-reflection.json"
THOUGHT_NOW_MS = utc_ms("2026-11-14T03:10:05.159Z")
THOUGHT_EXPECTED = ("About 3 hours ago, I thought: This time I'm going straight to the stone beside the plot, no more guarding, "
                    "a glance at the hut as I pass, a plain question for Corvin if they show, and the plaza only after the stone is cut.")


def check_ago():
    """自检 ②：移植的 ago 对产品测试样本逐字相同；返回 [(样本, 词, 分支)]。"""
    rows = []
    for at_ms, now_ms, want, tag in AGO_SAMPLES:
        got = ago_words(at_ms, now_ms)
        assert got == want, f"ago 样本 {tag}：移植算出 {got!r}，测试断言 {want!r}"
        rows.append((tag, got))
    fx = json.loads(THOUGHT_FIXTURE.read_text(encoding="utf8"))["latest"]["self"]
    line = ago_words(fx["at_ms"], THOUGHT_NOW_MS) + THOUGHT + fx["closing"]
    assert line == THOUGHT_EXPECTED, f"新栏整句样本不同：{line!r}"
    rows.append(("新栏整句 s1z round5", line[:40] + "…"))
    # 计划里 label_12h 的“现实约 10 分钟 = 游戏约 12 小时”：600 s 的 ago 恰是 label_12h 的词（只核对计划的说法）
    assert ago_words(0, 600_000) == FIXED_AGO["label_12h"]
    return rows


def ago_branches(rows):
    """把对上的样本按 ago 的分支归类：Just now / N.5 hours / 整数小时 / 天。"""
    def branch(w):
        if w.startswith("Just now"):
            return "Just now"
        if ".5 hours" in w:
            return "N.5 hours"
        if "hour" in w:
            return "整数小时"
        if "day" in w:
            return "天"
        return "新栏整句"
    out = {}
    for _, w in rows:
        out[branch(w)] = out.get(branch(w), 0) + 1
    return out


# ---------------------------------------------------------------- 只读目录的哈希汇总

def tree_digest(roots):
    """三个只读目录下全部文件（相对路径 + 内容）的 sha256 汇总；返回 {目录: (文件数, 摘要)}。"""
    out = {}
    for root in roots:
        h, n = hashlib.sha256(), 0
        for p in sorted(q for q in root.rglob("*") if q.is_file()):
            h.update(p.relative_to(root).as_posix().encode("utf8") + b"\0")
            h.update(hashlib.sha256(p.read_bytes()).digest())
            n += 1
        out[root.name] = (n, h.hexdigest())
    return out


# ---------------------------------------------------------------- 时刻

def journal_ms(k):
    """第 k 轮“自己”一问日记的时刻 = moments.json rounds[k].now（t′）；与 stored.json 里该条的 t 断言相同。"""
    rounds = {r["k"]: r for r in x2.read_json(MOMENTS)["rounds"]}
    now_iso = rounds[k]["now"]
    stored = [r for r in x2.read_json(STORED) if r["round"] == k and r["key"] == "Q_self"]
    assert len(stored) == 1 and stored[0]["t"] == now_iso, f"第 {k} 轮 Q_self 的 stored.t 与 moments.now 不同"
    return utc_ms(now_iso), now_iso


# ---------------------------------------------------------------- 变体

def build():
    """生成全部变体并做自检 ① ③；返回 (texts, notes, order, send_order, shared)。"""
    texts, notes, order, send_order, shared = {}, {}, [], [], {}
    for label in BASE_LABELS:
        fname, k = x3.BASES[label]
        raw = (x2.STATES_DIR / fname).read_bytes()
        base = raw.decode("utf8")
        (entry,) = x3.entries_for("selfplan", k)      # (轮, 问, 取法, 收尾一句)；与 S1-X3 selfplan 同一函数
        closing = entry[3]
        assert s1x.one_line(closing) == closing, f"{label} 收尾句含换行等，one_line 会改写它"
        at_ms, at_iso = journal_ms(k)
        state_ms = x2.file_ms(fname)
        real_ago = ago_words(at_ms, state_ms)
        bodies = {
            "R0": None,
            "selfplan": closing,
            "label_real": real_ago + THOUGHT + closing,
            "label_now": FIXED_AGO["label_now"] + THOUGHT + closing,
            "label_12h": FIXED_AGO["label_12h"] + THOUGHT + closing,
        }
        for variant in VARIANTS:
            name = f"{label}_{variant}"
            body = bodies[variant]
            if body is None:
                text = base
                assert text.encode("utf8") == raw, f"{name} 与基准 state 不逐字节相同"
            else:
                text, _ = x2.insert_column(base, [body])   # 内含：去掉新栏与基准相同、位置在 Current situation 之前
            # 自检 ①：R0 / selfplan 与 s1x3/variants/ 逐字节相同
            if variant in ("R0", "selfplan"):
                want = (S1X3_VARIANTS / f"{name}.txt").read_bytes()
                assert text.encode("utf8") == want, f"{name} 与 s1x3/variants/{name}.txt 不逐字节相同"
            # 自检 ③：label 变体去掉新栏后等于基准 state
            if variant.startswith("label_"):
                lines = text.split("\n")
                col = [i for i, l in enumerate(lines) if l.startswith(x3.COLUMN_PREFIX)]
                assert len(col) == 1 and lines[col[0]] == x3.COLUMN_PREFIX + body, f"{name} 新栏不是唯一一行或正文不对"
                assert "\n".join(lines[:col[0]] + lines[col[0] + 1:]).encode("utf8") == raw, f"{name} 去掉新栏后不等于基准"
            texts[name] = text
            order.append(name)
            notes[name] = dict(base_state=fname, round=k, body=body, delta_chars=len(text) - len(base),
                               state_chars=len(text))
            x2.write_text(VARIANTS_DIR / f"{name}.txt", text)
        notes[f"{label}_label_real"].update(journal_at=at_iso, state_at=x2.ms_iso(state_ms),
                                            real_elapsed_ms=state_ms - at_ms, ago=real_ago)
        # label_real 与 label_now / label_12h 逐字相同时不另发，判定共用读数
        dup = next((v for v in ("label_now", "label_12h") if texts[f"{label}_{v}"] == texts[f"{label}_label_real"]), None)
        for variant in VARIANTS:
            name = f"{label}_{variant}"
            if variant == "label_real" and dup:
                shared[name] = f"{label}_{dup}"
            else:
                send_order.append(name)
    assert len(order) == len(BASE_LABELS) * len(VARIANTS)
    x2.write_json(VARIANTS_DIR / "notes.json", dict(notes=notes, shared=shared))
    return texts, notes, order, send_order, shared


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="不发请求：只生成变体、做三项自检、打印")
    a = ap.parse_args()
    before = tree_digest(READ_ONLY)
    ago_rows = check_ago()
    texts, notes, order, send_order, shared = build()
    print(f"自检 ② 通过：{len(ago_rows)} 个样本，分支 {ago_branches(ago_rows)}")
    print(f"自检 ① ③ 通过：{len(order)} 个变体（R0 / selfplan 逐字节同 s1x3/variants/；label 去栏同基准）")
    for name in order:
        n = notes[name]
        extra = f"  ago={n['ago']!r} 日记 {n['journal_at']} -> state {n['state_at']}" if "ago" in n else ""
        print(f"  {name:16} +{n['delta_chars']:4} 字  state={n['state_chars']:5}{extra}")
    print(f"共用读数（不另发）：{shared or '无'}；发送 {len(send_order)} 个变体 x {x2.JEV_REPEATS} 次 = "
          f"{len(send_order) * x2.JEV_REPEATS} 个请求，并发 <= {x2.JEV_WORKERS}")
    if a.dry_run:
        assert tree_digest(READ_ONLY) == before, "只读目录在 dry-run 中被改动"
        print(f"只读目录哈希（前后相同）：{before}")
        return
    if not os.environ.get("TYPESAFE_API_KEY"):
        s1q.load_env()   # 只读主检出 .env 的 TYPESAFE_* 进本进程环境，不打印
    x2.log(f"s1r6a jev start: {len(send_order)} 变体 x {x2.JEV_REPEATS} 次，并发 <= {x2.JEV_WORKERS}，"
           f"超时 {x2.JEV_TIMEOUT_S} s；只读目录哈希 {before}")
    data = x2.run_jev({n: texts[n] for n in send_order}, send_order)
    after = tree_digest(READ_ONLY)
    data.update(variant_notes=notes, shared=shared, ago_selfcheck=ago_rows,
                read_only_digest=dict(before=before, after=after, same=before == after))
    x2.write_json(RESULTS, data)
    for v in data["variants"]:
        x2.log(f"jev {v['variant']} top1={v['top1_counts']} "
               f"avg={ {c: round(p, 3) for c, p in v['avg_probs'].items() if p} } failed={v['failed']}")
    x2.log(f"只读目录哈希 after {after} same={before == after}")
    if before != after:
        x2.stop("只读目录 s1x2/ s1x3/ s1t/ 的哈希运行前后不同")
    if data.get("stopped"):
        x2.stop(data["stopped"])


if __name__ == "__main__":
    main()
