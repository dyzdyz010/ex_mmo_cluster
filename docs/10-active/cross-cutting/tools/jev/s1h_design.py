"""只测试：S1-H 第 1 轮离线测量（内容形态与驱动来源；探索性，不是验收）。只向 Jev 发请求（HTTPS），不起服务端。
素材、候选表 T1、请求模板、读数、发问与区间输出沿用 s1e_design.py 第 3 轮（import，不改它）；每个变体只动一栏的一处。
测量计划与期望原文：.demo/observe/npc-slice1-20261112/s1h/plan.md。

==== 发问前的期望（统筹会话 2026-11-13 发问前写定；原样抄录自 plan.md，不得修改；落空如实记落空） ====
## 发问前的期望（方向与归因）
1. **F 组（写法本身不应改变选择）**：N3_F1 / F2 / F3 / F123 的 top1 各自与 N3_F0 的 top1 相同（4 次里至少 3 次），N3_F0 top1 的平均概率与 N3_F0 相差不超过 0.15；V3_F123 的 top1 仍是 `confront_wrecker`（≥ 3/4），平均概率与 V3_F0 相差不超过 0.15。4 次之间的概率极差不比 F0 的极差大出 0.10 以上（去噪不应增加离散）。归因：三种写法改动只是压缩 / 去零 / 去后缀，不增不减事实。
2. **D1（期间事实：没人来）**：N3_D1 的 `guard_hut` 平均概率低于 N3_F0，`visit_plaza` 平均概率高于 N3_F0（方向）。不要求 top1 改变。归因：事实栏新增“守屋期间平安”，这是第 3 轮里“只加时间 / 只加需求都不动”之外的第一类“关于屋子的事实”。
3. **D1r（期间事实：有人来过又走）**：N3_D1r 的 `guard_hut` 平均概率不低于 N3_F0（容差 0.05），且高于 N3_D1（方向相反）。
4. **D2（只有推断）**：N3_D2 的 `visit_plaza` 平均概率高于 N3_F0（方向），**但低于或等于 N3_D12**。归因：推断一句是否独立于事实起作用。
5. **D12（事实 + 推断）**：N3_D12 的 `visit_plaza` 平均概率 ≥ N3_D1 且 ≥ N3_D2，`guard_hut` 平均概率 ≤ N3_D1 且 ≤ N3_D2（叠加性）；不要求 top1 改变（第 3 轮里一句需求 + 一句时间两项叠加也只到各半）。
6. **D12r**：N3_D12r 的 `guard_hut` 平均概率 ≥ N3_D1r（反向叠加）。
7. **不被压掉**：V3_D1 与 V3_D12 的 top1 仍是 `confront_wrecker`（各 ≥ 3/4）；S3_D12 的 `confront_wrecker` 概率 ≤ 0.05；S3_F0 的 top1 仍是 `guard_hut`。
8. 汇报只写：各期望成立 / 落空、概率移动的方向与量、归因（哪一栏的哪一句起作用）；不评价“守屋是否正确”，不写“必须选 X”。
局限（先写下）：每类信息只试一种措辞；句子位置固定一处；4 次采样；素材只有一个 NPC 的一份记忆；探索性结果不算验收。
==== 抄录结束 ====

实现时的判读约定（plan.md 没有逐字规定的地方；report 逐条打印所用数值，便于复核）：
- “平均概率”= 同一变体 4 次应答里该候选概率的算术平均；某次应答缺该候选的概率则只对有值的求平均；无任何值 = 缺样 = 落空。
- 期望 1 里“N3_F0 top1”= N3_F0 的 4 次里出现最多的 top1（并列时取该并列候选里平均概率最高者）；“平均概率相差”比较的是
  该候选在变体与在 N3_F0 的平均概率；“概率极差”= 该候选 4 次概率的 max-min。V 组同理，候选取 confront_wrecker。
- “≥ 3/4”= 4 次里至少 3 次的 top1 符合；S3_F0 的 top1 仍是 guard_hut 按同一“≥ 3/4”约定。
- 期望 8 是汇报格式，不判定。
- D 组句子里的“12”按所在 state 的实际守屋句数替换（N3 为 10、V3 为 12、S3 为 7；见 edits.txt），F1 同。

用法（素材与模板路径写在脚本里；不带 --round，只有第 1 轮；Windows 控制台输出中文需加 -X utf8）：
  python -I -B s1h_design.py dryrun    # 只生成变体与 diff，不发任何请求
  python -I -B s1h_design.py run       # 发问：每变体 4 次、并发 <= 3；第 1 轮尚未运行
  python -I -B s1h_design.py report [--results PATH]   # 离线出表并逐条判定期望
凭据同 s1e_design.py / s1c2_counterfactual.py：run 只读主检出 .env 的 TYPESAFE_* 进本进程环境；值不打印、不写文件。
"""
import argparse, json, re, statistics, sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from difflib import SequenceMatcher
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # python -I 不把脚本目录放进 sys.path
import s1c2_counterfactual as c
import s1e_design as e

HERE = Path(__file__).resolve().parent
OUT = e.DEMO / 's1h/round1'
RESULTS = HERE / 'results-s1h-round1.json'
REPEATS, WORKERS, TIMEOUT = c.REPEATS, min(c.WORKERS, 3), c.TIMEOUT
WJH, RA, MEM, SIT = 'What just happened', 'Recent activities', e.MEM, e.SIT
PREFIX = 'Oldest first. '
SOURCES = {k: e.SOURCES[k] for k in ('N3', 'S3', 'V3')}

# ---------------------------------------------------------------- 句子（plan.md 原文）

D1_FMT = 'During those %d guards nobody came near the hut.'
D1R_FMT = 'During those %d guards someone came near the hut twice and then walked away.'
D2_LINE = '- Inference (from my own recent watches): the rebuilt hut seems safe for now.'
D2R_LINE = '- Inference (from my own recent watches): the hut is not safe yet; someone could come back.'
F1_WJH_FMT = 'I did "guard_hut" %d times in a row; all of them completed.'
F1_RA_FMT = 'guard_hut: completed %d times in a row.'

EV = r'At \S+ \(UTC\), I did "guard_hut" \([^)]*\)\. Result: completed\.'


class Cx(c.Ctx):
    def __init__(self):
        super().__init__(e.VANDAL_CID, e.VANDAL_NAME)
        self.stats = {}  # 栏 -> 改动处数（逐条改动项 / 行 / 句段）


def guard_n(st):
    body = st.sec[WJH]
    m = re.fullmatch(re.escape(PREFIX) + '(' + EV + '(?: ' + EV + ')*)', body)
    if not m:
        raise c.Missing('%s: not exactly a run of guard_hut completed sentences' % WJH)
    return len(re.findall(EV, m.group(1)))


# ---------------------------------------------------------------- F 组操作（对 State 的栏操作 (st, cx)）

def f1(st, cx):
    n = guard_n(st)
    st.sec[WJH] = PREFIX + F1_WJH_FMT % n
    ra = st.sec[RA]
    k = ra.count('guard_hut: completed.')
    if k == 0 or ra != PREFIX + ' '.join(['guard_hut: completed.'] * k):
        raise c.Missing('%s: not exactly a run of "guard_hut: completed."' % RA)
    st.sec[RA] = PREFIX + F1_RA_FMT % k
    cx.stats[WJH], cx.stats[RA] = 1, 1
    cx.log('"%s": %d guard_hut sentences -> 1 sentence (%d times)' % (WJH, n, n))
    cx.log('"%s": %d "guard_hut: completed." -> 1 phrase (%d times)' % (RA, k, k))


def f2(st, cx):
    body = st.sec[SIT]
    if body.count('Inventory: ') != 1 or not body.endswith('.'):
        raise c.Missing('%s: expected one trailing "Inventory: ....' % SIT)
    i = body.index('Inventory: ') + len('Inventory: ')
    items = body[i:-1].split(', ')
    for it in items:
        if not re.fullmatch(r'material \d+: \d+ units', it):
            raise c.Missing('%s: unexpected inventory item %r' % (SIT, it))
    kept = [it for it in items if not re.fullmatch(r'material \d+: 0 units', it)]
    st.sec[SIT] = body[:i] + ', '.join(kept) + '.'
    cx.stats[SIT] = len(items) - len(kept)
    cx.log('"%s": removed %d zero items, kept %d: %s' % (SIT, len(items) - len(kept), len(kept), '; '.join(kept)))


SUFFIX = re.compile(r' \| When: [^|]+ \| Involving: [^|]+(?: \| .*)?$')


def f3(st, cx):
    out, n = [], 0
    for line in st.sec[MEM].split('\n'):
        if line.startswith('- Recalled: '):
            m = SUFFIX.search(line)
            if m:
                n += 1
                cx.log('  cut %d chars from a Recalled line: %s' % (len(m.group(0)), m.group(0).strip()))
                line = line[:m.start()]
        out.append(line)
    if not n:
        raise c.Missing('%s: no Recalled line with a "| When: … | Involving: …" suffix' % MEM)
    st.sec[MEM] = '\n'.join(out)
    cx.stats[MEM] = n
    cx.log('"%s": %d Recalled lines lost their suffix' % (MEM, n))


# ---------------------------------------------------------------- D 组操作（栏尾加句，不删原文）

def add_tail(st, cx, title, joiner, text):
    st.sec[title] = st.sec[title] + joiner + text
    cx.stats[title] = cx.stats.get(title, 0) + 1
    cx.log('appended to the end of "%s": %s' % (title, text))


def d1(st, cx):
    add_tail(st, cx, WJH, ' ', D1_FMT % guard_n(st))


def d1r(st, cx):
    add_tail(st, cx, WJH, ' ', D1R_FMT % guard_n(st))


def d2(st, cx):
    add_tail(st, cx, MEM, '\n', D2_LINE)


def d2r(st, cx):
    add_tail(st, cx, MEM, '\n', D2R_LINE)


OPS = {'F1': f1, 'F2': f2, 'F3': f3, 'D1': d1, 'D1r': d1r, 'D2': d2, 'D2r': d2r}

# ---------------------------------------------------------------- 独立核对（不复用操作的实现；任何越界 -> 报错停下）
# 每个核对 (old, new, n) -> None，不满足就 assert 失败；n = 该素材原文的守屋句数。


def v_f1_wjh(old, new, n):
    assert old.count('I did "guard_hut"') == n and old.count('I did "') == n
    assert new == PREFIX + F1_WJH_FMT % n, 'F1 WJH column is not the one merged sentence'


def v_f1_ra(old, new, n):
    k = old.count('guard_hut: completed.')
    assert k >= 1 and old.count('completed') == k and new == PREFIX + F1_RA_FMT % k, 'F1 Recent activities mismatch'


def v_f2(old, new, n):
    po, _, io = old.partition('Inventory: ')
    pn, _, inn = new.partition('Inventory: ')
    assert po == pn, 'text before Inventory changed'
    to, tn = io[:-1].split(', '), inn[:-1].split(', ')
    assert io.endswith('.') and inn.endswith('.')
    it = iter(to)
    assert all(any(x == y for y in it) for x in tn), 'kept items are not an in-order subsequence of the original'
    assert all(not x.endswith(': 0 units') for x in tn), 'a zero item survived'
    gone = [x for x in to if x not in tn]
    assert len(gone) == len(to) - len(tn) and all(re.fullmatch(r'material \d+: 0 units', x) for x in gone), 'removed a non-zero item'


def v_f3(old, new, n):
    lo, ln = old.split('\n'), new.split('\n')
    assert len(lo) == len(ln), 'F3 changed the number of lines'
    cut = 0
    for a, b in zip(lo, ln):
        if a == b:
            assert not (a.startswith('- Recalled: ') and ' | When: ' in a), 'a Recalled line with suffix was left alone'
            continue
        assert a.startswith('- Recalled: ') and a.startswith(b) and b.startswith('- Recalled: ')
        tail = a[len(b):]
        assert tail.startswith(' | When: ') and ' | Involving: ' in tail and ' | When: ' not in b, 'F3 cut more than the suffix'
        cut += 1
    assert cut == sum(1 for a in lo if a.startswith('- Recalled: ') and ' | When: ' in a)


def v_add(text, joiner):
    def v(old, new, n):
        assert new == old + joiner + (text % n if '%d' in text else text), 'not a pure tail addition of the declared sentence'
    return v


CHECKS = {
    'F1': {WJH: v_f1_wjh, RA: v_f1_ra}, 'F2': {SIT: v_f2}, 'F3': {MEM: v_f3},
    'D1': {WJH: v_add(D1_FMT, ' ')}, 'D1r': {WJH: v_add(D1R_FMT, ' ')},
    'D2': {MEM: v_add(D2_LINE, '\n')}, 'D2r': {MEM: v_add(D2R_LINE, '\n')},
}

# ---------------------------------------------------------------- 变体表（次序即发问 / 报告次序）：(键, 来源, 操作名列表)

VARIANTS = [
    ('N3_F0', 'N3', []), ('V3_F0', 'V3', []),
    ('N3_F1', 'N3', ['F1']), ('N3_F2', 'N3', ['F2']), ('N3_F3', 'N3', ['F3']),
    ('N3_F123', 'N3', ['F1', 'F2', 'F3']), ('V3_F123', 'V3', ['F1', 'F2', 'F3']),
    ('N3_D1', 'N3', ['D1']), ('N3_D1r', 'N3', ['D1r']), ('N3_D2', 'N3', ['D2']),
    ('N3_D12', 'N3', ['D1', 'D2']), ('N3_D12r', 'N3', ['D1r', 'D2r']),
    ('V3_D1', 'V3', ['D1']), ('V3_D12', 'V3', ['D1', 'D2']),
    ('S3_F0', 'S3', []), ('S3_D12', 'S3', ['D1', 'D2']),
]
KEYS = [v[0] for v in VARIANTS]


def template():
    t = json.load(open(e.TEMPLATE, encoding='utf-8'))
    return {'instructions': t['instructions'], 'candidates': t['candidates'] + e.T1_EXTRA}


# ---------------------------------------------------------------- dryrun

def tok_chars(a, b):
    ta, tb = re.findall(r'\S+|\s+', a), re.findall(r'\S+|\s+', b)
    add = dele = 0
    for tag, i1, i2, j1, j2 in SequenceMatcher(None, ta, tb, autojunk=False).get_opcodes():
        if tag != 'equal':
            dele += sum(map(len, ta[i1:i2]))
            add += sum(map(len, tb[j1:j2]))
    return add, dele


def dryrun(a):
    OUT.mkdir(parents=True, exist_ok=True)
    json.dump(template(), open(OUT / 'template.json', 'w', encoding='utf-8', newline='\n'), indent=1, ensure_ascii=False)
    texts = {k: p.read_text(encoding='utf-8') for k, p in SOURCES.items()}
    counts = {k: guard_n(c.State(t)) for k, t in texts.items()}
    edits = ['S1-H round 1 (dry run)',
             'sources: ' + ', '.join('%s = %s' % (k, p) for k, p in SOURCES.items()),
             'template: %s + candidates %s -> %s' % (e.TEMPLATE, [x['name'] for x in e.T1_EXTRA], OUT / 'template.json'),
             'guard_hut sentences in "What just happened" (actual; plan.md says 12): ' + ', '.join('%s=%d' % kv for kv in counts.items()),
             'sentences use the actual count of the source state', '']
    dry = ['S1-H round 1 dry run: %d variants, no request sent' % len(VARIANTS), '']
    for key, src, ops in VARIANTS:
        cx, st = Cx(), c.State(texts[src])
        for o in ops:
            OPS[o](st, cx)
        out = st.render()
        (OUT / (key + '.txt')).write_bytes(out.encode('utf-8'))
        before = c.State(texts[src])
        declared = {t for o in ops for t in CHECKS[o]}
        changed = {t for t in c.TITLES if before.sec[t] != st.sec[t]}
        if changed != declared:
            raise c.Missing('%s: changed sections %s != declared %s' % (key, sorted(changed), sorted(declared)))
        # 独立核对：每个声称栏的内容恰是声称的改动；其余栏逐字节不变（由 `changed == declared` 保证）
        for o in ops:
            for title, chk in CHECKS[o].items():
                chk(before.sec[title], st.sec[title], counts[src])
        if not ops:
            assert out == texts[src], '%s: unchanged variant differs from its source' % key
        # 同一栏被两个操作改（本表不存在）会让上面的单操作核对失效，显式拒绝
        assert len([t for o in ops for t in CHECKS[o]]) == len(declared), '%s: two ops touch the same section' % key
        lo, ln = texts[src].split('\n'), out.split('\n')
        line_ch = [i + 1 for i in range(max(len(lo), len(ln))) if i >= len(lo) or i >= len(ln) or lo[i] != ln[i]]
        add, dele = tok_chars(texts[src], out) if ops else (0, 0)
        order = [t for t in c.TITLES if t in changed]
        spots = sum(cx.stats.get(t, 0) for t in order)
        line = '%-8s src %s | ops %-10s | changed sections: %-42s | spots %3d | lines %-8s | +%d / -%d chars | %s' % (
            key, src, '+'.join(ops) or '(none)', ', '.join(order) or 'none (byte-identical)', spots,
            ','.join(map(str, line_ch)) or '-', add, dele, 'within claim OK')
        print(line)
        dry.append(line)
        edits += ['=== %s  (source %s)' % (key, SOURCES[src].name),
                  'rule: ' + (' + '.join(ops) if ops else 'none (copy of source)'),
                  'spots changed: ' + (', '.join('%s=%d' % (t, cx.stats[t]) for t in order) or 'none')] + ['  ' + l for l in cx.lines]
        edits.append('  self-check: sections changed vs source = %s (declared: same; content verified independently: OK)' %
                     (order or 'none'))
        edits.append('')
    (OUT / 'edits.txt').write_text('\n'.join(edits), encoding='utf-8', newline='\n')
    dry += ['', 'guard_hut sentence counts (actual): ' + ', '.join('%s=%d' % kv for kv in counts.items())]
    (OUT / 'dryrun.txt').write_text('\n'.join(dry) + '\n', encoding='utf-8', newline='\n')
    print('wrote %d variants + template.json + edits.txt + dryrun.txt to %s' % (len(VARIANTS), OUT))


# ---------------------------------------------------------------- run（尚未运行；不得在 dryrun 之外调用）

def run(a):
    if RESULTS.exists():
        raise SystemExit('%s exists; refusing to overwrite' % RESULTS)
    tpl = json.load(open(OUT / 'template.json', encoding='utf-8'))
    texts = {k: (OUT / (k + '.txt')).read_text(encoding='utf-8') for k in KEYS}
    c.load_env()
    from jev import ask, ENV
    q = c.question(tpl)
    cells = [(k, r) for k in KEYS for r in range(REPEATS)]

    def one(cell):
        key, r = cell
        row = {'variant': key, 'repeat': r + 1}
        try:
            answers, _, seconds = ask(texts[key], q, timeout=TIMEOUT)
        except Exception as ex:  # 失败如实记，不重试、不补问
            return {**row, 'error': type(ex).__name__}
        row['latency_ms'] = round(seconds * 1000)
        if 'error' in answers:
            row['error'] = {'http': answers['error']}
        else:
            row['answer'] = answers['activity']
        return row

    with ThreadPoolExecutor(WORKERS) as pool:
        rows = list(pool.map(one, cells))
    data = {'model': ENV['TYPESAFE_MODEL'], 'repeats': REPEATS, 'workers': WORKERS, 'timeout_s': TIMEOUT,
            'template': str(OUT / 'template.json'), 'candidates': [x['name'] for x in tpl['candidates']],
            'variants': {k: {'state_file': 's1h/round1/%s.txt' % k} for k in KEYS}, 'rows': rows}
    json.dump(data, open(RESULTS, 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
    print('requested', len(rows), 'answered', sum('answer' in r for r in rows), 'errors', sum('error' in r for r in rows))


# ---------------------------------------------------------------- report（离线，无模型调用）

CW, GH, VP = 'confront_wrecker', 'guard_hut', 'visit_plaza'


class Stat:
    def __init__(self, rows, key):
        ans = [r['answer'] for r in sorted((r for r in rows if r['variant'] == key), key=lambda r: r['repeat']) if 'answer' in r]
        self.n = len(ans)
        self.top1 = Counter(x['choice'] for x in ans)
        self.p = {}
        for x in ans:
            for k, v in (x.get('probabilities') or {}).items():
                self.p.setdefault(k, []).append(v)

    def mean(self, cand):
        v = self.p.get(cand)
        return statistics.fmean(v) if v else None

    def rng(self, cand):
        v = self.p.get(cand)
        return max(v) - min(v) if v else None

    def mode(self):
        if not self.top1:
            return None
        best = max(self.top1.values())
        return max((k for k, v in self.top1.items() if v == best), key=lambda k: self.mean(k) or 0.0)


def check(desc, fn, *vals):
    """vals 里有 None（缺样）一律落空；比较前 round 到 9 位避免浮点边界误判。"""
    shown = ', '.join('-' if v is None else ('%.4f' % v if isinstance(v, float) else str(v)) for v in vals)
    if any(v is None for v in vals):
        return False, '%s  [缺样: %s]' % (desc, shown)
    return bool(fn(*[round(v, 9) if isinstance(v, float) else v for v in vals])), '%s  [%s]' % (desc, shown)


def judge(S):
    """返回 [(序号, 标题, [(成立?, 说明)...])]；每条期望所有子项都成立才算成立。"""
    g, v = (lambda k: S[k].mean(GH)), (lambda k: S[k].mean(VP))
    out = []

    f0 = S['N3_F0']
    t = f0.mode()
    cs = []
    for k in ('N3_F1', 'N3_F2', 'N3_F3', 'N3_F123'):
        x = S[k]
        cs.append(check('%s top1==%s(N3_F0 的 top1) 次数 >= 3' % (k, t), lambda n: n >= 3, x.top1[t] if t and x.n else None))
        cs.append(check('%s |mean(%s) - N3_F0| <= 0.15' % (k, t), lambda d: abs(d) <= 0.15,
                        None if t is None or x.mean(t) is None or f0.mean(t) is None else x.mean(t) - f0.mean(t)))
        cs.append(check('%s 极差(%s) - N3_F0 极差 <= 0.10' % (k, t), lambda d: d <= 0.10,
                        None if t is None or x.rng(t) is None or f0.rng(t) is None else x.rng(t) - f0.rng(t)))
    x, b = S['V3_F123'], S['V3_F0']
    cs.append(check('V3_F123 top1==confront_wrecker 次数 >= 3', lambda n: n >= 3, x.top1[CW] if x.n else None))
    cs.append(check('V3_F123 |mean(CW) - V3_F0| <= 0.15', lambda d: abs(d) <= 0.15,
                    None if x.mean(CW) is None or b.mean(CW) is None else x.mean(CW) - b.mean(CW)))
    cs.append(check('V3_F123 极差(CW) - V3_F0 极差 <= 0.10', lambda d: d <= 0.10,
                    None if x.rng(CW) is None or b.rng(CW) is None else x.rng(CW) - b.rng(CW)))
    out.append((1, 'F 组（写法本身不应改变选择）；N3_F0 top1 = %s' % t, cs))

    out.append((2, 'D1（期间事实：没人来）', [
        check('guard_hut: N3_D1 < N3_F0', lambda a, b: a < b, g('N3_D1'), g('N3_F0')),
        check('visit_plaza: N3_D1 > N3_F0', lambda a, b: a > b, v('N3_D1'), v('N3_F0'))]))
    out.append((3, 'D1r（期间事实：有人来过又走）', [
        check('guard_hut: N3_D1r >= N3_F0 - 0.05', lambda a, b: a >= b - 0.05, g('N3_D1r'), g('N3_F0')),
        check('guard_hut: N3_D1r > N3_D1', lambda a, b: a > b, g('N3_D1r'), g('N3_D1'))]))
    out.append((4, 'D2（只有推断）', [
        check('visit_plaza: N3_D2 > N3_F0', lambda a, b: a > b, v('N3_D2'), v('N3_F0')),
        check('visit_plaza: N3_D2 <= N3_D12', lambda a, b: a <= b, v('N3_D2'), v('N3_D12'))]))
    out.append((5, 'D12（事实 + 推断，叠加性）', [
        check('visit_plaza: N3_D12 >= N3_D1', lambda a, b: a >= b, v('N3_D12'), v('N3_D1')),
        check('visit_plaza: N3_D12 >= N3_D2', lambda a, b: a >= b, v('N3_D12'), v('N3_D2')),
        check('guard_hut: N3_D12 <= N3_D1', lambda a, b: a <= b, g('N3_D12'), g('N3_D1')),
        check('guard_hut: N3_D12 <= N3_D2', lambda a, b: a <= b, g('N3_D12'), g('N3_D2'))]))
    out.append((6, 'D12r（反向叠加）', [
        check('guard_hut: N3_D12r >= N3_D1r', lambda a, b: a >= b, g('N3_D12r'), g('N3_D1r'))]))
    out.append((7, '不被压掉', [
        check('V3_D1 top1==confront_wrecker 次数 >= 3', lambda n: n >= 3, S['V3_D1'].top1[CW] if S['V3_D1'].n else None),
        check('V3_D12 top1==confront_wrecker 次数 >= 3', lambda n: n >= 3, S['V3_D12'].top1[CW] if S['V3_D12'].n else None),
        check('S3_D12 mean(confront_wrecker) <= 0.05', lambda a: a <= 0.05, S['S3_D12'].mean(CW)),
        check('S3_F0 top1==guard_hut 次数 >= 3', lambda n: n >= 3, S['S3_F0'].top1[GH] if S['S3_F0'].n else None)]))
    return out


def report(a):
    data = json.load(open(a.results, encoding='utf-8'))
    rows = data['rows']
    cands = data['candidates']
    lat = [r['latency_ms'] for r in rows if 'latency_ms' in r]
    print('S1-H round 1 | model', data['model'], '| requests', len(rows), '| answered', sum('answer' in r for r in rows),
          '| failed', sum('answer' not in r for r in rows), '| latency_ms median', statistics.median(lat) if lat else '-',
          'min', min(lat, default='-'), 'max', max(lat, default='-'))
    S = {k: Stat(rows, k) for k in KEYS}
    for k in KEYS:
        s = S[k]
        print('\n%s | answered %d/%d | top1 %s' % (k, s.n, REPEATS, ', '.join('%s %d' % kv for kv in s.top1.most_common()) or '-'))
        order = [x for x in (GH, VP, CW) if x in cands] + [x for x in cands if x not in (GH, VP, CW)]
        for cand in order:
            v = s.p.get(cand)
            print('  %-18s mean %s  min %s  max %s' % (cand, '%.3f' % s.mean(cand) if v else '-', '%.3f' % min(v) if v else '-',
                                                      '%.3f' % max(v) if v else '-'))
    print('\n==== 与 plan.md 8 条期望逐条比对 ====')
    for no, title, cs in judge(S):
        ok = all(x for x, _ in cs)
        print('\n期望 %d %s：%s' % (no, title, '成立' if ok else '落空'))
        for x, d in cs:
            print('  [%s] %s' % ('成立' if x else '落空', d))
    print('\n期望 8：汇报格式（成立 / 落空、概率移动方向与量、归因），不判定。')


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('dryrun')
    sub.add_parser('run')
    sub.add_parser('report').add_argument('--results', type=Path, default=RESULTS)
    args = ap.parse_args()
    {'dryrun': dryrun, 'run': run, 'report': report}[args.cmd](args)
