"""只测试：标准人格描述（big5.py）的强度阶梯在 Jev 上是否有序。
单维度塑造：5 个维度 × 9 级 × persona.py 的 4 个情境 × 2 种状态（中性、与高分倾向相冲突的状态）× REPEATS 次，无记忆。
期望在运行前手工写在 UP 里：该维度升高时应当更常被选中的选项；None = 没有明确预期，只列出不计分。
判据：9 级里“选中 UP 集合”的指示序列应当单调不降（没有“低级选中、高级反而不选”的逆序对），并且两端不同。
用法：python traits.py run（720 次 Jev 请求，写 results-traits.json）；python traits.py report（离线）"""
import json, sys
from concurrent.futures import ThreadPoolExecutor
from big5 import PAIRS, domain, render
from persona import SCENARIOS, INSTRUCTIONS

REPEATS = 2
WORKERS = 3
OUT = 'results-traits.json'
CONFLICT = {'meal': 'starving_broke', 'work': 'exhausted_hurt', 'walk': 'fog_night', 'combat': 'losing'}

UP = {
    'EXT': {'meal': ['share_meal', 'tavern_stew'], 'work': ['help_mara'], 'walk': ['market_square'], 'combat': ['press_attack']},
    'AGR': {'meal': ['share_meal'], 'work': ['help_mara', 'finish_fence'], 'walk': None, 'combat': ['offer_truce']},
    'CON': {'meal': ['bread_and_cheese', 'skip_meal'], 'work': ['finish_fence', 'quarry_stone', 'repair_roof'], 'walk': None, 'combat': None},
    'NEU': {'meal': None, 'work': None, 'walk': ['stay_home', 'lakeshore'], 'combat': ['retreat_to_village', 'call_for_help']},
    'OPE': {'meal': ['forage_mushrooms'], 'work': ['explore_cave'], 'walk': ['forest_ruins', 'hilltop'], 'combat': None},
}


def state(scenario, name, level, condition):
    s = SCENARIOS[scenario]
    return ('Character: A villager. Personality: %s.\nCurrent condition: %s\nRelevant memories: None.\nScene: %s'
            % (render(domain(name, level)), s['conditions'][condition][0], s['scene']))


def run():
    from jev import ask, ENV
    cells = [(sc, d, level, c, r) for sc in SCENARIOS for d in PAIRS for level in range(1, 10)
             for c in ('neutral', CONFLICT[sc]) for r in range(REPEATS)]

    def one(cell):
        sc, d, level, c, r = cell
        question = {'type': 'choice', 'instructions': INSTRUCTIONS, 'criteria': SCENARIOS[sc]['options']}
        answers, usage, seconds = ask(state(sc, d, level, c), {'q': question})
        row = {'scenario': sc, 'domain': d, 'level': level, 'condition': c, 'repeat': r, 'seconds': round(seconds, 3)}
        if 'error' in answers:
            row['error'] = answers
        else:
            row.update(choice=answers['q']['choice'], confidence=answers['q']['confidence'], tokens=usage['input_tokens'])
        return row

    with ThreadPoolExecutor(WORKERS) as pool:
        rows = list(pool.map(one, cells))
    json.dump({'model': ENV['TYPESAFE_MODEL'], 'repeats': REPEATS, 'rows': rows}, open(OUT, 'w', encoding='utf-8'), indent=1)
    print('requested', len(cells), 'answered', sum('choice' in r for r in rows), 'errors', sum('error' in r for r in rows))


def report():
    data = json.load(open(OUT, encoding='utf-8'))
    rows = [r for r in data['rows'] if 'choice' in r]
    expected = len(SCENARIOS) * len(PAIRS) * 9 * 2 * data['repeats']
    print('model', data['model'], '| requested', expected, '| answered', len(rows), '| errors', len(data['rows']) - len(rows))
    if len(rows) != expected:
        print('INCOMPLETE: results below cover answered cells only')
    by = {}
    for r in rows:
        by.setdefault((r['scenario'], r['domain'], r['condition'], r['level']), set()).add(r['choice'])
    print('[repeat] cells with identical top1 across repeats: %d / %d' % (sum(len(v) == 1 for v in by.values()), len(by)))

    scored = ordered = moved = 0
    for d in PAIRS:
        print('\n=== %s (1 = extremely %s … 9 = extremely %s) ===' % (d, PAIRS[d][0][0], PAIRS[d][0][1]))
        for sc in SCENARIOS:
            for c in ('neutral', CONFLICT[sc]):
                ladder = ['|'.join(sorted(by.get((sc, d, c, level), ['?']))) for level in range(1, 10)]
                note = ''
                up = UP[d][sc]
                if up:
                    # 重复不一致的格按“两次都在集合里”才算选中
                    hit = [all(x in up for x in cell.split('|')) for cell in ladder]
                    inversions = sum(hit[i] and not hit[j] for i in range(9) for j in range(i + 1, 9))
                    first = hit.index(True) + 1 if any(hit) else None
                    note = '  UP=%s inversions=%d first_level=%s' % (','.join(up), inversions, first)
                    if c == 'neutral':
                        scored += 1
                        ordered += inversions == 0
                        moved += inversions == 0 and hit[8] and not hit[0]
                print('%-7s %-15s %s%s' % (sc, c, ' > '.join(ladder), note))
    print('\n[ladder] neutral ladders with a hand-written expectation: %d; no inversions: %d; '
          'no inversions and low end differs from high end: %d' % (scored, ordered, moved))


if __name__ == '__main__':
    {'run': run, 'report': report}[sys.argv[1]]()
