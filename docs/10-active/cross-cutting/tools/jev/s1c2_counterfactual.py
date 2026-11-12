"""只测试：S1-C2 实跑之后的离线逐栏对照（B / S / V 三组真实 state）。只向 Jev 发请求（HTTPS），不起服务端。
合同来源：.demo/observe/npc-slice1-20261112/s1c2/plan.md “离线逐栏对照”一节；下面的期望与判定规则逐字抄自该节，
运行前定稿，不许改；落空如实记落空。办法同 s1c2_pilot.py（请求体与 Selector.body 一致，同一 instructions、
同一候选表与次序；二者取自 --template 那个 JSON，格式 {"instructions": "...", "candidates": [{"name": ..., "criterion": ...}, ...]}，
候选次序即发问次序）。

==== plan.md 原文（抄录） ====
每个变体问 4 次，≥ 3 / 4 算成立；先做复现检查。并发 ≤ 3，单次超时 60 秒，不重试；请求失败计为不符合，不补问。
变体全文与逐行删改写进 counterfactual/，统筹会话核对后再问。
原文复现不成立时，其余变体照问、只作记录，该项判不通过。栏目删空时的写法以 mind.ex 为准。
“重建方向” = top1 ∈ {build_hut, gather_stone}。

B 那次 state：
| 变体 | 做法 | 期望 |
| original | 原文（复现） | 重建方向 |
| no_event | 去掉“What just happened”里那一整句事件（含情绪尾巴） | 重建方向 |
| no_gone | 去掉处境里 `is gone` 一句 | 重建方向 |
| no_event_no_gone | 两处都去掉 | 不在重建方向 |
| no_anger | 只去掉情绪栏愤怒一句 | 不变（重建方向） |
| no_distrust | 只去掉 Distrusts 一句 | 不变（重建方向） |
| no_own_activity | 去掉自己的 `I did …` 条目与 Recent activities 条目（空栏写 `None yet.`） | 不变（重建方向） |
| all_removed | 事件句、`is gone`、愤怒、Distrusts 全去 | `visit_plaza` |
(b) 通过 = 在线 B 的 top1 在重建方向且 state 含两句事实 + original 复现成立 + no_event_no_gone 不在重建方向 + all_removed 回到 `visit_plaza`。
单栏变体（no_event / no_gone / no_anger / no_distrust / no_own_activity）是记录项，说明哪一栏单独就够。

S 第 1 次 state：original ×4（复现 S 的在线 top1，作为 (c) 的基线）。

V 第 1 次 state：
| 变体 | 做法 | 期望 |
| original | 原文（复现） | 与在线 V 第 1 次 top1 相同 |
| no_memory | 记忆栏按下面的固定规则去掉提到那件事或该角色的行 | 不变（Distrusts + 在附近就够） |
| no_distrust | 只去掉 Distrusts 一句 | 不变（只凭记忆仍偏离基线） |
| no_memory_no_distrust | 两处都去掉 | 回到 S 的基线 top1 |
| no_own_activity | 去掉自己的 `I did …` 条目与 Recent activities 条目 | 不变 |
| nobody_nearby | Nearby 改回 `Nobody else is nearby.`，Distrusts 改回 `Distrusts actor V, who is not nearby.` | `visit_plaza` |
| memory_blank_no_distrust（记录项） | 整个记忆栏清成产品的空栏写法，并去掉 Distrusts | 回到 S 的基线 top1 |
no_memory 的固定规则（运行前定，不按结果调）：“What I remember”里凡含 V 的 cid、`Corvin`，或（不分大小写）词干
`remov` / `destroy` / `dismantl` / `demolish` / `tore` / `torn` / `damag` / `vandal` / `rebuil` 之一的行——召回行整行删，
`- Belief (…):` 行保留标签、清空正文。删了哪些行、剩下哪些行都列出来。
(c) 通过 = 在线 V 第 1 次 top1 ≠ S 第 1 次 top1 + 两份 original 复现成立 + no_distrust 仍 ≠ 基线（记忆单独起作用）+ no_memory_no_distrust 回到基线。
no_distrust 变回基线 → 效应来自不衰减的信任而非记忆，(c) 不通过；no_memory_no_distrust 不回基线 → 来自别的栏，(c) 不通过（不确定）——
此时 memory_blank_no_distrust 只用来说明原因是不是在记忆栏里没被规则删到的行，不改判定。no_memory、no_own_activity、nobody_nearby 是记录项。
==== 抄录结束 ====

本脚本对“不变”这类期望的落地（可判定条件）：
  B 组“不变（重建方向）” = top1 ∈ 重建方向；
  V 组“不变” = top1 与 V original 的多数 top1 相同（“多数” = 4 次里至少 3 次同一个 top1，否则该条件“无法判定”）；
  “回到 S 的基线 top1” = top1 与 S original 的多数 top1 相同（同上）；
  V original “与在线 V 第 1 次 top1 相同” = top1 == --online-v；S original “复现 S 的在线 top1” = top1 == --online-s；
  “不在重建方向” = top1 ∉ {build_hut, gather_stone}（plan 原文；pilot 曾写成 {visit_plaza, guard_hut}，五项候选里差一个 gather_limestone）。
  请求失败 / 未应答不计命中；成立 = 命中数 ≥ 3（分母恒为 4 次发问）。
  (c) 的“≠ 基线”“回到基线”的基线 = S original 的多数 top1。
  变体计数：B 8 + S 1 + V 7 = 16，16 × 4 = 64 次请求。
  no_memory 的两处落地（plan“运行前补充”）：一条 Belief 占多行时按整条算，任一行命中就清空整条正文、保留标签；
  词干只在词首算命中。

栏目删空时的写法（NpcServer.Mind，apps/npc_server/lib/npc_server/mind.ex）：
  情绪栏空 `Nothing notable.`（第 96 行）；记忆栏空 `Nothing relevant.`（第 121 行）；
  What just happened 空 `Nothing new.`（第 118 行）；Recent activities 空 `None yet.`（第 179 行）；
  Nearby 无人 `Nobody else is nearby.`（第 152 行）；Belief 正文空 `- Belief (<id>): `（第 126 行，冒号后一个空格）。

用法：
  python -B s1c2_counterfactual.py prepare --b B.txt --s S.txt --v V.txt --vandal-cid CID --vandal-name Corvin --template T.json
  python -B s1c2_counterfactual.py run --template T.json
  python -B s1c2_counterfactual.py report [--online-b NAME] [--online-s NAME] [--online-v NAME]
凭据：run 在进程环境里没有 TYPESAFE_* 时，只读进主检出 D:/hemifuture/ex_mmo_cluster/.env 的 TYPESAFE_* 到本进程环境；值不打印、不写文件。
"""
import argparse, json, os, re, statistics, sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPEATS, WORKERS, TIMEOUT = 4, 3, 60
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
CF = ROOT / '.demo/observe/npc-slice1-20261112/s1c2/counterfactual'
OUT = HERE / 'results-s1c2-counterfactual.json'
MAIN_ENV = Path('D:/hemifuture/ex_mmo_cluster/.env')

REBUILD = {'build_hut', 'gather_stone'}

# ---------------------------------------------------------------- state 解析（栏 = 行首 `栏名: `）

TITLES = ['Character', 'Feelings and relationships', 'What just happened', 'What I remember',
          'Current situation', 'Recent activities']


class Missing(Exception):
    """应当存在的句 / 行没找到：显式报错，不静默跳过。"""


class State:
    def __init__(self, text):
        self.tail = '\n' if text.endswith('\n') else ''
        lines = text[:len(text) - len(self.tail)].split('\n')
        sec, cur, idx = {}, None, 0
        for line in lines:
            if idx < len(TITLES) and line.startswith(TITLES[idx] + ': '):
                cur = TITLES[idx]
                idx += 1
                sec[cur] = [line[len(cur) + 2:]]
            elif cur is None:
                raise Missing('state does not start with "%s: "' % TITLES[0])
            else:
                sec[cur].append(line)
        if idx != len(TITLES):
            raise Missing('section "%s" not found (in order)' % TITLES[idx])
        self.sec = {k: '\n'.join(v) for k, v in sec.items()}
        if self.render() != text:
            raise Missing('state does not round-trip through the section parser')

    def render(self):
        return '\n'.join(t + ': ' + self.sec[t] for t in TITLES) + self.tail


class Ctx:
    def __init__(self, cid, name):
        self.cid, self.name, self.lines = cid, name, []

    def log(self, s):
        self.lines.append(s)


# ---------------------------------------------------------------- What just happened

STAMP = re.compile(r'At \d{4}-\d{2}-\d{2}T[\d:.]+Z \(UTC\), ')
PREFIX = 'Oldest first. '
# life/state.ex account(:removed, …) 的原文 + 同一事件的情绪尾巴（可选；有无如实记）。
EVENT_RE = re.compile(r'At \S+ \(UTC\), Actor (\d+) removed the entire building "([^"]*)" that I built, [^;]*; '
                      r'the building no longer exists\.( I feel angry toward this actor; my trust changed\.)?')
OWN_RE = re.compile(r'At \S+ \(UTC\), I did "')


def entries_of(st):
    body = st.sec['What just happened']
    if body == 'Nothing new.':
        return []
    if not body.startswith(PREFIX):
        raise Missing('What just happened: does not start with %r' % PREFIX)
    rest = body[len(PREFIX):]
    starts = [m.start() for m in STAMP.finditer(rest)]
    if not starts or starts[0] != 0:
        raise Missing('What just happened: entries do not start with a timestamp')
    bounds = starts + [len(rest) + 1]  # 条目之间恰好一个空格；最后一条没有
    ents = [rest[a:b - 1] for a, b in zip(bounds, bounds[1:])]
    if ' '.join(ents) != rest:
        raise Missing('What just happened: entries do not rejoin to the original text')
    return ents


def set_entries(st, ents):
    st.sec['What just happened'] = (PREFIX + ' '.join(ents)) if ents else 'Nothing new.'


def find_event(st, cid=None):
    return [e for e in entries_of(st)
            if EVENT_RE.fullmatch(e) and (cid is None or EVENT_RE.fullmatch(e).group(1) == cid)]


def drop_event(st, cx):
    hit = find_event(st, cx.cid)
    if len(hit) != 1:
        raise Missing('What just happened: expected exactly 1 whole-removal event of actor %s ("removed the entire '
                      'building … no longer exists."), found %d' % (cx.cid, len(hit)))
    tail = EVENT_RE.fullmatch(hit[0]).group(3)
    cx.log('removed from "What just happened" the event entry (emotion tail %s): %s' % ('present' if tail else 'ABSENT', hit[0]))
    set_entries(st, [e for e in entries_of(st) if e != hit[0]])
    if st.sec['What just happened'] == 'Nothing new.':
        cx.log('  "What just happened" is now empty -> wrote "Nothing new."')


def drop_own_activity(st, cx):
    ents = entries_of(st)
    own = [e for e in ents if OWN_RE.match(e)]
    if not own:
        raise Missing('What just happened: no own `I did "…"` entry found')
    for e in own:
        cx.log('removed from "What just happened" the own-activity entry: ' + e)
    set_entries(st, [e for e in ents if not OWN_RE.match(e)])
    if st.sec['What just happened'] == 'Nothing new.':
        cx.log('  "What just happened" is now empty -> wrote "Nothing new."')
    recent = st.sec['Recent activities']
    if recent == 'None yet.':
        raise Missing('Recent activities: already "None yet." (no entry to remove)')
    cx.log('replaced the whole "Recent activities" body %r with "None yet."' % recent)
    st.sec['Recent activities'] = 'None yet.'


# ---------------------------------------------------------------- Current situation

GONE_RE = re.compile(r'My building "[^"]*" at \(\d+, \d+, \d+\) is gone\. ?')
NEARBY_RE = re.compile(r'Nearby: .*? m away\)\.')


def drop_gone(st, cx):
    body = st.sec['Current situation']
    hit = GONE_RE.findall(body)
    if len(hit) != 1:
        raise Missing('Current situation: expected exactly 1 `My building "…" at (x, y, z) is gone.` sentence, found %d' % len(hit))
    cx.log('removed from "Current situation": ' + hit[0].rstrip())
    st.sec['Current situation'] = GONE_RE.sub('', body)


def nobody_nearby_situation(st, cx):
    body = st.sec['Current situation']
    hit = NEARBY_RE.findall(body)
    if len(hit) != 1:
        raise Missing('Current situation: expected exactly 1 `Nearby: … m away).` sentence, found %d' % len(hit))
    if cx.name not in hit[0]:
        raise Missing('Current situation: Nearby sentence does not name %s: %s' % (cx.name, hit[0]))
    cx.log('replaced in "Current situation": %s  ->  Nobody else is nearby.' % hit[0])
    st.sec['Current situation'] = body.replace(hit[0], 'Nobody else is nearby.')


# ---------------------------------------------------------------- Feelings and relationships

SENT = re.compile(r'(?:Feels \w+ \w+ toward|Deeply distrusts|Distrusts|Deeply trusts|Trusts) '
                  r'(?:actor \d+, who is not nearby|.+? \(actor \d+\))\.')


def feelings_of(st):
    body = st.sec['Feelings and relationships']
    if body == 'Nothing notable.':
        return []
    ss = [m.group(0) for m in SENT.finditer(body)]
    if ' '.join(ss) != body:
        raise Missing('Feelings and relationships: cannot split into known sentences: %r' % body)
    return ss


def drop_feeling(st, cx, label, is_kind):
    ss = feelings_of(st)
    hit = [s for s in ss if is_kind(s) and re.search(r'actor %s\b' % cx.cid, s)]
    if not hit:
        raise Missing('Feelings and relationships: no %s sentence about actor %s in %r' % (label, cx.cid, ss))
    for s in hit:
        cx.log('removed from "Feelings and relationships": ' + s)
    rest = [s for s in ss if s not in hit]
    st.sec['Feelings and relationships'] = ' '.join(rest) or 'Nothing notable.'
    if not rest:
        cx.log('  "Feelings and relationships" is now empty -> wrote "Nothing notable."')


def drop_anger(st, cx):
    drop_feeling(st, cx, 'anger', lambda s: s.startswith('Feels ') and ' anger toward ' in s)


def drop_distrust(st, cx):
    drop_feeling(st, cx, 'Distrusts', lambda s: s.startswith(('Distrusts ', 'Deeply distrusts ')))


def distrust_not_nearby(st, cx):
    ss = feelings_of(st)
    named = re.compile(r'(Deeply distrusts|Distrusts) %s \(actor %s\)\.' % (re.escape(cx.name), cx.cid))
    hit = [s for s in ss if named.fullmatch(s)]
    if len(hit) != 1:
        raise Missing('Feelings and relationships: expected exactly 1 `Distrusts %s (actor %s).` sentence, found %d in %r'
                      % (cx.name, cx.cid, len(hit), ss))
    new = named.fullmatch(hit[0]).group(1) + ' actor %s, who is not nearby.' % cx.cid
    cx.log('replaced in "Feelings and relationships": %s  ->  %s' % (hit[0], new))
    out = [new if s == hit[0] else s for s in ss]
    others = [s for s in out if s != new and ('%s (actor %s)' % (cx.name, cx.cid)) in s]
    if others:
        cx.log('  WARNING: other sentences still name %s (not changed, plan only changes Distrusts): %s' % (cx.name, others))
    st.sec['Feelings and relationships'] = ' '.join(out)


# ---------------------------------------------------------------- What I remember

STEMS = ['remov', 'destroy', 'dismantl', 'demolish', 'tore', 'torn', 'damag', 'vandal', 'rebuil']
ITEM = re.compile(r'- Belief \(([^)]*)\):( |$)|- Recalled: ')


def memory_items(st):
    body = st.sec['What I remember']
    if body == 'Nothing relevant.':
        raise Missing('What I remember: product empty form "Nothing relevant." (nothing to remove)')
    lines = body.split('\n')
    items = []
    for line in lines[1:]:
        if ITEM.match(line):
            items.append([line])
        elif items:
            items[-1].append(line)
        else:
            raise Missing('What I remember: unexpected line before the first item: %r' % line)
    if not items:
        raise Missing('What I remember: no `- Belief (…):` / `- Recalled:` item found')
    return lines[0], items


def hits_in(line, cx):
    out = []
    if cx.cid in line:
        out.append('cid ' + cx.cid)
    if cx.name in line:
        out.append(cx.name)
    for stem in STEMS:
        ms = list(re.finditer(re.escape(stem), line, re.I))
        # 词干只在词首算命中（plan“运行前补充”第 2 条）：`tore` 不命中 `store` / `restore`。
        if any(m.start() == 0 or not line[m.start() - 1].isalnum() for m in ms):
            out.append(stem)
    return out


def no_memory(st, cx):
    head, items = memory_items(st)
    deleted, cleared, kept, out = [], [], [], [head]
    for item in items:
        hit_lines = [(l, hits_in(l, cx)) for l in item if hits_in(l, cx)]
        belief = ITEM.match(item[0]).group(1) is not None
        if not hit_lines:
            kept.extend('%s' % l for l in item if l.strip())
            out.extend(item)
        elif belief:
            label = '- Belief (%s): ' % ITEM.match(item[0]).group(1)
            cleared.append((label, hit_lines, len(item)))
            out.append(label)
            kept.append(label + '(body cleared)')
        else:
            deleted.append((item, hit_lines))
    cx.log('"What I remember" header line kept: ' + head)
    cx.log('DELETED recalled lines (%d):' % len(deleted))
    for item, hl in deleted:
        for l in item:
            cx.log('  - ' + l)
        cx.log('    matched: ' + '; '.join('%s' % ', '.join(h) for _, h in hl))
    cx.log('BELIEF lines with body cleared, label kept (%d):' % len(cleared))
    for label, hl, n in cleared:
        cx.log('  - %s<%d physical lines cleared>; matching physical lines:' % (label, n))
        for l, h in hl:
            cx.log('      [%s] %s' % (', '.join(h), l))
    cx.log('KEPT lines (non-blank physical lines; cleared beliefs shown as label only) (%d):' % len(kept))
    for l in kept:
        cx.log('  | ' + l)
    st.sec['What I remember'] = '\n'.join(out)


def memory_blank(st, cx):
    head, items = memory_items(st)
    cx.log('replaced the whole "What I remember" body (%d items: %s) with "Nothing relevant."'
           % (len(items), ', '.join(i[0].split(':')[0] for i in items)))
    st.sec['What I remember'] = 'Nothing relevant.'


# ---------------------------------------------------------------- 各组原文的前提检查（不改文本，只在应有的句缺失时报错）

def check_b(st, cx):
    ev, gone = find_event(st, cx.cid), GONE_RE.findall(st.sec['Current situation'])
    if len(ev) != 1 or len(gone) != 1:
        raise Missing('B state facts: whole-removal event entries of actor %s = %d, `is gone` sentences = %d (need 1 and 1)'
                      % (cx.cid, len(ev), len(gone)))
    if cx.name in st.sec['Current situation']:
        raise Missing('B state: %s appears in Current situation (vandal should not be nearby)' % cx.name)
    cx.log('(unchanged; B facts present: 1 event entry + 1 `is gone` sentence; vandal not in Current situation)')


def check_s(st, cx):
    hit = NEARBY_RE.findall(st.sec['Current situation'])
    if len(hit) != 1:
        raise Missing('S state: expected exactly 1 `Nearby: … m away).` sentence, found %d' % len(hit))
    cx.log('(unchanged; S Nearby sentence: %s)' % hit[0])


def check_v(st, cx):
    hit = NEARBY_RE.findall(st.sec['Current situation'])
    if len(hit) != 1 or cx.name not in hit[0]:
        raise Missing('V state: Nearby sentence missing or does not name %s: %r' % (cx.name, hit))
    cx.log('(unchanged; V Nearby sentence: %s)' % hit[0])


# ---------------------------------------------------------------- 变体表（次序即报告 / 发问次序）
# (组, 变体, 操作, 期望种类, 角色, 期望说明)
# 期望种类: rebuild | not_rebuild | plaza | online_S | online_V | same_V | base_S；角色: verdict = 验收项，record = 记录项。
VARIANTS = [
    ('B', 'original', [check_b], 'rebuild', 'verdict', '重建方向（复现）'),
    ('B', 'no_event', [drop_event], 'rebuild', 'record', '重建方向'),
    ('B', 'no_gone', [drop_gone], 'rebuild', 'record', '重建方向'),
    ('B', 'no_event_no_gone', [drop_event, drop_gone], 'not_rebuild', 'verdict', '不在重建方向'),
    ('B', 'no_anger', [drop_anger], 'rebuild', 'record', '不变（重建方向）'),
    ('B', 'no_distrust', [drop_distrust], 'rebuild', 'record', '不变（重建方向）'),
    ('B', 'no_own_activity', [drop_own_activity], 'rebuild', 'record', '不变（重建方向）'),
    ('B', 'all_removed', [drop_event, drop_gone, drop_anger, drop_distrust], 'plaza', 'verdict', 'visit_plaza'),
    ('S', 'original', [check_s], 'online_S', 'verdict', '复现 S 的在线 top1（(c) 的基线）'),
    ('V', 'original', [check_v], 'online_V', 'verdict', '与在线 V 第 1 次 top1 相同（复现）'),
    ('V', 'no_memory', [no_memory], 'same_V', 'record', '不变（Distrusts + 在附近就够）'),
    ('V', 'no_distrust', [drop_distrust], 'same_V', 'verdict', '不变（只凭记忆仍偏离基线；(c) 另判 ≠ S 基线）'),
    ('V', 'no_memory_no_distrust', [no_memory, drop_distrust], 'base_S', 'verdict', '回到 S 的基线 top1'),
    ('V', 'no_own_activity', [drop_own_activity], 'same_V', 'record', '不变'),
    ('V', 'nobody_nearby', [nobody_nearby_situation, distrust_not_nearby], 'plaza', 'record', 'visit_plaza'),
    ('V', 'memory_blank_no_distrust', [memory_blank, drop_distrust], 'base_S', 'record', '回到 S 的基线 top1（记录项）'),
]
KEYS = ['%s_%s' % (g, n) for g, n, *_ in VARIANTS]
PLAN_TOTAL = 16  # 8 + 1 + 7


def path_of(key):
    return CF / (key + '.txt')


# ---------------------------------------------------------------- prepare

def prepare(a):
    template = json.load(open(a.template, encoding='utf-8'))
    assert isinstance(template['instructions'], str) and template['candidates'], 'bad --template'
    sources = {'B': Path(a.b), 'S': Path(a.s), 'V': Path(a.v)}
    CF.mkdir(parents=True, exist_ok=True)
    report = ['sources: ' + ', '.join('%s = %s' % (g, p) for g, p in sources.items()),
              'vandal: cid %s, name %s' % (a.vandal_cid, a.vandal_name), '']
    errors, wrote = [], 0
    for (g, name, ops, *_), key in zip(VARIANTS, KEYS):
        path_of(key).unlink(missing_ok=True)
        cx = Ctx(a.vandal_cid, a.vandal_name)
        try:
            st = State(sources[g].read_text(encoding='utf-8'))
            for op in ops:
                op(st, cx)
            text = st.render()
        except Missing as e:
            errors.append('%s: %s' % (key, e))
            report += ['=== %s  ERROR (variant not written): %s' % (key, e), '']
            continue
        path_of(key).write_text(text, encoding='utf-8', newline='\n')
        wrote += 1
        report += ['=== %s  (source %s)' % (key, sources[g].name)] + ['  ' + l if not l.startswith('  ') else l
                                                                   for l in cx.lines] + ['']
    if errors:
        report = ['ERRORS (%d) -- listed variants were NOT written:' % len(errors)] + ['  ' + e for e in errors] + [''] + report
    (CF / 'edits.txt').write_text('\n'.join(report), encoding='utf-8', newline='\n')
    print('wrote %d / %d variants + edits.txt to %s (plan table: %d)' % (wrote, len(VARIANTS), CF, PLAN_TOTAL))
    for e in errors:
        print('ERROR', e)
    sys.exit(1 if errors else 0)


# ---------------------------------------------------------------- run

def load_env():
    if 'TYPESAFE_API_KEY' not in os.environ:
        for line in MAIN_ENV.read_text(encoding='utf-8').splitlines():
            if '=' in line and not line.startswith('#'):
                k, v = line.split('=', 1)
                if k.startswith('TYPESAFE_'):
                    os.environ[k] = v.strip()


def question(template):
    # 候选次序 = 模板里的次序；顶层键序同 s1c2_pilot.py（criteria、instructions、type）。
    return {'activity': {'criteria': {c['name']: c['criterion'] for c in template['candidates']},
                         'instructions': template['instructions'], 'type': 'choice'}}


def run(a):
    template = json.load(open(a.template, encoding='utf-8'))
    missing = [k for k in KEYS if not path_of(k).exists()]
    if missing:
        sys.exit('missing prepared variants (run prepare first): %s' % missing)
    texts = {k: path_of(k).read_text(encoding='utf-8') for k in KEYS}
    load_env()
    from jev import ask, ENV
    q = question(template)
    cells = [(k, r) for k in KEYS for r in range(REPEATS)]

    def one(cell):
        key, r = cell
        row = {'variant': key, 'repeat': r + 1}
        try:
            answers, _, seconds = ask(texts[key], q, timeout=TIMEOUT)
        except Exception as e:  # 网络 / 超时：如实记失败，不重试、不补问
            return {**row, 'error': type(e).__name__}
        row['latency_ms'] = round(seconds * 1000)
        if 'error' in answers:
            row['error'] = {'http': answers['error']}
        else:
            row['answer'] = answers['activity']
        return row

    with ThreadPoolExecutor(WORKERS) as pool:
        rows = list(pool.map(one, cells))
    data = {'model': ENV['TYPESAFE_MODEL'], 'repeats': REPEATS, 'workers': WORKERS, 'timeout_s': TIMEOUT,
            'template': str(a.template), 'candidates': [c['name'] for c in template['candidates']],
            'variants': {'%s_%s' % (g, n): {'expected': desc, 'role': role, 'kind': kind,
                                            'state_file': 's1c2/counterfactual/%s_%s.txt' % (g, n)}
                         for g, n, _, kind, role, desc in VARIANTS},
            'rows': rows}
    json.dump(data, open(OUT, 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
    print('requested', len(rows), 'answered', sum('answer' in r for r in rows), 'errors', sum('error' in r for r in rows))


# ---------------------------------------------------------------- report（离线，无模型调用）

class Results:
    def __init__(self, data, a):
        self.a = a
        self.rows = {k: sorted((r for r in data['rows'] if r['variant'] == k), key=lambda r: r['repeat']) for k in KEYS}

    def picks(self, key):
        return [r['answer']['choice'] for r in self.rows[key] if 'answer' in r]

    def majority(self, key):
        top = Counter(self.picks(key)).most_common(1)
        return top[0][0] if top and top[0][1] >= 3 else None

    def predicate(self, kind):
        """(判定 top1 的函数, 无法判定的原因)。"""
        online = {'online_S': self.a.online_s, 'online_V': self.a.online_v}
        if kind == 'rebuild':
            return (lambda c: c in REBUILD), None
        if kind == 'not_rebuild':
            return (lambda c: c not in REBUILD), None
        if kind == 'plaza':
            return (lambda c: c == 'visit_plaza'), None
        if kind in online:
            name = online[kind]
            return ((lambda c: c == name), None) if name else (None, 'needs --online-%s' % kind[-1].lower())
        key = {'same_V': 'V_original', 'base_S': 'S_original'}[kind]
        m = self.majority(key)
        return ((lambda c: c == m), None) if m else (None, '%s has no >=3/4 majority top1' % key)

    def judge(self, key, kind):
        """(状态, 命中数)；状态 MEETS / MISSES / INDETERMINATE (原因) / NOT RUN。"""
        if not self.rows[key]:
            return 'NOT RUN', None
        fn, why = self.predicate(kind)
        if fn is None:
            return 'INDETERMINATE (%s)' % why, None
        hits = sum(fn(c) for c in self.picks(key))
        return ('MEETS' if hits >= 3 else 'MISSES'), hits

    def count(self, key, fn):
        return sum(fn(c) for c in self.picks(key))


def tri(conds):
    """条件列表 [(说明, True/False/None)] -> 总判定。"""
    if any(v is False for _, v in conds):
        return 'NOT PASSED'
    return 'INDETERMINATE' if any(v is None for _, v in conds) else 'PASSED'


def report(a):
    data = json.load(open(OUT, encoding='utf-8'))
    res = Results(data, a)
    rows = data['rows']
    lat = [r['latency_ms'] for r in rows if 'latency_ms' in r]
    print('model', data['model'], '| requests', len(rows), '| answered', sum('answer' in r for r in rows), '| failed',
          sum('answer' not in r for r in rows), '| latency_ms median', statistics.median(lat) if lat else '-',
          'min', min(lat, default='-'), 'max', max(lat, default='-'))
    print('online: B=%s S=%s V=%s' % (a.online_b, a.online_s, a.online_v))
    status = {}
    for g, n, _, kind, role, desc in VARIANTS:
        key = '%s_%s' % (g, n)
        st, hits = res.judge(key, kind)
        status[key] = (st, hits)
        print('\n%s | %s | expect: %s | %s%s' % (key, '验收项' if role == 'verdict' else '记录项', desc, st,
                                                 '' if hits is None else ' (%d/%d, need 3/%d)' % (hits, REPEATS, REPEATS)))
        for r in res.rows[key]:
            if 'answer' not in r:
                print('  #%d FAILED %s' % (r['repeat'], r['error']))
                continue
            ans = r['answer']
            p = ans.get('probabilities') or {}
            print('  #%d top1=%s p=%s conf=%s | %s' % (
                r['repeat'], ans['choice'], '%.2f' % p[ans['choice']] if ans['choice'] in p else '?', ans.get('confidence'),
                ' '.join('%s=%.2f' % kv for kv in p.items())))
    ok = lambda key: {'MEETS': True, 'MISSES': False}.get(status[key][0])

    # ---- (b)
    facts = None
    if path_of('B_original').exists():
        try:
            s = State(path_of('B_original').read_text(encoding='utf-8'))
            facts = len(find_event(s)) == 1 and len(GONE_RE.findall(s.sec['Current situation'])) == 1
        except Missing:
            facts = False
    b_conds = [('online B top1 in rebuild direction (--online-b)', None if not a.online_b else a.online_b in REBUILD),
               ('B state has both facts (event entry + `is gone`)', facts),
               ('B original reproduces (rebuild direction)', ok('B_original')),
               ('B no_event_no_gone not in rebuild direction', ok('B_no_event_no_gone')),
               ('B all_removed back to visit_plaza', ok('B_all_removed'))]
    print('\n==== (b) %s' % tri(b_conds))
    for text, v in b_conds:
        print('  %-55s %s' % (text, {True: 'yes', False: 'NO', None: 'undetermined'}[v]))

    # ---- (c)
    base = res.majority('S_original')
    differs = lambda key: None if base is None or not res.rows[key] else res.count(key, lambda c: c != base) >= 3
    returns = lambda key: None if base is None or not res.rows[key] else res.count(key, lambda c: c == base) >= 3
    c_conds = [('online V top1 != online S top1', None if not (a.online_s and a.online_v) else a.online_s != a.online_v),
               ('S original reproduces online S', ok('S_original')),
               ('V original reproduces online V', ok('V_original')),
               ('V no_distrust still != baseline (memory alone acts)', differs('V_no_distrust')),
               ('V no_memory_no_distrust back to baseline', returns('V_no_memory_no_distrust'))]
    print('\n==== (c) %s   (baseline = S original majority top1: %s)' % (tri(c_conds), base))
    for text, v in c_conds:
        print('  %-55s %s' % (text, {True: 'yes', False: 'NO', None: 'undetermined'}[v]))
    if returns('V_no_distrust'):
        print('  note: V no_distrust is back at the baseline -> the effect comes from the non-decaying trust, not memory')
    if c_conds[4][1] is False:
        print('  note: V no_memory_no_distrust is not back at the baseline -> the effect comes from other columns (uncertain)')
        print('        memory_blank_no_distrust back at baseline: %s (explanatory only: yes = unmatched lines in the memory '
              'column; no = not the memory column; does not change the verdict)' % returns('V_memory_blank_no_distrust'))


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('prepare')
    for flag in ('--b', '--s', '--v', '--vandal-cid', '--vandal-name', '--template'):
        p.add_argument(flag, required=True)
    p = sub.add_parser('run')
    p.add_argument('--template', required=True)
    p = sub.add_parser('report')
    for flag in ('--online-b', '--online-s', '--online-v'):
        p.add_argument(flag)
    args = ap.parse_args()
    {'prepare': prepare, 'run': run, 'report': report}[args.cmd](args)
