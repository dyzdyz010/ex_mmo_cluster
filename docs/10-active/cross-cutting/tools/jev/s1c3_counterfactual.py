"""只测试：S1-C3 离线对照（验收的离线部分）。只向 Jev 发请求（HTTPS），不起服务端。
对两份真实 state（S = 陌生人在附近，V = 破坏者在附近）做逐栏对照，判定 S1-C3 的离线条件；在线条件由统筹会话另判。
分栏 / 句级删改 / 发问与结果格式复用 s1c2_counterfactual.py 与 s1e_design.py（import，不改它们）；规则 E′ = s1e_design.strip_event 带本脚本的词干表。

==== S1-C3 离线对照的期望（统筹会话运行前写定，抄自 s1c3/plan.md；原样抄录，不得修改；落空如实记落空） ====
素材：在线 S 第 1 次（陌生人 Tobin 在附近）与 V 第 1 次（破坏者 Corvin 在附近）的 state 全文；请求模板 = 停节点前从节点导出的 instructions + 6 个候选。
每个变体问 4 次，>= 3 次符合算成立；请求失败计为不符合，不补问。“confront” = top1 是 confront_wrecker；“not confront” = top1 是其余任一候选。
判定项：
- S_original：not confront，且多数 top1 = 在线 S 第 1 次的 top1（复现）。
- V_original：confront（复现在线）。
- V_no_event：not confront（去掉记忆栏里那件事后回到基线；Distrusts 保留）。
- V_no_distrust：confront（只去掉 Distrusts 不回到基线）。
- V_no_event_no_distrust：not confront。
记录项：
- V_memory_blank：not confront。
- V_no_own_activity：confront（不变）。
- V_nearby_no_cid：confront（Nearby 改回不带 cid 的旧写法，Distrusts 保留；同 S1-E 的 A_V）。
- V_nearby_no_cid_no_distrust：not confront（同 S1-E 的 A_V_no_distrust）。
“回到基线”的可判定条件 = not confront；该变体的多数 top1 是否等于 S_original 的多数 top1 另记，不进判定。
(c) 的离线条件 = S_original、V_original 复现成立 + V_no_event not confront + V_no_distrust confront + V_no_event_no_distrust not confront；在线条件由统筹会话另判。
V_no_event 不成立时看 V_memory_blank：它 not confront 且删后的记忆栏里能指出漏删的行 → 记“规则漏删，不判通过（不确定）”，不改规则重问作验收。
==== 抄录结束 ====

规则 E′（“去掉记忆栏里那件事”，物理行级，只作用于 What I remember 栏）：行内（不分大小写，子串）含破坏者 cid、破坏者名字，
或词干表 STEMS_EP 任一即命中（不含 rebuil、guard）。栏头说明句永不删；`- Recalled:` 行命中整行删；Belief 条目内命中的物理行删掉，
命中的是条目首行则保留标签、清掉标签后的文字；未命中的行原样保留。逐条删改记进 edits.txt；一行都没命中 raise。
“Nearby 改回旧写法”：处境栏里 `Nearby: <名> (NPC, actor <cid>, <d> m away).` 去掉 `actor <cid>, `（只针对破坏者；该片段须恰好出现一次）。

用法（素材路径、破坏者 cid / 名字、模板、在线 top1 都由命令行给；--out 缺省 .demo/observe/npc-slice1-20261112/s1c3/counterfactual）：
  python -B s1c3_counterfactual.py prepare --s S.txt --v V.txt --vandal-cid CID --vandal-name Corvin --template T.json \
      --s-online-top1 NAME --v-online-top1 NAME [--out DIR]
  python -B s1c3_counterfactual.py run [--out DIR]
  python -B s1c3_counterfactual.py report
凭据同 s1c2_counterfactual.py：run 只读主检出 .env 的 TYPESAFE_* 进本进程环境；值不打印、不写文件。
"""
import argparse, hashlib, json, statistics
from collections import Counter
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

import s1c2_counterfactual as c
import s1e_design as e

HERE = Path(__file__).resolve().parent
DEMO = e.DEMO
DEFAULT_OUT = DEMO / 's1c3/counterfactual'
RESULTS = HERE / 'results-s1c3-counterfactual.json'
REPEATS, WORKERS, TIMEOUT = c.REPEATS, min(c.WORKERS, 3), c.TIMEOUT
FEEL, MEM, SIT = e.FEEL, e.MEM, e.SIT
JUST, RECENT = 'What just happened', 'Recent activities'
CF, NC = e.CF, e.NC

STEMS_EP = ['remov', 'destr', 'dismantl', 'demolish', 'vandal', 'harm', 'angr', 'anger', 'trust', 'tore', 'torn', 'tear',
            'wreck', 'damag', 'disrupt', 'setback', 'lost', 'loss', 'wrong', 'gone', 'no longer', 'vulnerab', 'knock', 'raz',
            'pulled down', 'took down', 'taken down']


# ---------------------------------------------------------------- 操作

def rule_ep(cid, name):
    def op(st, cx):
        e.strip_event(st, cx, [('cid ' + cid, cid), (name, name)], STEMS_EP, tag="rule E'")
    return op


def nearby_old(cid, name):
    frag, old = 'Nearby: %s (NPC, actor %s, ' % (name, cid), 'Nearby: %s (NPC, ' % name

    def op(st, cx):
        body = st.sec[SIT]
        if body.count(frag) != 1:
            raise c.Missing('Current situation: expected exactly 1 %r, found %d' % (frag, body.count(frag)))
        cx.log('replaced in "Current situation": %r  ->  %r' % (frag, old))
        st.sec[SIT] = body.replace(frag, old)
    return op


# ---------------------------------------------------------------- 变体表（次序即发问 / 报告次序）
# (键, 来源, 操作名, 期望, 期望说明, 声明要动的栏, 记录项)；操作名在 make_ops 里取。

VARIANTS = [
    ('S_original', 'S', [], NC, '陌生人在附近；多数 top1 须等于在线 S 第 1 次的 top1', set(), False),
    ('V_original', 'V', [], CF, '破坏者在附近；复现在线', set(), False),
    ('V_no_event', 'V', ['E'], NC, '去掉记忆栏里那件事后回到基线（Distrusts 保留）', {MEM}, False),
    ('V_no_distrust', 'V', ['D'], CF, '只去掉 Distrusts 不回到基线', {FEEL}, False),
    ('V_no_event_no_distrust', 'V', ['E', 'D'], NC, '两处都去掉', {MEM, FEEL}, False),
    ('V_memory_blank', 'V', ['M'], NC, '记录项：整个记忆栏清空，Distrusts 保留', {MEM}, True),
    ('V_no_own_activity', 'V', ['O'], CF, '记录项：去掉自己的活动（What just happened 里 I did 条目 + Recent activities）', {JUST, RECENT}, True),
    ('V_nearby_no_cid', 'V', ['N'], CF, '记录项：Nearby 改回不带 cid 的旧写法，Distrusts 保留', {SIT}, True),
    ('V_nearby_no_cid_no_distrust', 'V', ['N', 'D'], NC, '记录项：Nearby 旧写法 + 去掉 Distrusts', {SIT, FEEL}, True),
]


def make_ops(cid, name):
    return {'E': rule_ep(cid, name), 'D': c.drop_distrust, 'M': c.memory_blank, 'O': c.drop_own_activity,
            'N': nearby_old(cid, name)}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def rel(path):
    p = Path(path).resolve()
    try:
        return p.relative_to(DEMO.resolve()).as_posix()
    except ValueError:
        return str(p)


# ---------------------------------------------------------------- prepare

def prepare(a):
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    cid, name = a.vandal_cid, a.vandal_name
    template = json.load(open(a.template, encoding='utf-8'))
    names = [x['name'] for x in template['candidates']]
    for need in ('confront_wrecker', a.s_online_top1, a.v_online_top1):
        if need not in names:
            raise c.Missing('candidate %r is not in the template: %s' % (need, names))
    texts = {'S': Path(a.s).read_text(encoding='utf-8'), 'V': Path(a.v).read_text(encoding='utf-8')}
    if name in texts['S']:
        raise c.Missing('S contains %r: wrong file for S' % name)
    for frag in ('Nearby: %s (NPC, actor %s, ' % (name, cid), 'Distrusts %s (actor %s).' % (name, cid)):
        if frag not in texts['V']:
            raise c.Missing('V does not contain %r: wrong file for V' % frag)
    srcs = {'S': Path(a.s), 'V': Path(a.v)}
    ops = make_ops(cid, name)
    report = ['S1-C3 counterfactual variants',
              'sources: S = %s (sha256 %s), V = %s (sha256 %s)' % (srcs['S'], sha(srcs['S']), srcs['V'], sha(srcs['V'])),
              'template: %s (sha256 %s), candidates %s' % (a.template, sha(a.template), names),
              'vandal: cid %s, name %s; online top1: S = %s, V = %s' % (cid, name, a.s_online_top1, a.v_online_top1), '']
    summary = []
    for key, src, opnames, _, _, declared, _ in VARIANTS:
        cx = c.Ctx(cid, name)
        st = c.State(texts[src])
        for o in opnames:
            ops[o](st, cx)
        text = st.render()
        if not opnames:
            assert text.encode('utf-8') == srcs[src].read_bytes(), '%s: unchanged variant differs from its source' % key
        (out / (key + '.txt')).write_bytes(text.encode('utf-8'))
        before = c.State(texts[src])
        changed = {t for t in c.TITLES if before.sec[t] != st.sec[t]}
        if changed != declared:
            raise c.Missing('%s: changed sections %s != declared %s' % (key, sorted(changed), sorted(declared)))
        order = [t for t in c.TITLES if t in changed]
        summary.append((key, order))
        report += ['=== %s  (source %s)' % (key, srcs[src].name)] + ['  ' + l for l in cx.lines]
        report += ['  self-check: sections changed vs source = %s (declared %s: OK)' % (order or 'none (byte-identical)',
                                                                                      order or 'none'), '']
    (out / 'edits.txt').write_text('\n'.join(report), encoding='utf-8', newline='\n')
    meta = {'s': str(srcs['S']), 's_sha256': sha(srcs['S']), 'v': str(srcs['V']), 'v_sha256': sha(srcs['V']),
            'vandal_cid': cid, 'vandal_name': name, 'template': str(Path(a.template).resolve()), 'template_sha256': sha(a.template),
            's_online_top1': a.s_online_top1, 'v_online_top1': a.v_online_top1, 'out': str(out.resolve())}
    (out / 'meta.json').write_text(json.dumps(meta, indent=1, ensure_ascii=False), encoding='utf-8', newline='\n')
    print('wrote %d variants + edits.txt + meta.json to %s' % (len(VARIANTS), out))
    for key, order in summary:
        print('  %-28s changed: %s' % (key, ', '.join(order) or 'none'))


# ---------------------------------------------------------------- run

def run(a):
    out = Path(a.out)
    meta = json.load(open(out / 'meta.json', encoding='utf-8'))
    template = json.load(open(meta['template'], encoding='utf-8'))
    keys = [v[0] for v in VARIANTS]
    texts = {k: (out / (k + '.txt')).read_text(encoding='utf-8') for k in keys}
    c.load_env()
    from jev import ask, ENV
    q = c.question(template)
    cells = [(k, r) for k in keys for r in range(REPEATS)]

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
            'template': meta['template'], 'candidates': [x['name'] for x in template['candidates']], 'meta': meta,
            'variants': {k: {'expected': e.exp_text(x), 'why': w, 'record_only': rec, 'state_file': rel(out / (k + '.txt'))}
                         for k, _, _, x, w, _, rec in VARIANTS},
            'rows': rows}
    json.dump(data, open(RESULTS, 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
    print('requested', len(rows), 'answered', sum('answer' in r for r in rows), 'errors', sum('error' in r for r in rows))


# ---------------------------------------------------------------- report（离线，无模型调用）

def majority(rs):
    ch = Counter(r['answer']['choice'] for r in rs if 'answer' in r)
    top = ch.most_common(1)
    return top[0][0] if top and top[0][1] >= 3 else None


def report(a):
    data = json.load(open(RESULTS, encoding='utf-8'))
    rows = data['rows']
    s_top1 = data['meta']['s_online_top1']
    lat = [r['latency_ms'] for r in rows if 'latency_ms' in r]
    print('S1-C3 离线对照 | model', data['model'], '| requests', len(rows), '| answered', sum('answer' in r for r in rows),
          '| failed', sum('answer' not in r for r in rows), '| latency_ms median', statistics.median(lat) if lat else '-',
          'min', min(lat, default='-'), 'max', max(lat, default='-'))
    meets, maj = {}, {}
    for key, _, _, exp, why, _, rec in VARIANTS:
        rs = sorted((r for r in rows if r['variant'] == key), key=lambda r: r['repeat'])
        ok = e.exp_ok(exp)
        hits = sum(1 for r in rs if 'answer' in r and ok(r['answer']['choice']))
        maj[key] = majority(rs)
        meets[key] = hits >= 3 and (key != 'S_original' or maj[key] == s_top1)
        extra = ' | 多数 top1 须 = %s' % s_top1 if key == 'S_original' else ''
        print('\n%s | expect %s (%s)%s | %s (%d/%d)%s' % (key, e.exp_text(exp), why, extra, 'MEETS' if meets[key] else 'MISSES',
                                                         hits, REPEATS, ' | 记录项' if rec else ''))
        for r in rs:
            if 'answer' not in r:
                print('  #%d FAILED %s' % (r['repeat'], r['error']))
                continue
            ans = r['answer']
            p = ans.get('probabilities') or {}
            order = [k for k in e.FRONT if k in p] + [k for k in p if k not in e.FRONT]
            print('  #%d top1=%s | %s' % (r['repeat'], ans['choice'], ' '.join('%s=%.2f' % (k, p[k]) for k in order)))
        line = '  多数 top1: %s' % (maj[key] or '无多数')
        if key != 'S_original':
            base = maj['S_original']
            line += ' | 等于 S_original 的多数 top1（%s）？ %s（另记项，不进判定）' % (
                base or '无多数', 'YES' if maj[key] is not None and maj[key] == base else 'NO')
        print(line)
    yn = lambda b: 'YES' if b else 'NO'
    print('\n==== 离线判定（1–3 是在线条件，由统筹会话另判） ====')
    print('4 复现：S_original 成立且 V_original 成立？ %s' % yn(meets['S_original'] and meets['V_original']))
    print('5 V_no_event 为 not confront？ %s' % yn(meets['V_no_event']))
    print('6 V_no_distrust 为 confront？ %s' % yn(meets['V_no_distrust']))
    print('7 V_no_event_no_distrust 为 not confront？ %s' % yn(meets['V_no_event_no_distrust']))
    if not meets['V_no_event']:
        print('5 未成立：看 V_memory_blank（%s）与删后记忆栏（edits.txt）；规则漏删记“规则漏删，不判通过（不确定）”，不改规则重问作验收。'
              % ('MEETS' if meets['V_memory_blank'] else 'MISSES'))


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('prepare')
    for flag in ('--s', '--v', '--vandal-cid', '--vandal-name', '--template', '--s-online-top1', '--v-online-top1'):
        p.add_argument(flag, required=True)
    p.add_argument('--out', default=str(DEFAULT_OUT))
    sub.add_parser('run').add_argument('--out', default=str(DEFAULT_OUT))
    sub.add_parser('report')
    args = ap.parse_args()
    {'prepare': prepare, 'run': run, 'report': report}[args.cmd](args)
