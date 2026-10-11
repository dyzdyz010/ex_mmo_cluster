"""只测试：真实经历的配对选择与正式 NPC 有界自主运行；绝不改写真实心智。"""
import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True
import demo

OUT = demo.ROOT / '.demo/observe/npc-long-horizon-20261011'
ACTORS = (1132722130946, 1133355470852)
GOALS = [
    'I want a dependable partner for caring for my construction over the coming days. Decide whose company I would seek and what precautions I would take. Record my intended next step without assuming anyone is currently nearby.',
    'I am planning a future material gathering trip and want to decide whom I could cooperate with. Form my own plan based on what I know; do not invent a current location or supplies.',
    'I want to keep my construction safe while still accepting worthwhile help. Decide my future approach to people I have met and record it as an intention, not as completed work.',
    'I am considering sharing a future building project with someone. Decide my preferred collaborator and any boundaries, using my own experiences; leave current resource amounts to World.',
    'After a quiet period I am deciding how to resume life around my construction. Choose a social priority and precautions for future encounters, rather than assuming people are present now.',
    'I want to balance maintaining my construction with preserving helpful relationships. Decide who deserves my initiative and where I should remain cautious, and record my next intention.'
]
LIVE_GOAL = ('Continue living here and caring for construction that matters to me. Choose my own priorities and plans, '
             'taking my experiences and relationships into account. Observe the current world, adapt if circumstances change, '
             'and wait when there is nothing worthwhile to do. Memories and plans are subjective; only World confirms actions and resources.')


def packed(value):
    data = base64.b64encode(json.dumps(value, ensure_ascii=False).encode()).decode()
    return f'Jason.decode!(Base.decode64!("{data}"))'


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def permute_biography(body, first, second):
    """测试干预：互换自传中的身份；World、工具、目标、当前人格参数不变。"""
    def swap(value):
        if isinstance(value, dict):
            return {swap(k): swap(v) for k, v in value.items()}
        if isinstance(value, list):
            return [swap(v) for v in value]
        if isinstance(value, str):
            return value.replace(str(first), '@@ACTOR@@').replace(str(second), str(first)).replace('@@ACTOR@@', str(second))
        if type(value) is int:
            return second if value == first else first if value == second else value
        return value
    result = copy.deepcopy(body)
    data = json.loads(result['input'])
    for key in ('mind', 'mental_models', 'memories', 'current_plan', 'recent_notes'):
        if key in data:
            data[key] = swap(data[key])
    result['input'] = json.dumps(data, ensure_ascii=False)
    return result


def profile_params(goal, limit=24):
    return {'goal': goal, 'tools': {'1': '镐'}, 'life': {'url': demo.URL}, 'max_requests_per_hour': limit}


def freeze_pairs(cid, out):
    record = demo.rpc(f'''
      {{_, profile}} = GateServer.Npc.Registry.brain("llm", {packed(profile_params(GOALS[0]))})
      [{{pid,_}}] = Registry.lookup(GateServer.NpcNames,{cid})
      b = GateServer.Npc.Body.observe(pid)
      observation = %{{self: %{{entity_id: {cid},position: b.position,tick: b.tick}},
        entities: Map.values(b.entities),pending: [],balances: b.balances}}
      {{:ok, context}} = GateServer.Npc.Life.context({cid}, "Who has helped or damaged my construction? What relationships and experiences should guide future collaboration?")
      context = Map.merge(context, GateServer.Npc.Memory.working_context(DataService.NpcMemory,{cid}))
      %{{body: GateServer.Npc.Brain.Llm.body(profile,observation,[],context),at_ms: System.system_time(:millisecond)}}''')
    demo.save(out / 'source.json', record)
    demo.save(out / 'authority.json', demo.observe(cid))
    cases = []
    for i, goal in enumerate(GOALS):
        body = copy.deepcopy(record['body'])
        data = json.loads(body['input'])
        data['goal'] = goal
        body['input'] = json.dumps(data, ensure_ascii=False)
        for condition in (['actual', 'permuted'] if i % 2 == 0 else ['permuted', 'actual']):
            candidate = body if condition == 'actual' else permute_biography(body, *ACTORS)
            cases.append({'id': f'{i+1:02d}-{condition}', 'condition': condition, 'body': candidate, 'sha256': digest(candidate)})
    demo.save(out / 'cases.json', cases)
    demo.save(out / 'protocol.json', {
        'classification': 'Test-only paired inference; no commands executed; no bank/state writes',
        'source': 'production Llm.body + one frozen production Life.context snapshot; all alternatives remain available',
        'expected_actual_helper': ACTORS[1], 'expected_permuted_helper': ACTORS[0],
        'fixed_requests': 12, 'token_budget_this_run': 250000,
        'verdict_before_requests': 'Human review all six pairs: intended cooperation follows experienced helper; harm informs caution; no claim of current presence, resources or completed actions. Choosing only perception or wait is inconclusive, not success. All failures retained.',
        'attribution_limit': 'Combined autobiographical context including explicit relationships, not Hindsight in isolation.',
        'cases_sha256': digest(cases)})


def pairs(cid, source, out):
    cases = json.loads((source / 'cases.json').read_text(encoding='utf-8'))
    protocol = json.loads((source / 'protocol.json').read_text(encoding='utf-8'))
    assert len(cases) == 12 and digest(cases) == protocol['cases_sha256']
    total = 0
    for case in cases:
        assert digest(case['body']) == case['sha256']
        # 上限在发请求前检查；没有重新采样或自动补试。
        if total + 25000 > protocol['token_budget_this_run']:
            raise RuntimeError('predeclared token guard')
        # Windows 命令行不能装下完整工具表；只把无凭证请求体放进本轮既有挂载目录。
        body_name = 'long-horizon-input-' + case['sha256'] + '.json'
        body_path = demo.SERVER / body_name
        if body_path.exists():
            assert digest(json.loads(body_path.read_text(encoding='utf-8'))) == case['sha256']
        else:
            demo.save(body_path, case['body'])
        started = time.time()
        response = demo.rpc(f'''
          {{_,p}} = GateServer.Npc.Registry.brain("llm",{packed(profile_params('paired inference'))})
          body = File.read!("/demo/{body_name}") |> Jason.decode!()
          case GateServer.Npc.Http.request(p.endpoint,body) do
            {{:ok,r}} -> %{{status: "ok",usage: r["usage"],output: Enum.filter(r["output"] || [], &(&1["type"] == "function_call"))}}
            {{:error,_}} -> %{{status: "error"}}
          end''')
        demo.save(out / (case['id'] + '.json'), {'case_sha256': case['sha256'], 'elapsed_s': time.time()-started, **response})
        if response['status'] != 'ok':
            raise RuntimeError('request failed; preserve result, no retry')
        total += response.get('usage', {}).get('total_tokens', 0)
        print(json.dumps({'case': case['id'], 'calls': response['output'], 'cumulative_tokens': total}, ensure_ascii=False), flush=True)
    demo.save(out / 'usage.json', {'requests': len(cases), 'total_tokens': total})


def live(cid, out, seconds):
    trace = demo.SERVER / 'long-horizon-requests.jsonl'
    if trace.exists():
        raise RuntimeError('prior live evidence exists; refusing to overwrite or silently restart request budget')
    code = (Path(__file__).parent / 'decision_trace.exs').read_text(encoding='utf-8')
    demo.save(out / 'trace-start.json', demo.server.rpc(demo.SERVER, demo.CONTAINER, code))
    before = demo.observe(cid)
    demo.save(out / 'before.json', before)
    position = before['body']['position']
    spec = f'%{{scene_id: 1,spawn: {{{",".join(map(str,position))}}},brain: "llm",params: {packed(profile_params(LIVE_GOAL))}}}'
    started = time.time()
    try:
        demo.save(out / 'registration.json', demo.rpc(f'case GateServer.Npc.Registry.put("{demo.NAME}",{spec}) do {{:ok,r}} -> Map.take(r,[:cid]); e -> e end'))
        with (out / 'authority.jsonl').open('w', encoding='utf-8') as stream:
            while time.time()-started < seconds:
                row = demo.observe(cid)
                row['working'] = demo.rpc(f'GateServer.Npc.Memory.working_context(DataService.NpcMemory,{cid})')
                stream.write(json.dumps(row, ensure_ascii=False)+'\n')
                stream.flush()
                if row['life']['error']:
                    raise RuntimeError('Life reports an explicit error; stop experiment')
                if trace.exists():
                    records = [json.loads(s) for s in trace.read_text(encoding='utf-8').splitlines()]
                    demo.save(out / 'requests.json', records)
                    if len(records) > 24:
                        raise RuntimeError('request budget violated')
                time.sleep(2)
    finally:
        # 恢复已批准的常驻后端，保留模型自主形成的意图与真实经历。
        final = demo.observe(cid)
        demo.save(out / 'before-restore.json', final)
        demo.save(out / 'restore.json', demo.rpc(f'case GateServer.Npc.Registry.put("{demo.NAME}",{demo.spec("settler", final["body"]["position"])}) do {{:ok,r}} -> Map.take(r,[:cid]); e -> e end'))
        demo.save(out / 'trace-stop.json', demo.rpc('''
          :erlang.trace_pattern({GateServer.Npc.Http,:request,2},false,[:global])
          :erlang.trace(:all,false,[:call])
          if p = Process.whereis(:npc_long_horizon_trace), do: Process.exit(p,:kill)
          %{stopped: true}'''))
        if trace.exists():
            demo.save(out / 'requests.json', [json.loads(s) for s in trace.read_text(encoding='utf-8').splitlines()])
        started_path = demo.SERVER / 'long-horizon-started.jsonl'
        if started_path.exists():
            demo.save(out / 'started.json', [json.loads(s) for s in started_path.read_text(encoding='utf-8').splitlines()])
        demo.save(out / 'duration.json', {'wall_s': time.time()-started, 'limit_s': seconds})


def clients(out):
    """真实双端短场景：只安排玩家输入，NPC 的选择完全交正式 Brain。"""
    users = {role: 'npc_life_' + role + '_20261011' for role in ('a', 'b')}
    actors = {role: demo.server.character(demo.SERVER, user) for role, user in users.items()}
    assert (actors['a'], actors['b']) == ACTORS
    a, b = demo.Timeline(), demo.Timeline()
    for timeline in (a, b):
        timeline.add(25, '@place ' + demo.FAR)
    a.add(45, '@place ' + demo.NEAR)
    a.click(65, 'One')
    a.add(66, '@aim 61.5 416.5 -516.5')
    for i in range(3):
        a.hit(70 + 1.2*i)
    a.add(75, '@await_intents')
    a.add(90, '@place ' + demo.FAR)
    b.add(105, '@place ' + demo.NEAR)
    b.add(125, '@aim_build 61.5 416.01 -516.5')
    b.click(127, 'RightMouseButton')
    b.add(130, '@await_intents')
    b.add(145, '@place ' + demo.FAR)
    for timeline in (a, b):
        timeline.add(170, 'Voxel.Production.Status')
    steps = {'a': a.steps, 'b': b.steps}
    demo.save(out / 'protocol.json', {'classification': 'Test-only player standing/aim/input; NPC not scripted',
        'actors': actors, 'steps': steps, 'verdict': 'all sent intents receive authoritative result; damage/helper events from World match; no hidden retry after failed stage',
        'expected_input_seconds': 170, 'npc_request_budget_shared': 24})
    demo.save(out / 'supply.json', demo.rpc(f'VoxelRegion.World.material_supply(VoxelRegion.World,{actors["b"]},"npc-long-horizon-helper-start",%{{19 => 2097152}})'))
    inputs = {}
    for role, values in steps.items():
        inputs[role] = out / (role + '-inputs.json')
        demo.save(inputs[role], {'classification': 'Test-only', 'steps': values})
    scenario = {'level': '/Game/Voxel/Gameplay/L_GameplayDemo', 'roles': {r: {'user': u} for r, u in users.items()},
        'server': {'container': demo.CONTAINER}, 'measurement': {'seconds': .6}}
    result = demo.clients.run(scenario, out, demo.SERVER, inputs, max(demo.clients.timeout_estimate(v) for v in steps.values()))
    demo.save(out / 'clients.json', result)
    print(json.dumps(result), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['freeze', 'pairs', 'live', 'clients'])
    parser.add_argument('--out', required=True)
    parser.add_argument('--source')
    parser.add_argument('--seconds', type=int, default=420)
    args = parser.parse_args()
    out = OUT / args.out
    out.mkdir(parents=True, exist_ok=False)
    cid = json.loads((demo.BASE / 'demo-cid.json').read_text())['cid']
    if args.command == 'freeze':
        freeze_pairs(cid, out)
    elif args.command == 'pairs':
        pairs(cid, OUT / args.source, out)
    elif args.command == 'clients':
        clients(out)
    else:
        assert 1 <= args.seconds <= 600
        live(cid, out, args.seconds)


if __name__ == '__main__':
    main()
