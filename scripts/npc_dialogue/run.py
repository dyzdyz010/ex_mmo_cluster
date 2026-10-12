"""只测试：独立 Demo 的真实双端对话；断言失败保留证据并停下模型。"""
import argparse
import json
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
CLIENT = Path('C:/Users/DYZ/orca/workspaces/Voxim/npc-dialogue-20261011')
sys.path.insert(0, str(CLIENT / 'Docs/R7'))
from harness import clients, server, events
sys.path.insert(0, str(ROOT / 'scripts/npc_life'))
import demo
from long_horizon import packed
import verify

assert clients.ROOT == CLIENT, 'must launch the isolated client worktree'
BASE = ROOT / '.demo/observe/npc-dialogue-20261011'
FIRST = 607440080896
SECOND_NAME = '松岚'
ACTORS = {'a': 1132722130946, 'b': 1133355470852}
UI_TEXT = '大家好，我叫访客甲，今天在工坊旁见面。'
FAR_TEXT = '青石约定：我提议明天先观察工坊再商量分工，现在只是提议。'
LIMIT = 16


def registry(name, brain, params, position):
    spec = '%{scene_id: 1, spawn: {' + ','.join(map(str, position)) + '}, brain: "' + brain + '", params: ' + packed(params) + '}'
    return demo.ok(demo.rpc(f'case NpcServer.Registry.put({packed(name)},{spec}) do {{:ok,r}} -> {{:ok,Map.take(r,[:cid])}}; e -> e end'))['cid']


def snapshot(cid):
    return demo.rpc(f'''[{{pid,_}}] = Registry.lookup(NpcServer.Names,{cid})
      {{:ok,life}} = NpcServer.Life.observe({cid})
      %{{at_ms: System.system_time(:millisecond),body: NpcServer.Body.observe(pid) |> Map.take([:position,:tick,:entities,:outcomes,:dialogue]),
        life: life, stored: DataService.NpcMemory.get({cid},"life","state")}}''')


def status(cid):
    return demo.ok(demo.rpc(f'NpcServer.Life.Hindsight.status(%{{url: "{demo.URL}",bank: "npc-life-{cid}"}})'))


def tokens(value):
    return sum(r['input_tokens'] + r['output_tokens'] for r in value['usage'].values())


def prepare(out):
    ledger=json.loads((BASE/'budget-ledger.json').read_text(encoding='utf-8'))
    if ledger['cumulative_tokens_before'] >= 2000000:
        raise RuntimeError('cumulative token budget exhausted; paid preparation is disabled')
    before = snapshot(FIRST)
    demo.save(out / 'first-before.json', before)
    assert verify.npc_ready(before), 'first NPC not entered'
    params = {'definition': demo.DEFINITION, 'sites': [{'anchor_micro': [488,3328,-4136], 'orientation': 0,
        'stand': [63.5,-516.5]}], 'revisit_ticks': 36000, 'tools': {'1':'镐'}, 'life': {'url':demo.URL}}
    # 原探针416.91落在新列实心格内部；World实查416为地面、417以上空气，从其上方合法下扫出生点。
    column=demo.rpc('cells = for y <- 415..421, do: {65,y,-517}; VoxelRegion.World.material_snapshot(VoxelRegion.World,[],cells)')
    demo.save(out/'spawn-column.json',column)
    assert all(c['material']==0 for c in column['probe_occupancy'] if c['cell'][1]>=417), 'spawn clearance changed'
    second = registry(SECOND_NAME, 'settler', params, [65.5,420.0,-516.5])
    deadline = time.monotonic() + 120
    while True:
        row = snapshot(second)
        demo.save(out / 'second-before.json', row)
        if verify.npc_ready(row):
            break
        if row['life']['error'] or time.monotonic() > deadline:
            raise RuntimeError('new Life memory initialization failed')
        time.sleep(2)
    demo.save(out / 'fixtures.json', {'classification':'Test-only', 'npcs':[FIRST,second], 'actors':ACTORS,
        'second_settler_params':params, 'npc_request_limits':[LIMIT,LIMIT],
        **ledger, 'cumulative_token_cap':2000000,
        'decision_guard':350000, 'reserved_inflight_and_memory_tokens':2000000-ledger['cumulative_tokens_before']-350000})
    for cid in [FIRST,second]:
        demo.save(out / f'memory-before-{cid}.json', status(cid))
    return second, params


def plan():
    a, b = demo.Timeline(), demo.Timeline()
    for t in [a,b]:
        t.add(25, '@place ' + demo.NEAR)
        t.add(32, '@look_settled 63.5 417.8 -516.5')
    a.click(40,'Enter')
    a.add(41,'@type '+UI_TEXT)
    a.add(43,'@slate Enter')
    for t in [a,b]:t.add(50,'@await_peer ui_confirmed')
    a.add(65,f'Voxim.Dialogue.Say {FIRST} 0 你愿意和身边的松岚聊聊以后怎样照顾工坊吗？请你们自己商量，我先旁听。')
    b.click(92,'Enter')
    b.add(93,'@type 我是访客乙，我也在旁听，你们可以有自己的不同意见。')
    b.add(95,'@slate Enter')
    # 取消不得产生发言；随后移动/输入仍应正常。
    a.click(115,'Enter')
    a.add(116,'@type 这句取消，不应发送。')
    a.add(118,'@slate Escape')
    a.add(122,'@look_settled 65.5 417.8 -516.5')
    b.add(175,'@place '+demo.FAR)
    a.add(190,'Voxim.Dialogue.Say 0 0 '+FAR_TEXT)
    b.add(205,f'Voxim.Dialogue.Say {FIRST} 0 我在远处，这条应被拒绝。')
    b.add(235,'@place '+demo.NEAR)
    a.add(255,f'Voxim.Dialogue.Say {FIRST} 0 对于刚才的青石约定，你怎么看？这不代表事情已经做完。')
    for t in [a,b]:
        t.add(300,'Voxim.Dialogue.Status')
        t.add(302,'Voxel.Production.Status')
    return {role: {'classification':'Test-only','steps':t.steps} for role,t in [('a',a),('b',b)]}


def scene_rows(since, path):
    r = subprocess.run(['docker','logs','--since',str(since),demo.CONTAINER], capture_output=True, text=True, encoding='utf-8')
    r.check_returncode()
    raw = r.stdout + r.stderr
    path.write_text(raw,encoding='utf-8')
    rows = []
    for line in raw.splitlines():
        start = line.find('{"')
        if start >= 0:
            try:
                row = json.loads(line[start:])
            except ValueError:
                continue
            if row.get('schema') == 'voxim-scene-v1' and row.get('event','').startswith('dialogue.'):
                rows.append(row)
    return rows


def check(out, second):
    evidence = {role: events.read(out / role / 'client.log') for role in ACTORS}
    rows = json.loads((out/'scene.json').read_text(encoding='utf-8'))
    truth = verify.authority_events(rows)
    received = {r:[e for e in xs if e['event']=='dialogue.speech'] for r,xs in evidence.items()}
    result = verify.delivery(truth,received,ACTORS,[FIRST,second])
    requests = {}
    for role,xs in evidence.items():
        requests[role] = []
        for sent in [e for e in xs if e['event']=='dialogue.request']:
            answers = [e for e in xs if e['event']=='dialogue.result' and e['request_id']==sent['request_id']]
            assert len(answers)==1, 'one correlated result required'
            answer = answers[0]
            if sent['text']=='我在远处，这条应被拒绝。':
                assert answer['reason']=='target_out_of_range', answer
                continue
            requests[role].append(verify.player_request(sent,answer,truth,ACTORS[role]))
    assert any(e['text']==UI_TEXT and e['speaker_id']==ACTORS['a'] for e in truth),'UMG text missing'
    assert not any('这句取消' in e['text'] for e in truth),'cancel submitted text'
    panels=[e for e in evidence['a'] if e['event']=='dialogue.panel']
    assert [e['open'] for e in panels]==[True,False,True,False],'UMG send/cancel lifecycle incomplete'
    far = next(e for e in truth if e['text']==FAR_TEXT)
    assert ACTORS['b'] not in far['recipients'] and ACTORS['a'] in far['recipients'],'distance negative failed'
    model = json.loads((out/'requests.json').read_text(encoding='utf-8'))
    for cid in [FIRST,second]:
        speeches = [e for e in truth if e['speaker_id']==cid]
        calls = [call for r in model if json.loads(r['request']['input'])['self']['entity_id']==cid for call in r['calls'] if call['name']=='say']
        assert calls and speeches, f'no actual independent model speech {cid}'
        for speech in speeches:
            assert any(json.loads(c['arguments'])['text'].strip()==speech['text'] for c in calls),'speech lacks model provenance'
    return {**result,'player_requests':requests,'accepted':True,'authority_speeches':len(truth)}


def live(out):
    out.mkdir(parents=True,exist_ok=False)
    second, idle_params = prepare(out)
    identity = server.execution_identity(demo.SERVER,demo.CONTAINER)
    identity.update(client_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=CLIENT,text=True).strip(),client_binary=clients.binary_digest())
    demo.save(out/'execution.json',identity)
    run_id = 'dialogue-'+out.name
    trace = demo.SERVER/(run_id+'-requests.jsonl')
    starts = demo.SERVER/(run_id+'-started.jsonl')
    assert not trace.exists() and not starts.exists(),'trace evidence already exists'
    code=(ROOT/'scripts/npc_life/decision_trace.exs').read_text(encoding='utf-8').replace('/demo/long-horizon-','/demo/'+run_id+'-')
    demo.save(out/'trace.json',server.rpc(demo.SERVER,demo.CONTAINER,code))
    scenario={'level':'/Game/Voxel/Gameplay/L_GameplayDemo','roles':{'a':{'user':'npc_life_a_20261011'},'b':{'user':'npc_life_b_20261011'}},
        'server':{'container':demo.CONTAINER},'measurement':{'seconds':0.6}}
    inputs={}
    for role,steps in plan().items():
        inputs[role]=out/(role+'-inputs.json')
        demo.save(inputs[role],steps)
    stop=threading.Event()
    errors=[]
    started=time.time()
    enabled=False
    def monitor():
        nonlocal enabled
        try:
            with (out/'snapshots.jsonl').open('w',encoding='utf-8') as history:
                while not stop.is_set():
                    log=out/'a/client.log'
                    observed={role:events.read(out/role/'client.log') if (out/role/'client.log').exists() else [] for role in ACTORS}
                    for xs in observed.values():
                        for e in xs:
                            if e['event']=='dialogue.result' and e['reason'] not in ('ok','target_out_of_range'):
                                raise RuntimeError('player dialogue failed: '+str(e))
                    if not enabled and all(any(e['event']=='dialogue.speech' and e['text']==UI_TEXT for e in xs) for xs in observed.values()):
                        goals={FIRST:'我住在这里并照顾工坊。今天希望认识旁边的松岚，互相介绍并商量以后如何观察和照顾工坊。我依据自己已有经历决定态度与边界，可以询问、拒绝或沉默，不必取悦访客。只说自己的话，不替别人回答。使用简洁中文；暂时无事就等待。',
                            second:'我是松岚，刚来到这里，想了解邻居LifeBuilder的经历和工坊的情况，形成自己的看法。我愿意主动交谈，也可以拒绝不合理的建议。不代替别人发言，不把口头提议当作已发生的事实。使用简洁中文；暂时无事就等待。'}
                        for cid,name in [(FIRST,demo.NAME),(second,SECOND_NAME)]:
                            row=snapshot(cid)
                            params={'goal':goals[cid],'tools':{'1':'镐'},'life':{'url':demo.URL},'max_requests_per_hour':LIMIT}
                            assert registry(name,'life',params,row['body']['position'])==cid
                        enabled=True
                        demo.save(out/'models-started.json',{'at':time.time(),'limits':[LIMIT,LIMIT]})
                        for role in ACTORS:(out/role/'replay.done').write_text('ui_confirmed',encoding='utf-8')
                    if time.time()-started>130 and not enabled:
                        raise RuntimeError('first UMG speech failed; no model activation')
                    if enabled:
                        for cid in [FIRST,second]:
                            row=snapshot(cid)
                            history.write(json.dumps({'cid':cid,**row},ensure_ascii=False)+'\n');history.flush()
                            if row['life']['error']: raise RuntimeError(str(row['life']['error']))
                    if trace.exists():
                        records=[json.loads(s) for s in trace.read_text(encoding='utf-8').splitlines()]
                        demo.save(out/'requests.json',records)
                        if any(r['status']!='ok' for r in records): raise RuntimeError('external model request failed')
                        if sum(r['usage']['total_tokens'] for r in records)>=350000: raise RuntimeError('decision token guard')
                    stop.wait(3)
        except BaseException as error:
            errors.append(repr(error));(out/'abort').write_text(repr(error),encoding='utf-8')
    worker=threading.Thread(target=monitor)
    worker.start()
    try:
        result=clients.run(scenario,out,demo.SERVER,inputs,timeout=430)
        demo.save(out/'clients.json',result)
    finally:
        stop.set();worker.join(timeout=90)
        if worker.is_alive(): errors.append('monitor did not stop')
        # 只等已启动请求结束及大脑进入自然空闲；不取消请求后把未知花费记成零。
        deadline=time.monotonic()+60
        settled_since=None
        while enabled:
            begun=starts.read_text(encoding='utf-8').splitlines() if starts.exists() else []
            finished=trace.read_text(encoding='utf-8').splitlines() if trace.exists() else []
            if len(begun)==len(finished):
                settled_since=settled_since or time.monotonic()
                if time.monotonic()-settled_since>=2:break
            else:settled_since=None
            if time.monotonic()>deadline:
                errors.append('model drain timeout; unfinished usage remains unknown');break
            time.sleep(.25)
        for cid,name in [(FIRST,demo.NAME),(second,SECOND_NAME)]:
            try:
                row=snapshot(cid);demo.save(out/f'before-restore-{cid}.json',row)
                if row['body']['position'] is None:raise RuntimeError('NPC has no entered position')
                assert registry(name,'settler',idle_params,row['body']['position'])==cid
                demo.save(out/f'after-restore-{cid}.json',snapshot(cid))
            except Exception as error:
                errors.append('restore '+str(cid)+': '+repr(error))
                # 已复现的准备失败：不能用空位置恢复，停用本人登记且保留记忆；其余清理仍必须执行。
                demo.save(out/f'disabled-{cid}.json',demo.rpc(f'NpcServer.Registry.remove({packed(name)})'))
        demo.save(out/'trace-stop.json',demo.rpc(':erlang.trace_pattern({NpcServer.Http,:request,2},false,[:global]); :erlang.trace(:all,false,[:call]); if pid=Process.whereis(:npc_long_horizon_trace),do: Process.exit(pid,:kill); :ok'))
        if trace.exists():demo.save(out/'requests.json',[json.loads(s) for s in trace.read_text(encoding='utf-8').splitlines()])
        if starts.exists():demo.save(out/'started.json',[json.loads(s) for s in starts.read_text(encoding='utf-8').splitlines()])
        demo.save(out/'scene.json',scene_rows(started,out/'server.log'))
        demo.save(out/'errors.json',errors)
    assert not errors,errors
    assert all(r['replay']=='success' for r in result.values()),'replay failed'
    verdict=check(out,second)
    demo.save(out/'verdict.json',verdict)
    print(json.dumps(verdict,ensure_ascii=False),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('mode',choices=['plan','live','check','upgrade']);parser.add_argument('--run',default='dual-01');parser.add_argument('--image')
    args=parser.parse_args();out=BASE/args.run
    if args.mode=='plan':print(json.dumps(plan(),ensure_ascii=False,indent=2))
    elif args.mode=='live':live(out)
    elif args.mode=='upgrade':demo.upgrade(FIRST,out,args.image)
    else:
        fixtures=json.loads((out/'fixtures.json').read_text(encoding='utf-8'))
        print(json.dumps(check(out,fixtures['npcs'][1]),ensure_ascii=False))
