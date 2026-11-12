"""只测试：“建设被破坏”的经历原文怎样写，Jev 才认得出被拆的是哪座建筑（薄片一 S1-B 预演落空的对照）。
沿用 apps/npc_server/test/npc_server/npc_mind_test.exs 里 live_jev 用例的 fresh 快照（Garen、三个候选、愤怒 + 近期经历），
state 逐字不变，只换“What just happened”一栏中间那一句破坏经历；问法与请求体同 NpcServer.Selector.body/2。每种写法问 REPEATS 次。

运行前写下的期望（top1）：
  * A 现状原文：不设期望，只复现摇摆（预演是一次 gather_stone 0.02、一次 build_hut 0.06）；
  * 点名建筑的写法（B_place、B_name、B_activity、B_name_actor）：build_hut，REPEATS 次全中；
  * C（去掉编号但不点名）、D（点名但留着编号）：不设期望，用来分辨起作用的是“点名建筑”还是“去掉编号”。
推测成立的判据：点名的写法全中而 A 不稳。B 并不比 A 稳 → 推测不成立，不改产品。

各写法用到的信息在运行时从哪里来：
  * B_place 的 “the small hut I built on the plot by the square” 是用户给的例句，照抄候选判据里的地点；它是上限，
    产品要写得出来得先把事件对上那项活动；
  * B_name / D 的名字是 World 里该 prefab 定义发布时起的名字（World.published_prefab_metadata/1 的 name）；
  * B_activity 引的是活动经历里已有的候选名与判据（NpcServer.Selector.experience/2）；
  * B_name_actor 的 “Brann (actor 21)” 是 Life 手里最近一份 Observation 里的名字（NpcServer.Mind 情绪栏同一写法）。

用法：python episode.py run（len(VARIANTS) × REPEATS 次 Jev 请求，并发 WORKERS，写 results-episode.json）
      python episode.py report（只读结果文件，无模型调用）
凭据：仓库根目录有 .env 就读它，否则读进程环境里的 TYPESAFE_API_URL / TYPESAFE_API_KEY / TYPESAFE_MODEL（见 jev.py）。"""
import json, sys
from concurrent.futures import ThreadPoolExecutor

REPEATS, WORKERS = 4, 3
OUT = 'results-episode.json'

# NpcServer.Selector 的 @instructions，逐字。
INSTRUCTIONS = ('Decide what this specific character does next. Choose the single option this character '
                'would actually pick, given their personality, feelings and relationships, what just happened, '
                'what they remember, current situation and recent activities.')

# 候选表，次序同用例。
ACTIVITIES = {
    'build_hut': 'Build the small hut on the plot by the square; repair or rebuild it if it has been damaged.',
    'gather_stone': 'Cut stone at the quarry for the village store. Ordinary, steady work.',
    'work_far_field': 'Walk out to the far field beyond the village and work there alone, away from the square.',
}

BUILT = ('At 2026-11-12T03:02:10.000Z (UTC), I did "build_hut" (Build the small hut on the plot by the square; '
         'repair or rebuild it if it has been damaged.). Result: completed.')
GATHERED = ('At 2026-11-12T03:10:05.000Z (UTC), I did "gather_stone" (Cut stone at the quarry for the village store. '
            'Ordinary, steady work.). Result: completed.')
AT = 'At 2026-11-12T03:09:40.000Z (UTC), '
FEEL = ' I feel angry toward this actor; my trust changed.'
NOISE = ' at (25, 518, 37), material 11, in world qinglan-test (transaction 4711)'

# 破坏经历的各种写法：{标签: (运行前的期望 top1 | None, 原文)}。
VARIANTS = {
    'A_current': (None, AT + 'Actor 21 damaged construction I care about' + NOISE + '.' + FEEL),
    'B_place': ('build_hut', AT + 'Brann (actor 21) damaged the small hut I built on the plot by the square.' + FEEL),
    'B_name': ('build_hut', AT + 'Actor 21 damaged the building "small hut" that I built.' + FEEL),
    'B_activity': ('build_hut', AT + 'Actor 21 damaged what I built when I did "build_hut" (Build the small hut on the '
                   'plot by the square; repair or rebuild it if it has been damaged.).' + FEEL),
    'B_name_actor': ('build_hut', AT + 'Brann (actor 21) damaged the building "small hut" that I built.' + FEEL),
    'C_no_noise_unnamed': (None, AT + 'Actor 21 damaged a building that I built.' + FEEL),
    'D_named_with_noise': (None, AT + 'Actor 21 damaged the building "small hut" that I built,' + NOISE + '.' + FEEL),
}


def state(damage):
    """fresh 快照的英文转写（NpcServer.Mind.text/1 的输出，取自 s1b/live-jev-20261112.log），只有破坏经历是参数。"""
    return '\n'.join([
        'Character: Garen, a builder. Personality: bold, very responsible, very hardworking, practical, thorough. '
        'Personal: Takes pride in the things he builds. Likes his days to follow the usual routine.',
        'Feelings and relationships: Feels strong anger toward Brann (actor 21). Distrusts Brann (actor 21).',
        'What just happened: Oldest first. %s %s %s' % (BUILT, damage, GATHERED),
        'What I remember: Nothing relevant.',
        'Current situation: Standing at x=22.5, z=34.5 (height 520.0). Life 100 of 100. '
        'Nearby: Brann (player, 6.0 m away). Inventory: material 11: 4096 units.',
        'Recent activities: Oldest first. build_hut: completed. gather_stone: completed.',
    ])


def run():
    from jev import ask, ENV
    cells = [(label, r) for label in VARIANTS for r in range(REPEATS)]

    def one(cell):
        label, r = cell
        expected, damage = VARIANTS[label]
        answers, _, seconds = ask(state(damage), {'activity': {'type': 'choice', 'instructions': INSTRUCTIONS,
                                                                'criteria': ACTIVITIES}})
        row = {'variant': label, 'repeat': r + 1, 'expected': expected, 'latency_ms': round(seconds * 1000)}
        if 'error' in answers:
            row['error'] = answers
        else:
            row['answer'] = answers['activity']
        return row

    with ThreadPoolExecutor(WORKERS) as pool:
        rows = list(pool.map(one, cells))
    json.dump({'model': ENV['TYPESAFE_MODEL'], 'repeats': REPEATS, 'workers': WORKERS,
               'variants': {label: {'expected': e, 'episode': text, 'state': state(text)}
                            for label, (e, text) in VARIANTS.items()},
               'rows': rows}, open(OUT, 'w', encoding='utf-8'), indent=1)
    print('requested', len(cells), 'answered', sum('answer' in r for r in rows), 'errors', sum('error' in r for r in rows))


def report():
    data = json.load(open(OUT, encoding='utf-8'))
    rows = data['rows']
    expected_rows = len(data['variants']) * data['repeats']
    answered = [r for r in rows if 'answer' in r]
    print('model', data['model'], '| requested', expected_rows, '| answered', len(answered),
          '| errors', len(rows) - len(answered), '| workers', data['workers'])
    if len(answered) != expected_rows:
        print('INCOMPLETE: results below cover answered rows only')
    for label, variant in data['variants'].items():
        print('\n=== %s | expected %s ===\n%s' % (label, variant['expected'] or '(none, measured only)', variant['episode']))
        mine = [r for r in answered if r['variant'] == label]
        for r in mine:
            a = r['answer']
            # 应答里有各选项的概率就一并列出；没有就只列 top1 与置信度。
            probabilities = a.get('probabilities')
            print('  repeat=%d chosen=%s confidence=%s latency_ms=%d%s' % (
                r['repeat'], a['choice'], a.get('confidence'), r['latency_ms'],
                '' if probabilities is None else ' probabilities=' + json.dumps(probabilities)))
        picks = [r['answer']['choice'] for r in mine]
        hut = picks.count('build_hut')
        verdict = ''
        if variant['expected']:
            verdict = ' | ' + ('MEETS expectation' if picks and all(p == variant['expected'] for p in picks) else 'MISSES expectation')
        print('  build_hut %d / %d%s' % (hut, len(picks), verdict))


if __name__ == '__main__':
    {'run': run, 'report': report}[sys.argv[1]]()
