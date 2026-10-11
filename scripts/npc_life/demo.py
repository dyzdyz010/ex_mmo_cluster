"""只测试：单个持久 NPC 的真实双端人生场景，复用 Voxim R7 运行器。"""
import argparse
import hashlib
import json
import math
import os
import re
from pathlib import Path
import subprocess
import sys
import threading
import time

# 借用目录只读：在跨树 import 前禁止 Python 写入旁侧 __pycache__。
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT.parent / 'Voxim/Docs/R7'))
from harness import clients, server, events, checks

BASE = ROOT / '.demo/observe/npc-life-20261011'
SERVER = BASE / 'server'
CONTAINER = 'voxim-npc-life-demo-20261011'
NAME = 'LifeBuilder'
CELL = [61, 416, -517]
DEFINITION = 'ecbed49e267852ff5f55c1f220e094efa8544a70599434d096c5bd9dee857e2a'
FAR = '22.5 419.91 -517.5'
NEAR = '59.5 416.91 -516.5'
URL = 'http://voxim-npc-life-loop-20261011:8888'
NPC_MD5 = 'for {m,_} <- :code.all_loaded(), String.starts_with?(Atom.to_string(m),"Elixir.GateServer.Npc."), into: %{}, do: {Atom.to_string(m),Base.encode16(m.module_info(:md5),case: :lower)}'


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def rpc(code):
    return server.rpc(SERVER, CONTAINER, '(fn ->\n' + code + '\nend).() |> GateServer.Npc.Context.plain() |> Jason.encode!()')


def ok(value):
    if not isinstance(value, list) or value[0] != 'ok':
        raise RuntimeError(str(value))
    return value[1]


def spec(brain='settler', spawn=(63.5, 416.91, -516.5)):
    params = {'tools': {'1': '镐'}, 'life': {'url': URL}}
    if brain == 'settler':
        params.update(definition=DEFINITION, sites=[{'anchor_micro': [488, 3328, -4136], 'orientation': 0,
                      'stand': [63.5, -516.5]}], revisit_ticks=36000)
    else:
        params.update(goal='Continue caring for and maintaining my construction. Consider my past experiences, cached beliefs and current observations to choose my next step. Historical memories are subjective; query World for current numeric truth.',
                      max_requests_per_hour=1)
    return ('%{scene_id: 1, spawn: {' + ','.join(map(str, spawn)) + '}, brain: ' + json.dumps(brain) +
            ', params: Jason.decode!(' + json.dumps(json.dumps(params, ensure_ascii=False), ensure_ascii=False) + ')}')


def observe(cid):
    return rpc(f'''[{{pid,_}}] = Registry.lookup(GateServer.NpcNames,{cid})
    body = GateServer.Npc.Body.observe(pid) |> Map.take([:position,:tick,:entities,:outcomes])
    {{:ok,life}} = GateServer.Npc.Life.observe({cid})
    {{:ok,events}} = VoxelRegion.World.interactions_since(VoxelRegion.World,0)
    material = VoxelRegion.World.material_snapshot(VoxelRegion.World,[{cid}],[{{61,416,-517}}])
    %{{at_ms: System.system_time(:millisecond),body: body,life: life,interactions: events,material: material}}''')


def wait_for(cid, predicate, out, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        row = observe(cid)
        save(out, row)
        if predicate(row):
            return row
        if row['life']['error']:
            raise RuntimeError(str(row['life']['error']))
        time.sleep(2)
    raise TimeoutError(str(out))


def prepare(out, correction=False):
    rows = rpc('GateServer.Npc.Registry.list()')
    if rows and not correction:
        raise RuntimeError('fresh preparation refuses existing NPC registration')
    cid = ok(rpc(f'case DataService.CharacterStore.ensure_npc({json.dumps(NAME)}) do {{:ok,r}} -> {{:ok,Map.take(r,[:id])}}; e -> e end'))['id']
    units = 2097152 - 512 if correction else 2097152
    supply_id = 'npc-life-initial-correction' if correction else 'npc-life-initial'
    supply = rpc(f'VoxelRegion.World.material_supply(VoxelRegion.World,{cid},"{supply_id}",%{{19 => {units}}})')
    registered = rpc(f'case GateServer.Npc.Registry.put({json.dumps(NAME)},{spec()}) do {{:ok,r}} -> {{:ok,Map.take(r,[:cid])}}; e -> e end')
    assert ok(registered)['cid'] == cid
    save(out / 'fixtures.json', {'classification': 'Test-only', 'cid': cid, 'supply': supply, 'registry': registered,
                              'author_cadence_ticks': 36000, 'scope': 'initial finite material; NPC builds own cube'})
    save(BASE / 'demo-cid.json', {'cid': cid, 'name': NAME})
    row = wait_for(cid, lambda r: any(e['actor'] == cid and e['kind'] == 'build' and e['cell'] == CELL
                                   for e in r['interactions']['events']), out / 'built.json')
    identity = server.execution_identity(SERVER, CONTAINER)
    identity['npc_loaded_beam_md5'] = rpc(NPC_MD5)
    identity['client_binary'] = clients.binary_digest()
    save(out / 'execution.json', identity)
    save(BASE / 'demo-cid.json', {'cid': cid, 'name': NAME})
    return row


class Timeline:
    def __init__(self):
        self.steps = [{'after_seconds': 1, 'command': 'log LogVoxim Log'}, {'after_seconds': 2, 'command': 'M1.Reconnect'}]

    def add(self, at, command):
        self.steps.append({'after_seconds': round(at, 2), 'command': command})

    def click(self, at, key):
        self.add(at, '@press ' + key)
        self.add(at + .12, '@release ' + key)

    def hit(self, at):
        self.click(at, 'LeftMouseButton')
        self.add(at + .15, '@measure_begin')
        self.add(at + .8, '@measure_end')


def plan(cycles=6, fresh=False, pending_repair=False):
    a, b = Timeline(), Timeline()
    for t in (a, b):
        t.add(25, '@place ' + FAR)
    marks = []
    if fresh:
        a.add(45, '@place 60.2 416.91 -516.5')
        a.add(49, '@look_settled 63.5 417.8 -516.5')
        b.add(45, '@look_settled 63.5 417.8 -516.5')
        a.add(55, '@place ' + FAR)
        a.add(65, '@place 60.2 416.91 -516.5')
        a.add(69, '@look_settled 63.5 417.8 -516.5')
        a.add(75, '@place ' + FAR)
        end = 90
    else:
        if pending_repair:
            b.add(35, '@place ' + NEAR)
            b.add(39, '@aim_build 61.5 416.01 -516.5')
            b.click(41, 'RightMouseButton')
            b.add(43, '@await_intents')
            b.add(55, '@place ' + FAR)
        else:
            for start in (45, 65):
                a.add(start, '@place 60.0 416.91 -516.5')
                a.add(start + 10, '@place ' + FAR)
        for i in range(cycles):
            start = 90 + i * 45
            a.add(start, '@place ' + NEAR)
            a.click(start + 4, 'One')
            a.add(start + 5, '@aim 61.5 416.5 -516.5')
            for j in range(3):
                a.hit(start + 8 + 1.2 * j)
            a.add(start + 12, '@await_intents')
            a.add(start + 20, '@place ' + FAR)
            b.add(start + 24, '@place ' + NEAR)
            b.add(start + 28, '@aim_build 61.5 416.01 -516.5')
            b.click(start + 30, 'RightMouseButton')
            b.add(start + 32, '@await_intents')
            b.add(start + 41, '@place ' + FAR)
            marks.append({'cycle': i + 1, 'harm': start + 8, 'help': start + 30, 'end': start + 40})
        end = 90 + cycles * 45 + 10
    for t in (a, b):
        t.add(end, 'Voxel.Production.Status')
    return {'a': a.steps, 'b': b.steps}, marks


def verdict(rows, cid, actors, cycles):
    last = rows[-1]
    state = last['life']['state']
    errors = []
    for kind, actor, count in [('damage', actors['a'], 'damage_count'), ('help', actors['b'], 'help_count')]:
        if state['evidence'][count] != cycles:
            errors.append(f'{count}: expected {cycles}, got {state["evidence"][count]}')
        source = state['evidence']['anger' if kind == 'damage' else 'gratitude']
        if not source or source['actor'] != actor:
            errors.append(kind + ' actor mismatch')
        elif not any(e['seq'] == source['seq'] and e['actor'] == actor and e['cell'] == CELL
                     for e in last['interactions']['events']):
            errors.append(kind + ' missing authority event')
    seen = {}
    for row in rows:
        decision = row['life'].get('decision') or {}
        choice = decision.get('choice') or decision.get('social') or {}
        if choice:
            seen.setdefault(str(choice), []).append(row['body']['position'])
    behavior = behavior_evidence(rows, actors)
    behavior_ok = all(sum(p['accepted'] for p in behavior if p['mode'] == mode) >= 2 for mode in ('avoid','thank'))
    return {'accepted': not errors and behavior_ok, 'authority_accepted': not errors, 'behavior_accepted': behavior_ok, 'errors': errors, 'counts': state['evidence'],
            'traits': state['traits'], 'relationships': state['relationships'],
            'behavior_acceptance': 'requires correlated sampled positions and terminal Outcomes; counters alone insufficient',
            'decision_groups': seen, 'behavior': behavior}


def distance(a, b):
    return math.sqrt(sum((x-y)**2 for x,y in zip(a,b)))


def behavior_evidence(rows, actors):
    # 只按同一社会来源与实际终态归因；计数、枚举或回放成功均不能替代位移。
    groups = []
    previous = None
    for i,row in enumerate(rows):
        social = (row['life'].get('decision') or {}).get('social')
        if social and social['source_seq'] is not None and social['mode'] in ('avoid','thank'):
            key = (social['mode'],social['source_seq'],social['actor'])
            if previous != key:
                groups.append((key,[]))
            groups[-1][1].append(i)
            previous = key
        else:
            previous = None
    result = []
    for (mode,seq,actor), indices in groups:
        first = rows[indices[0]]
        social = first['life']['decision']['social']
        entity = first['body']['entities'].get(str(actor))
        target = social['target']
        expected_actor = actors['a' if mode == 'avoid' else 'b']
        source = next((e for e in first['interactions']['events'] if e['seq'] == seq),None)
        event_ok = any(e['seq'] == seq and e['actor'] == actor and e['cell'] == CELL for e in first['interactions']['events'])
        terminals = []
        prior = (first['life'].get('decision') or {}).get('last_outcome')
        prior_id = prior and prior.get('id')
        for r in rows[indices[0]:]:
            subsequent = (r['life'].get('decision') or {}).get('social')
            if subsequent and (subsequent['mode'],subsequent['source_seq'],subsequent['actor']) != (mode,seq,actor):
                break
            outcome = (r['life'].get('decision') or {}).get('last_outcome')
            if outcome and outcome['status'] == 'done' and outcome['verb'] == 'move_to' and target:
                if prior_id is not None and outcome.get('id') == prior_id:
                    continue
                p = (outcome.get('data') or {}).get('position')
                if p and outcome['data'].get('settled') and math.hypot(p[0]-target[0],p[2]-target[2]) < 1.2:
                    terminals.append((r,p,outcome))
                    break
        start = distance(first['body']['position'],entity['position']) if entity else None
        end = distance(terminals[0][1],entity['position']) if entity and terminals else None
        changed = start is not None and end is not None and ((end-start > .25) if mode == 'avoid' else (start-end > .25))
        result.append({'mode': mode,'source_seq': seq,'actor': actor,'start_distance': start,'end_distance': end,
                       'observed_at_ms': first.get('at_ms'),'source_age_ms': first.get('at_ms',0)-source.get('at_ms',0) if source else None,
                       'initial_position': first['body']['position'],'target': target,
                       'terminal': terminals[0][2] if terminals else None,
                       'target_tolerance_accepted': bool(terminals and terminals[0][2]['data'].get('within_tolerance')),
                       'contract': 'settled approach/avoidance with actual distance change; exact destination tolerance reported separately',
                       'accepted': actor == expected_actor and event_ok and changed})
    return result


def social(cid, out, cycles=6, fresh=False, custom_steps=None):
    users = {role: 'npc_life_' + ('fresh_' if fresh else '') + role + '_20261011' for role in ('a', 'b')}
    actors = {r: server.character(SERVER, u) for r, u in users.items()}
    if not fresh:
        save(out / 'helper-supply.json', rpc(f'VoxelRegion.World.material_supply(VoxelRegion.World,{actors["b"]},"npc-life-helper-initial",%{{19 => {2097152 * cycles}}})'))
    initial = observe(cid)['life']['state']['evidence']
    existing = initial['damage_count']
    pending_repair = initial['damage_count'] == initial['help_count'] + 1
    steps, marks = plan(cycles-existing if not fresh else cycles, fresh, pending_repair)
    if custom_steps is not None:
        steps, marks = custom_steps, []
    inputs = {}
    for role, values in steps.items():
        inputs[role] = out / (role + '-inputs.json')
        save(inputs[role], {'classification': 'Test-only', 'steps': values})
    save(out / 'plan.json', {'classification': 'Test-only', 'actors': actors, 'marks': marks, 'fixture_scope': 'player standing and aim only'})
    rows, stop = [], threading.Event()
    def sample():
        flushed = False
        with (out / 'authority.jsonl').open('w', encoding='utf-8') as stream:
            while not stop.is_set():
                try:
                    row = observe(cid)
                    rows.append(row)
                    stream.write(json.dumps(row, ensure_ascii=False) + '\n')
                    stream.flush()
                    if not fresh and not flushed and row['life']['state']['evidence']['help_count'] >= 2 and row['life']['job'] is None:
                        save(out / 'phase-two-flush.json', rpc(f'GateServer.Npc.Life.flush({cid})'))
                        flushed = True
                    if row['life']['error']:
                        (out / 'abort').write_text('Life authority failure\n')
                        break
                except Exception as e:
                    stream.write(json.dumps({'error': repr(e)}) + '\n')
                    (out / 'abort').write_text('authority observation failed\n')
                    break
                stop.wait(2)
    thread = threading.Thread(target=sample)
    thread.start()
    try:
        scenario = {'level': '/Game/Voxel/Gameplay/L_GameplayDemo', 'roles': {r: {'user': u} for r,u in users.items()},
                    'server': {'container': CONTAINER}, 'measurement': {'seconds': .6}}
        replay = clients.run(scenario, out, SERVER, inputs, max(clients.timeout_estimate(v) for v in steps.values()))
    finally:
        stop.set()
        thread.join()
    save(out / 'clients.json', replay)
    save(out / 'final.json', observe(cid))
    if not fresh:
        save(out / 'verdict.json', verdict(rows, cid, actors, cycles))
    return replay


def upgrade(cid, out, image):
    # 镜像必须来自根已审查的本轮构建；只替换拥有的容器，世界与数据库不重建。
    import service
    manifest = json.loads((BASE / ('build-' + image.rsplit('-', 1)[-1] + '.json')).read_text())
    assert manifest['image'] == image and manifest['exit_code'] == 0
    def inspect_field(field):
        return subprocess.check_output(['docker','inspect','--format',field,CONTAINER],text=True).strip()
    mounts = json.loads(inspect_field('{{json .Mounts}}'))
    ports = json.loads(inspect_field('{{json .HostConfig.PortBindings}}'))
    assert len(mounts) == 1 and Path(mounts[0]['Source']).resolve() == SERVER.resolve() and mounts[0]['Destination'] == '/demo'
    assert ports == {'27361/tcp':[{'HostIp':'127.0.0.1','HostPort':'27361'}],
                     '27363/udp':[{'HostIp':'127.0.0.1','HostPort':'27363'}]}
    digest = subprocess.check_output(['docker','image','inspect','--format','{{.Id}}',image],text=True).strip()
    assert digest == manifest['image_id']
    save(out/'before.json',observe(cid))
    save(out/'old-execution.json',server.execution_identity(SERVER,CONTAINER))
    prior = (SERVER/'identity.json').stat().st_mtime_ns
    auth = service.config()['HINDSIGHT_API_LLM_API_KEY']
    subprocess.run(['docker','stop','--time','10',CONTAINER],check=True,capture_output=True)
    subprocess.run(['docker','rm',CONTAINER],check=True,capture_output=True)
    command = ['docker','run','-d','--user','0:0','--name',CONTAINER,'--network',service.NETWORK,
               '-p','127.0.0.1:27361:27361/tcp','-p','127.0.0.1:27363:27363/udp',
               '-v',str(SERVER)+':/demo','--env-file',str(SERVER/'docker.env'),'-e','NPC_LLM_KEY',
               image,'sh','/demo/start.sh']
    subprocess.run(command,env={**os.environ,'NPC_LLM_KEY':auth},check=True,capture_output=True)
    deadline = time.monotonic()+120
    while (SERVER/'identity.json').stat().st_mtime_ns == prior:
        if time.monotonic()>deadline:
            raise TimeoutError('new release did not publish readiness')
        time.sleep(1)
    save(SERVER/'version.json',manifest)
    after = observe(cid)
    save(out/'after.json',after)
    assert json.loads((out/'before.json').read_text())['life']['state'] == after['life']['state']
    identity = server.execution_identity(SERVER,CONTAINER)
    identity['npc_loaded_beam_md5'] = rpc(NPC_MD5)
    save(out/'execution.json',identity)


def repair_memory(cid, out):
    # 用公开纯 State 从原始 World 事件重建文字；不把重建心智写回 Life。
    before = observe(cid)
    save(out/'before.json',before)
    documents = json.loads((BASE/'time-audit-01/documents.json').read_text())['items']
    ranges = [{'id':d['id'],'first':int(d['id'].rsplit(':',1)[-1].split('-')[0]),
               'last':int(d['id'].rsplit('-',1)[-1])} for d in documents]
    rebuilt = rpc(f'''{{:ok,history}} = VoxelRegion.World.interactions_since(VoxelRegion.World,0)
      state = GateServer.Npc.Life.State.new({cid},"{before['life']['state']['world_id']}",0,0)
      {{state,episodes}} = GateServer.Npc.Life.State.advance(state,history.events,history.cursor,0)
      docs = Jason.decode!({json.dumps(json.dumps(ranges))})
      fragments = Enum.map(docs,fn d ->
        chosen = Enum.filter(episodes,&(&1["seq"] >= d["first"] and &1["seq"] <= d["last"]))
        %{{"id" => d["id"],"at_ms" => hd(chosen)["at_ms"],"text" => Enum.map_join(chosen,"\\n",& &1["text"])}}
      end)
      %{{rebuilt_state: state,episodes: episodes,fragments: fragments}}''')
    save(out/'rebuilt.json',rebuilt)
    assert rebuilt['rebuilt_state'] == before['life']['state']
    assert len(rebuilt['episodes']) == 12 and len(rebuilt['fragments']) == 2
    payload = json.dumps(json.dumps(rebuilt['fragments'],ensure_ascii=False),ensure_ascii=False)
    result = rpc(f'GateServer.Npc.Life.Hindsight.retain(%{{url: "{URL}",bank: "npc-life-{cid}"}},Jason.decode!({payload}))')
    save(out/'replace-retain.json',result)
    ok(result)
    deadline = time.monotonic()+600
    while True:
        status = ok(rpc(f'GateServer.Npc.Life.Hindsight.status(%{{url: "{URL}",bank: "npc-life-{cid}"}})'))
        save(out/'hindsight-status.json',status)
        pending = [o for o in status['operations'] if o['status'] in ('pending','processing')]
        if not pending and status['stats']['pending_operations'] == 0 and status['stats']['pending_consolidation'] == 0:
            break
        if time.monotonic()>deadline:
            raise TimeoutError('replacement consolidation unfinished')
        time.sleep(3)
    memory(cid,out)
    after = observe(cid)
    save(out/'after.json',after)
    assert after['life']['state'] == before['life']['state']


def matched_fresh(cid, out):
    # 距离依据真实 XYZ；先确认自然工位已停稳，再生成既有 ReplayInputs。
    stable = []
    deadline = time.monotonic()+90
    while time.monotonic()<deadline:
        row = observe(cid)
        stable.append(row)
        if len(stable)>=4 and all(distance(r['body']['position'],row['body']['position'])<.03 for r in stable[-4:]):
            break
        time.sleep(2)
    else:
        raise TimeoutError('NPC did not naturally settle at construction')
    save(out/'natural-settled.json',stable)
    p = row['body']['position']
    dy,dz = p[1]-416.91,p[2]+516.5
    x = p[0]-math.sqrt(3.4**2-dy**2-dz**2)
    assert 59 <= x <= 61, 'planned player standing leaves validated west ground'
    near = f'{x:.6f} 416.91 -516.5'
    a,b = Timeline(),Timeline()
    for t in (a,b):
        t.add(25,'@place '+FAR)
    a.add(65,'@place '+near)
    a.add(85,'@place '+FAR)
    # 展示阶段位于验证之后：东侧没有施工方块遮挡，相机窗口留足三十秒。
    a.add(110,'@place 62.5 416.91 -516.5')
    a.add(120,f'@look_settled {p[0]+1.4:.6f} {p[1]+.7:.6f} {p[2]:.6f}')
    for t in (a,b):
        t.add(160,'Voxel.Production.Status')
    save(out/'matching-fixture.json',{'classification':'Test-only','npc_position':p,'player_position':[x,416.91,-516.5],
         'planned_distance':3.4,'approach_seconds':65,'exit_seconds':85,'showcase_look_seconds':120,'showcase_end_seconds':160})
    return social(cid,out,fresh=True,custom_steps={'a':a.steps,'b':b.steps})


def limited_llm(cid, out):
    # 复用既有脱敏 trace：不记录 endpoint/key，只给真实生产请求补上下文摘要与返回用量。
    trace_path = SERVER/'life-llm-requests.jsonl'
    if trace_path.exists():
        raise RuntimeError('formal limited decision already has trace evidence')
    code = (ROOT/'scripts/npc_soak_trace.exs').read_text(encoding='utf-8')
    code = code.replace('/demo/llm-requests.jsonl','/demo/life-llm-requests.jsonl')
    code = code.replace('row = %{pid: inspect(pid)', '''decoded = if is_binary(input), do: Jason.decode!(input), else: %{}
        models = decoded["mental_models"] || %{}
        summary = %{model_sha256: Map.new(models,fn {k,v} -> {k,Base.encode16(:crypto.hash(:sha256,v),case: :lower)} end),
          model_metadata: decoded["model_metadata"], model_cached_at_ms: decoded["model_cached_at_ms"],
          memory_count: length(decoded["memories"] || []), memory_retrieval: decoded["memory_retrieval"],
          recall_latency_ms: decoded["recall_latency_ms"], mind: decoded["mind"],
          goal: decoded["goal"]}
        row = %{context: summary, pid: inspect(pid)''')
    code = code.replace('line = Jason.encode!(Map.merge(row, %{t1:', '''calls = case result do
          {:ok,response} -> Enum.filter(response["output"] || [],&(&1["type"] == "function_call")) |> Enum.map(&Map.take(&1,["name","arguments","call_id"]))
          _ -> []
        end
        line = Jason.encode!(Map.merge(row, %{calls: calls, t1:''')
    save(out/'trace-start.json',server.rpc(SERVER,CONTAINER,code))
    before = observe(cid)
    save(out/'before.json',before)
    started = time.time()
    try:
        position = before['body']['position']
        result = rpc(f'case GateServer.Npc.Registry.put("{NAME}",{spec("llm",position)}) do {{:ok,r}} -> {{:ok,Map.take(r,[:cid])}}; e -> e end')
        assert ok(result)['cid'] == cid
        save(out/'registration.json',result)
        deadline = time.monotonic()+360
        with (out/'authority.jsonl').open('w',encoding='utf-8') as stream:
            while time.monotonic()<deadline:
                row = observe(cid)
                stream.write(json.dumps(row,ensure_ascii=False)+'\n')
                stream.flush()
                if trace_path.exists():
                    save(out/'request.json',json.loads(trace_path.read_text().splitlines()[0]))
                    if json.loads(trace_path.read_text().splitlines()[0])['status'] != 'ok':
                        raise RuntimeError('formal LLM request failed; inspect safe trace result')
                    if any(isinstance(o.get('id'),int) and o['status'] in ('done','rejected','cancelled') for o in row['body']['outcomes']):
                        break
                    # wait 为 Brain 本地动作，没有 Body Outcome；仍需如实保留返回工具。
                    request = json.loads(trace_path.read_text().splitlines()[0])
                    if any(c['name']=='wait' for c in request['calls']):
                        break
                time.sleep(2)
        if not (out/'request.json').exists():
            raise TimeoutError('formal LLM response was not observed')
        save(out/'after.json',observe(cid))
        logs = subprocess.check_output(['docker','logs','--since',str(int(started)),CONTAINER],stderr=subprocess.STDOUT,text=True,encoding='utf-8')
        (out/'decision.log').write_text('\n'.join(l for l in logs.splitlines() if 'npc_llm_' in l),encoding='utf-8')
    finally:
        save(out/'trace-stop.json',rpc(''' :erlang.trace_pattern({GateServer.Npc.Http,:request,2},false,[:global])
          :erlang.trace(:all,false,[:call])
          if pid = Process.whereis(:run07_llm_tracer), do: Process.exit(pid,:kill)
          %{stopped: true}'''))


def approach_evidence(rows, actor, point, at_ms, end_ms, baseline=False, old_distance=3.2, new_distance=4.16):
    before = max((r for r in rows if r['at_ms']<at_ms),key=lambda r:r['at_ms'])
    window = [r for r in rows if at_ms<=r['at_ms']<end_ms]
    initial = distance(before['body']['position'],point)
    previous = (before['life'].get('decision') or {}).get('last_outcome')
    previous_id = previous and previous.get('id')
    terminal = None
    choices = []
    for row in window:
        decision = row['life'].get('decision') or {}
        social = decision.get('social')
        if social and social['actor']==actor:
            choices.append(social)
        outcome = decision.get('last_outcome')
        target = choices[-1].get('target') if choices else None
        if choices and outcome and outcome.get('id')!=previous_id and outcome['status']=='done' and outcome['verb']=='move_to' and outcome['data'].get('settled') and target and math.hypot(outcome['data']['position'][0]-target[0],outcome['data']['position'][2]-target[2])<1.2:
            terminal = outcome
            break
    no_relation = str(actor) not in before['life']['state']['relationships']
    # 对照必须在旧安全距离之外、新谨慎距离之内；名义选点不是额外生产规则。
    matched = old_distance<initial<new_distance and at_ms-before['at_ms']<=3000
    if baseline:
        movement = max(distance(before['body']['position'],r['body']['position']) for r in window)
        state = before['life']['state']
        accepted = matched and no_relation and movement<.03 and not any(c['mode']!='work' for c in choices) and all(r['life']['state']==state for r in window)
    else:
        movement = distance(before['body']['position'],terminal['data']['position']) if terminal else 0
        accepted = matched and no_relation and terminal is not None and movement>.25 and any(c['mode']=='cautious' and c['source_seq']==40 for c in choices)
    return {'actor':actor,'baseline':baseline,'at_ms':at_ms,'before_at_ms':before['at_ms'],
            'initial_position':before['body']['position'],'player_fixture_position':point,'initial_xyz_distance':initial,
            'matching_distance_accepted':matched,'relationship_absent':no_relation,'social_choices':choices,
            'causal_interval':{'old_safe_distance':old_distance,'new_cautious_distance':new_distance},
            'terminal':terminal,'actual_xyz_displacement':movement,'accepted':accepted}


def fresh_judge(out):
    result = []
    # 阈值调用唯一纯规则 owner，从本轮前后 canonical 状态派生，不复制行为公式。
    states = [json.loads(path.read_text())['life']['state'] for path in (BASE/'pre-social-01/observe.json',BASE/'fresh-matched-01/final.json')]
    distances = []
    for state in states:
        payload = json.dumps(json.dumps(state))
        choice = rpc(f'GateServer.Npc.Life.State.behavior(Jason.decode!({payload}),%{{self: %{{position: {{0.0,0.0,0.0}}}},entities: [%{{entity_id: 106220752897,position: {{3.4,0.0,0.0}}}}]}},{state["last_at_ms"]})')
        distances.append(choice['distance'])
    save(out/'public-policy-distances.json',distances)
    for name,baseline in [('social-02',True),('fresh-01',False),('fresh-matched-01',False)]:
        source = BASE/name
        rows = [json.loads(s) for s in (source/'authority.jsonl').read_text().splitlines() if '"at_ms"' in s]
        actor = json.loads((source/'plan.json').read_text())['actors']['a']
        commands = [e for e in events.read(source/'a/client.log') if e['event']=='replay.command']
        for i,e in enumerate(commands):
            command = e['command']
            if not command.startswith('@place '):
                continue
            point = list(map(float,command.split()[1:]))
            if baseline and point[0]!=60.0 or name=='fresh-01' and point[0]!=60.2 or name=='fresh-matched-01' and not 59<=point[0]<=61:
                continue
            next_place = next(n for n in commands[i+1:] if n['command'].startswith('@place '))
            item = approach_evidence(rows,actor,point,e['_log_utc_seconds']*1000,next_place['_log_utc_seconds']*1000,baseline,*distances)
            item['source'] = name
            item['replays'] = {r:record['replay'] for r,record in json.loads((source/'clients.json').read_text()).items()}
            result.append(item)
    accepted = all(sum(r['accepted'] for r in result if r['baseline']==baseline)>=2 for baseline in (True,False))
    controls = [r['initial_xyz_distance'] for r in result if r['baseline'] and r['accepted']]
    post = [r['initial_xyz_distance'] for r in result if not r['baseline'] and r['accepted']]
    farther = bool(controls and post) and min(post)>max(controls)
    accepted = accepted and farther
    save(out/'verdict.json',{'accepted':accepted,'post_farther_than_controls':farther,
         'contract':'two no-harm controls and two cautious settled displacements after cold restart, all outside old safe distance and inside new distance; post starts farther away so closer approach cannot explain change; invalid opportunities preserved','approaches':result})
    return accepted


def memory(cid, out, timeout=900):
    save(out / 'flush.json', rpc(f'GateServer.Npc.Life.flush({cid})'))
    wait_for(cid, lambda r: r['life']['job'] is None and r['life']['pending_fragments'] == 0 and r['life']['retained'] > 0,
             out / 'retain-ready.json', timeout)
    save(out / 'refresh.json', rpc(f'GateServer.Npc.Life.refresh({cid})'))
    row = wait_for(cid, lambda r: r['life']['job'] is None and not r['life']['cache_dirty'] and
                   r['life']['cache'] is not None and all(r['life']['cache']['models'].values()),out / 'memory-ready.json',timeout)
    save(out / 'context.json', rpc(f'GateServer.Npc.Life.context({cid},"Who helped or harmed my construction, at which place and times?")'))
    save(out / 'hindsight-status.json', rpc(f'GateServer.Npc.Life.Hindsight.status(%{{url: "{URL}",bank: "npc-life-{cid}"}})'))
    return row


def judge(sources, out, cid, cycles):
    rows, client_reports = [], []
    fixture_windows = {'avoid':[],'thank':[]}
    actors = None
    for source in sources:
        path = source / 'authority.jsonl'
        if path.exists():
            rows.extend(json.loads(s) for s in path.read_text(encoding='utf-8').splitlines() if '"at_ms"' in s)
        if not (source / 'clients.json').exists():
            continue
        actors = json.loads((source / 'plan.json').read_text())['actors']
        roles = {r: {'events': events.read(source/r/'client.log'), 'lines': events.lines(source/r/'client.log')} for r in ('a','b')}
        for role,data in roles.items():
            places = [e for e in data['events'] if e['event']=='replay.command' and e['command'].startswith('@place ')]
            for i,event in enumerate(places[:-1]):
                if event['command']=='@place '+NEAR:
                    fixture_windows['avoid' if role=='a' else 'thank'].append((event['_log_utc_seconds']*1000,places[i+1]['_log_utc_seconds']*1000))
        report = {'source': str(source.relative_to(BASE)), 'checks': {}, 'errors': []}
        replay = json.loads((source/'clients.json').read_text())
        report['replays'] = {r:replay[r]['replay'] for r in ('a','b')}
        report['scope'] = 'actual committed interaction prefix; failed/skipped replay steps retain their failure classification'
        first = min(e['_log_utc_seconds'] for r in roles.values() for e in r['events'] if e['event'] == 'replay.command')*1000
        last = max(e['_log_utc_seconds'] for r in roles.values() for e in r['events'] if e['event'] == 'replay.command')*1000
        authority = [e for e in rows[-1]['interactions']['events'] if e['actor'] in actors.values() and first <= e['at_ms'] <= last]
        txns = {e['seq'] for e in authority}
        for role,data in roles.items():
            try:
                checks.character_identity(data['lines'],actors[role],expected_sessions=1)
                received = {int(m.group(1)) for line in data['lines'] if (m:=re.search(r'Voxel canonical_applied txn=(\d+)',line))}
                assert txns <= received, ('missing canonical transactions',sorted(txns-received))
                sent = {e['client_seq']:e for e in data['events'] if e['event']=='intent.sent' and e['coord']==CELL}
                returned = {e['client_seq']:e for e in data['events'] if e['event']=='intent.result'}
                actor_txns = {e['seq'] for e in authority if e['actor']==actors[role]}
                assert bool(sent) == bool(actor_txns), 'missing actual actor inputs or authority transactions'
                assert all(k in returned and returned[k]['result']==0 for k in sent), 'actual intended inputs rejected or missing results'
                assert {returned[k]['txn'] for k in sent} == actor_txns, 'intended input/authority transaction mismatch'
                report['checks'][role] = {'canonical_transactions':sorted(txns),'intended_transactions':sorted(actor_txns),'authenticated_cid':actors[role]}
            except AssertionError as e:
                report['errors'].append({'role': role,'failure':str(e)})
        damage = {e['seq'] for e in authority if e['kind'] in ('damage','destroy')}
        if damage:
            try:
                report['damage_projection'] = checks.reconcile_transactions(roles,'damage.confirmed',damage)
            except AssertionError as e:
                report['errors'].append({'failure':str(e)})
        client_reports.append(report)
    rows.sort(key=lambda r:r['at_ms'])
    result = verdict(rows,cid,actors,cycles)
    for item in result['behavior']:
        window = next(((start,end) for start,end in fixture_windows[item['mode']] if start<=item['observed_at_ms']<end),None)
        item['declared_approach_window'] = window is not None
        event = next(e for e in rows[-1]['interactions']['events'] if e['seq']==item['source_seq'])
        item['trigger_kind'] = 'new_authority_interaction' if window and event['at_ms']>=window[0] else 'remembered_source_actor_reentry'
        if not item['declared_approach_window']:
            item['accepted'] = False
            item['limitation'] = 'startup/AOI observation outside declared approach; retained as confound'
    result['behavior_accepted'] = all(sum(p['accepted'] for p in result['behavior'] if p['mode']==mode)>=2 for mode in ('avoid','thank'))
    result['accepted'] = result['authority_accepted'] and result['behavior_accepted']
    result['clients'] = client_reports
    result['all_replays_completed'] = all(all(v == 'success' for v in p['replays'].values()) for p in client_reports)
    result['client_authority_accepted'] = all(not r['errors'] for r in client_reports)
    result['accepted'] = result['accepted'] and result['client_authority_accepted']
    result['judge_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    save(out/'verdict.json',result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare','initial-correction','social','fresh','matched-fresh','fresh-judge','upgrade','repair-memory','memory','flush','watch','judge','observe','restart','llm','restore','dry'])
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--cycles', type=int, default=6)
    parser.add_argument('--seconds', type=int, default=180)
    parser.add_argument('--sources', type=Path, nargs='*')
    parser.add_argument('--image')
    args = parser.parse_args()
    args.out = args.out.resolve()
    if args.out.exists():
        raise SystemExit('new output directory required')
    args.out.mkdir(parents=True)
    if args.command == 'dry':
        steps, marks = plan(args.cycles)
        save(args.out / 'plan.json', {'steps': steps, 'marks': marks})
        print(json.dumps({'last_seconds': max(s['after_seconds'] for v in steps.values() for s in v)}))
        return
    if args.command in ('prepare','initial-correction'):
        prepare(args.out,args.command == 'initial-correction')
        print('NPC prepared through real build')
        return
    cid = json.loads((BASE / 'demo-cid.json').read_text())['cid']
    if args.command == 'upgrade':
        upgrade(cid,args.out,args.image)
        print('same canonical NPC/world upgraded')
    elif args.command == 'repair-memory':
        repair_memory(cid,args.out)
        print('same document IDs replaced and models refreshed; canonical unchanged')
    elif args.command == 'matched-fresh':
        print(json.dumps(matched_fresh(cid,args.out)))
    elif args.command == 'fresh-judge':
        print(json.dumps({'personality_behavior_accepted':fresh_judge(args.out)}))
    elif args.command in ('social','fresh'):
        print(json.dumps(social(cid,args.out,args.cycles,args.command == 'fresh')))
    elif args.command == 'judge':
        result = judge([s.resolve() for s in args.sources],args.out,cid,args.cycles)
        print(json.dumps({k:result[k] for k in ['accepted','authority_accepted','behavior_accepted','client_authority_accepted']}))
    elif args.command == 'memory':
        memory(cid,args.out)
        print('actual retain/cache/recall finished')
    elif args.command == 'flush':
        save(args.out / 'flush.json', rpc(f'GateServer.Npc.Life.flush({cid})'))
    elif args.command == 'watch':
        deadline = time.monotonic() + args.seconds
        with (args.out / 'authority.jsonl').open('w',encoding='utf-8') as stream:
            while time.monotonic() < deadline:
                stream.write(json.dumps(observe(cid),ensure_ascii=False) + '\n')
                stream.flush()
                time.sleep(.25)
    elif args.command == 'restart':
        import service
        save(args.out / 'before.json', observe(cid))
        service.stop()
        service.start(600)
        save(args.out / 'restart.json', server.restart(SERVER,CONTAINER,args.out / 'server-restart.log',120))
        wait_for(cid, lambda r: r['life']['state'] is not None,args.out / 'after.json',90)
        save(args.out / 'context.json', rpc(f'GateServer.Npc.Life.context({cid},"Who repaired or damaged my construction?")'))
    elif args.command == 'llm':
        limited_llm(cid,args.out)
        print('one production LLM request observed; inspect actual action and limitation')
    elif args.command == 'restore':
        position = observe(cid)['body']['position']
        save(args.out / 'before.json', observe(cid))
        save(args.out / 'registration.json', rpc(f'case GateServer.Npc.Registry.put("{NAME}",{spec("llm" if args.command == "llm" else "settler",position)}) do {{:ok,r}} -> {{:ok,Map.take(r,[:cid])}}; e -> e end'))
        for i in range(30):
            save(args.out / f'sample-{i:02d}.json', observe(cid))
            time.sleep(2)
    else:
        save(args.out / 'observe.json', observe(cid))
        identity = server.execution_identity(SERVER, CONTAINER)
        identity['npc_loaded_beam_md5'] = rpc(NPC_MD5)
        identity['client_binary'] = clients.binary_digest()
        save(args.out / 'execution.json', identity)


if __name__ == '__main__':
    main()
