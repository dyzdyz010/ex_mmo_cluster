"""只测试：单个真实玩家验证目标选择、UMG、系统输入法；NPC模型保持关闭。"""
import argparse
import json
import sys
from pathlib import Path
sys.dont_write_bytecode=True
import run


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--run',default='ui-01');args=parser.parse_args()
    out=run.BASE/args.run;out.mkdir(parents=True,exist_ok=False);(out/'b').mkdir()
    registrations=run.demo.rpc('GateServer.Npc.Registry.list()')
    assert not any(r['enabled'] and r['brain'] in ('life','llm') for r in registrations),'paid models must be stopped'
    assert not any(r['enabled'] and 'life' in r['params'] for r in registrations),'paid memory workers must be stopped'
    npc=run.demo.rpc(f'''[{{pid,_}}] = Registry.lookup(GateServer.NpcNames,{run.FIRST})
      %{{body: GateServer.Npc.Body.observe(pid) |> Map.take([:position,:tick,:entities,:outcomes,:dialogue])}}''')
    assert npc['body']['position'] is not None,'first NPC not entered'
    run.demo.save(out/'before.json',npc)
    position=npc['body']['position'];aim=[position[0],position[1]+.4,position[2]]
    t=run.demo.Timeline();t.add(25,'@place '+run.demo.NEAR);t.add(32,'@look_settled '+' '.join(map(str,aim)))
    t.click(36,'O');t.click(39,'Enter');t.add(40,'@click Dialogue/TargetButton')
    t.add(41,'@type 我来测试指定对象，先问候一下。');t.add(43,'@slate Enter')
    t.click(49,'Enter');t.add(50,'@click Dialogue/NearbyButton');t.add(51,'@type 这句取消，不应发送。')
    t.add(53,'@click Dialogue/CancelButton');t.click(58,'Enter');t.add(59,'@await_peer finish_manual')
    t.add(60,'Voxim.Dialogue.Status');t.add(61,'Voxel.Production.Status')
    inputs=out/'a-inputs.json';run.demo.save(inputs,{'classification':'Test-only','steps':t.steps})
    run.demo.save(out/'execution.json',{'server':run.server.execution_identity(run.demo.SERVER,run.demo.CONTAINER),
        'client_binary':run.clients.binary_digest(),'client_commit':run.subprocess.check_output(['git','rev-parse','HEAD'],cwd=run.CLIENT,text=True).strip()})
    scenario={'level':'/Game/Voxel/Gameplay/L_GameplayDemo','roles':{'a':{'user':'npc_life_a_20261011'}},'server':{'container':run.demo.CONTAINER}}
    records=run.clients.run(scenario,out,run.demo.SERVER,{'a':inputs},timeout=360)
    run.demo.save(out/'clients.json',records)
    assert records['a']['replay']=='success','UI replay incomplete'
    events=run.events.read(out/'a/client.log');sent=[e for e in events if e['event']=='dialogue.request']
    selected=next(e for e in sent if e['text']=='我来测试指定对象，先问候一下。')
    assert selected['target_id'] in [run.FIRST,51107598336],'actual aiming did not select an NPC'
    assert not any('这句取消' in e['text'] for e in sent),'cancel submitted text'
    for request in sent:
        results=[e for e in events if e['event']=='dialogue.result' and e['request_id']==request['request_id']]
        assert len(results)==1 and results[0]['reason']=='ok','UMG request failed'
    assert any(e['event']=='dialogue.status' for e in events),'CLI status missing'
    run.demo.save(out/'automated-verdict.json',{'accepted':True,'scope':'aimed NPC target, real UMG send/cancel, correlated results, CLI status',
        'requests':sent,'ime':'requires separate native observation and candidate-Enter evidence'})


if __name__=='__main__':main()
