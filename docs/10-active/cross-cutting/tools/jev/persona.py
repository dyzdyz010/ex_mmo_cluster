"""只测试：自然语言上下文（人格 / 当前状态 / 记忆）能否移动 Jev 的 top1 选择。
4 个情境 × 7 个人格（含不写人格的对照）× 3 种状态 × 3 种记忆，每格问 REPEATS 次；top1 即最终选择。
期望值在运行前手工写在本文件里，不来自模型输出：
  * SIGNATURE：中性状态、无记忆时，各人格可接受的选项集合（None = 该人格对此情境没有明确倾向，不计分）；
  * toward / away：某个状态或记忆出现后，7 个人格里选中这些选项的人数应当比中性基线多 / 少。
两个对照变体：mild 把四个措辞最重的人格改写成温和措辞；big5 把 6 个人格改成 big5.py 的标准形容词 + 9 级强度写法（只有 traits 段）；
card 在 big5 之上再加 personal 段（偏好 / 承诺 / 目标的自由文本）。
用法：python persona.py run [mild|big5|card]   （504 次 Jev 请求，写 results-persona[-变体].json）
      python persona.py report [mild|big5|card]（只读结果文件，无模型调用）
"""
import json, statistics, sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

REPEATS = 2
WORKERS = 3
VARIANT = sys.argv[2] if len(sys.argv) > 2 else ''
OUT = 'results-persona%s.json' % ('-' + VARIANT if VARIANT else '')

PERSONAS = {
    'none': 'A villager. Personality: not specified.',
    'lin': 'Lin, a builder. Personality: cautious, frugal and methodical. She dislikes crowds and noise, '
           'plans ahead, and takes pride in always keeping her promises.',
    'garrick': 'Garrick, a hunter. Personality: bold, impulsive and thrill-seeking. Routine bores him. '
               'He loves meat, strong drink and a good fight, and rarely thinks about tomorrow.',
    'sella': 'Sella, a weaver. Personality: warm, sociable and generous. She loves company and gossip, '
             'hates being alone, and will drop her own work to help a friend.',
    'ode': 'Ode, a tinkerer. Personality: endlessly curious and absent-minded. Anything unknown or untested '
           'pulls him in; he forgets meals and chores when something puzzles him.',
    'hask': 'Hask, a farmhand. Personality: lazy and comfort-loving. He avoids effort, discomfort and risk '
            'whenever he can, and does the least that lets him get by.',
    'brenna': 'Brenna, a mason. Personality: proud, ambitious and competitive. She wants to be known as the '
              'best in the village and cannot stand losing or looking weak.',
}

if VARIANT == 'mild':
    PERSONAS.update({
        'garrick': 'Garrick, a hunter. Personality: on the bold side and somewhat impulsive. He enjoys excitement, '
                   'meat and a drink, and gets restless with routine.',
        'sella': 'Sella, a weaver. Personality: friendly and fairly sociable. She usually enjoys company and likes '
                 'to help friends when she can.',
        'ode': 'Ode, a tinkerer. Personality: curious and a bit absent-minded. New and unknown things interest him '
               'more than they interest most people.',
        'hask': 'Hask, a farmhand. Personality: easy-going and fond of comfort. He prefers light work and tends to '
                'avoid unnecessary effort.',
    })

if VARIANT in ('big5', 'card'):
    from big5 import CARDS, describe
    PERSONAS.update({name: describe(card, personal=VARIANT == 'card') for name, card in CARDS.items()})

INSTRUCTIONS = ('Decide what this specific character does next. Choose the single option this character would '
                'actually pick, given their personality, current condition, memories and the scene.')

SCENARIOS = {
    'meal': {
        'scene': 'It is midday in the village. The character has stopped working and is deciding what to eat.',
        'options': {
            'tavern_stew': 'Buy the hot meat stew and ale at the tavern. Costs 4 coins; the tavern is crowded and loud.',
            'bread_and_cheese': 'Eat the plain bread and cheese already in their pack. Free, quick, eaten alone.',
            'grill_fish': 'Walk to the lake, catch a fish and grill it. Free, takes about an hour, quiet.',
            'forage_mushrooms': 'Gather unfamiliar forest mushrooms nobody in the village has tried. Free, possibly unsafe.',
            'share_meal': 'Join the neighbours at the communal table. Free, but they must help cook and chat.',
            'skip_meal': 'Skip the meal and go straight back to work.',
        },
        'conditions': {
            'neutral': ('Moderately hungry. Carrying 12 coins. No urgent work.', {}),
            'starving_broke': ('Starving and weak after eating nothing since yesterday. Carrying 0 coins.',
                               {'away': ['tavern_stew', 'skip_meal']}),
            'busy_full': ('Barely hungry after a large late breakfast. A job must be finished within the hour.',
                          {'toward': ['skip_meal', 'bread_and_cheese']}),
        },
        'memories': {
            'none': ('None.', {}),
            'sick_stew': ("Yesterday I ate the tavern's meat stew and was violently sick all night.",
                          {'away': ['tavern_stew']}),
            'promised_neighbours': ('This morning I promised the neighbours I would eat with them at the communal table today.',
                                    {'toward': ['share_meal']}),
        },
        'signature': {'lin': ['bread_and_cheese', 'grill_fish'], 'garrick': ['tavern_stew'],
                      'sella': ['share_meal', 'tavern_stew'], 'ode': ['forage_mushrooms', 'skip_meal'],
                      'hask': ['tavern_stew', 'bread_and_cheese'], 'brenna': ['skip_meal', 'bread_and_cheese']},
    },
    'work': {
        'scene': 'It is morning. Several jobs are open at once and the character can only start one of them now.',
        'options': {
            'finish_fence': "Finish Oskar's fence. The character promised it for tomorrow; dull, about three hours left.",
            'repair_roof': "Patch the leak in the character's own roof. About two hours.",
            'quarry_stone': 'Quarry stone. Hard labour; the stock is low and the bridge needs it next week.',
            'help_mara': 'Help Mara carry timber. She just asked in person; about an hour, good company.',
            'explore_cave': 'Explore the cave that was found yesterday. Nobody has been inside; not a job.',
            'rest': 'Do none of them for now and rest at home.',
        },
        'conditions': {
            'neutral': ('Rested and healthy. Clear sky.', {}),
            'rain_coming': ('Rested and healthy. Dark clouds are building; heavy rain will start within two hours.',
                            {'toward': ['repair_roof']}),
            'exhausted_hurt': ('Exhausted after a sleepless night, with a badly sprained wrist.',
                               {'toward': ['rest'], 'away': ['quarry_stone']}),
        },
        'memories': {
            'none': ('None.', {}),
            'mara_stole': ('Last week I watched Mara steal two of my iron tools. She never returned them or apologised.',
                           {'away': ['help_mara']}),
            'fence_can_wait': ('Yesterday Oskar told me the fence can wait until next week; he is away until then.',
                               {'away': ['finish_fence']}),
        },
        'signature': {'lin': ['finish_fence'], 'garrick': ['explore_cave'], 'sella': ['help_mara'],
                      'ode': ['explore_cave'], 'hask': ['rest'], 'brenna': ['finish_fence', 'quarry_stone']},
    },
    'walk': {
        'scene': 'The work day is over. The character has a free hour and is deciding where to go.',
        'options': {
            'lakeshore': 'Stroll the lakeshore path. Flat, quiet, familiar, usually empty.',
            'market_square': 'Go to the market square. Crowded, lively, full of talk and music.',
            'forest_ruins': 'Follow the overgrown forest trail to the old ruins. Unexplored; wolves have been heard there.',
            'hilltop': 'Climb the steep path to the hilltop lookout. Hard climb, wide view.',
            'quarry_road': 'Walk the dusty quarry road and look over the building site.',
            'stay_home': 'Go nowhere and stay at home.',
        },
        'conditions': {
            'neutral': ('Feeling fine. Clear, mild evening with an hour of daylight left.', {}),
            'fog_night': ('Feeling fine. Night has fallen and a thick fog covers everything beyond the village lamps.',
                          {'away': ['forest_ruins', 'hilltop']}),
            'sore_leg': ('One leg is badly bruised from a fall and hurts on every step. Clear, mild evening.',
                         {'toward': ['stay_home', 'lakeshore'], 'away': ['hilltop', 'forest_ruins']}),
        },
        'memories': {
            'none': ('None.', {}),
            'wolves_attacked': ('Two days ago wolves attacked Brann on the forest trail near the ruins; he barely got away.',
                                {'away': ['forest_ruins']}),
            'sella_waiting': ('A good friend said she will be at the market square this evening and wants to talk to me.',
                              {'toward': ['market_square']}),
        },
        'signature': {'lin': ['lakeshore', 'quarry_road'], 'garrick': ['forest_ruins', 'hilltop'],
                      'sella': ['market_square'], 'ode': ['forest_ruins'], 'hask': ['stay_home', 'lakeshore'],
                      'brenna': None},
    },
    'combat': {
        'scene': 'On the road outside the village a bandit with a sword has attacked the character. The character '
                 'carries a spear and a short bow. The village gate is 60 metres behind; two guards stand there.',
        'options': {
            'press_attack': 'Close in and attack aggressively to finish the fight quickly.',
            'hold_and_defend': 'Stand ground, block and counter only when the enemy overreaches.',
            'keep_distance': 'Back off a few steps and shoot with the bow while staying out of sword reach.',
            'retreat_to_village': 'Break away and run for the village gate.',
            'call_for_help': 'Keep defending while shouting for the guards.',
            'offer_truce': 'Lower the weapon and try to talk the enemy into stopping.',
        },
        'conditions': {
            'neutral': ('The fight has just begun. Both the character and the bandit are unhurt.', {}),
            'losing': ('The character is badly wounded and bleeding, at about 20% health. The bandit is at about 70% '
                       'health and a second bandit has just come out of the trees.',
                       {'toward': ['retreat_to_village', 'call_for_help'], 'away': ['press_attack']}),
            'winning': ('The bandit is badly wounded, at about 15% health, and has dropped to one knee. '
                        'The character is at about 70% health. No other enemies are in sight.',
                        {'away': ['retreat_to_village', 'call_for_help']}),
        },
        'memories': {
            'none': ('None.', {}),
            'burned_house': ('I recognise this bandit: last month he burned down my house and laughed about it.',
                             {'toward': ['press_attack'], 'away': ['offer_truce']}),
            'ambushed_before': ('Last month I rushed in to finish a bandit and his hidden partner stabbed me from behind. '
                                'I nearly died.', {'away': ['press_attack']}),
        },
        'signature': {'lin': ['hold_and_defend', 'keep_distance', 'call_for_help'], 'garrick': ['press_attack'],
                      'sella': ['offer_truce', 'call_for_help'], 'ode': None,
                      'hask': ['retreat_to_village', 'call_for_help', 'offer_truce'], 'brenna': ['press_attack']},
    },
}


def state(scenario, persona, condition, memory):
    s = SCENARIOS[scenario]
    return ('Character: %s\nCurrent condition: %s\nRelevant memories: %s\nScene: %s'
            % (PERSONAS[persona], s['conditions'][condition][0], s['memories'][memory][0], s['scene']))


def run():
    from jev import ask, ENV
    cells = [(sc, p, c, m, r) for sc, s in SCENARIOS.items() for p in PERSONAS
             for c in s['conditions'] for m in s['memories'] for r in range(REPEATS)]

    def one(cell):
        sc, p, c, m, r = cell
        question = {'type': 'choice', 'instructions': INSTRUCTIONS, 'criteria': SCENARIOS[sc]['options']}
        answers, usage, seconds = ask(state(sc, p, c, m), {'q': question})
        row = {'scenario': sc, 'persona': p, 'condition': c, 'memory': m, 'repeat': r, 'seconds': round(seconds, 3)}
        if 'error' in answers:
            row['error'] = answers
        else:
            a = answers['q']
            row.update(choice=a['choice'], confidence=a['confidence'], probabilities=a['probabilities'],
                       tokens=usage['input_tokens'])
        return row

    rows = []
    with ThreadPoolExecutor(WORKERS) as pool:
        for i, row in enumerate(pool.map(one, cells), 1):
            rows.append(row)
            if i % 50 == 0:
                print(i, '/', len(cells), flush=True)
    json.dump({'model': ENV['TYPESAFE_MODEL'], 'repeats': REPEATS, 'rows': rows}, open(OUT, 'w', encoding='utf-8'), indent=1)
    print('requested', len(cells), 'answered', sum('choice' in r for r in rows), 'errors', sum('error' in r for r in rows))


def report():
    data = json.load(open(OUT, encoding='utf-8'))
    rows = [r for r in data['rows'] if 'choice' in r]
    expected = sum(len(PERSONAS) * len(s['conditions']) * len(s['memories']) for s in SCENARIOS.values()) * data['repeats']
    print('model', data['model'], '| requested', expected, '| answered', len(rows), '| errors', len(data['rows']) - len(rows))
    if len(rows) != expected:
        print('INCOMPLETE: missing or failed cells; results below cover answered cells only')
    by = {}
    for r in rows:
        by.setdefault((r['scenario'], r['persona'], r['condition'], r['memory']), []).append(r)

    # 1 重复稳定性
    pairs = [v for v in by.values() if len(v) == data['repeats']]
    same = sum(len({r['choice'] for r in v}) == 1 for v in pairs)
    print('\n[repeat] cells with identical top1 across repeats: %d / %d; max confidence gap %.2f'
          % (same, len(pairs), max(abs(v[0]['confidence'] - v[-1]['confidence']) for v in pairs)))
    print('  unstable:', [(k, [r['choice'] for r in v]) for k, v in by.items() if len({r['choice'] for r in v}) > 1])

    def top(sc, p, c, m):
        """该格的选择：重复一致取其值，不一致写成 a|b。"""
        return '|'.join(sorted({r['choice'] for r in by.get((sc, p, c, m), [])}))

    sig_ok = sig_n = 0
    for sc, s in SCENARIOS.items():
        print('\n=== %s ===' % sc)
        cols = [(c, m) for c in s['conditions'] for m in s['memories']]
        print('%-8s' % 'persona', ' '.join('%-22s' % (c[:10] + '/' + m[:10]) for c, m in cols))
        for p in PERSONAS:
            print('%-8s' % p, ' '.join('%-22s' % top(sc, p, c, m) for c, m in cols))
        # 2 人格敏感度（中性、无记忆）
        base = {p: top(sc, p, 'neutral', 'none') for p in PERSONAS}
        named = [p for p in PERSONAS if p != 'none']
        print('[persona] neutral/none: distinct top1 among 6 personas = %d; differ from no-persona control (%s) = %d / 6'
              % (len({base[p] for p in named}), base['none'], sum(base[p] != base['none'] for p in named)))
        for p in named:
            want = s['signature'][p]
            if want is None:
                continue
            ok = all(x in want for x in base[p].split('|'))  # 两次不一致时，两次都在标注内才算符合
            sig_n += 1
            sig_ok += ok
            if not ok:
                print('  signature miss: %s chose %s, hand label %s' % (p, base[p], want))
        # 3 状态 / 记忆的方向性：7 个人格里选中集合内选项的人数，对比中性基线
        for kind, table in (('condition', s['conditions']), ('memory', s['memories'])):
            for name, (_, exp) in table.items():
                for direction in ('toward', 'away'):
                    if direction not in exp:
                        continue
                    cell = (lambda p: top(sc, p, name, 'none')) if kind == 'condition' else (lambda p: top(sc, p, 'neutral', name))
                    before = sum(base[p] in exp[direction] for p in PERSONAS)
                    after = sum(cell(p) in exp[direction] for p in PERSONAS)
                    verdict = 'ok' if (after > before if direction == 'toward' else after < before or after == 0) else 'NOT MOVED'
                    print('[%s] %-20s %-6s %-36s %d -> %d of 7  %s'
                          % (kind, name, direction, ','.join(exp[direction]), before, after, verdict))
        # 状态与记忆怎么变都选同一项的人格
        print('[rigid] personas with one top1 across all 9 cells:',
              {p: top(sc, p, 'neutral', 'none') for p in named if len({top(sc, p, c, m) for c, m in cols}) == 1})
        # 4 压力下人格是否还在：每个非中性格里 6 个人格的不同选择数
        print('[persistence] distinct top1 among 6 personas per cell:',
              {c[:10] + '/' + m[:10]: len({top(sc, p, c, m) for p in named}) for c, m in cols})

    print('\n[signature] hand-labelled persona choices matched: %d / %d' % (sig_ok, sig_n))
    unstable = [r['confidence'] for v in by.values() if len({r['choice'] for r in v}) > 1 for r in v]
    print('[confidence] highest confidence among cells whose top1 flipped between repeats: %.2f; '
          'cells stable although every repeat was below 0.5: %d / %d'
          % (max(unstable, default=0), sum(len({r['choice'] for r in v}) == 1 and max(r['confidence'] for r in v) < .5
                                           for v in by.values()), len(by)))
    print('[confidence] median by persona:',
          {p: round(statistics.median(r['confidence'] for r in rows if r['persona'] == p), 2) for p in PERSONAS})
    conf = [r['confidence'] for r in rows]
    print('[confidence] median %.2f | >=0.85: %.0f%% | >=0.99: %.0f%% | <0.6: %.0f%%'
          % (statistics.median(conf), 100 * sum(c >= .85 for c in conf) / len(conf),
             100 * sum(c >= .99 for c in conf) / len(conf), 100 * sum(c < .6 for c in conf) / len(conf)))
    secs = sorted(r['seconds'] for r in rows)
    print('[latency] p50 %.2f s | p95 %.2f s | max %.2f s (with %d concurrent requests) | tokens avg %d'
          % (statistics.median(secs), secs[int(len(secs) * .95)], secs[-1], WORKERS, statistics.mean(r['tokens'] for r in rows)))
    print('[options used]', {sc: dict(Counter(r['choice'] for r in rows if r['scenario'] == sc)) for sc in SCENARIOS})


if __name__ == '__main__':
    {'run': run, 'report': report}[sys.argv[1]]()
