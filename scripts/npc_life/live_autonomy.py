"""只测试：一次固定样本，无玩家开场的NPC交谈→两次有限材料自主修复；首失败停后续。"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
CLIENT = Path('C:/Users/DYZ/orca/workspaces/Voxim/npc-dialogue-20261011')
sys.path.insert(0, str(CLIENT/'Docs/R7'))
from harness import clients, events, server
import demo
import autonomy
import budget_service as budget
from long_horizon import packed, confirmed_stage, ACTORS

sys.path.insert(0, str(demo.ROOT/'scripts/npc_dialogue'))
import verify

CIDS = budget.CIDS
OUT = demo.ROOT/'.demo/observe/npc-autonomy-20261011'


def body(cid):
    return demo.rpc(f'[{{pid,_}}] = Registry.lookup(NpcServer.Names,{cid}); NpcServer.Body.observe(pid) |> Map.take([:position,:tick,:entities,:outcomes,:dialogue])')


def register(row, brain, params, position):
    spec='%{scene_id: 1, spawn: {'+','.join(map(str,position))+'}, brain: '+packed(brain)+', params: '+packed(params)+'}'
    result=demo.ok(demo.rpc(f'case NpcServer.Registry.put({packed(row["name"])},{spec}) do {{:ok,r}} -> {{:ok,Map.take(r,[:cid])}}; e -> e end'))
    assert result['cid']==row['cid']


def plan():
    a,b=demo.Timeline(),demo.Timeline()
    for t in (a,b):
        t.add(25,'@place '+demo.NEAR)
        t.add(30,'@await_peer conversation_complete')
    for phase,start in [(1,60),(2,100)]:
        a.add(start,'@place '+demo.NEAR)
        a.click(start+1,'One')
        a.add(start+2,'@aim 61.5 416.5 -516.5')
        for n in range(3):a.hit(start+4+1.2*n)
        a.add(start+8,'@await_intents')
        a.add(start+9,'@place '+demo.FAR)
        a.add(start+10,'@await_peer '+('npc-repair-1' if phase==1 else 'success'))
    a.add(130,'Voxel.Production.Status')
    b.add(60,'@place '+demo.FAR)
    b.add(65,'@await_peer npc-repairs-complete')
    b.add(132,'Voxel.Production.Status')
    return {'a':a.steps,'b':b.steps}


def conversation(authority, observed, requests):
    """返回完整双向交谈证据；玩家引导、只有独白、无模型来源都不得放行破坏。"""
    if not authority:return None
    assert all(e['speaker_id'] in CIDS for e in authority), 'player speech triggered experiment'
    directed={(e['speaker_id'],e['target_id'],e['conversation_id']) for e in authority}
    paired={c for a,b,c in directed if a!=b and (b,a,c) in directed and a in CIDS and b in CIDS}
    if not paired:return None
    visible=[e for e in authority if e['conversation_id'] in paired and set(ACTORS)<=set(e['recipients'])]
    visible_directions={(e['speaker_id'],e['target_id'],e['conversation_id']) for e in visible}
    if not any(a!=b and (b,a,c) in visible_directions for a,b,c in visible_directions):return None
    for e in authority:
        calls=[c for r in requests if r['status']=='ok' and json.loads(r['request']['input'])['self']['entity_id']==e['speaker_id'] for c in r['calls'] if c['name']=='say']
        if not any(json.loads(c['arguments'])['text'].strip()==e['text'] for c in calls):return None
    heard={role:[e for e in rows if e['event']=='dialogue.speech'] for role,rows in observed.items()}
    # 客户端可能尚未消费已经接纳的权威发言；等待逐笔齐全，不能只对交集作比较。
    for role,cid in zip(('a','b'),ACTORS):
        expected={verify.key(e) for e in authority if cid in e['recipients']}
        if not expected <= {verify.key(e) for e in heard[role]}:return None
    return verify.delivery(authority,heard,dict(zip(('a','b'),ACTORS)),CIDS)


def scene(since):
    result=subprocess.run(['docker','logs','--since',str(since),demo.CONTAINER],capture_output=True,text=True,encoding='utf8')
    result.check_returncode()
    rows=[]
    for line in (result.stdout+result.stderr).splitlines():
        start=line.find('{"')
        if start>=0:
            try:r=json.loads(line[start:])
            except ValueError:continue
            if r.get('schema')=='voxim-scene-v1' and r.get('event','').startswith('dialogue.'):rows.append(r)
    return rows


def records(path):
    return [json.loads(line) for line in path.read_text(encoding='utf8').splitlines()] if path.exists() else []


def shutdown(out, rows, enabled, errors):
    """清理各owner独立执行；预算控制失联不得跳过NPC恢复、停用或trace停止。"""
    try:
        demo.save(out/'budget-closed.json',budget.budget('close'))
        drain=time.monotonic()+155
        while budget.budget()['in_flight_tokens']:
            if time.monotonic()>drain:raise TimeoutError('unsettled paid requests remain reserved')
            time.sleep(1)
    except Exception as error:
        errors.append('budget shutdown: '+repr(error))
        try:
            budget.docker('stop','--time','10',budget.NAME)
        except Exception as stopped:
            errors.append('budget process stop: '+repr(stopped))
    for row in rows:
        try:
            current=body(row['cid']);demo.save(out/f'body-after-{row["cid"]}.json',current)
            if row['cid'] in enabled:demo.save(out/f'life-after-{row["cid"]}.json',demo.observe(row['cid']))
            register(row,row['brain'],row['params'],current['position'])
        except Exception as error:
            errors.append('restore: '+repr(error))
            try:
                demo.save(out/f'disabled-{row["cid"]}.json',demo.rpc(f'NpcServer.Registry.remove({packed(row["name"])})'))
            except Exception as disabled:
                errors.append('disable: '+repr(disabled))
    try:
        demo.save(out/'trace-stop.json',demo.rpc(':erlang.trace_pattern({NpcServer.Http,:request,2},false,[:global]); :erlang.trace(:all,false,[:call]); if pid=Process.whereis(:npc_long_horizon_trace),do: Process.exit(pid,:kill); :ok'))
    except Exception as error:
        errors.append('trace stop: '+repr(error))


def run(out, seconds=560):
    out.mkdir(parents=True,exist_ok=False)
    assert clients.ROOT==CLIENT, 'Hello40 isolated client required'
    rows=demo.rpc('NpcServer.Registry.list()')
    assert {r['cid'] for r in rows}==set(CIDS) and all(r['brain']=='settler' and 'life' not in r['params'] for r in rows)
    initial=demo.rpc('VoxelRegion.World.material_snapshot(VoxelRegion.World,[607440080896],[{61,416,-517}])')
    assert initial['probe_occupancy'][0]['material']==19 and initial['material_balances'][0]['units']==0
    assert not budget.budget()['halted'], 'shared paid gate already closed'
    demo.save(out/'registry-before.json',rows)
    demo.save(out/'world-before.json',initial)
    for r in rows:demo.save(out/f'body-before-{r["cid"]}.json',body(r['cid']))
    goals={CIDS[0]:autonomy.GOAL+' I would also like a brief conversation with my neighbor 松岚 about how we each see life here, then attend to my ongoing responsibilities. Use concise Chinese in conversation. Other speakers express their own views; words alone do not confirm work.',
           CIDS[1]:'我是松岚，在工坊旁安顿。我希望了解邻居LifeBuilder的经历，可以主动交谈、表达自己的看法或拒绝建议；聊过后正常休息观察，不反复询问相同问题。不代替邻居施工，不把口头提议当完成的事。用简洁中文。'}
    params={cid:{'goal':goals[cid],'tools':{'1':'镐'},'skills':['gather','travel'],'life':{'url':demo.URL},'max_requests_per_hour':30 if cid==CIDS[0] else 8} for cid in CIDS}
    demo.save(out/'protocol.json',{'classification':'Test-only','params':params,'actors':ACTORS,'source_cells':autonomy.SOURCES,
        'seconds':seconds,'stages':['spontaneous_npc_conversation','npc_repair_1','npc_repair_2'],
        'budget_before':budget.budget(),'no_player_speech_or_repair':True,'first_failure_stops':True})
    identity=server.execution_identity(demo.SERVER,demo.CONTAINER)
    identity.update(client_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=CLIENT,text=True).strip(),client_binary=clients.binary_digest())
    demo.save(out/'execution.json',identity)
    run_id='autonomy-'+out.name
    trace=demo.SERVER/(run_id+'-requests.jsonl')
    starts=demo.SERVER/(run_id+'-started.jsonl')
    assert not trace.exists() and not starts.exists(), 'refuse evidence overwrite'
    code=(demo.ROOT/'scripts/npc_life/decision_trace.exs').read_text(encoding='utf8').replace('/demo/long-horizon-','/demo/'+run_id+'-')
    demo.save(out/'trace.json',server.rpc(demo.SERVER,demo.CONTAINER,code))
    inputs={}
    for role,steps in plan().items():
        inputs[role]=out/(role+'-inputs.json');demo.save(inputs[role],{'classification':'Test-only','steps':steps})
    stop=threading.Event();errors=[];enabled=[]
    started=time.time();deadline=time.monotonic()+seconds
    def monitor():
        phase=0;cursor=initial['seq'];units=0;harm=False;receipt=None;enabled_at=None
        try:
            with (out/'snapshots.jsonl').open('w',encoding='utf8') as history:
                while not stop.is_set():
                    observed={r:events.read(out/r/'client.log') if (out/r/'client.log').exists() else [] for r in ('a','b')}
                    placed=all(any(e['event']=='replay.place' and e['ok'] for e in xs) for xs in observed.values())
                    if not enabled and placed:
                        for row in rows:
                            position=body(row['cid'])['position'];assert position is not None
                            register(row,'life',params[row['cid']],position);enabled.append(row['cid'])
                        enabled_at=time.monotonic()
                    if not enabled and time.time()-started>120:raise TimeoutError('both clients placement readiness')
                    ledger=budget.budget()
                    demo.save(out/'budget-latest.json',ledger)
                    if ledger['halted']:raise RuntimeError('shared budget gate: '+ledger['halted'])
                    model=records(trace);demo.save(out/'requests.json',model)
                    if any(r['status']!='ok' for r in model):raise RuntimeError('decision request failed')
                    if enabled:
                        current={}
                        for cid in CIDS:
                            value=demo.observe(cid);current[cid]=value
                            history.write(json.dumps({'cid':cid,**value},ensure_ascii=False)+'\n');history.flush()
                            if value['life']['error']:raise RuntimeError('Life failure: '+str(value['life']['error']))
                        world=current[CIDS[0]]
                        if phase==0:
                            authority=verify.authority_events(scene(started))
                            accepted=conversation(authority,observed,model)
                            if accepted:
                                demo.save(out/'conversation.json',{'accepted':True,**accepted,'authority':authority})
                                for r in ('a','b'):(out/r/'replay.done').write_text('conversation_complete\n',encoding='utf8')
                                phase=1
                            elif time.monotonic()-enabled_at>180:raise TimeoutError('spontaneous conversation not confirmed')
                        else:
                            client=observed['a']
                            sent=[e for e in client if e['event']=='intent.sent']
                            results=[e for e in client if e['event']=='intent.result']
                            if not harm and len(results)>=phase*3:
                                chosen=sent[(phase-1)*3:phase*3];keys={e['client_seq'] for e in chosen}
                                proof=confirmed_stage(chosen+[e for e in results if e['client_seq'] in keys],world['interactions']['events'],cursor,ACTORS[0],3,'destroy')
                                demo.save(out/f'harm-{phase}.json',proof);harm=True
                            if harm:
                                receipt=receipt or autonomy.repair_receipt(world['interactions']['events'],cursor,world['material'],units)
                                txns=[e['seq'] for e in receipt['gather']+[receipt['build']]] if receipt else []
                                if receipt and autonomy.copied(out,txns):
                                    demo.save(out/f'repair-{phase}.json',receipt)
                                    demo.save(out/f'repaired-state-{phase}.json',world)
                                    if phase==2:
                                        (out/'a/replay.done').write_text('npc-repairs-complete\n',encoding='utf8');return
                                    (out/'b/replay.done').write_text('npc-repair-1\n',encoding='utf8')
                                    cursor=receipt['build']['seq'];units=receipt['units_after'];phase=2;harm=False;receipt=None
                    if time.monotonic()>deadline:raise TimeoutError(f'stage {phase} did not complete before deadline')
                    stop.wait(2)
        except BaseException as error:
            errors.append(repr(error));(out/'abort').write_text(repr(error),encoding='utf8')
            demo.save(out/'budget-failure.json',budget.budget('close'))
    worker=threading.Thread(target=monitor);worker.start()
    scenario={'level':'/Game/Voxel/Gameplay/L_GameplayDemo','roles':{'a':{'user':'npc_life_a_20261011'},'b':{'user':'npc_life_b_20261011'}},
              'server':{'container':demo.CONTAINER},'measurement':{'seconds':.6}}
    try:
        result=clients.run(scenario,out,demo.SERVER,inputs,timeout=seconds+15)
        demo.save(out/'clients.json',result)
    finally:
        stop.set();worker.join(timeout=30)
        if worker.is_alive():errors.append('monitor failed to stop')
        shutdown(out,rows,enabled,errors)
        demo.save(out/'requests.json',records(trace));demo.save(out/'started.json',records(starts))
        try:
            demo.save(out/'scene.json',scene(started));demo.save(out/'budget-final.json',budget.budget())
        except Exception as error:
            errors.append('final evidence: '+repr(error))
        demo.save(out/'errors.json',errors)
    assert not errors,errors
    assert all(r['replay']=='success' for r in result.values()), 'client replay failed'
    assert all((out/f'repair-{phase}.json').exists() for phase in (1,2)), 'repair stage missing'
    observed={r:events.read(out/r/'client.log') for r in ('a','b')}
    final=conversation(verify.authority_events(scene(started)),observed,records(trace))
    assert final is not None
    demo.save(out/'verdict.json',{'accepted':True,'conversation':final,'repairs':2,'budget':budget.budget()})


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--out',required=True);parser.add_argument('--seconds',type=int,default=560)
    args=parser.parse_args();run(OUT/args.out,args.seconds)
