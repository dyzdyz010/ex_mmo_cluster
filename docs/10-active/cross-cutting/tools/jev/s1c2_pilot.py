"""只测试：S1-D2 之后、S1-C2 实跑之前的离线预检。只向 Jev 发请求（HTTPS），不起服务端。
问题：产品现在写的 state（整座移除的标准经历句 + 处境里的 `is gone`）下，Garen 是否转向重建；
去掉哪一处来源后仍然转向，哪一处是必需的。

基准 state 取自上次实跑 C2 发问（E/states/asked-20261112T121753Z.txt，E = .demo/observe/npc-slice1-20261112/s1c）。
`base` 只做两处改动，使之等于 S1-D2 提交 c0489bd7 之后产品在同一情形下写出的文本：
  (1) 事件句：`Actor … damaged the building …` 换成 life/state.ex `account(:removed, …)`（第 341 行）的原文，后面的
      `I feel angry toward this actor; my trust changed.` 原样保留（npc_selector_test.exs 第 840–845 行有同一写法）；
  (2) 处境：Mind.building/1（mind.ex 第 145–146 行）的 `My building "small hut" at (25, 518, 37) is gone.`，
      插在 `Nearby`/`Nobody else is nearby.` 之后、`Inventory:` 之前（Mind.situation/2，npc_mind_test.exs 第 98 行同一次序）。
其余一字不动。其余变体都从 base 出发，每个只删指定来源。栏目删空时的写法取自 mind.ex：
  情绪栏空 -> `Nothing notable.`（第 96 行）；近期活动空 -> `None yet.`（第 179 行）；
  （“What just happened”空 -> `Nothing new.`，第 118 行；本脚本的变体都不会把这一栏删空。）

请求体与 s1c_diag.py 相同（同一 instructions、同一五项候选、jev.ask）；每变体 REPEATS 次，并发 WORKERS，单次超时 60 秒，
不重试；失败如实记失败，不补问。

期望（统筹会话运行前写定，照抄，不许改；落空如实记落空）。“重建方向”= top1 in {build_hut, gather_stone}。
每个变体 4 次里 >= 3 次符合算成立。
  base              重建方向
  no_event          重建方向（处境里的 is gone 单独就够）
  no_gone           重建方向（标准事件句单独就够）
  no_event_no_gone  不在重建方向（top1 是 visit_plaza 或 guard_hut）
  no_anger          重建方向（不变）
  no_distrust       重建方向（不变）
  no_own_activity   重建方向（不变）
  all_removed       visit_plaza

凭据：进程环境里没有 TYPESAFE_* 时，只读进主检出 D:/hemifuture/ex_mmo_cluster/.env 的 TYPESAFE_API_URL / KEY / MODEL
到本进程环境；值不打印、不写文件。
用法：python -B s1c2_pilot.py prepare | run | report
"""
import json, os, re, statistics, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPEATS, WORKERS, TIMEOUT = 4, 3, 60
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
E = ROOT / '.demo/observe/npc-slice1-20261112'
PILOT = E / 's1c2/pilot'
SOURCE = E / 's1c/states/asked-20261112T121753Z.txt'
OUT = HERE / 'results-s1c2-pilot.json'
MAIN_ENV = Path('D:/hemifuture/ex_mmo_cluster/.env')

from s1c_diag import ACTIVITIES, INSTRUCTIONS, DAMAGE, TAIL, DISTRUST, SIT_GONE, INVENTORY  # noqa: E402

REBUILD = {'build_hut', 'gather_stone'}
EXPECT = {
    'rebuild': ('重建方向 (top1 in build_hut / gather_stone)', lambda c: c in REBUILD),
    'not_rebuild': ('不在重建方向 (top1 in visit_plaza / guard_hut)', lambda c: c in {'visit_plaza', 'guard_hut'}),
    'plaza': ('visit_plaza', lambda c: c == 'visit_plaza'),
}

# life/state.ex account(:removed, …) 的原文 + 同一事件的情绪尾巴（规则模式）。
EMOTION_TAIL = ' I feel angry toward this actor; my trust changed.'
REMOVED = ('Actor 1984744656898 removed the entire building "small hut" that I built, ' + TAIL +
           '; the building no longer exists.')
EVENT_NEW = REMOVED + EMOTION_TAIL
ANGER = 'Feels strong anger toward actor 1984744656898, who is not nearby.'
# “What just happened”里自己的活动经历：`At <t> (UTC), I did "<名>" (<判据>). Result: completed.`
OWN_ACTIVITY = re.compile(r'At \S+ \(UTC\), I did "[a-z_]+" \(.*?\)\. Result: completed\. ?')


def once(text, old, new, count=1):
    assert text.count(old) == count, (text.count(old), count, old)
    return text.replace(old, new)


def make_base(c2):
    text = once(c2, DAMAGE + EMOTION_TAIL, EVENT_NEW)
    return once(text, INVENTORY, SIT_GONE + INVENTORY)


def drop_event(text):
    return once(text, 'At 2026-11-12T12:17:26.734Z (UTC), ' + EVENT_NEW + ' ', '')


def drop_gone(text):
    return once(text, SIT_GONE, '')


def drop_anger(text):
    return once(text, ANGER + ' ', '')


def drop_distrust(text):
    return once(text, ' ' + DISTRUST, '')


def drop_own_activity(text):
    text, n = OWN_ACTIVITY.subn('', text)
    assert n == 6, n
    # “Recent activities”空了：Mind.recent([]) = "None yet."
    head, _, _ = text.rpartition('\nRecent activities: ')
    return head + '\nRecent activities: None yet.'


def drop_all(text):
    # 情绪栏空了：Mind.feelings 没有任何句子时写 "Nothing notable."
    text = once(drop_gone(drop_event(text)), ANGER + ' ' + DISTRUST, 'Nothing notable.')
    return text


def variants():
    base = make_base(SOURCE.read_text(encoding='utf-8'))
    return {
        'base': (base, 'rebuild'),
        'no_event': (drop_event(base), 'rebuild'),
        'no_gone': (drop_gone(base), 'rebuild'),
        'no_event_no_gone': (drop_gone(drop_event(base)), 'not_rebuild'),
        'no_anger': (drop_anger(base), 'rebuild'),
        'no_distrust': (drop_distrust(base), 'rebuild'),
        'no_own_activity': (drop_own_activity(base), 'rebuild'),
        'all_removed': (drop_all(base), 'plaza'),
    }


def prepare():
    PILOT.mkdir(parents=True, exist_ok=True)
    out = variants()
    for label, (text, _) in out.items():
        (PILOT / (label + '.txt')).write_text(text, encoding='utf-8', newline='\n')
    print('wrote', len(out), 'variants to', PILOT)
    return out


def load_env():
    if 'TYPESAFE_API_KEY' not in os.environ:
        for line in MAIN_ENV.read_text(encoding='utf-8').splitlines():
            if '=' in line and not line.startswith('#'):
                k, v = line.split('=', 1)
                if k.startswith('TYPESAFE_'):
                    os.environ[k] = v.strip()


def question():
    return {'activity': {'criteria': ACTIVITIES, 'instructions': INSTRUCTIONS, 'type': 'choice'}}


def run():
    load_env()
    from jev import ask, ENV
    texts = prepare()
    cells = [(label, r) for label in texts for r in range(REPEATS)]

    def one(cell):
        label, r = cell
        row = {'variant': label, 'repeat': r + 1}
        try:
            answers, _, seconds = ask(texts[label][0], question(), timeout=TIMEOUT)
        except Exception as e:  # 网络 / 超时：如实记失败，不重试
            return {**row, 'error': type(e).__name__}
        row['latency_ms'] = round(seconds * 1000)
        if 'error' in answers:
            row['error'] = {'http': answers['error']}
        else:
            row['answer'] = answers['activity']
        return row

    with ThreadPoolExecutor(WORKERS) as pool:
        rows = list(pool.map(one, cells))
    data = {'model': ENV['TYPESAFE_MODEL'], 'repeats': REPEATS, 'workers': WORKERS, 'source': SOURCE.name,
            'variants': {l: {'expected': EXPECT[e][0], 'state_file': 's1c2/pilot/%s.txt' % l} for l, (_, e) in texts.items()},
            'rows': rows}
    json.dump(data, open(OUT, 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
    print('requested', len(rows), 'answered', sum('answer' in r for r in rows), 'errors', sum('error' in r for r in rows))


def report():
    data = json.load(open(OUT, encoding='utf-8'))
    rows = data['rows']
    lat = [r['latency_ms'] for r in rows if 'latency_ms' in r]
    print('requests', len(rows), 'failed', sum('answer' not in r for r in rows),
          'latency_ms median', statistics.median(lat), 'min', min(lat), 'max', max(lat))
    expect_of = {l: [k for k, v in EXPECT.items() if v[0] == d['expected']][0] for l, d in data['variants'].items()}
    for label in data['variants']:
        mine = sorted((r for r in rows if r['variant'] == label), key=lambda r: r['repeat'])
        picks = [r['answer']['choice'] for r in mine if 'answer' in r]
        hits = sum(EXPECT[expect_of[label]][1](c) for c in picks)
        print('\n%s | expect %s | %s (%d/%d answered, need %d/%d)' % (
            label, EXPECT[expect_of[label]][0], 'MEETS' if hits >= 3 else 'MISSES', len(picks), len(mine), 3, REPEATS))
        for r in mine:
            if 'answer' not in r:
                print('  #%d ERROR %s' % (r['repeat'], r['error']))
                continue
            a = r['answer']
            p = a.get('probabilities') or {}
            print('  #%d %s conf=%s | %s' % (r['repeat'], a['choice'], a.get('confidence'),
                                              ' '.join('%s=%.2f' % (k, v) for k, v in p.items())))


if __name__ == '__main__':
    {'prepare': prepare, 'run': run, 'report': report}[sys.argv[1]]()
