"""只测试：S1-C2 事后离线诊断（探索性，不是验收）。只向 Jev 发请求（HTTPS），不起服务端。
目的：分清记忆栏的哪一部分让被测 NPC 选 guard_hut，以及记忆不占主导时“破坏者在附近”对“陌生人在附近”有无差别。
办法与分栏 / 句级删改 / 记忆栏分条 / 空栏写法 / 发问与结果格式全部复用 s1c2_counterfactual.py（import，不改它）。

==== 期望（统筹会话运行前写定；原样抄录，不得修改；落空如实记落空） ====
每个变体 4 次里 >= 3 次符合算成立。已知对照（不重问）：S 原文 guard_hut 4/4（0.77-0.80）；V 原文 guard_hut 4/4（0.64-0.71）。
- S_memory_blank：visit_plaza（记忆栏整体是守屋的来源）。
- S_beliefs_blank：visit_plaza（起作用的主要是四份认识，不是召回句）。
- S_recalled_removed：guard_hut（只删召回句不够）。
- S_no_guard_memory：visit_plaza（起作用的是记忆里“守过很多次”的内容）。
- S_no_distrust：guard_hut（不变）。
- V_memory_blank：guard_hut（记忆不占主导时，不信任的人就在附近仍足以让他守屋；与 S_memory_blank 成对比较）。
==== 抄录结束 ====

变体（每个只做写明的改动）：
  S_memory_blank      S 的整个记忆栏换成 `Nothing relevant.`
  S_beliefs_blank     S 的四条 `- Belief (…):` 清空正文、保留标签；`- Recalled:` 行全留
  S_recalled_removed  S 的所有 `- Recalled:` 行删掉；Belief 全留
  S_no_guard_memory   S 记忆栏里凡含 guard（不分大小写，子串）的 Recalled 行整行删；凡含 guard 的 Belief 条目（整条，多行按整条）
                      清空正文、保留标签；其余全留
  S_no_distrust       S 去掉情绪栏 Distrusts 一句（栏空写 `Nothing notable.`）
  V_memory_blank      V 的整个记忆栏换成 `Nothing relevant.`；Distrusts 与 Nearby: Corvin 保留

用法：
  python -B s1c2_postdiag.py prepare --s S.txt --v V.txt --vandal-cid CID --vandal-name Corvin --template T.json
  python -B s1c2_postdiag.py run --template T.json
  python -B s1c2_postdiag.py report
凭据同 s1c2_counterfactual.py：run 只读主检出 .env 的 TYPESAFE_* 进本进程环境；值不打印、不写文件。
"""
import argparse, json, statistics, sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

import s1c2_counterfactual as c

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
PD = ROOT / '.demo/observe/npc-slice1-20261112/s1c2/postdiag'
OUT = HERE / 'results-s1c2-postdiag.json'
REPEATS, WORKERS, TIMEOUT = c.REPEATS, c.WORKERS, c.TIMEOUT


# ---------------------------------------------------------------- 记忆栏操作（分条沿用 c.memory_items）

def is_belief(item):
    return c.ITEM.match(item[0]).group(1) is not None


def belief_label(item):
    return '- Belief (%s): ' % c.ITEM.match(item[0]).group(1)


def write_memory(st, head, parts):
    st.sec['What I remember'] = '\n'.join([head] + [l for item in parts for l in item])


def beliefs_blank(st, cx):
    head, items = c.memory_items(st)
    if not any(is_belief(i) for i in items):
        raise c.Missing('no Belief item')
    out = []
    for i in items:
        if is_belief(i):
            cx.log('Belief body cleared, label kept: %s<%d physical lines cleared>' % (belief_label(i), len(i)))
            out.append([belief_label(i)])
        else:
            out.append(i)
    cx.log('Recalled lines all kept: %d' % sum(not is_belief(i) for i in items))
    write_memory(st, head, out)


def recalled_removed(st, cx):
    head, items = c.memory_items(st)
    rec = [i for i in items if not is_belief(i)]
    if not rec:
        raise c.Missing('no Recalled item')
    for i in rec:
        cx.log('DELETED Recalled: ' + ' / '.join(i))
    cx.log('Belief items all kept intact: %d' % sum(is_belief(i) for i in items))
    write_memory(st, head, [i for i in items if is_belief(i)])


def no_guard_memory(st, cx):
    head, items = c.memory_items(st)
    has = lambda item: any('guard' in l.lower() for l in item)
    out, deleted, cleared, kept_b, kept_r = [], [], [], [], []
    for i in items:
        if is_belief(i):
            if has(i):
                cleared.append(i)
                out.append([belief_label(i)])
            else:
                kept_b.append(i)
                out.append(i)
        elif has(i):
            deleted.append(i)
        else:
            kept_r.append(i)
            out.append(i)
    cx.log('DELETED Recalled lines containing "guard" (%d):' % len(deleted))
    for i in deleted:
        cx.log('  - ' + ' / '.join(i))
    cx.log('Belief bodies CLEARED (label kept) because the entry contains "guard" (%d): %s'
           % (len(cleared), ', '.join(belief_label(i).strip() for i in cleared) or '-'))
    cx.log('Belief entries KEPT intact (%d): %s' % (len(kept_b), ', '.join(belief_label(i).strip() for i in kept_b) or '-'))
    cx.log('Recalled lines KEPT (%d):' % len(kept_r))
    for i in kept_r:
        cx.log('  | ' + ' / '.join(i))
    write_memory(st, head, out)


def check_changed(st, cx):
    pass


# ---------------------------------------------------------------- 变体表（次序即报告 / 发问次序）
# (键, 源 S|V, 操作, 期望 top1, 期望说明)
VARIANTS = [
    ('S_memory_blank', 'S', [c.memory_blank], 'visit_plaza', '记忆栏整体是守屋的来源'),
    ('S_beliefs_blank', 'S', [beliefs_blank], 'visit_plaza', '起作用的主要是四份认识，不是召回句'),
    ('S_recalled_removed', 'S', [recalled_removed], 'guard_hut', '只删召回句不够'),
    ('S_no_guard_memory', 'S', [no_guard_memory], 'visit_plaza', '起作用的是记忆里“守过很多次”的内容'),
    ('S_no_distrust', 'S', [c.drop_distrust], 'guard_hut', '不变'),
    ('V_memory_blank', 'V', [c.memory_blank], 'guard_hut', '记忆不占主导时，不信任的人就在附近仍足以让他守屋'),
]
KEYS = [v[0] for v in VARIANTS]


def path_of(key):
    return PD / (key + '.txt')


def prepare(a):
    sources = {'S': Path(a.s), 'V': Path(a.v)}
    PD.mkdir(parents=True, exist_ok=True)
    report = ['sources: ' + ', '.join('%s = %s' % kv for kv in sources.items()),
              'vandal: cid %s, name %s' % (a.vandal_cid, a.vandal_name), '']
    for key, src, ops, _, _ in VARIANTS:
        cx = c.Ctx(a.vandal_cid, a.vandal_name)
        st = c.State(sources[src].read_text(encoding='utf-8'))
        for op in ops:
            op(st, cx)
        path_of(key).write_text(st.render(), encoding='utf-8', newline='\n')
        report += ['=== %s  (source %s)' % (key, sources[src].name)] + ['  ' + l for l in cx.lines] + ['']
    (PD / 'edits.txt').write_text('\n'.join(report), encoding='utf-8', newline='\n')
    print('wrote %d variants + edits.txt to %s' % (len(VARIANTS), PD))


def run(a):
    template = json.load(open(a.template, encoding='utf-8'))
    texts = {k: path_of(k).read_text(encoding='utf-8') for k in KEYS}
    c.load_env()
    from jev import ask, ENV
    q = c.question(template)
    cells = [(k, r) for k in KEYS for r in range(REPEATS)]

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
            'template': str(a.template), 'candidates': [x['name'] for x in template['candidates']],
            'variants': {k: {'expected': e, 'why': w, 'state_file': 's1c2/postdiag/%s.txt' % k} for k, _, _, e, w in VARIANTS},
            'rows': rows}
    json.dump(data, open(OUT, 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
    print('requested', len(rows), 'answered', sum('answer' in r for r in rows), 'errors', sum('error' in r for r in rows))


def report(a):
    data = json.load(open(OUT, encoding='utf-8'))
    rows = data['rows']
    lat = [r['latency_ms'] for r in rows if 'latency_ms' in r]
    print('model', data['model'], '| requests', len(rows), '| answered', sum('answer' in r for r in rows), '| failed',
          sum('answer' not in r for r in rows), '| latency_ms median', statistics.median(lat) if lat else '-',
          'min', min(lat, default='-'), 'max', max(lat, default='-'))
    for key, _, _, exp, why in VARIANTS:
        rs = sorted((r for r in rows if r['variant'] == key), key=lambda r: r['repeat'])
        hits = sum(1 for r in rs if 'answer' in r and r['answer']['choice'] == exp)
        print('\n%s | expect %s (%s) | %s (%d/%d)' % (key, exp, why, 'MEETS' if hits >= 3 else 'MISSES', hits, REPEATS))
        for r in rs:
            if 'answer' not in r:
                print('  #%d FAILED %s' % (r['repeat'], r['error']))
                continue
            ans = r['answer']
            p = ans.get('probabilities') or {}
            print('  #%d top1=%s guard_hut=%.2f visit_plaza=%.2f | %s' % (
                r['repeat'], ans['choice'], p.get('guard_hut', float('nan')), p.get('visit_plaza', float('nan')),
                ' '.join('%s=%.2f' % kv for kv in p.items())))


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('prepare')
    for flag in ('--s', '--v', '--vandal-cid', '--vandal-name', '--template'):
        p.add_argument(flag, required=True)
    p = sub.add_parser('run')
    p.add_argument('--template', required=True)
    sub.add_parser('report')
    args = ap.parse_args()
    {'prepare': prepare, 'run': run, 'report': report}[args.cmd](args)
