"""只测试：连通性、延迟分布、计费口径（多问题是否共用 state）、state 大小上限。"""
import json, statistics, sys
from jev import ask
state = "A builder NPC stands on a stone platform. It carries 3 stone blocks. The wall it is building needs 22 blocks. A player just walked up and is standing 2 meters away, facing the NPC."
q1 = {'greet': {'type': 'noul', 'instructions': 'Should the NPC pause work to acknowledge the player?'}}
a, u, s = ask(state, q1); print('first', json.dumps(a), u, round(s, 3))
if 'error' in a: sys.exit(1)
lat = []
for _ in range(20):
    a, u, s = ask(state, q1); lat.append(s)
    if 'error' in a: print('error during latency run', a)
lat.sort(); print('latency_s n=20 min/p50/p90/max', [round(x, 3) for x in (lat[0], statistics.median(lat), lat[17], lat[-1])])
q8 = {f'q{i}': {'type': 'noul', 'instructions': t} for i, t in enumerate([
    'Is the NPC short of building material?', 'Is a player nearby?', 'Is the NPC in danger?', 'Is the wall finished?',
    'Should the NPC fetch more stone now?', 'Is the player facing the NPC?', 'Is the NPC indoors?', 'Is it raining?'])}
_, u1, s1 = ask(state, q1); _, u8, s8 = ask(state, q8)
print('usage 1 question', u1, round(s1, 3)); print('usage 8 questions', u8, round(s8, 3))
for words in (2_000, 10_000, 40_000, 120_000):
    a, u, s = ask(state + ' Filler: ' + 'stone ' * words, q1, timeout=120)
    print('state words', words, '->', a if 'error' in a else (u, round(s, 3)))
    if 'error' in a: break
