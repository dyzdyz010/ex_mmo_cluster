"""只测试：S1-E 离线设计试验（探索性，不是验收）。只向 Jev 发请求（HTTPS），不起服务端。
目的：试一张新候选表（S1-C2 的 5 个候选 + confront_wrecker），看“记得那件事的人（破坏者 Corvin）在附近”与
“陌生人 Tobin 在附近”能否区分，并逐栏归因。
办法与分栏 / 句级删改 / 记忆栏分条 / 空栏写法 / 发问与结果格式复用 s1c2_counterfactual.py（import，不改它）。
每轮的候选表、变体表、期望都在 ROUNDS 里按轮取；后续轮次往 ROUNDS 里加项即可。

==== 第 1 轮期望（统筹会话 2026-11-12 发问前写定；原样抄录，不得修改；落空如实记落空） ====
候选表 T1 = S1-C2 的 5 个候选 + confront_wrecker。每个变体问 4 次，>= 3 次符合算成立。
“confront” = top1 是 confront_wrecker；“not confront” = top1 是其余任一候选。
A 族（现行 state 写法）：
- A_S：not confront（陌生人在附近，基线）。
- A_N：not confront（无人在附近）。
- A_V：confront（破坏者在附近；Distrusts 一句把 Corvin 与 cid 对上，记忆栏有那件事）。
- A_V_no_event：not confront（去掉记忆栏里那件事后回到基线；只有 Distrusts 不足以满足判据里“曾经毁过我东西”）。
- A_V_no_distrust：设计要求 confront（只去掉 Distrusts 不回到基线）。统筹会话的预测：落空——去掉 Distrusts 后 state 里没有任何一句把 Corvin 与记忆里的 cid 对上。
- A_V_no_event_no_distrust：not confront。
- A_V_memory_blank：not confront（记录项）。
B 族（假设处境栏 Nearby 带上 cid，其余同 A 族）：
- B_S：not confront。
- B_V：confront。
- B_V_no_event：not confront。
- B_V_no_distrust：confront（记忆栏里那件事 + Nearby 的 cid 就够，不靠 Distrusts）。
- B_V_no_event_no_distrust：not confront。
一族算“离线能区分”= 该族所有非记录项的行都成立。A 族成立 → 不需要改产品。只有 B 族成立 → 结论是需要改 apps/ 里 Nearby 的写法，先向用户汇报。
两族都不成立 → 记落空，按落空的那几行决定第 2 轮（期望另写）。
==== 抄录结束 ====

==== 第 2 轮期望（统筹会话 2026-11-12 看过第 1 轮结果后、发问前写定；原样抄录，不得修改；落空如实记落空） ====
问题：候选表 T1 会不会妨碍实跑的前半段（平时去广场、破坏后重建）。四份 S1-C2 的真实 state 原文不改，只换成候选表 T1。
每个变体问 4 次，>= 3 次符合算成立。这几份 state 里破坏者都不在附近，Nearby 带不带 cid 没有差别。
- P_C1a（17:01:29，破坏之前的基线，在线 visit_plaza）：top1 = visit_plaza。
- P_C1b（17:02:00，破坏之前的基线，在线 visit_plaza）：top1 = visit_plaza。
- P_B（17:02:30，破坏后第 1 次选择，破坏者已离场，在线 build_hut）：top1 在重建方向（build_hut 或 gather_stone）。
- P_R（17:02:45，刚重建完、愤怒仍强、破坏者不在附近，在线 guard_hut）：not confront。
四行都成立 → T1 不妨碍前半段。任何一行落空 → 如实记，T1 不能原样上实跑，先调整候选表再问（期望另写）。
==== 抄录结束 ====

规则 E（“去掉记忆栏里那件事”，物理行级，只作用于 What I remember 栏）：行内（不分大小写，子串）含破坏者 cid 或词干
remov / destr / dismantl / demolish / vandal / harm / angr / anger / trust 即命中（不含 rebuil、guard）。
栏头说明句永不删；`- Recalled:` 行命中整行删；Belief 条目内物理行命中删该行，命中的是条目首行则保留标签 `- Belief (xxx): `、
只清掉标签后的文字；未命中的行（含空行、`##` 小标题）原样保留。

变体 = 来源（S / N / V）+ 操作；B 族先做 Nearby 改写（`Nearby: <名字> (NPC, 5.0 m away).` ->
`Nearby: <名字> (NPC, actor <cid>, 5.0 m away).`），再做与 A 族相同的操作。

用法（素材与模板路径写在脚本里）：
  python -B s1e_design.py prepare --round 1
  python -B s1e_design.py run --round 1
  python -B s1e_design.py report --round 1
凭据同 s1c2_counterfactual.py：run 只读主检出 .env 的 TYPESAFE_* 进本进程环境；值不打印、不写文件。
"""
import argparse, json, re, statistics
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

import s1c2_counterfactual as c

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
DEMO = ROOT / '.demo/observe/npc-slice1-20261112'
STATES = DEMO / 's1c2/states'
SOURCES = {'S': STATES / 'asked-20261112T171536.032Z.txt',
           'N': STATES / 'asked-20261112T171709.455Z.txt',
           'V': STATES / 'asked-20261112T171740.597Z.txt'}
SOURCES.update({'C1a': STATES / 'asked-20261112T170129.048Z.txt', 'C1b': STATES / 'asked-20261112T170159.681Z.txt',
                'B': STATES / 'asked-20261112T170230.812Z.txt', 'R': STATES / 'asked-20261112T170245.418Z.txt'})
TEMPLATE = DEMO / 's1c2/export/request-template.json'
VANDAL_CID, VANDAL_NAME = '1845497958402', 'Corvin'
STRANGER_CID, STRANGER_NAME = '5128442613763', 'Tobin'
REPEATS, WORKERS, TIMEOUT = c.REPEATS, min(c.WORKERS, 3), c.TIMEOUT

FEEL, MEM, SIT = 'Feelings and relationships', 'What I remember', 'Current situation'


def round_dir(n):
    return DEMO / ('s1e/round%d' % n)


def results_path(n):
    return HERE / ('results-s1e-round%d.json' % n)


# ---------------------------------------------------------------- Nearby 改写

def nearby_cid(name, cid):
    old = 'Nearby: %s (NPC, 5.0 m away).' % name
    new = 'Nearby: %s (NPC, actor %s, 5.0 m away).' % (name, cid)

    def op(st, cx):
        body = st.sec[SIT]
        if body.count(old) != 1:
            raise c.Missing('Current situation: expected exactly 1 %r, found %d' % (old, body.count(old)))
        cx.log('replaced in "Current situation": %s  ->  %s' % (old, new))
        st.sec[SIT] = body.replace(old, new)
    return op


# ---------------------------------------------------------------- 规则 E

STEMS_E = ['remov', 'destr', 'dismantl', 'demolish', 'vandal', 'harm', 'angr', 'anger', 'trust']


def hits_in_line(line, needles, stems):
    """needles = [(标签, 字面量)]，按子串、不分大小写；stems 同样不分大小写。返回命中的标签 / 词干（needles 在前）。"""
    low = line.lower()
    return [label for label, lit in needles if lit.lower() in low] + [s for s in stems if s in low]


def strip_event(st, cx, needles, stems, tag='rule E'):
    head, items = c.memory_items(st)
    out, deleted, cleared, kept_rec, belief_stat = [], [], [], [], []
    for item in items:
        belief = c.ITEM.match(item[0]).group(1) is not None
        if not belief:  # `- Recalled:` 行（一行一条）
            h = hits_in_line(item[0], needles, stems)
            if h:
                deleted.append((item[0], h))
            else:
                kept_rec.append(item[0])
                out.append(item)
            continue
        label = '- Belief (%s): ' % c.ITEM.match(item[0]).group(1)
        new, n_del = [], 0
        for i, line in enumerate(item):
            h = hits_in_line(line, needles, stems)
            if not h:
                new.append(line)
            elif i == 0:  # 条目首行：保留标签，只清标签后的文字
                cleared.append((label, line, h))
                new.append(label)
            else:
                deleted.append((line, h))
                n_del += 1
        belief_stat.append((label.strip(), len(item), n_del, len(new), sum(1 for l in new if l.strip())))
        out.append(new)
    if not deleted and not cleared:
        raise c.Missing('%s: no line in "What I remember" matched' % tag)
    cx.log('"What I remember" header line kept: ' + head)
    cx.log('DELETED / CLEARED lines (%d deleted, %d belief first-lines cleared):' % (len(deleted), len(cleared)))
    for line, h in deleted:
        cx.log('  - DELETED [%s] %s' % (', '.join(h), line))
    for label, line, h in cleared:
        cx.log('  - CLEARED (label %r kept) [%s] %s' % (label, ', '.join(h), line))
    cx.log('Recalled lines KEPT (%d):' % len(kept_rec))
    for l in kept_rec:
        cx.log('  | ' + l)
    for lab, total, nd, nk, nk_nb in belief_stat:
        cx.log('Belief %s: %d physical lines, deleted %d, kept %d (%d non-blank)' % (lab, total, nd, nk, nk_nb))
    st.sec[MEM] = '\n'.join([head] + [l for item in out for l in item])
    assert not hits_in_line(st.sec[MEM], needles, stems), '%s left a hit in the memory column' % tag


def rule_e(st, cx):
    strip_event(st, cx, [('cid ' + VANDAL_CID, VANDAL_CID)], STEMS_E)


# ---------------------------------------------------------------- 变体表（次序即报告 / 发问次序）
# (键, 来源, 操作, 期望, 期望说明, 声明要动的栏, 记录项)
T1_EXTRA = [{'name': 'confront_wrecker',
             'criterion': 'Walk over to the person standing nearby, stand in front of them and watch them closely, to make it '
                          'plain I have not forgotten what they did. Only do this when that person is someone who once '
                          'destroyed or removed something I built; otherwise there is no reason to.'}]

B_S_NEARBY = nearby_cid(STRANGER_NAME, STRANGER_CID)
B_V_NEARBY = nearby_cid(VANDAL_NAME, VANDAL_CID)
CF, NC = 'confront', 'not_confront'

ROUNDS = {
    1: {
        'candidates_extra': T1_EXTRA,
        'variants': [
            ('A_S', 'S', [], NC, '陌生人在附近，基线', set(), False),
            ('A_N', 'N', [], NC, '无人在附近', set(), False),
            ('A_V', 'V', [], CF, '破坏者在附近；Distrusts 把 Corvin 与 cid 对上，记忆栏有那件事', set(), False),
            ('A_V_no_event', 'V', [rule_e], NC, '去掉记忆栏里那件事后回到基线', {MEM}, False),
            ('A_V_no_distrust', 'V', [c.drop_distrust], CF, '设计要求 confront（统筹会话预测落空）', {FEEL}, False),
            ('A_V_no_event_no_distrust', 'V', [rule_e, c.drop_distrust], NC, '两处都去掉', {MEM, FEEL}, False),
            ('A_V_memory_blank', 'V', [c.memory_blank], NC, '记录项：整个记忆栏清空，Distrusts 保留', {MEM}, True),
            ('B_S', 'S', [B_S_NEARBY], NC, 'Nearby 带 cid，陌生人', {SIT}, False),
            ('B_V', 'V', [B_V_NEARBY], CF, 'Nearby 带 cid，破坏者', {SIT}, False),
            ('B_V_no_event', 'V', [B_V_NEARBY, rule_e], NC, 'Nearby 带 cid，去掉记忆里那件事', {SIT, MEM}, False),
            ('B_V_no_distrust', 'V', [B_V_NEARBY, c.drop_distrust], CF, '记忆里那件事 + Nearby cid 就够，不靠 Distrusts',
             {SIT, FEEL}, False),
            ('B_V_no_event_no_distrust', 'V', [B_V_NEARBY, rule_e, c.drop_distrust], NC, 'Nearby 带 cid，两处都去掉',
             {SIT, MEM, FEEL}, False),
        ],
    },
    2: {
        'candidates_extra': T1_EXTRA,
        'variants': [
            ('P_C1a', 'C1a', [], frozenset({'visit_plaza'}), '破坏之前的基线，原文 + T1', set(), False),
            ('P_C1b', 'C1b', [], frozenset({'visit_plaza'}), '破坏之前的基线，原文 + T1', set(), False),
            ('P_B', 'B', [], frozenset({'build_hut', 'gather_stone'}), '破坏后第 1 次选择（破坏者已离场），原文 + T1', set(), False),
            ('P_R', 'R', [], NC, '刚重建完、破坏者不在附近，原文 + T1', set(), False),
        ],
    },
}


def exp_text(exp):
    return exp if isinstance(exp, str) else 'top1 in {%s}' % ', '.join(sorted(exp))


def exp_ok(exp):
    if exp == CF:
        return lambda ch: ch == 'confront_wrecker'
    if exp == NC:
        return lambda ch: ch != 'confront_wrecker'
    return lambda ch: ch in exp


def template_of(n):
    t = json.load(open(TEMPLATE, encoding='utf-8'))
    return {'instructions': t['instructions'], 'candidates': t['candidates'] + ROUNDS[n]['candidates_extra']}


# ---------------------------------------------------------------- prepare

def prepare(a):
    n = a.round
    d = round_dir(n)
    d.mkdir(parents=True, exist_ok=True)
    template = template_of(n)
    json.dump(template, open(d / 'template.json', 'w', encoding='utf-8', newline='\n'), indent=1, ensure_ascii=False)
    texts = {k: p.read_text(encoding='utf-8') for k, p in SOURCES.items()}
    report = ['round %d' % n, 'sources: ' + ', '.join('%s = %s' % (k, p) for k, p in SOURCES.items()),
              'template: %s + candidates %s -> %s' % (TEMPLATE, [x['name'] for x in ROUNDS[n]['candidates_extra']],
                                                      d / 'template.json'),
              'vandal: cid %s, name %s; stranger: cid %s, name %s' % (VANDAL_CID, VANDAL_NAME, STRANGER_CID, STRANGER_NAME), '']
    summary = []
    for key, src, ops, _, _, declared, _ in ROUNDS[n]['variants']:
        cx = c.Ctx(VANDAL_CID, VANDAL_NAME)
        st = c.State(texts[src])
        for op in ops:
            op(st, cx)
        out = st.render()
        if not ops:
            assert out == texts[src], '%s: unchanged variant differs from its source' % key
        (d / (key + '.txt')).write_bytes(out.encode('utf-8'))
        before = c.State(texts[src])
        changed = {t for t in c.TITLES if before.sec[t] != st.sec[t]}
        if changed != declared:
            raise c.Missing('%s: changed sections %s != declared %s' % (key, sorted(changed), sorted(declared)))
        order = [t for t in c.TITLES if t in changed]
        summary.append((key, order))
        report += ['=== %s  (source %s)' % (key, SOURCES[src].name)] + ['  ' + l for l in cx.lines]
        report += ['  self-check: sections changed vs source = %s (declared %s: OK)' % (order or 'none (byte-identical)',
                                                                                      order or 'none'), '']
    (d / 'edits.txt').write_text('\n'.join(report), encoding='utf-8', newline='\n')
    print('round %d: wrote %d variants + template.json + edits.txt to %s' % (n, len(ROUNDS[n]['variants']), d))
    for key, order in summary:
        print('  %-26s changed: %s' % (key, ', '.join(order) or 'none'))


# ---------------------------------------------------------------- run

def run(a):
    n = a.round
    d = round_dir(n)
    variants = ROUNDS[n]['variants']
    keys = [v[0] for v in variants]
    template = json.load(open(d / 'template.json', encoding='utf-8'))
    texts = {k: (d / (k + '.txt')).read_text(encoding='utf-8') for k in keys}
    c.load_env()
    from jev import ask, ENV
    q = c.question(template)
    cells = [(k, r) for k in keys for r in range(REPEATS)]

    def one(cell):
        key, r = cell
        row = {'variant': key, 'repeat': r + 1}
        try:
            answers, _, seconds = ask(texts[key], q, timeout=TIMEOUT)
        except Exception as e:  # 失败如实记，不重试、不补问
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
            'round': n, 'template': str(d / 'template.json'), 'candidates': [x['name'] for x in template['candidates']],
            'variants': {k: {'expected': exp_text(e), 'why': w, 'record_only': rec, 'state_file': 's1e/round%d/%s.txt' % (n, k)}
                         for k, _, _, e, w, _, rec in variants},
            'rows': rows}
    json.dump(data, open(results_path(n), 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
    print('requested', len(rows), 'answered', sum('answer' in r for r in rows), 'errors', sum('error' in r for r in rows))


# ---------------------------------------------------------------- report（离线，无模型调用）

FRONT = ['confront_wrecker', 'guard_hut', 'visit_plaza']


def report(a):
    n = a.round
    data = json.load(open(results_path(n), encoding='utf-8'))
    rows = data['rows']
    lat = [r['latency_ms'] for r in rows if 'latency_ms' in r]
    print('round', n, '| model', data['model'], '| requests', len(rows), '| answered', sum('answer' in r for r in rows),
          '| failed', sum('answer' not in r for r in rows), '| latency_ms median', statistics.median(lat) if lat else '-',
          'min', min(lat, default='-'), 'max', max(lat, default='-'))
    meets = {}
    for key, _, _, exp, why, _, rec in ROUNDS[n]['variants']:
        rs = sorted((r for r in rows if r['variant'] == key), key=lambda r: r['repeat'])
        ok = exp_ok(exp)
        hits = sum(1 for r in rs if 'answer' in r and ok(r['answer']['choice']))
        meets[key] = hits >= 3
        print('\n%s | expect %s (%s) | %s (%d/%d)%s' % (key, exp_text(exp), why, 'MEETS' if meets[key] else 'MISSES', hits, REPEATS,
                                                     ' | 记录项' if rec else ''))
        for r in rs:
            if 'answer' not in r:
                print('  #%d FAILED %s' % (r['repeat'], r['error']))
                continue
            ans = r['answer']
            p = ans.get('probabilities') or {}
            order = [k for k in FRONT if k in p] + [k for k in p if k not in FRONT]
            print('  #%d top1=%s | %s' % (r['repeat'], ans['choice'], ' '.join('%s=%.2f' % (k, p[k]) for k in order)))
    print()
    for fam in dict.fromkeys(k.split('_')[0] for k, *_ in ROUNDS[n]['variants']):
        rel = [k for k, _, _, _, _, _, rec in ROUNDS[n]['variants'] if k.startswith(fam + '_') and not rec]
        bad = [k for k in rel if not meets[k]]
        print('%s 族：所有非记录项都成立？ %s%s' % (fam, 'YES' if not bad else 'NO', '' if not bad else '（落空：%s）' % ', '.join(bad)))


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name in ('prepare', 'run', 'report'):
        sub.add_parser(name).add_argument('--round', type=int, required=True, choices=sorted(ROUNDS))
    args = ap.parse_args()
    {'prepare': prepare, 'run': run, 'report': report}[args.cmd](args)
