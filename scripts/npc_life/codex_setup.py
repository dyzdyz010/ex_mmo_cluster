"""只测试：在固定独立 Demo 接通本机登录与 Hindsight，保留原存档。"""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
import demo
import service
from budget_service import metadata, configure
from long_horizon import packed
from hourly_year import MODEL, EFFORT, ROLES, LIFE_GOAL


def setup(out, cli, resume=False):
    out = out.resolve()
    if resume:
        memory = metadata(service.NAME)
        values = dict(item.split('=',1) for item in memory['Config']['Env'])
        assert values['HINDSIGHT_API_LLM_BASE_URL'] == 'http://host.docker.internal:27365/memory/v1'
        key = values['HINDSIGHT_API_LLM_API_KEY']
        before = json.loads((out/'stored-before.json').read_text(encoding='utf8'))
        process = type('OwnedBridge', (), json.loads((out/'bridge-process.json').read_text()))()
    else:
        out.mkdir(parents=True, exist_ok=False)
        service.preflight(required=True)
        rows = demo.rpc('NpcServer.Registry.list()')
        if {row['cid'] for row in rows} != {607440080896, 51107598336} or any(row['brain'] != 'settler' or 'life' in row['params'] for row in rows):
            raise RuntimeError('owned Demo registrations are not quiescent')
        demo.save(out/'registry-before.json', rows)
        before = demo.rpc('Map.new([607440080896,51107598336], fn cid -> {cid,DataService.NpcMemory.get(cid,"life","state")} end)')
        demo.save(out/'stored-before.json', before)
        key = secrets.token_urlsafe(32)
        bridge_out = out/'bridge'
        logs = (out/'bridge-process.log').open('w', encoding='utf8')
        process = subprocess.Popen([sys.executable, '-B', str(Path(__file__).with_name('codex_bridge.py')),
                                    '--out', str(bridge_out), '--cli', str(cli)],
                                   stdout=logs, stderr=logs, env={**os.environ, 'NPC_CODEX_BRIDGE_KEY': key},
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        demo.save(out/'bridge-process.json', {'pid': process.pid, 'port': 27365, 'model': MODEL, 'effort': EFFORT})
        for _ in range(30):
            try:
                with urllib.request.urlopen('http://127.0.0.1:27365/health', timeout=2) as response:
                    assert json.load(response)['pid'] == process.pid
                break
            except OSError:
                if process.poll() is not None:
                    raise RuntimeError('bridge failed to start')
                time.sleep(.5)
        else:
            raise TimeoutError('bridge readiness')
        probe = {'model': MODEL, 'reasoning': {'effort': EFFORT}, 'input': 'Choose look.',
                 'tools': [{'type': 'function', 'name': 'look', 'description': 'observe',
                            'parameters': {'type': 'object', 'properties': {}, 'required': [], 'additionalProperties': False}}],
                 'tool_choice': 'required'}
        request = urllib.request.Request('http://127.0.0.1:27365/decision/v1/responses',
                                        data=json.dumps(probe).encode(),
                                        headers={'Content-Type': 'application/json', 'Authorization': 'Bearer '+key})
        with urllib.request.urlopen(request, timeout=180) as response:
            answer = json.load(response)
        assert answer['output'][0]['name'] == 'look'
        demo.save(out/'decision-preflight.json', answer)
        memory = metadata(service.NAME)
        # 只替换本任务记忆容器的出口，沿用原镜像与两个数据卷。
        configure(memory, {'HINDSIGHT_API_LLM_BASE_URL': 'http://host.docker.internal:27365/memory/v1',
                           'HINDSIGHT_API_LLM_API_KEY': key, 'HINDSIGHT_API_LLM_MODEL': MODEL,
                           'HINDSIGHT_API_LLM_REASONING_EFFORT': EFFORT,
                           'HINDSIGHT_API_LLM_TIMEOUT': '180', 'HINDSIGHT_API_LLM_MAX_RETRIES': '0',
                           'HINDSIGHT_API_LLM_OUTPUT_LANGUAGE': 'English'},
                  ['--shm-size=1g', '-p', '127.0.0.1:18908:8888',
                   '-v', service.NAME+'-pg:/home/hindsight/.pg0', '-v', service.NAME+'-hf:/home/hindsight/.cache/huggingface'])
        service.ready(180)
    bank = 'codex-preflight-facts03-'+out.name
    code = f'''config = %{{url: "{demo.URL}", bank: "{bank}"}}
      {{:ok,_}} = NpcServer.Life.Hindsight.ensure(config,"CLI transport probe")
      retained = NpcServer.Life.Hindsight.retain(config,[%{{"id" => "transport-probe", "text" => "On October 12, 2026, Mara visited the North library and borrowed a blue atlas from librarian Ivo. Mara promised Ivo to return the atlas tomorrow.", "at_ms" => System.system_time(:millisecond)}}])
      %{{retained: retained, status: NpcServer.Life.Hindsight.status(config)}}'''
    result = demo.rpc(code)
    demo.save(out/'hindsight-preflight-facts03.json', result)
    if result['retained'][0] != 'ok':
        raise RuntimeError('independent Hindsight preflight failed')
    game = metadata(demo.CONTAINER)
    previous = (demo.SERVER/'identity.json').stat().st_mtime_ns
    configure(game, {'NPC_LLM_URL': 'http://host.docker.internal:27365/decision/v1/responses',
                     'NPC_LLM_KEY': key, 'NPC_LLM_MODEL': MODEL, 'NPC_LLM_EFFORT': EFFORT,
                     'NPC_LLM_TIMEOUT_MS': '180000'},
              ['--user', '0:0', '-p', '127.0.0.1:27361:27361/tcp', '-p', '127.0.0.1:27363:27363/udp',
               '-v', str(demo.SERVER)+':/demo'])
    deadline = time.monotonic()+120
    while (demo.SERVER/'identity.json').stat().st_mtime_ns == previous:
        if time.monotonic() > deadline:
            raise TimeoutError('Demo readiness')
        time.sleep(1)
    after = demo.rpc('Map.new([607440080896,51107598336], fn cid -> {cid,DataService.NpcMemory.get(cid,"life","state")} end)')
    demo.save(out/'stored-after.json', after)
    assert before == after, 'stored Life state changed during endpoint wiring'
    params = {'goal': '我是知衡，学者。'+LIFE_GOAL, 'tools': {'1': '镐'},
              'cadence': 'manual', 'max_requests_per_hour': 'unlimited', 'skills': ['gather', 'travel', 'build']}
    scholar = demo.ok(demo.rpc(f'''case NpcServer.Registry.put("知衡",%{{scene_id: 1, spawn: {{64.5,418.0,-516.5}}, brain: "llm",params: {packed(params)}}}) do
      {{:ok,row}} -> {{:ok,Map.take(row,[:cid])}}; error -> error end'''))
    demo.save(out/'scholar.json', scholar)
    demo.save(out/'registry-after.json', demo.rpc('NpcServer.Registry.list()'))
    demo.save(out/'manifest.json', {'status': 'wired', 'model': MODEL, 'effort': EFFORT,
                                  'bridge_pid': process.pid, 'roles': ROLES, 'scholar_cid': scholar['cid'],
                                  'game_image_id': game['Image'], 'memory_image_id': memory['Image']})
    print(json.dumps({'status': 'wired', 'scholar_cid': scholar['cid'], 'bridge_pid': process.pid}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--resume', action='store_true')
    args = parser.parse_args()
    setup(args.out, args.cli, args.resume)
