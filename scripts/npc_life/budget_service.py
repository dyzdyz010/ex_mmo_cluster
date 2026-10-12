"""只测试：本任务18908记忆与27361/27363 Demo的单次预算接线，不替换镜像或重建数据。"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

import demo
import service
import budget_proxy

NAME = 'voxim-npc-budget-20261011'
URL = f'http://{NAME}:8080'
DIRECTORY = demo.ROOT / '.demo/observe/npc-autonomy-20261011/budget'
BASELINE = 2010947
CAP = 3000000
CIDS = [607440080896, 51107598336]


def docker(*args, env=None):
    return subprocess.check_output(['docker', *args], env=env, text=True, encoding='utf8').strip()


def metadata(name):
    # 完整环境只驻内存；调用方保存证据时仅挑公开身份。
    return json.loads(docker('inspect', name))[0]


def budget(action='status'):
    return json.loads(docker('exec', NAME, 'python', '/probe/budget_proxy.py', action, '--db', '/ledger/ledger.db'))


def memory_stats(cid):
    with urllib.request.urlopen(service.API+f'/v1/default/banks/npc-life-{cid}/stats', timeout=10) as response:
        return json.load(response)


def configure(old, overrides, extra):
    name = old['Name'].lstrip('/')
    values = dict(item.split('=', 1) for item in old['Config']['Env'])
    values.update(overrides)
    docker('stop', '--time', '15', name)
    docker('rm', name)
    command = ['run', '-d', '--name', name, '--network', service.NETWORK, *extra]
    for key in values:
        command += ['-e', key]
    # 固定旧镜像，继续使用其原始入口；只覆盖已核验的命令。
    docker(*command, old['Image'], *old['Config']['Cmd'], env={**os.environ, **values})
    assert metadata(name)['Image'] == old['Image'], 'image changed during endpoint wiring'


def setup(out):
    out.mkdir(parents=True, exist_ok=False)
    # 先对已经付费且留有usage的真实完整输入核验计数，失败不得改容器或启用人生后端。
    count_preflight(out)
    service.preflight(required=True)
    game, memory = metadata(demo.CONTAINER), metadata(service.NAME)
    assert game['HostConfig']['PortBindings'] == {
        '27361/tcp': [{'HostIp':'127.0.0.1','HostPort':'27361'}],
        '27363/udp': [{'HostIp':'127.0.0.1','HostPort':'27363'}]}
    mounts = game['Mounts']
    assert len(mounts)==1 and Path(mounts[0]['Source']).resolve()==demo.SERVER.resolve() and mounts[0]['Destination']=='/demo'
    assert game['Config']['Cmd']==['sh','/demo/start.sh'] and game['Config']['User']=='0:0'
    registry = demo.rpc('NpcServer.Registry.list()')
    assert {r['cid'] for r in registry} == set(CIDS)
    assert all(r['brain']=='settler' and 'life' not in r['params'] for r in registry), 'paid owner still running'
    demo.save(out/'registry-before.json', registry)
    for cid in CIDS:
        stats=memory_stats(cid)
        demo.save(out/f'memory-before-{cid}.json', stats)
        assert stats['pending_operations']==stats['pending_consolidation']==0, 'memory work not drained'
    before = demo.rpc('Map.new([607440080896,51107598336], fn cid -> {cid,DataService.NpcMemory.get(cid,"life","state")} end)')
    demo.save(out/'stored-before.json',before)
    DIRECTORY.mkdir(parents=True, exist_ok=False)
    demo.save(DIRECTORY/'authorization.json', {'prior_actual_tokens':BASELINE, 'old_cap':2000000,
        'additional_authorized_tokens':1000000, 'cap':CAP, 'available_tokens':CAP-BASELINE,
        'source':'用户明确回复：追加 1,000,000 token；旧超额继续计入。'})
    upstream=service.config()['HINDSIGHT_API_LLM_BASE_URL']+'/responses'
    docker('run','-d','--name',NAME,'--user','0:0','--network',service.NETWORK,
        '-v',str(Path(__file__).parent.resolve())+':/probe:ro','-v',str(DIRECTORY)+':/ledger',
        '-e','NPC_BUDGET_UPSTREAM','--entrypoint','python',service.IMAGE,
        '/probe/budget_proxy.py','serve','--db','/ledger/ledger.db','--baseline',str(BASELINE),'--cap',str(CAP),
        env={**os.environ,'NPC_BUDGET_UPSTREAM':upstream})
    deadline=time.monotonic()+15
    while True:
        try:
            initial=budget();break
        except subprocess.CalledProcessError:
            if time.monotonic()>deadline:raise
            time.sleep(.5)
    assert initial['actual_tokens']==BASELINE and not initial['halted']
    settings={'HINDSIGHT_API_LLM_BASE_URL':URL+'/memory/v1',
              'HINDSIGHT_API_LLM_TIMEOUT':'180','HINDSIGHT_API_LLM_MAX_RETRIES':'0',
              'HINDSIGHT_API_LLM_OUTPUT_LANGUAGE':'English'}
    # 当前固定实例无分操作endpoint/timeout/retry覆盖；发现覆盖必须先显式解释，不能漏过预算出口。
    keys=[e.split('=',1)[0] for e in memory['Config']['Env']]
    assert not any('_LLM_' in k and any(s in k for s in ['RETAIN_','REFLECT_','CONSOLIDATION_','MENTAL_MODEL_REFRESH_']) for k in keys)
    configure(memory, settings, ['--shm-size=1g','-p','127.0.0.1:18908:8888',
        '-v',service.NAME+'-pg:/home/hindsight/.pg0','-v',service.NAME+'-hf:/home/hindsight/.cache/huggingface'])
    service.ready(180)
    previous=(demo.SERVER/'identity.json').stat().st_mtime_ns
    configure(game, {'NPC_LLM_URL':URL+'/decision/v1/responses','NPC_LLM_TIMEOUT_MS':'180000'},
        ['--user','0:0','-p','127.0.0.1:27361:27361/tcp','-p','127.0.0.1:27363:27363/udp',
         '-v',str(demo.SERVER)+':/demo'])
    deadline=time.monotonic()+120
    while (demo.SERVER/'identity.json').stat().st_mtime_ns==previous:
        if time.monotonic()>deadline:raise TimeoutError('Demo readiness')
        time.sleep(1)
    after=demo.rpc('Map.new([607440080896,51107598336], fn cid -> {cid,DataService.NpcMemory.get(cid,"life","state")} end)')
    assert before==after, 'wiring changed stored NPC state'
    demo.save(out/'stored-after.json',after)
    # 冷重建后读取实际生效配置，而非以启动参数充当接线证据。
    actual=demo.rpc('Map.new(["NPC_LLM_URL","NPC_LLM_TIMEOUT_MS"],fn k -> {k,System.get_env(k)} end)')
    assert actual['NPC_LLM_URL']==URL+'/decision/v1/responses' and actual['NPC_LLM_TIMEOUT_MS']=='180000'
    effective=json.loads(docker('exec',service.NAME,'python','-c',
        'import json;from hindsight_api.config import get_config;c=get_config();print(json.dumps({k:getattr(c,k) for k in ["llm_base_url","llm_timeout","llm_max_retries","llm_output_language"]}))'))
    assert effective=={'llm_base_url':URL+'/memory/v1','llm_timeout':180.0,'llm_max_retries':0,'llm_output_language':'English'}
    demo.save(out/'wiring.json',{'classification':'Test-only','decision':actual,'memory':effective,
        'server_image':game['Image'],'memory_image':memory['Image'],'budget':budget()})


def count_preflight(out):
    source=demo.ROOT/'.demo/observe/npc-dialogue-20261011/dual-02/requests.json'
    frozen=json.loads(source.read_text(encoding='utf8'))[0]
    config=service.config()
    upstream=config['HINDSIGHT_API_LLM_BASE_URL']+'/responses'
    proxy=budget_proxy.Proxy(None,upstream)
    body={k:v for k,v in frozen['request'].items() if k in proxy.COUNT_FIELDS}
    result={'source':str(source.relative_to(demo.ROOT)),'recorded_input_tokens':frozen['usage']['input_tokens'],
            'generation_requests':0,'accepted':False}
    try:
        response=proxy.post(upstream+'/input_tokens',body,'Bearer '+config['HINDSIGHT_API_LLM_API_KEY'])
        result['counted_input_tokens']=response.get('input_tokens')
        result['accepted']=response.get('object')=='response.input_tokens' and response.get('input_tokens')==result['recorded_input_tokens']
    except Exception as error:
        result['error']=type(error).__name__
    demo.save(out/'counter-contract.json',result)
    if not result['accepted']:raise RuntimeError('provider token count contract not verified; paid setup stopped')


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['setup','status','close']);parser.add_argument('--out',default='budget-wiring-01')
    args=parser.parse_args()
    if args.action=='setup':setup(demo.ROOT/'.demo/observe/npc-autonomy-20261011'/args.out)
    else:print(json.dumps(budget(args.action)))
