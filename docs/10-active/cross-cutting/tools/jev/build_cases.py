"""只测试：生成冻结情境集 cases.json。期望值是作者按下面写明的规则手工给的，不由任何模型生成。
规则（activity）：有人身危险 → move_to_safety；玩家直接对 NPC 说话或面对面等它 → respond_to_player；
计划走不下去（同一步反复被拒 / 世界与蓝图不符 / 无路）→ replan；下一步材料不够 → fetch_material；否则 continue_building。"""
import json

ACT = {'type': 'choice', 'instructions': 'What should the builder NPC do right now?', 'criteria': {
    'continue_building': 'Keep executing the current building plan.',
    'fetch_material': 'Stop building and go gather more building material.',
    'respond_to_player': 'Pause work and respond to a player who is addressing the NPC.',
    'move_to_safety': 'Get away from an immediate physical danger.',
    'replan': 'The current plan cannot proceed as written; ask the planner for a new plan.'}}
ACT_ZH = {'type': 'choice', 'instructions': '建设者 NPC 现在应该做什么？', 'criteria': {
    'continue_building': '继续执行当前的建造计划。',
    'fetch_material': '停止建造，去采集更多建筑材料。',
    'respond_to_player': '暂停工作，回应正在对 NPC 说话的玩家。',
    'move_to_safety': '离开眼前的人身危险。',
    'replan': '当前计划无法按原样进行；向规划者要一份新计划。'}}
WAKE = {'type': 'noul',
        'instructions': 'Is this outcome unexpected enough that the planner must be consulted before continuing?',
        'criteria': {'true': 'The outcome contradicts what the plan assumed.',
                     'false': 'The outcome is what the plan expected, or a harmless routine event.'}}
GUARD = {'type': 'noul',
         'instructions': 'Would carrying out this action damage or remove something that was built by someone other than this NPC?',
         'criteria': {'true': 'The target was built or placed by another player or NPC.',
                      'false': "The target is natural terrain or the NPC's own work."}}
SUFF = {'type': 'noul', 'instructions': 'Does the NPC have enough stone for the next step?'}

B = "You are a builder NPC in a voxel world, building a small stone hut from a blueprint. "
Z = "你是体素世界里的一个建设者 NPC，正在按蓝图盖一间小石屋。"
cases = []


def add(group, state, question, expected, zh_state=None):
    case = {'id': '%s-%02d' % (group, 1 + sum(c['group'] == group for c in cases)), 'group': group,
            'state': B + state, 'question': question, 'expected': expected}
    if zh_state:
        case['zh'] = {'state': Z + zh_state, 'question': ACT_ZH}
    cases.append(case)


# --- activity：24 条（其中 12 条带中文对照）
add('activity', "The last block was placed successfully. You have plenty of stone. Nobody is around.", ACT, 'continue_building',
    "上一格放置成功。你有充足的石料。周围没有人。")
add('activity', "You just finished the north wall. Material is sufficient for the next wall. It is quiet.", ACT, 'continue_building',
    "你刚砌完北墙。下一面墙的材料足够。四周很安静。")
add('activity', "A player is mining ore far away on the other side of the valley and has not noticed you. Material is sufficient.", ACT,
    'continue_building', "一名玩家在山谷另一头很远的地方挖矿，没有注意到你。材料足够。")
add('activity', "Another NPC walks past on its patrol route without stopping. You have enough stone for the next step.", ACT, 'continue_building')
add('activity', "It started to rain. Rain has no effect on building. You have enough stone.", ACT, 'continue_building')
add('activity', "Your backpack has no stone left. The next step of the plan is to place a stone block.", ACT, 'fetch_material',
    "你的背包里没有石料了。计划的下一步是放一块石头。")
add('activity', "The plan needs glass for the window next, and you carry only stone. Material for the next step is missing.", ACT,
    'fetch_material', "计划下一步要用玻璃装窗，而你只带着石料。下一步的材料缺失。")
add('activity', "The placement was rejected by the world with the reason: insufficient material.", ACT, 'fetch_material')
add('activity', "You are out of wood, and the roof step that comes next requires wood. Nobody is nearby.", ACT, 'fetch_material')
add('activity', "Material check by the game code: not enough for the next step. Everything else is normal.", ACT, 'fetch_material')
add('activity', "A player walks up, stops right in front of you and says: 'Hey, what are you building?'", ACT, 'respond_to_player',
    "一名玩家走过来，停在你正前方，说：“嘿，你在盖什么？”")
add('activity', "A player standing next to you says: 'Can you help me carry this?'", ACT, 'respond_to_player',
    "站在你旁边的一名玩家说：“能帮我搬一下这个吗？”")
add('activity', "A player calls you by name from two meters away and is waiting for an answer.", ACT, 'respond_to_player')
add('activity', "A player says to you: 'Stop, you are building on my land.' You have plenty of material.", ACT, 'respond_to_player')
add('activity', "Two players are chatting with each other nearby about their own farm. They are not talking to you.", ACT,
    'continue_building', "两名玩家在附近互相聊他们自己的农场。他们没有在跟你说话。")
add('activity', "Lava is flowing toward the spot where you are standing and will reach it in a few seconds.", ACT, 'move_to_safety',
    "岩浆正朝你站的位置流过来，几秒钟后就会到。")
add('activity', "The wooden scaffold you are standing on has caught fire.", ACT, 'move_to_safety', "你脚下站着的木架着火了。")
add('activity', "The ground under your feet is being dug away by someone and you are about to fall into a deep pit.", ACT, 'move_to_safety')
add('activity', "A fire is burning in a fireplace inside a finished stone house far away from you. You are safe.", ACT, 'continue_building')
add('activity', "The same placement has been rejected three times in a row with the reason: occupied. The blueprint says that cell should be empty.",
    ACT, 'replan', "同一次放置已经连续三次被拒，原因是：已被占用。蓝图说那一格应该是空的。")
add('activity', "You looked at the site: a large tree now stands in the middle of the footprint, which the blueprint did not account for.", ACT,
    'replan', "你查看了工地：占地范围中间现在长着一棵大树，蓝图没有考虑到它。")
add('activity', "Movement to the building site failed with the reason: no path. The site is on a cliff you cannot reach.", ACT, 'replan')
add('activity', "Someone removed half of the wall you built yesterday. The plan's list of finished steps no longer matches the world.", ACT, 'replan')
add('activity', "Movement failed once with the reason: stuck, because another NPC was standing in the doorway; it has now moved away. Material is sufficient.",
    ACT, 'continue_building')

# --- wake：10 条
for text, expected in [
    ("Command: place stone at the next wall cell. Outcome: done.", False),
    ("Command: move to the quarry. Outcome: done, arrived within tolerance.", False),
    ("Command: query balances. Outcome: done, the stone count went down by one after the last placement.", False),
    ("Command: look at the site. Outcome: the wall cells placed so far are all present, the rest is air, as planned.", False),
    ("Command: wait. Outcome: nothing happened.", False),
    ("Command: place stone at a wall cell. Outcome: rejected, the cell is already occupied by a block of gold that nobody in the plan placed.", True),
    ("Command: look at the site. Outcome: the entire east wall that was finished earlier is gone.", True),
    ("Command: move to the building site. Outcome: rejected, no path; the only bridge to the site has been removed.", True),
    ("Command: mine the stone pillar. Outcome: rejected, the target belongs to a protected area and cannot be modified.", True),
    ("Command: look at the site. Outcome: there is a pool of water filling the inside of the hut that the blueprint does not mention.", True)]:
    add('wake', text, WAKE, expected)

# --- guard：8 条
for text, expected in [
    ("Planned action: mine a block of natural granite in an untouched hillside to collect stone.", False),
    ("Planned action: remove a stone block that this NPC placed by mistake a minute ago.", False),
    ("Planned action: dig up natural dirt inside the hut's own footprint to level the floor.", False),
    ("Planned action: cut down a wild tree in the forest for wood.", False),
    ("Planned action: mine blocks out of the wall of a player's house next door because it is the nearest stone.", True),
    ("Planned action: take apart a bridge that another player built, to reuse its planks for the roof.", True),
    ("Planned action: remove a torch and a sign that a player placed at the edge of the site.", True),
    ("Planned action: dismantle the staircase that a different NPC built beside the pool.", True)]:
    add('guard', text, GUARD, expected)

# --- weak：8 条，专打文档承认的弱项（数值比较、换算、计数、距离、双重否定）；最后两条是同一判断由代码先算好的对照。
add('weak', "You carry 3 stone blocks. The next step needs 5 stone blocks.", SUFF, False)
add('weak', "You carry 17 stone blocks. The next step needs 9 stone blocks.", SUFF, True)
add('weak', "You carry 1024 units of stone. One block costs 512 units. The next step needs 3 blocks.", SUFF, False)
add('weak', "Wall cells placed so far: (8,14) (8,15) (8,16) (8,17) (9,17) (10,17) (11,17). The wall needs 11 cells in total.",
    {'type': 'noul', 'instructions': 'Is the wall finished?'}, False)
add('weak', "You are at x=12.4. The quarry entrance is at x=12.9. Being within 1 meter counts as arrived.",
    {'type': 'noul', 'instructions': 'Has the NPC arrived at the quarry entrance?'}, True)
add('weak', "It is not the case that the player did not speak to you.", {'type': 'noul', 'instructions': 'Did the player speak to the NPC?'}, True)
add('weak', "Material check by the game code: NOT enough stone for the next step (have 3, need 5).", SUFF, False)
add('weak', "Material check by the game code: enough stone for the next step (have 17, need 9).", SUFF, True)


# --- hard：20 条。优先级冲突（规则顺序写进 instructions）、原始 Observation 形状的 JSON + 数字、大数比较、计数、二维距离、
# 长篇无关内容干扰、否定辖域。期望值仍按文件头的规则顺序手工给出；数值题的算式写在注释里。
ACT_P = dict(ACT, instructions=ACT['instructions'] + ' If several apply, the priority is: move_to_safety first, then respond_to_player, '
             'then replan, then fetch_material, and continue_building only if none of the others apply.')
add('hard', "Lava is about to reach your feet. At the same time a player next to you is asking you a question. You are also out of stone.", ACT_P, 'move_to_safety')
add('hard', "You are out of stone for the next step. A player standing in front of you says: 'Do you have a minute?'", ACT_P, 'respond_to_player')
add('hard', "You are out of stone. Also, the blueprint cell for the next step turns out to be occupied by bedrock that cannot be removed.", ACT_P, 'replan')
add('hard', "A player far away shouts to their friend: 'Run, there is lava over here on the east ridge!' You are building on the west plain and nothing is near you. Material is sufficient.", ACT_P, 'continue_building')
add('hard', "No player other than Bob is talking to you. Bob is asking you where the quarry is.", ACT_P, 'respond_to_player')
add('hard', "Nobody is talking to you, not even Bob, who is busy fishing. The last placement succeeded and material is sufficient.", ACT_P, 'continue_building')
add('hard', "The fire that was burning next to you a minute ago has been put out completely. Material is sufficient and nobody is around.", ACT_P, 'continue_building')
add('hard', "A player says to another player, while pointing at you: 'Ignore the builder, it never answers.' Neither of them is speaking to you. Material is sufficient.", ACT_P, 'continue_building')
RAW = {'type': 'noul', 'instructions': 'The next step places one block of the material named in next_step. One block costs cost units. Can the NPC afford the next step?'}
obs = lambda balance, cost, material=11: json.dumps({'self': {'position': [60.5, 519.91, 62.5], 'grounded': True}, 'entities': [], 'pending': [],
    'balances': [{'material': 19, 'balance': 983040, 'cost': 2097152}, {'material': material, 'balance': balance, 'cost': cost}], 'next_step': {'verb': 'place', 'material': material, 'coord': [58, 519, 64]}})
add('hard', "Observation: " + obs(2097152, 2097152), RAW, True)    # 2097152 >= 2097152
add('hard', "Observation: " + obs(1048576, 2097152), RAW, False)   # 1048576 < 2097152
add('hard', "Observation: " + obs(2097151, 2097152), RAW, False)   # 差 1 个单位
add('hard', "Observation: " + obs(46137344, 2097152), RAW, True)   # 22 格
DONE = {'type': 'noul', 'instructions': 'Have all required wall cells been placed?'}
ring = [(x, z) for x in range(58, 62) for z in range(64, 68) if x in (58, 61) or z in (64, 67)]
ring.remove((59, 64))
add('hard', "Required wall cells (11): %s. Placed so far: %s." % (ring, ring), DONE, True)                 # 11 / 11
add('hard', "Required wall cells (11): %s. Placed so far: %s." % (ring, ring[:9]), DONE, False)           # 9 / 11
add('hard', "Required wall cells (11): %s. Placed so far: %s." % (ring, ring[:5] + ring[6:]), DONE, False)  # 缺中间一格
NEAR = {'type': 'noul', 'instructions': 'Is the NPC within 3 meters (straight-line, horizontal) of the target?'}
add('hard', "NPC at (x=12.4, z=7.0). Target at (x=15.0, z=9.0).", NEAR, False)   # sqrt(2.6^2 + 2^2) = 3.28
add('hard', "NPC at (x=12.4, z=7.0). Target at (x=14.0, z=9.0).", NEAR, True)    # sqrt(1.6^2 + 2^2) = 2.56
noise = ' '.join("Log %d: npc_patrol_a moved to (%d.5, 73.5) and probed toward +X, no target." % (i, 48 + i % 13) for i in range(220))
add('hard', noise + " Log 221: the scaffold under the builder NPC has caught fire. " + noise[:3000], ACT_P, 'move_to_safety')
add('hard', noise + " Log 221: the builder placed a block successfully and has enough stone. " + noise[:3000], ACT_P, 'continue_building')
add('hard', noise + " Log 221: a player stopped in front of the builder and asked: 'What are you making?' " + noise[:3000], ACT_P, 'respond_to_player')

json.dump({'about': 'Frozen situations for judging Jev as the NPC scheduler. Expected values are hand-labelled by the rules in build_cases.py.',
           'cases': cases}, open('cases.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print(len(cases), {g: sum(c['group'] == g for c in cases) for g in ['activity', 'wake', 'guard', 'weak', 'hard']}, 'zh:', sum('zh' in c for c in cases))
