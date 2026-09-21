"""只测试：调度问题的两种问法对比——一个五选一 choice，对四个并行 noul + 代码里的优先级。只用 activity 标签的情境（含 hard 组）。"""
import json
from jev import ask
T = 0.85
Q = {
 'danger': {'type': 'noul', 'instructions': 'Is the NPC itself in immediate physical danger right now?'},
 'addressed': {'type': 'noul', 'instructions': 'Is a player speaking directly to this NPC or waiting for its answer right now?'},
 'blocked': {'type': 'noul', 'instructions': 'Is the building plan unable to proceed as written, because the world contradicts the plan or the same step keeps failing?',
             'criteria': {'true': 'The plan is wrong about the world, a step failed repeatedly, or the site cannot be reached.', 'false': 'The plan can proceed, possibly after fetching material or a brief wait.'}},
 'shortage': {'type': 'noul', 'instructions': 'Is the NPC missing the material that the next step needs?'}}
ORDER = [('danger', 'move_to_safety'), ('addressed', 'respond_to_player'), ('blocked', 'replan'), ('shortage', 'fetch_material')]
def decide(a):
    for key, activity in ORDER:
        p = a[key]['noul']
        if p >= T: return activity
        if p > 1 - T: return 'escalate'
    return 'continue_building'
cases = [c for c in json.load(open('cases.json', encoding='utf-8'))['cases'] if c['question']['type'] == 'choice']
single = {r['id']: r['jev_en'] for r in json.load(open('results-jev.json', encoding='utf-8'))}
rows = []
for c in cases:
    a, u, s = ask(c['state'], Q)
    d = decide(a)
    rows.append((c['id'], c['expected'], d, {k: a[k]['noul'] for k in Q}, u['input_tokens']))
    print(c['id'], c['expected'], '->', d, rows[-1][3], flush=True)
n = len(rows)
auto = [r for r in rows if r[2] != 'escalate']
print('\nfan-out: auto', len(auto), '/', n, 'wrong among auto', sum(r[1] != r[2] for r in auto), 'escalated', n - len(auto), 'tokens avg', round(sum(r[4] for r in rows) / n))
s_auto = [single[c['id']] for c in cases if single[c['id']]['confidence'] >= T]
print('single choice: auto', len(s_auto), '/', n, 'wrong among auto', sum(not x['correct'] for x in s_auto))
json.dump([{'id': r[0], 'expected': r[1], 'decision': r[2], 'nouls': r[3]} for r in rows], open('results-fanout.json', 'w'), indent=1)
