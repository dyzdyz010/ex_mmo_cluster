"""只测试：Jev 的选择对“记忆里连续 N 天做同一件事”有没有可推论的响应，响应方向是否随人格而定。
吃什么、散步去哪（persona.py，中性状态）× 5 个人格 × 把 6 个选项逐个当作“连续做了 N 天的那一件”（N = 3、7）+ 无历史基线，每格 REPEATS 次。
历史只原样列出每天做了什么，不加“腻了”之类的结论。
运行前写下的预期（用户的预测）：喜欢新鲜感的人格在连续 7 天之后不再选那一项（12 格里 0 格）；
very predictable 仍选那一项的格数多于喜欢新鲜感的人格。none 只测量。
用法：python habit.py run（260 次 Jev 请求，写 results-habit.json）；python habit.py report（离线）"""
import json, sys
from concurrent.futures import ThreadPoolExecutor
from big5 import render
from persona import SCENARIOS, INSTRUCTIONS
from routine import DID

REPEATS, WORKERS = 2, 3
OUT = 'results-habit.json'
LENGTHS = (3, 7)
PERSONAS = {
    'none': 'A villager. Personality: not specified.',
    'predictable': 'A villager. Personality: %s.' % render({'spontaneous': 2}),
    'spontaneous': 'A villager. Personality: %s.' % render({'spontaneous': 8}),
    'curious_spontaneous': 'A villager. Personality: %s.' % render({'curious': 9, 'spontaneous': 9}),
    'likes_novelty': 'A villager. Personality: not specified. Preferences: likes novelty and new experiences, '
                     'and gets bored when things repeat.',
}
NOVELTY = ('spontaneous', 'curious_spontaneous', 'likes_novelty')


def memories(scenario, option, days):
    if not days:
        return 'None.'
    ago = lambda n: 'yesterday' if n == 1 else '%d days ago' % n
    return ('What I did at this time on previous days, oldest first: '
            + '; '.join('%s I %s' % (ago(n), DID[scenario][option]) for n in range(days, 0, -1)) + '.')


def run():
    from jev import ask, ENV
    cells = [(sc, p, option, days, r) for sc in DID for p in PERSONAS
             for option, days in [(None, 0)] + [(o, n) for o in DID[sc] for n in LENGTHS] for r in range(REPEATS)]

    def one(cell):
        sc, p, option, days, r = cell
        s = SCENARIOS[sc]
        state = ('Character: %s\nCurrent condition: %s\nRelevant memories: %s\nScene: %s'
                 % (PERSONAS[p], s['conditions']['neutral'][0], memories(sc, option, days), s['scene']))
        answers, _, _ = ask(state, {'q': {'type': 'choice', 'instructions': INSTRUCTIONS, 'criteria': s['options']}})
        row = {'scenario': sc, 'persona': p, 'repeated': option, 'days': days, 'repeat': r}
        if 'error' in answers:
            row['error'] = answers
        else:
            row.update(choice=answers['q']['choice'], probabilities=answers['q']['probabilities'])
        return row

    with ThreadPoolExecutor(WORKERS) as pool:
        rows = list(pool.map(one, cells))
    json.dump({'model': ENV['TYPESAFE_MODEL'], 'rows': rows}, open(OUT, 'w', encoding='utf-8'), indent=1)
    print('requested', len(cells), 'answered', sum('choice' in r for r in rows), 'errors', sum('error' in r for r in rows))


def report():
    data = json.load(open(OUT, encoding='utf-8'))
    rows = [r for r in data['rows'] if 'choice' in r]
    expected = len(DID) * len(PERSONAS) * (1 + 6 * len(LENGTHS)) * REPEATS
    print('model', data['model'], '| requested', expected, '| answered', len(rows), '| errors', len(data['rows']) - len(rows))
    if len(rows) != expected:
        print('INCOMPLETE: results below cover answered cells only')
    by = {}
    for r in rows:
        by.setdefault((r['scenario'], r['persona'], r['repeated'], r['days']), []).append(r)
    cell = lambda *key: '|'.join(sorted({r['choice'] for r in by[key]}))
    prob = lambda *key: sum(r['probabilities'][key[2]] for r in by[key]) / len(by[key])
    stuck = {}
    for sc in DID:
        print('\n=== %s: top1 after N days of the option in the column (* = picked it again) ===' % sc)
        print('%-20s %-5s %-18s' % ('persona', 'days', 'no history') + ' '.join('%-18s' % o for o in DID[sc]))
        for p in PERSONAS:
            base = cell(sc, p, None, 0)
            for days in LENGTHS:
                picks = [cell(sc, p, o, days) for o in DID[sc]]
                # 两次里有一次选回去也算“仍选那一项”
                again = [o in pick.split('|') for o, pick in zip(DID[sc], picks)]
                stuck[(p, days)] = stuck.get((p, days), 0) + sum(again)
                print('%-20s %-5d %-18s' % (p, days, base) + ' '.join('%-18s' % (pick + ('*' if a else '')) for pick, a in zip(picks, again)))
            # 基线首选被重复之后，它的概率怎么变
            if '|' not in base:
                print('%-20s       P(%s): no history %.2f -> 3 days %.2f -> 7 days %.2f'
                      % ('', base, sum(r['probabilities'][base] for r in by[(sc, p, None, 0)]) / REPEATS,
                         prob(sc, p, base, 3), prob(sc, p, base, 7)))
    total = len(DID) * 6
    print('\n[stuck] cells (of %d) where the repeated option was picked again:' % total,
          {p: {days: stuck[(p, days)] for days in LENGTHS} for p in PERSONAS})
    for p in NOVELTY:
        print('[expectation] %s never repeats after 7 days: %s' % (p, 'ok' if stuck[(p, 7)] == 0 else 'NOT MET (%d)' % stuck[(p, 7)]))
    print('[expectation] predictable repeats more than every novelty persona after 7 days:',
          'ok' if all(stuck[('predictable', 7)] > stuck[(p, 7)] for p in NOVELTY) else 'NOT MET')


if __name__ == '__main__':
    {'run': run, 'report': report}[sys.argv[1]]()
