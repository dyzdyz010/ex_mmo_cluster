"""只测试：S1-I“放进 state 后”阶段——把 36 条反思产出逐条放进真实 state，向 Jev 发问并记录各候选概率（不判定期望）。
只向 Jev 发请求（HTTPS），不起服务端。素材 N3 / V3、候选表 T1、请求模板、概率读数沿用 s1h_design.py / s1e_design.py（import，不改它们）。

输入：.demo/observe/npc-slice1-20261112/s1i/outputs/outputs.json（36 条；用 key、bank、producer、sample、clean，clean 逐字使用）。

变体（每个只在原文上加声明的那一处，其余逐字节不变；124 次请求）：
  N3_F0      N3 原文，4 次           V3_F0      V3 原文，4 次
  N3_D2      N3 + s1h 的 D2_LINE（“What I remember” 栏尾），4 次
  N3_D12r    N3 + D1r 事实句（“What just happened” 栏尾）+ D2R_LINE（“What I remember” 栏尾），4 次
  N3_<key>   N3 的 “What I remember” 栏末尾加一行 `- Reflection (my own conclusion, may be wrong): <clean>`，36 个 x 2 次
  V3_<key>   V3 同位置加同一行，18 个（每个 bank x producer 的 sample 1、2）x 2 次

用法（Windows 控制台输出中文需加 -X utf8）：
  python -I -B s1i_design.py dryrun    # 生成变体到 .demo/.../s1i/jev/ + edits.txt，断言只多出声明的行 / 句；不发请求
  python -I -B s1i_design.py run       # 发问：并发 <= 3，超时同 s1c2（60 s），失败最多重试 2 次；要求 dryrun 已通过

凭据同 s1h_design.py：run 只读主检出 .env 的 TYPESAFE_* 进本进程环境；值不打印、不写文件；只记录模型名。

第 2 轮（--round 2，两个子命令都加；不带则与第 1 轮完全一致）：
  输入 s1i/outputs2/outputs.json（48 条，另有 rule 字段）；变体写到 s1i/jev2/，结果写 results-s1i-round2.json。
  变体（152 次请求）：N3_F0 x4、V3_F0 x4、N3_<key> x 48（各 2 次）、V3_<key> x 24（每个 bank x producer x rule 的 sample 1、2，各 2 次）；
  不含 D2 / D12r。加行位置与前缀同第 1 轮。结果 JSON 的 state_file 为 s1i/jev2/<名>.txt，其余形状同下。
  python -I -B s1i_design.py dryrun --round 2 ；python -I -B s1i_design.py run --round 2

结果 JSON（results-s1i.json）形状：
  {"model": str, "repeats_note": str, "workers": 3, "timeout_s": 60, "max_retries": 2, "candidates": [候选名...],
   "started": ISO 时间, "finished": ISO 时间, "requests": 请求总数, "answered": 应答数, "failed": 失败数,
   "variants": [ {"variant": 名, "source": "N3"|"V3", "key": 如 "m1-R-3" 或 null,
                  "state_file": 相对路径, "model": 模型名,
                  "requests": [ {"repeat": 1.., "ok": bool, "top1": 候选名|null, "probs": {候选名: 概率}|null,
                                 "attempts": 尝试次数, "latency_ms": 成功那次的耗时|null,
                                 "error": 失败信息|null, "time": 该请求完成的 ISO 时间} ... ],
                  "time": 该变体最后一次请求完成的 ISO 时间 } ... ]}
变体次序：N3_F0, N3_D2, N3_D12r, V3_F0, 然后 N3_<key> x 36、V3_<key> x 18（按 outputs.json 次序）。
"""
import argparse, datetime, json, sys, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # python -I 不把脚本目录放进 sys.path
import s1c2_counterfactual as c
import s1e_design as e
import s1h_design as h

HERE = Path(__file__).resolve().parent
DEMO = e.DEMO
OUTPUTS = DEMO / 's1i/outputs/outputs.json'
OUT = DEMO / 's1i/jev'
RESULTS = HERE / 'results-s1i.json'
ROUNDS = {  # 轮次 -> (outputs.json, 变体目录, 结果 JSON, 记录数, state_file 前缀)；第 1 轮取值即上面三个常量
    1: dict(outputs=OUTPUTS, out=OUT, results=RESULTS, n=36, prefix='s1i/jev'),
    2: dict(outputs=DEMO / 's1i/outputs2/outputs.json', out=DEMO / 's1i/jev2', results=HERE / 'results-s1i-round2.json',
            n=48, prefix='s1i/jev2'),
}
WORKERS, TIMEOUT, MAX_RETRIES = min(c.WORKERS, 3), c.TIMEOUT, 2
MEM = h.MEM
LINE_FMT = '- Reflection (my own conclusion, may be wrong): %s'
SOURCES = {k: e.SOURCES[k] for k in ('N3', 'V3')}
TRIES = {'F0': 4, 'D2': 4, 'D12r': 4}  # 参考变体各 4 次；产出变体各 2 次
PRODUCT_REPEATS = 2


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')


def cfg(a):
    return ROUNDS[getattr(a, 'round', 1)]


def load_outputs(rd=1):
    k = ROUNDS[rd]
    recs = json.load(open(k['outputs'], encoding='utf-8'))
    assert len(recs) == k['n'], 'expected %d records, got %d' % (k['n'], len(recs))
    keys = [r['key'] for r in recs]
    assert len(set(keys)) == k['n'], 'duplicate keys'
    for r in recs:
        assert isinstance(r['clean'], str) and r['clean'] and '\n' not in r['clean'] and '\r' not in r['clean'], \
            '%s: clean is not a non-empty single line' % r['key']
        assert r['sample'] in (1, 2, 3, 4)
    return recs


def variant_table(recs, rd=1):
    """[(变体名, 来源, key|None, 操作名列表, 产出行|None, 次数)]"""
    if rd == 2:
        v = [('N3_F0', 'N3', None, [], None, 4), ('V3_F0', 'V3', None, [], None, 4)]
        v += [('N3_' + r['key'], 'N3', r['key'], [], LINE_FMT % r['clean'], PRODUCT_REPEATS) for r in recs]
        v += [('V3_' + r['key'], 'V3', r['key'], [], LINE_FMT % r['clean'], PRODUCT_REPEATS) for r in recs if r['sample'] in (1, 2)]
        assert len(v) == 2 + 48 + 24 and sum(x[5] for x in v) == 152
        return v
    v = [('N3_F0', 'N3', None, [], None, 4), ('N3_D2', 'N3', None, ['D2'], None, 4),
         ('N3_D12r', 'N3', None, ['D1r', 'D2r'], None, 4), ('V3_F0', 'V3', None, [], None, 4)]
    v += [('N3_' + r['key'], 'N3', r['key'], [], LINE_FMT % r['clean'], PRODUCT_REPEATS) for r in recs]
    v += [('V3_' + r['key'], 'V3', r['key'], [], LINE_FMT % r['clean'], PRODUCT_REPEATS) for r in recs if r['sample'] in (1, 2)]
    assert len(v) == 4 + 36 + 18 and sum(x[5] for x in v) == 124
    return v


def template():
    return h.template()


def dryrun(a):
    rd = getattr(a, 'round', 1)
    OUT = cfg(a)['out']
    OUTPUTS = cfg(a)['outputs']
    OUT.mkdir(parents=True, exist_ok=True)
    recs = load_outputs(rd)
    table = variant_table(recs, rd)
    json.dump(template(), open(OUT / 'template.json', 'w', encoding='utf-8', newline='\n'), indent=1, ensure_ascii=False)
    texts = {k: p.read_text(encoding='utf-8') for k, p in SOURCES.items()}
    counts = {k: h.guard_n(c.State(t)) for k, t in texts.items()}
    edits = ['S1-I put-into-state phase (dry run)',
             'sources: ' + ', '.join('%s = %s' % (k, p) for k, p in SOURCES.items()),
             'outputs: %s (%d records; clean used verbatim)' % (OUTPUTS, len(recs)),
             'reflection line format: %s' % (LINE_FMT % '<clean>'),
             'guard_hut sentences in "What just happened": ' + ', '.join('%s=%d' % kv for kv in counts.items()), '']
    for name, src, key, ops, line, reps in table:
        before = c.State(texts[src])
        st = c.State(texts[src])
        cx = h.Cx()
        for o in ops:
            h.OPS[o](st, cx)
        if line is not None:
            st.sec[MEM] = st.sec[MEM] + '\n' + line
            cx.log('appended to the end of "%s": %s' % (MEM, line))
        out = st.render()
        (OUT / (name + '.txt')).write_bytes(out.encode('utf-8'))
        declared = {t for o in ops for t in h.CHECKS[o]} | ({MEM} if line is not None else set())
        changed = {t for t in c.TITLES if before.sec[t] != st.sec[t]}
        assert changed == declared, '%s: changed sections %s != declared %s' % (name, sorted(changed), sorted(declared))
        # 独立核对：声明栏的内容恰是声明的改动；其余栏逐字节不变（由 changed == declared 保证）
        for o in ops:
            for title, chk in h.CHECKS[o].items():
                chk(before.sec[title], st.sec[title], counts[src])
        if line is not None:
            assert st.sec[MEM] == before.sec[MEM] + '\n' + line, '%s: not a pure tail addition of the reflection line' % name
            assert line.endswith(recs[[r['key'] for r in recs].index(key)]['clean']), '%s: clean not verbatim' % name
            assert out.count(line) == 1 and out.count('- Reflection (') == 1, '%s: reflection line count' % name
            # 整个文本层面：删掉这一行（含前导换行）应得到原文
            assert out.replace('\n' + line, '', 1) == texts[src], '%s: removing the line does not give the source' % name
        if not ops and line is None:
            assert out == texts[src], '%s: unchanged variant differs from its source' % name
        lo, ln = texts[src].split('\n'), out.split('\n')
        diff_lines = [i + 1 for i in range(max(len(lo), len(ln))) if i >= len(lo) or i >= len(ln) or lo[i] != ln[i]]
        order = [t for t in c.TITLES if t in changed]
        shown = (line[:90] + '...') if line is not None and len(line) > 90 else line
        edits += ['=== %s  (source %s, %d requests)' % (name, SOURCES[src].name, reps),
                  'changed sections: ' + (', '.join(order) or 'none (byte-identical)'),
                  'lines differing from source (1-based): ' + (','.join(map(str, diff_lines)) or '-')]
        edits += ['  ' + l if line is None or l != cx.lines[-1] else '  appended to the end of "%s": %s' % (MEM, shown) for l in cx.lines]
        edits += ['  self-check: only declared sections changed; content verified independently: OK', '']
    (OUT / 'edits.txt').write_text('\n'.join(edits), encoding='utf-8', newline='\n')
    print('dryrun OK: %d variants, %d requests planned; assertions all passed; wrote to %s' %
          (len(table), sum(x[5] for x in table), OUT))


def run(a):
    rd = getattr(a, 'round', 1)
    OUT, RESULTS = cfg(a)['out'], cfg(a)['results']
    if RESULTS.exists():
        raise SystemExit('%s exists; refusing to overwrite' % RESULTS)
    recs = load_outputs(rd)
    table = variant_table(recs, rd)
    missing = [n for n, *_ in table if not (OUT / (n + '.txt')).exists()]
    if missing or not (OUT / 'template.json').exists():
        raise SystemExit('run dryrun first (missing: %s)' % (missing[:3] or 'template.json'))
    tpl = json.load(open(OUT / 'template.json', encoding='utf-8'))
    texts = {n: (OUT / (n + '.txt')).read_text(encoding='utf-8') for n, *_ in table}
    cands = [x['name'] for x in tpl['candidates']]
    c.load_env()
    from jev import ask, ENV
    q = c.question(tpl)
    cells = [(n, r + 1) for n, _, _, _, _, reps in table for r in range(reps)]
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
    variants = [{'variant': n, 'source': src, 'key': key, 'state_file': '%s/%s.txt' % (cfg(a)['prefix'], n), 'model': ENV['TYPESAFE_MODEL'],
                 'requests': sorted(by[n], key=lambda r: r['repeat']), 'time': max(r['time'] for r in by[n])}
                for n, src, key, _, _, _ in table]
    ok = sum(r['ok'] for _, r in got)
    data = {'model': ENV['TYPESAFE_MODEL'], 'repeats_note': 'reference variants 4 requests; product variants 2 requests',
            'workers': WORKERS, 'timeout_s': TIMEOUT, 'max_retries': MAX_RETRIES, 'candidates': cands,
            'started': started, 'finished': now(), 'requests': len(got), 'answered': ok, 'failed': len(got) - ok,
            'variants': variants}
    json.dump(data, open(RESULTS, 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
    print('requests', len(got), 'answered', ok, 'failed', len(got) - ok, '->', RESULTS)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name in ('dryrun', 'run'):
        sub.add_parser(name).add_argument('--round', type=int, choices=(1, 2), default=1)
    args = ap.parse_args()
    {'dryrun': dryrun, 'run': run}[args.cmd](args)
