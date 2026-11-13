"""只测试：S1-K——按游戏时间措辞的驱动测量与正向驱动叠加（离线，只打 Jev；探索性，不是验收；不判定期望）。
只向 Jev 发请求（HTTPS），不起服务端 / 容器 / 任何长驻进程。素材 N3 / V3、候选表 T1、请求模板、概率读数沿用 s1h_design.py / s1e_design.py /
s1c2_counterfactual.py（import，不改它们）；格式与流程同 s1i_design.py。
计划与期望（由统筹会话持有）：.demo/observe/npc-slice1-20261112/s1k/plan.md。

游戏时间：整数微秒重写 apps/mmo_contracts/lib/mmo_contracts/world_time.ex 的公式与常量（game_us(t) = game0 + (t - epoch_us) * rate；
epoch_us = 1_792_972_800_000_000、game0 = 6 小时、rate = 72），不手填任何时刻；“多久以前” = 两个真实时刻的游戏时间差，按 plan.md 换词规则：
小时数四舍五入到 0.5；不足 0.25 小时写 `Just now`；>= 48 小时写天；整数小时 1 写 `1 hour`，其余 `N hours`（含 `0.5 hours`、`13.5 hours`）。
日内时段：05–11 morning、12–16 afternoon、17–20 evening、其余 night。

变体（17 个 x 4 次 = 68 次请求；写到 .demo/observe/npc-slice1-20261112/s1k/variants/<名>.txt + template.json + edits.txt）：
  N3_F0 原文 | N3_T1 “What just happened” 10 句的 `At <UTC> (UTC),` 换成 `About N hours ago,` / `Just now,` | N3_T2 最前面加 Now 行
  N3_E1h / E14h / E3d  Feelings 那句 `...who is not nearby.` -> `...who is not nearby: he removed my hut about <X> ago.`（X = 1 hour / 真值 / 3 days）
  N3_Dsoc / DsocL  Now 行后接 ` I last spent time with other people about <X> ago.`（X = 真值 / 2 days）
  N3_Pdue / Plater  Now 行 + 最后一行 `Plans and promises: ... tonight.` / `... tomorrow morning.`
  N3_S2 = E14h + Dsoc；S3 = S2 + 期间事实 `During those N guards nobody came near the hut.`；S4 = S3 + Pdue 约定行；
  N3_S5 / S5u = S4 + “What I remember” 末尾一行 `- Reflection (my own conclusion, may be wrong): <clean>`（s1i/outputs2 的 m1-C-A2-2 / m1-R-A1-4）
  V3_F0 原文 | V3_S4 在 V3 上做与 S4 相同的四处（时刻、真值、句数按 V3）
干跑断言：每个变体由“声明的改动片段”顺序施加；独立核对 = 把片段倒序还原必须逐字节得到原文，每个插入片段恰出现声明次数，
声明栏之外的栏逐字节不变，叠加变体的片段恰是各成分片段之和。任何一条不过即报错停下（run 不会开始）。

用法（Windows 控制台输出中文需加 -X utf8）：
  python -I -B s1k_design.py dryrun    # 生成变体 + edits.txt，断言；不发请求
  python -I -B s1k_design.py run       # 发问：并发 <= 3，超时同 s1c2（60 s），失败最多重试 2 次；要求 dryrun 已通过；结果文件已存在则拒绝覆盖
凭据同 s1h_design.py：run 只读主检出 .env 的 TYPESAFE_* 进本进程环境；值不打印、不写文件；只记录模型名。

结果 JSON（results-s1k.json）形状同 results-s1i.json：
  {"model", "repeats_note", "workers": 3, "timeout_s": 60, "max_retries": 2, "candidates": [...], "started", "finished",
   "requests", "answered", "failed",
   "variants": [ {"variant", "source": "N3"|"V3", "key": null, "state_file": "s1k/variants/<名>.txt", "model",
                  "requests": [ {"repeat", "ok", "top1", "probs": {候选: 概率}, "attempts", "latency_ms", "error", "time"} ... ],
                  "time"} ... ]}
"""
import argparse, datetime, json, re, sys, time
from concurrent.futures import ThreadPoolExecutor
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # python -I 不把脚本目录放进 sys.path
import s1c2_counterfactual as c
import s1e_design as e
import s1h_design as h

HERE = Path(__file__).resolve().parent
DEMO = e.DEMO
OUT = DEMO / 's1k/variants'
RESULTS = HERE / 'results-s1k.json'
REFL_JSON = DEMO / 's1i/outputs2/outputs.json'
REFL_KEYS = {'S5': 'm1-C-A2-2', 'S5u': 'm1-R-A1-4'}
SOURCES = {k: e.SOURCES[k] for k in ('N3', 'V3')}
WORKERS, TIMEOUT, MAX_RETRIES = min(c.WORKERS, 3), c.TIMEOUT, 2
REPEATS = 4
WJH, MEM = h.WJH, h.MEM

# ---------------------------------------------------------------- 游戏时间（出处：MmoContracts.WorldTime，整数微秒）
MINUTE_US = 60_000_000
HOUR_US = 60 * MINUTE_US
DAY_US = 24 * HOUR_US
EPOCH_US, GAME0, RATE = 1_792_972_800_000_000, 6 * HOUR_US, 72


def game_us(t_us):
    return GAME0 + (t_us - EPOCH_US) * RATE


def minute_of_day(t_us):
    return (game_us(t_us) % DAY_US) // MINUTE_US  # Python 的 % 与 // 对负数也是向下取整，同 Integer.mod / floor_div


def unix_us(iso):
    m = re.fullmatch(r'(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?Z', iso)
    assert m, iso
    y, mo, d, hh, mi, ss = map(int, m.groups()[:6])
    frac = int((m.group(7) or '0').ljust(6, '0'))
    days = (datetime.date(y, mo, d) - datetime.date(1970, 1, 1)).days
    return ((days * 24 + hh) * 60 + mi) * 60 * 1_000_000 + ss * 1_000_000 + frac


def period(minute):
    hour = minute // 60
    return 'morning' if 5 <= hour <= 11 else 'afternoon' if 12 <= hour <= 16 else 'evening' if 17 <= hour <= 20 else 'night'


def now_line(asked_us):
    m = minute_of_day(asked_us)
    return 'Now: It is %s, %02d:%02d.' % (period(m), m // 60, m % 60)


def hours_between(t_then_us, t_now_us):
    return Fraction(game_us(t_now_us) - game_us(t_then_us), HOUR_US)


def words_ago(t_then_us, t_now_us):
    """返回不含 about / ago 的词：'Just now' 或 'N hours' / '1 hour' / 'N days'。"""
    hrs = hours_between(t_then_us, t_now_us)
    if hrs < Fraction(1, 4):
        return 'Just now'
    if hrs >= 48:
        n = int(hrs / 24 + Fraction(1, 2))
        return '%d day%s' % (n, '' if n == 1 else 's')
    halves = int(hrs * 2 + Fraction(1, 2))  # 四舍五入到 0.5 小时（hrs 为正，int 即向下取整）
    if halves % 2 == 0:
        n = halves // 2
        return '%d hour%s' % (n, '' if n == 1 else 's')
    return '%d.5 hours' % (halves // 2)


ASKED = {'N3': '2026-11-13T01:12:50.994Z', 'V3': '2026-11-13T01:13:53.298Z'}  # 素材文件名里的时刻
WRECKED = '2026-11-13T01:01:25.591Z'   # 屋被拆
SOCIAL_END = '2026-11-13T01:07:04.875Z'  # 去广场结束
STAMP = re.compile(r'At (\d{4}-\d{2}-\d{2}T[\d:.]+Z) \(UTC\), ')
FEEL = {'N3': 'Distrusts actor 920628760578, who is not nearby.', 'V3': 'Distrusts Corvin (actor 920628760578).'}
D1_FMT = h.D1_FMT
PDUE = 'Plans and promises: Maren and I agreed to meet at the plaza tonight.'
PLATER = 'Plans and promises: Maren and I agreed to meet at the plaza tomorrow morning.'
REFL_FMT = '- Reflection (my own conclusion, may be wrong): %s'


# ---------------------------------------------------------------- 片段与成分
# 片段 (kind, old, new, 栏)：
#   prefix  整个文本前面插入 new（new 以换行结尾）；suffix 文本末尾（尾换行之前）插入 '\n' + new；
#   replace 文本里唯一出现的 old 换成 new。栏 = 受影响的 state 栏（prefix / suffix 的 Now / Plans 行不是栏，记 None）。
def pieces_for(comp, src, text, ctx):
    asked = unix_us(ASKED[src])
    true_e, true_d = words_ago(unix_us(WRECKED), asked), words_ago(unix_us(SOCIAL_END), asked)
    ns = ctx['n_guard'][src]
    if comp == 'T1':
        out = []
        for m in STAMP.finditer(text):
            w = words_ago(unix_us(m.group(1)), asked)
            new = 'Just now, ' if w == 'Just now' else 'About %s ago, ' % w
            out.append(('replace', m.group(0), new, WJH))
        assert len(out) == ns, (comp, src, len(out), ns)
        return out
    if comp == 'NOW':
        return [('prefix', None, now_line(asked) + '\n', None)]
    if comp in ('DSOC', 'DSOCL'):
        x = true_d if comp == 'DSOC' else '2 days'
        return [('prefix', None, now_line(asked) + ' I last spent time with other people about %s ago.\n' % x, None)]
    if comp in ('E1H', 'E14H', 'E3D'):
        x = {'E1H': '1 hour', 'E14H': true_e, 'E3D': '3 days'}[comp]
        old = FEEL[src]
        assert old.endswith('.')
        return [('replace', old, old[:-1] + ': he removed my hut about %s ago.' % x, 'Feelings and relationships')]
    if comp == 'DUR':
        tail = 'Result: completed.\nWhat I remember:'
        return [('replace', tail, 'Result: completed. ' + D1_FMT % ns + '\nWhat I remember:', WJH)]
    if comp in ('PDUE', 'PLATER'):
        return [('suffix', None, PDUE if comp == 'PDUE' else PLATER, None)]
    if comp in ('REFL', 'REFLU'):
        clean = ctx['refl'][REFL_KEYS['S5' if comp == 'REFL' else 'S5u']]
        old = '\nCurrent situation: '
        return [('replace', old, '\n' + REFL_FMT % clean + old, MEM)]
    raise KeyError(comp)


def apply(kind, old, new, text):
    if kind == 'prefix':
        return new + text
    if kind == 'suffix':
        body = text[:-1] if text.endswith('\n') else text
        return body + '\n' + new + text[len(body):]
    assert text.count(old) == 1, 'old text not unique: %r' % old[:60]
    return text.replace(old, new, 1)


def unapply_all(pcs, text, source):
    """独立的还原（不复用 apply）：从成品里删掉 / 换回声明的片段。replace 片段按其 old 在原文里的先后位置顺序还原
    （T1 的新词会重复，只能按位置）；prefix / suffix 先去掉。"""
    for kind, old, new, _ in pcs:
        if kind == 'prefix':
            assert text.startswith(new), 'prefix piece missing'
            text = text[len(new):]
        elif kind == 'suffix':
            end = chr(10) + new
            i = text.rfind(end)
            assert i >= 0 and text[i + len(end):] in ('', chr(10)), 'suffix piece not at the end'
            text = text[:i] + text[i + len(end):]
    reps = sorted((p for p in pcs if p[0] == 'replace'), key=lambda p: source.index(p[1]))
    cursor = 0
    for _, old, new, _ in reps:
        if len(new) > 40:  # 长片段（事实句 / 反思 / 关系史）必须恰出现一次
            assert text.count(new) == 1, 'inserted piece count != 1: %r' % new[:60]
        i = text.find(new, cursor)
        assert i >= 0, 'declared piece not found in order: %r' % new[:60]
        text = text[:i] + old + text[i + len(new):]
        cursor = i + len(old)
    return text


def compose(*parts):
    return [p for p in parts]


# 变体 -> 成分（plan.md；叠加变体 = 各成分之和）。Now 行并入 DSOC / DSOCL，不另加 NOW。
VARIANTS = [
    ('N3_F0', 'N3', []), ('N3_T1', 'N3', ['T1']), ('N3_T2', 'N3', ['NOW']),
    ('N3_E1h', 'N3', ['E1H']), ('N3_E14h', 'N3', ['E14H']), ('N3_E3d', 'N3', ['E3D']),
    ('N3_Dsoc', 'N3', ['DSOC']), ('N3_DsocL', 'N3', ['DSOCL']),
    ('N3_Pdue', 'N3', ['NOW', 'PDUE']), ('N3_Plater', 'N3', ['NOW', 'PLATER']),
    ('N3_S2', 'N3', ['E14H', 'DSOC']), ('N3_S3', 'N3', ['E14H', 'DSOC', 'DUR']),
    ('N3_S4', 'N3', ['E14H', 'DSOC', 'DUR', 'PDUE']),
    ('N3_S5', 'N3', ['E14H', 'DSOC', 'DUR', 'PDUE', 'REFL']),
    ('N3_S5u', 'N3', ['E14H', 'DSOC', 'DUR', 'PDUE', 'REFLU']),
    ('V3_F0', 'V3', []), ('V3_S4', 'V3', ['E14H', 'DSOC', 'DUR', 'PDUE']),
]
# 每个变体声明的改动处数（plan.md 的“只动一栏一处 / 叠加各处之和”），独立于上面的成分表手写，用来核对成分表没写错
DECLARED_SPOTS = {'N3_F0': 0, 'N3_T1': 10, 'N3_T2': 1, 'N3_E1h': 1, 'N3_E14h': 1, 'N3_E3d': 1, 'N3_Dsoc': 1, 'N3_DsocL': 1,
                  'N3_Pdue': 2, 'N3_Plater': 2, 'N3_S2': 2, 'N3_S3': 3, 'N3_S4': 4, 'N3_S5': 5, 'N3_S5u': 5,
                  'V3_F0': 0, 'V3_S4': 4}
DECLARED_SECTIONS = {'N3_F0': set(), 'N3_T1': {WJH}, 'N3_T2': set(), 'N3_E1h': {'Feelings and relationships'},
                     'N3_E14h': {'Feelings and relationships'}, 'N3_E3d': {'Feelings and relationships'}, 'N3_Dsoc': set(),
                     'N3_DsocL': set(), 'N3_Pdue': set(), 'N3_Plater': set(), 'N3_S2': {'Feelings and relationships'},
                     'N3_S3': {'Feelings and relationships', WJH}, 'N3_S4': {'Feelings and relationships', WJH},
                     'N3_S5': {'Feelings and relationships', WJH, MEM}, 'N3_S5u': {'Feelings and relationships', WJH, MEM},
                     'V3_F0': set(), 'V3_S4': {'Feelings and relationships', WJH}}
KEYS = [v[0] for v in VARIANTS]
assert len(VARIANTS) == 17


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')


def template():
    return h.template()


def load_ctx(texts):
    refl = {r['key']: r['clean'] for r in json.load(open(REFL_JSON, encoding='utf-8'))}
    for k in REFL_KEYS.values():
        assert k in refl and refl[k] and '\n' not in refl[k], k
    return {'refl': refl, 'n_guard': {k: h.guard_n(c.State(t)) for k, t in texts.items()}}


def build(name, src, comps, texts, ctx):
    text = texts[src]
    pcs = []
    for comp in comps:
        pcs += pieces_for(comp, src, texts[src], ctx)
    # 先施加 prefix / replace / suffix；顺序固定：replace 先（针对原文），再 suffix，最后 prefix
    order = {'replace': 0, 'suffix': 1, 'prefix': 2}
    pcs.sort(key=lambda p: order[p[0]])
    # prefix 只允许一个（Now 行并入 DSOC 时不再单独加 NOW）
    assert sum(p[0] == 'prefix' for p in pcs) <= 1, name
    for p in pcs:
        text = apply(*p[:3], text)
    return text, pcs


def dryrun(a):
    OUT.mkdir(parents=True, exist_ok=True)
    json.dump(template(), open(OUT / 'template.json', 'w', encoding='utf-8', newline='\n'), indent=1, ensure_ascii=False)
    texts = {k: p.read_text(encoding='utf-8') for k, p in SOURCES.items()}
    ctx = load_ctx(texts)
    ev = {}
    for k in ('N3', 'V3'):
        t = unix_us(ASKED[k])
        ev[k] = {'asked': ASKED[k], 'now_line': now_line(t), 'game_hours_since_wrecked': float(hours_between(unix_us(WRECKED), t)),
                 'E_word': words_ago(unix_us(WRECKED), t), 'Dsoc_word': words_ago(unix_us(SOCIAL_END), t),
                 'game_hours_since_social_end': float(hours_between(unix_us(SOCIAL_END), t))}
    edits = ['S1-K game-time wording (dry run)',
             'game clock (MmoContracts.WorldTime, integer microseconds): game_us(t) = game0 + (t - epoch_us) * rate; '
             'epoch_us=%d game0=6h rate=%d' % (EPOCH_US, RATE),
             'sources: ' + ', '.join('%s = %s' % (k, p) for k, p in SOURCES.items()),
             'asked-at: ' + ', '.join('%s = %s' % kv for kv in ASKED.items()),
             'hut removed at %s ; last time with people ended %s' % (WRECKED, SOCIAL_END),
             'guard_hut sentences in "What just happened": ' + ', '.join('%s=%d' % kv for kv in ctx['n_guard'].items())]
    for k, v in ev.items():
        edits.append('%s computed: %s | removed-hut elapsed %.3f game h -> "%s" | social elapsed %.3f game h -> "%s"' % (
            k, v['now_line'], v['game_hours_since_wrecked'], v['E_word'], v['game_hours_since_social_end'], v['Dsoc_word']))
    edits.append('')
    built = {}
    for name, src, comps in VARIANTS:
        out, pcs = build(name, src, comps, texts, ctx)
        built[name] = (src, comps, pcs)
        before_secs = c.State(texts[src])
        # 1. 改动处数 = 声明
        assert len(pcs) == DECLARED_SPOTS[name], '%s: spots %d != declared %d' % (name, len(pcs), DECLARED_SPOTS[name])
        # 2. 独立还原：倒序还原得原文
        back = unapply_all(pcs, out, texts[src])
        assert back == texts[src], '%s: reversing the declared edits does not give the source' % name
        # 3. 声明栏之外逐字节不变：去掉 Now 行 / Plans 行后按栏解析比较
        core = unapply_all([p for p in pcs if p[0] in ('prefix', 'suffix')], out, texts[src])
        changed = {t for t in c.TITLES if c.State(core).sec[t] != before_secs.sec[t]}
        assert changed == DECLARED_SECTIONS[name], '%s: changed sections %s != declared %s' % (name, sorted(changed), sorted(DECLARED_SECTIONS[name]))
        assert {p[3] for p in pcs if p[3]} == DECLARED_SECTIONS[name], name
        # 4. 行级：除声明的栏与首 / 末新增行外，其余行逐字节不变
        lo, ln = texts[src].split('\n'), out.split('\n')
        if any(p[0] == 'prefix' for p in pcs):
            assert ln[0].startswith('Now: It is '), name
            ln = ln[1:]
        if any(p[0] == 'suffix' for p in pcs):
            assert ln[-1].startswith('Plans and promises: '), name
            ln = ln[:-1]
        if name.endswith(('_S5', '_S5u')):  # 新增的一整行反思（在 What I remember 栏内）：先去掉它再逐行对
            r_ix = [i for i, l in enumerate(ln) if l.startswith('- Reflection (my own conclusion')]
            assert len(r_ix) == 1, name
            del ln[r_ix[0]]
        assert len(ln) == len(lo), name
        titles_by_line = {}
        for i, l in enumerate(lo):
            for t in c.TITLES:
                if l.startswith(t + ': '):
                    titles_by_line[i] = t
        cur, sec_of = None, []
        for i in range(len(lo)):
            cur = titles_by_line.get(i, cur)
            sec_of.append(cur)
        for i in range(len(lo)):
            if lo[i] != ln[i]:
                assert sec_of[i] in DECLARED_SECTIONS[name], '%s: line %d (%s) changed outside declared sections' % (name, i + 1, sec_of[i])
        # 5. 叠加变体的片段恰是成分片段之和
        total = []
        for comp in comps:
            total += pieces_for(comp, src, texts[src], ctx)
        assert sorted(map(repr, total)) == sorted(map(repr, pcs)), name
        if not comps:
            assert out == texts[src], '%s: unchanged variant differs from its source' % name
        (OUT / (name + '.txt')).write_bytes(out.encode('utf-8'))
        edits += ['=== %s  (source %s, %d requests, %d spots)' % (name, SOURCES[src].name, REPEATS, len(pcs)),
                  'components: ' + (' + '.join(comps) or 'none (copy of source)'),
                  'changed sections: ' + (', '.join(t for t in c.TITLES if t in changed) or 'none')]
        for kind, old, new, sec in pcs:
            if kind == 'prefix':
                edits.append('  added as the first line (before "Character"): %s' % new.rstrip('\n'))
            elif kind == 'suffix':
                edits.append('  added as the last line: %s' % new)
            elif name.endswith('_T1'):
                edits.append('  "%s" -> "%s"' % (old, new))
            else:
                shown = new if len(new) < 220 else new[:200] + '...'
                edits.append('  [%s] "%s" -> "%s"' % (sec, old.strip() if len(old) < 120 else old[:60] + '...', shown.strip()))
        edits += ['  self-check: reversing the declared edits gives the source byte-for-byte; no line outside the declared sections changed: OK', '']
    # 汇总：换算出的词
    edits += ['--- converted words', 'N3 T1 ten openings: ' + ' | '.join(p[2].rstrip(', ') for p in built['N3_T1'][2]),
              'V3 (what V3_S4 would give for a T1 rewrite; not a variant): ' + ' | '.join(
                  p[2].rstrip(', ') for p in map(lambda x: x, pieces_for('T1', 'V3', texts['V3'], ctx)))]
    (OUT / 'edits.txt').write_text('\n'.join(edits) + '\n', encoding='utf-8', newline='\n')
    print('dryrun OK: %d variants, %d requests planned; assertions all passed; wrote to %s' % (len(VARIANTS), len(VARIANTS) * REPEATS, OUT))
    for k, v in ev.items():
        print(k, v['now_line'], '| E:', v['E_word'], '(%.3f h)' % v['game_hours_since_wrecked'], '| Dsoc:', v['Dsoc_word'],
              '(%.3f h)' % v['game_hours_since_social_end'])
    print('N3 T1:', ' | '.join(p[2].rstrip(', ') for p in built['N3_T1'][2]))
    print('V3 T1 (reference):', ' | '.join(p[2].rstrip(', ') for p in pieces_for('T1', 'V3', texts['V3'], ctx)))


def run(a):
    if RESULTS.exists():
        raise SystemExit('%s exists; refusing to overwrite' % RESULTS)
    missing = [n for n in KEYS if not (OUT / (n + '.txt')).exists()]
    if missing or not (OUT / 'template.json').exists():
        raise SystemExit('run dryrun first (missing: %s)' % (missing[:3] or 'template.json'))
    tpl = json.load(open(OUT / 'template.json', encoding='utf-8'))
    texts = {n: (OUT / (n + '.txt')).read_text(encoding='utf-8') for n in KEYS}
    cands = [x['name'] for x in tpl['candidates']]
    c.load_env()
    from jev import ask, ENV
    q = c.question(tpl)
    cells = [(n, r + 1) for n in KEYS for r in range(REPEATS)]
    started = now()

    def one(cell):
        name, rep = cell
        row = {'repeat': rep, 'ok': False, 'top1': None, 'probs': None, 'attempts': 0, 'latency_ms': None, 'error': None}
        for attempt in range(1 + MAX_RETRIES):
            row['attempts'] = attempt + 1
            if attempt:
                time.sleep(3 * attempt)
            try:
                answers, _, seconds = ask(texts[name], q, timeout=TIMEOUT)
            except Exception as ex:  # 网络 / 超时
                row['error'] = type(ex).__name__
                continue
            if 'error' in answers:
                row['error'] = 'http %s' % answers['error']
                continue
            ans = answers.get('activity')
            if not isinstance(ans, dict) or 'choice' not in ans:
                row['error'] = 'malformed answer'
                continue
            row.update(ok=True, top1=ans['choice'], probs=ans.get('probabilities'), latency_ms=round(seconds * 1000), error=None)
            break
        row['time'] = now()
        return name, row

    with ThreadPoolExecutor(WORKERS) as pool:
        got = list(pool.map(one, cells))
    by = {}
    for name, row in got:
        by.setdefault(name, []).append(row)
    variants = [{'variant': n, 'source': src, 'key': None, 'state_file': 's1k/variants/%s.txt' % n, 'model': ENV['TYPESAFE_MODEL'],
                 'requests': sorted(by[n], key=lambda r: r['repeat']), 'time': max(r['time'] for r in by[n])}
                for n, src, _ in VARIANTS]
    ok = sum(r['ok'] for _, r in got)
    data = {'model': ENV['TYPESAFE_MODEL'], 'repeats_note': 'every variant 4 requests', 'workers': WORKERS, 'timeout_s': TIMEOUT,
            'max_retries': MAX_RETRIES, 'candidates': cands, 'started': started, 'finished': now(), 'requests': len(got),
            'answered': ok, 'failed': len(got) - ok, 'variants': variants}
    json.dump(data, open(RESULTS, 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
    print('requests', len(got), 'answered', ok, 'failed', len(got) - ok, '->', RESULTS)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name in ('dryrun', 'run'):
        sub.add_parser(name)
    args = ap.parse_args()
    {'dryrun': dryrun, 'run': run}[args.cmd](args)
