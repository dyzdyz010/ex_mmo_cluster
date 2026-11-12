"""只测试：把“前几天这个时候做了什么”写进记忆后，同一角色连续多天的 top1 会不会自然轮换。
2 个每天重复的情境（吃什么、散步去哪，取自 persona.py，中性状态）× 9 个人格 × 3 种记忆写法 × DAYS 天 × REPEATS 条链。
  * none ：不写历史（对照；每天的输入完全相同）；
  * log  ：只把最近 WINDOW 天自己的选择原样列出，不加“吃腻了”之类的结论；
  * tired：在 log 之上，同一选择连续满 TIRED_AFTER 天时由代码加一句“连着几天做同一件事，有点腻了”。
人格：不写人格的对照、big5.py 的 6 张标准卡，以及只写一对形容词的 very predictable / very spontaneous。
运行前写下的预期：spontaneous 在 log、tired 下选过的不同选项数不少于 predictable，且至少一个情境严格更多；
tired 的平均不同选项数高于 log（tired 是看过 none / log 结果后加的）。其余只测量、不计分。
用法：python routine.py run [arm…]（每个 arm 360 次 Jev 请求，链内串行，并入 results-routine.json）；python routine.py report（离线）"""
import json, os, sys
from concurrent.futures import ThreadPoolExecutor
from big5 import CARDS, describe, render
from persona import SCENARIOS, INSTRUCTIONS

DAYS, WINDOW, TIRED_AFTER, REPEATS, WORKERS = 10, 5, 3, 2, 3
ARMS = ('none', 'log', 'tired')
OUT = 'results-routine.json'

PERSONAS = {'none': 'A villager. Personality: not specified.',
            'predictable': 'A villager. Personality: %s.' % render({'spontaneous': 2}),
            'spontaneous': 'A villager. Personality: %s.' % render({'spontaneous': 8})}
PERSONAS.update({name: describe(card, personal=False) for name, card in CARDS.items()})

DID = {
    'meal': {'tavern_stew': 'bought the meat stew and ale at the tavern', 'bread_and_cheese': 'ate bread and cheese from my pack, alone',
             'grill_fish': 'caught and grilled a fish at the lake', 'forage_mushrooms': 'gathered and ate unfamiliar forest mushrooms',
             'share_meal': 'ate with the neighbours at the communal table', 'skip_meal': 'skipped the meal and kept working'},
    'walk': {'lakeshore': 'strolled the lakeshore path', 'market_square': 'went to the market square',
             'forest_ruins': 'followed the forest trail to the old ruins', 'hilltop': 'climbed to the hilltop lookout',
             'quarry_road': 'walked the quarry road past the building site', 'stay_home': 'stayed at home'},
}


def memories(scenario, history, tired=False):
    recent = history[-WINDOW:]
    if not recent:
        return 'None.'
    ago = lambda n: 'yesterday' if n == 1 else '%d days ago' % n
    text = ('What I did at this time on previous days, oldest first: '
            + '; '.join('%s I %s' % (ago(len(recent) - i), DID[scenario][c]) for i, c in enumerate(recent)) + '.')
    run_length = next((i for i, c in enumerate(reversed(history)) if c != history[-1]), len(history))
    if tired and run_length >= TIRED_AFTER:
        text += ' I have now done the same thing %d days in a row and I am getting tired of it.' % run_length
    return text


def run():
    from jev import ask, ENV
    arms = sys.argv[2:] or ARMS
    chains = [(sc, p, arm, r) for sc in DID for p in PERSONAS for arm in arms for r in range(REPEATS)]

    def one(chain):
        sc, p, arm, r = chain
        s = SCENARIOS[sc]
        question = {'type': 'choice', 'instructions': INSTRUCTIONS, 'criteria': s['options']}
        history, confidences = [], []
        for _ in range(DAYS):
            state = ('Character: %s\nCurrent condition: %s\nRelevant memories: %s\nScene: %s'
                     % (PERSONAS[p], s['conditions']['neutral'][0], memories(sc, [] if arm == 'none' else history, arm == 'tired'), s['scene']))
            answers, _, _ = ask(state, {'q': question})
            if 'error' in answers:
                return {'scenario': sc, 'persona': p, 'arm': arm, 'repeat': r, 'error': answers, 'choices': history}
            history.append(answers['q']['choice'])
            confidences.append(answers['q']['confidence'])
        return {'scenario': sc, 'persona': p, 'arm': arm, 'repeat': r, 'choices': history, 'confidences': confidences}

    with ThreadPoolExecutor(WORKERS) as pool:
        rows = list(pool.map(one, chains))
    if os.path.exists(OUT):  # 只重跑指定的 arm，其余保留
        rows = [r for r in json.load(open(OUT, encoding='utf-8'))['rows'] if r['arm'] not in arms] + rows
    json.dump({'model': ENV['TYPESAFE_MODEL'], 'days': DAYS, 'window': WINDOW, 'rows': rows}, open(OUT, 'w', encoding='utf-8'), indent=1)
    print('chains', len(chains), 'complete', sum('error' not in r for r in rows), 'errors', sum('error' in r for r in rows))


def streak(choices):
    best = run_length = 1
    for a, b in zip(choices, choices[1:]):
        run_length = run_length + 1 if a == b else 1
        best = max(best, run_length)
    return best


def report():
    data = json.load(open(OUT, encoding='utf-8'))
    rows = [r for r in data['rows'] if 'error' not in r]
    expected = len(DID) * len(PERSONAS) * len(ARMS) * REPEATS
    print('model', data['model'], '| chains requested', expected, '| complete', len(rows), '| errors', len(data['rows']) - len(rows))
    if len(rows) != expected:
        print('INCOMPLETE: results below cover complete chains only')
    distinct = {}
    for sc in DID:
        short = {c: c.split('_')[0][:6] for c in DID[sc]}
        print('\n=== %s (%d days, memory window %d) ===' % (sc, data['days'], data['window']))
        for p in PERSONAS:
            for arm in ARMS:
                for r in sorted((r for r in rows if (r['scenario'], r['persona'], r['arm']) == (sc, p, arm)), key=lambda r: r['repeat']):
                    c = r['choices']
                    distinct.setdefault((sc, p, arm), []).append(len(set(c)))
                    print('%-12s %-5s %-62s distinct=%d longest_streak=%d' % (p, arm, ' '.join(short[x] for x in c), len(set(c)), streak(c)))
    print()
    for arm in ARMS:
        chains = [r['choices'] for r in rows if r['arm'] == arm]
        print('[%s] chains %d | mean distinct options %.1f | chains with a single option all %d days: %d | mean longest streak %.1f'
              % (arm, len(chains), sum(len(set(c)) for c in chains) / len(chains), data['days'],
                 sum(len(set(c)) == 1 for c in chains), sum(streak(c) for c in chains) / len(chains)))
    mean = lambda key: sum(distinct[key]) / len(distinct[key])
    for arm in ('log', 'tired'):
        pairs = {sc: (mean((sc, 'predictable', arm)), mean((sc, 'spontaneous', arm))) for sc in DID}
        ok = all(s >= p for p, s in pairs.values()) and any(s > p for p, s in pairs.values())
        print('[expectation] distinct options under %s, predictable vs spontaneous:' % arm, pairs, 'ok' if ok else 'NOT MET')
    overall = {arm: sum(sum(v) for k, v in distinct.items() if k[2] == arm) / sum(len(v) for k, v in distinct.items() if k[2] == arm)
               for arm in ('log', 'tired')}
    print('[expectation] mean distinct options, tired > log:', overall, 'ok' if overall['tired'] > overall['log'] else 'NOT MET')
    print('[tired] distinct option sets per persona:',
          {sc: {p: sorted({c for r in rows if (r['scenario'], r['persona'], r['arm']) == (sc, p, 'tired') for c in r['choices']})
                for p in PERSONAS} for sc in DID})


if __name__ == '__main__':
    {'run': run, 'report': report}[sys.argv[1]]()
