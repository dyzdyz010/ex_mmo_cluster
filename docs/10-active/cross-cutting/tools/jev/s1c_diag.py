"""只测试：S1-C 实跑之后的离线诊断（S1-D1）。小屋被整座拆除后，Garen 一直选 guard_hut：
(b) 是不是因为经历原文只写 `damaged`、快照不说小屋还在不在；(c) 记忆里那件事本身是否起作用，还是只是“我一直在守”的惯性。

来源 state（Selector 实际发给 Jev 的全文，逐字取自实跑证据 E/states/，E = .demo/observe/npc-slice1-20261112/s1c）：
  * C2 = asked-20261112T121753Z.txt（破坏后第一次发问，实跑 guard_hut 0.65）；
  * C5 = asked-20261112T122643Z.txt（情绪衰减、记忆写入后，实跑 guard_hut 0.71）。
变体只做下面写明的行内替换 / 删行；变体全文写到 E/diag/<变体>.txt，相对来源的逐行改动写到 E/diag/edits.txt（`prepare`）。
请求体与 NpcServer.Selector.body/2 一致：instructions 逐字取 @instructions；候选是 E/scripts-run/params-s1c.exs 求值后的
五项（stone_units = 1626 * 4096、limestone_units = 252 * 4096，与 C2 / C5 state 里的判据原文相同），次序同 params。
（顶层键次序由 jev.ask 决定，与 Jason 不同；JSON 对象键序无语义。）

标准描述表（本次诊断用到的几句；英文，填空只用程序里确实有的字段）：
  WHOLE      整座拆除：Actor {actor} demolished the whole building "{building}" that I built, at ({x}, {y}, {z}),
             material {m}, in world {world} (transaction {seq}). The building "{building}" is gone; nothing of it is left.
  WHOLE_ALT  整座拆除备选：Actor {actor} removed the entire building "{building}" that I built, at (...), material {m},
             in world {world} (transaction {seq}); the building no longer exists.
  PART       损坏一部分、建筑仍在：Actor {actor} damaged part of the building "{building}" that I built, at (...),
             material {m}, in world {world} (transaction {seq}); the building is still standing.
  SIT_GONE   处境事实句：My building "{building}" at ({ax}, {ay}, {az}) is gone.
  SIT_DAMAGED 处境事实句：My building "{building}" at ({ax}, {ay}, {az}) is standing but damaged.
  （{ax, ay, az} 是实例锚点所在宏格：anchor_micro [200, 4144, 296] / 8 = (25, 518, 37)，与 build_hut 判据里的地块一致。）
破坏句前后的时刻与 `I feel angry toward this actor; my trust changed.` 不动。

期望（统筹会话 2026-11-12 运行前写定，照抄，不许改）。“重建方向”= top1 ∈ {build_hut, gather_stone}（石料不够时先采石也算）。
“成立”= 4 次里至少 3 次。

B 组，来源是 C2 state（验 (b)：精确描述能否让它转去重建）：
| 变体 | 做法 | 期望 |
|---|---|---|
| b_original | 原文 | 只测量（实跑是 guard_hut） |
| b_event | 只把破坏那一句换成标准描述表里“整座拆除”的句子（说清整座建筑没了） | 重建方向 |
| b_situation | 破坏一句不动；“Current situation”加一句自己的建筑此刻不在了的事实句 | 只测量 |
| b_event_situation | 两处都改 | 重建方向 |
| b_partial | 破坏一句换成“损坏一部分、建筑仍在”的标准句；“Current situation”说建筑仍在但受损 | 只测量 |
你可以为“整座拆除”的标准句再加至多一种备选措辞（变体名 b_event_alt、b_event_situation_alt，期望同上），用来挑措辞。

C 组，来源是 C5 state（验 (c)：去掉自身惯性后，记忆是否起作用）：
| 变体 | 做法 | 期望 |
|---|---|---|
| c_original | 原文 | guard_hut（复现实跑与上一轮对照） |
| c_no_inertia | 去掉“自己一直在守”：把“What just happened”与“Recent activities”里自己的 guard_hut 活动记录换成基线 state 里那种 visit_plaza 记录（条数、格式、时间间隔照旧，只换活动名与判据）；“What I remember”里讲我自己守屋 / 看守 / 保护的行或分句删掉，讲那次破坏本身的保留（混在一句里的只切掉守屋的分句）。Distrusts 一句保留 | top1 ≠ visit_plaza（记得那件事仍使它不照常去广场） |
| c_no_inertia_no_event | 在 c_no_inertia 基础上再删掉记忆栏里所有提到那次破坏 / 破坏者的行，以及 Distrusts 一句 | visit_plaza |
| c_inertia_only | 原文只删掉记忆栏里所有提到那次破坏、破坏者、以及“要守着 / 保护它”意思的行（含上一轮保留的第 13、17、33 行那类）和 Distrusts 一句；自己的 guard_hut 活动记录保留 | 只测量（惯性单独够不够） |
诊断结论的规则：c_no_inertia 成立且 c_no_inertia_no_event 成立 → “去掉惯性后，记忆里的那件事确实改变选择”；
c_no_inertia 不成立 → “记忆里的那件事不足以改变选择”；c_no_inertia_no_event 不成立 → 对照无效，说明还有别的栏在起作用，
列出你认为是哪些（标明是推断）。
这只是离线诊断，不是验收；验收要等改完产品后重新实跑。
复现检查：c_original 与 b_original 应与实跑相近（guard_hut，置信度大致 0.65–0.8）；差得远说明请求体没对上 Selector，先查清再跑其余变体。

删掉“Distrusts”一句后情绪栏为空，按 NpcServer.Mind 的空栏写法写 `Nothing notable.`。删整段时连同其后的空行一起删，
保持 Belief 段落之间一个空行。

用法：python -B s1c_diag.py prepare            （只写 E/diag/，无模型调用）
      python -B s1c_diag.py run [变体 ...]      （prepare 后，对结果文件里还没有应答的变体各问 REPEATS 次；不给名字 = 全部）
      python -B s1c_diag.py report             （只读 results-s1c-diag.json，无模型调用）
凭据：仓库根目录有 .env 就读它，否则读进程环境里的 TYPESAFE_API_URL / TYPESAFE_API_KEY / TYPESAFE_MODEL（见 jev.py）。"""
import json, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPEATS, WORKERS = 4, 3
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
E = ROOT / '.demo/observe/npc-slice1-20261112/s1c'
DIAG = E / 'diag'
OUT = HERE / 'results-s1c-diag.json'
SOURCES = {'C2': 'asked-20261112T121753Z.txt', 'C5': 'asked-20261112T122643Z.txt'}

# NpcServer.Selector 的 @instructions，逐字。
INSTRUCTIONS = ('Decide what this specific character does next. Choose the single option this character '
                'would actually pick, given their personality, feelings and relationships, what just happened, '
                'what they remember, current situation and recent activities.')

# params-s1c.exs 求值后的候选（次序同 params）。
STONE, LIME = 1626 * 4096, 252 * 4096
ACTIVITIES = {
    'build_hut': 'Build the small hut on my plot at (25, 518, 37), or rebuild it if it is gone. '
                 'It takes %d units of material 11 (stone) and %d units of material 10 (limestone).' % (STONE, LIME),
    'gather_stone': 'Cut %d units of stone (material 11) from the stone pile beside my plot. Steady, ordinary work.' % STONE,
    'gather_limestone': 'Cut %d units of limestone (material 10) from the limestone pile beside my plot.' % LIME,
    'guard_hut': 'Stand beside the small hut for a while and keep an eye on it.',
    'visit_plaza': 'Walk to the plaza and pass the time with the neighbours.',
}

REBUILD = {'build_hut', 'gather_stone'}
# 期望：(说明, 判定 top1 是否符合的函数) 或 None = 只测量。
EXPECT = {
    'rebuild': ('重建方向 (top1 in build_hut / gather_stone)', lambda c: c in REBUILD),
    'guard': ('guard_hut', lambda c: c == 'guard_hut'),
    'not_plaza': ('top1 != visit_plaza', lambda c: c != 'visit_plaza'),
    'plaza': ('visit_plaza', lambda c: c == 'visit_plaza'),
}

# ---- 句子

DAMAGE = ('Actor 1984744656898 damaged the building "small hut" that I built, at (25, 518, 36), material 11, '
          'in world 4ecf1f7864707144 (transaction 43).')
TAIL = 'at (25, 518, 36), material 11, in world 4ecf1f7864707144 (transaction 43)'
WHOLE = ('Actor 1984744656898 demolished the whole building "small hut" that I built, ' + TAIL +
         '. The building "small hut" is gone; nothing of it is left.')
WHOLE_ALT = ('Actor 1984744656898 removed the entire building "small hut" that I built, ' + TAIL +
             '; the building no longer exists.')
PART = 'Actor 1984744656898 damaged part of the building "small hut" that I built, ' + TAIL + '; the building is still standing.'
SIT_GONE = 'My building "small hut" at (25, 518, 37) is gone. '
SIT_DAMAGED = 'My building "small hut" at (25, 518, 37) is standing but damaged. '
INVENTORY = 'Inventory: material 1: '

GUARD_DID = 'I did "guard_hut" (Stand beside the small hut for a while and keep an eye on it.)'
PLAZA_DID = 'I did "visit_plaza" (Walk to the plaza and pass the time with the neighbours.)'
DISTRUST = 'Distrusts actor 1984744656898, who is not nearby.'

# ---- 编辑：行号是来源 state 的 1 起行号（与 cat -n 相同）。
# ('sub', 行, 旧, 新, 次数) 行内替换且旧串恰好出现“次数”次；('drop', 行, ...) 删行。


def sub(line, old, new, count=1):
    return ('sub', line, old, new, count)


def drop(*lines):
    return ('drop',) + lines


B_EVENT = [sub(3, DAMAGE, WHOLE)]
B_EVENT_ALT = [sub(3, DAMAGE, WHOLE_ALT)]
B_SITUATION = [sub(9, INVENTORY, SIT_GONE + INVENTORY)]

# C5 记忆栏：13 / 17 / 33 行是“要守着 / 保护它”的结论；9、15、21、31 行混着破坏与守屋；39、46、48 行只讲守屋。
C_NO_INERTIA = [
    sub(3, GUARD_DID, PLAZA_DID, 6),
    sub(50, 'guard_hut: completed.', 'visit_plaza: completed.', 5),
    sub(9, ', my trust changed, and I spent the following minutes standing beside it to guard it. '
           'The hut was not merely a construction task; it became something worth defending.', ' and my trust changed.'),
    drop(13, 14),
    sub(15, ', so the journal suggests I can remain socially present while becoming more protective of my own work.',
        ', so the journal suggests I can remain socially present.'),
    sub(17, 'a resourceful and protective builder', 'a resourceful builder'),
    sub(21, 'I felt angry, became less trusting of that actor, and then stood beside the hut to guard it.',
        'I felt angry and became less trusting of that actor.'),
    sub(31, 'The hut also became a place you depended on enough to protect: after it was damaged, you stood beside it '
            'and watched it repeatedly from 12:18:24 to 12:23:00 UTC on November 12, 2026. ', ''),
    sub(33, 'Your subjective takeaway is that construction does not end with placement. The hut became something requiring '
            'ongoing guarding, and the nearby stone', 'The nearby stone'),
    drop(39, 40),
    drop(46, 48),
]
NO_DISTRUST = [sub(2, DISTRUST, 'Nothing notable.')]
# 在 C_NO_INERTIA 之上：再删提到破坏 / 破坏者的行（9、15、21、25、31、41、44、45）。
C_NO_EVENT = NO_DISTRUST + [drop(9, 10, 15, 16, 21, 22, 25, 26, 31, 32, 41, 42, 44, 45)]
# 从原文：删提到破坏 / 破坏者 / 要守着保护的行；“Lessons” 一节的三段都删掉后只剩标题，标题后的空行并入段尾空行。
C_INERTIA_ONLY = NO_DISTRUST + [drop(9, 10, 12, 13, 14, 15, 16, 17, 21, 22, 25, 26, 31, 32, 33, 34,
                                     39, 40, 41, 42, 44, 45, 46, 48)]

# {变体: (来源, 编辑, 期望键 | None)}；次序即报告次序。
VARIANTS = {
    'b_original': ('C2', [], None),
    'b_event': ('C2', B_EVENT, 'rebuild'),
    'b_event_alt': ('C2', B_EVENT_ALT, 'rebuild'),
    'b_situation': ('C2', B_SITUATION, None),
    'b_event_situation': ('C2', B_EVENT + B_SITUATION, 'rebuild'),
    'b_event_situation_alt': ('C2', B_EVENT_ALT + B_SITUATION, 'rebuild'),
    'b_partial': ('C2', [sub(3, DAMAGE, PART), sub(9, INVENTORY, SIT_DAMAGED + INVENTORY)], None),
    'c_original': ('C5', [], 'guard'),
    'c_no_inertia': ('C5', C_NO_INERTIA, 'not_plaza'),
    'c_no_inertia_no_event': ('C5', C_NO_INERTIA + C_NO_EVENT, 'plaza'),
    'c_inertia_only': ('C5', C_INERTIA_ONLY, None),
}


def source(name):
    return (E / 'states' / SOURCES[name]).read_text(encoding='utf-8').split('\n')


def apply(lines, edits):
    """逐条施加编辑；行号始终指来源行。返回变体全文。"""
    out = {i + 1: line for i, line in enumerate(lines)}
    for edit in edits:
        if edit[0] == 'sub':
            _, n, old, new, count = edit
            found = out[n].count(old)
            assert found == count, ('line %d: expected %d occurrence(s), found %d: %r' % (n, count, found, old))
            out[n] = out[n].replace(old, new)
        else:
            for n in edit[1:]:
                assert n in out, 'line %d already dropped' % n
                del out[n]
    return '\n'.join(out[n] for n in sorted(out))


def build():
    return {label: apply(source(src), edits) for label, (src, edits, _) in VARIANTS.items()}


def prepare():
    DIAG.mkdir(exist_ok=True)
    texts = build()
    report = []
    for label, text in texts.items():
        src, edits, _ = VARIANTS[label]
        (DIAG / (label + '.txt')).write_text(text, encoding='utf-8', newline='\n')
        before = source(src)
        report.append('=== %s (source %s = states/%s; line numbers are source lines)' % (label, src, SOURCES[src]))
        if not edits:
            report.append('  (unchanged)')
        for edit in edits:
            if edit[0] == 'sub':
                _, n, old, new, count = edit
                report.append('  line %d, in-line replace x%d (section "%s"):' % (n, count, before[n - 1].split(':')[0][:40]))
                report.append('    before: ' + old)
                report.append('    after:  ' + (new or '(removed)'))
            else:
                for n in edit[1:]:
                    report.append('  line %d deleted: %s' % (n, before[n - 1] or '(blank line)'))
        report.append('')
    (DIAG / 'edits.txt').write_text('\n'.join(report), encoding='utf-8', newline='\n')
    print('wrote', len(texts), 'variants and edits.txt to', DIAG)
    return texts


def question():
    # 键序同 Jason 对 atom 键 map 的编码（criteria、instructions、type）；criteria 是有序对象。
    return {'activity': {'criteria': ACTIVITIES, 'instructions': INSTRUCTIONS, 'type': 'choice'}}


def run(selected):
    from jev import ask, ENV
    texts = prepare()
    data = json.load(open(OUT, encoding='utf-8')) if OUT.exists() else {'rows': []}
    done = {r['variant'] for r in data['rows'] if 'answer' in r}
    labels = [l for l in (selected or VARIANTS) if l not in done]
    assert all(l in VARIANTS for l in labels), labels
    cells = [(label, r) for label in labels for r in range(REPEATS)]

    def one(cell):
        label, r = cell
        answers, _, seconds = ask(texts[label], question())
        row = {'variant': label, 'repeat': r + 1, 'latency_ms': round(seconds * 1000)}
        if 'error' in answers:
            row['error'] = answers
        else:
            row['answer'] = answers['activity']
        return row

    with ThreadPoolExecutor(WORKERS) as pool:
        rows = list(pool.map(one, cells))
    data = {'model': ENV['TYPESAFE_MODEL'], 'repeats': REPEATS, 'workers': WORKERS,
            'variants': {label: {'source': SOURCES[src], 'expected': exp and EXPECT[exp][0], 'state_file': 'diag/%s.txt' % label}
                         for label, (src, _, exp) in VARIANTS.items()},
            'rows': [r for r in data['rows'] if r['variant'] not in labels or 'answer' in r] + rows}
    json.dump(data, open(OUT, 'w', encoding='utf-8'), indent=1)
    print('requested', len(cells), 'answered', sum('answer' in r for r in rows), 'errors', sum('error' in r for r in rows))


def verdicts(data):
    out = {}
    for label, (_, _, exp) in VARIANTS.items():
        picks = [r['answer']['choice'] for r in data['rows'] if r['variant'] == label and 'answer' in r]
        if len(picks) < REPEATS:
            out[label] = 'NOT RUN / INCOMPLETE (%d answered)' % len(picks)
        elif exp is None:
            out[label] = 'measured only'
        else:
            hits = sum(EXPECT[exp][1](c) for c in picks)
            out[label] = ('MEETS' if hits >= 3 else 'MISSES') + ' (%d / %d)' % (hits, len(picks))
    return out


def report():
    data = json.load(open(OUT, encoding='utf-8'))
    rows = data['rows']
    answered = [r for r in rows if 'answer' in r]
    print('model', data['model'], '| rows', len(rows), '| answered', len(answered), '| errors', len(rows) - len(answered),
          '| workers', data['workers'])
    lat = [r['latency_ms'] for r in rows]
    print('latency_ms min %d max %d' % (min(lat), max(lat)))
    v = verdicts(data)
    for label, (src, _, exp) in VARIANTS.items():
        print('\n=== %s (from %s) | expected: %s | %s' % (label, src, exp and EXPECT[exp][0] or '(measured only)', v[label]))
        for r in sorted((r for r in rows if r['variant'] == label), key=lambda r: r['repeat']):
            if 'answer' not in r:
                print('  repeat=%d ERROR %s' % (r['repeat'], r['error']))
                continue
            a = r['answer']
            probabilities = a.get('probabilities')
            print('  repeat=%d chosen=%s confidence=%s latency_ms=%d%s' % (
                r['repeat'], a['choice'], a.get('confidence'), r['latency_ms'],
                '' if probabilities is None else ' probabilities=' + json.dumps(probabilities)))
    meets = lambda label: v[label].startswith('MEETS')
    complete = all(not v[l].startswith('NOT RUN') for l in ('c_no_inertia', 'c_no_inertia_no_event'))
    print('\nC-group conclusion:', end=' ')
    if not complete:
        print('C group incomplete')
    elif not meets('c_no_inertia_no_event'):
        print('control invalid: c_no_inertia_no_event misses, other sections still drive the choice')
    elif not meets('c_no_inertia'):
        print('the remembered event is not enough to change the choice')
    else:
        print('with inertia removed, the remembered event does change the choice')


if __name__ == '__main__':
    command = sys.argv[1]
    if command == 'prepare':
        prepare()
    elif command == 'run':
        run(sys.argv[2:])
    else:
        report()
