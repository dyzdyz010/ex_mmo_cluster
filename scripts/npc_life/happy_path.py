"""只测试：三名既有 NPC 的植物散步 happy path，复用正式手动决策与既有取证。"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
import demo
import hourly_year as life


TASKS = [
    '我们邻里一起准备一条简短的植物散步路线。请结合自己的兴趣，在工坊附近选一个值得看的植物地点，'
    '亲自走到合适的观察位置，认识那里有什么，再与邻居简短分享地点和发现，记住有用的方法。'
    '已有足够观察就行动，做到就推进下一步，不必反复勘察同一处。',
    '现在请选一处邻居刚介绍过的植物地点，结合已有行走经验亲自去看看，与邻居交流你的新发现，'
    '最后记下这次学到的一点实用经验。可以沿用已经掌握的方法，完成后自行休息。'
]


def run(out, phase_seconds=600, phase_steps=24):
    """两个有限场景顺序运行；正常动作失败留在反馈中，外部服务错误停止且不重试。"""
    out = out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    progress = {'classification': 'Test-only', 'status': 'preparing', 'pid': os.getpid(),
                'started_at': life.now(), 'model': life.MODEL, 'effort': life.EFFORT,
                'phase': 0, 'completed_steps': 0, 'decision_tokens': 0,
                'phase_seconds': phase_seconds, 'phase_steps': phase_steps}
    life.atomic_json(out/'progress.json', progress)
    rows = demo.rpc('NpcServer.Registry.list()')
    rows = sorted([r for r in rows if r['name'] in life.ROLES], key=lambda r: list(life.ROLES).index(r['name']))
    if len(rows) != 3 or any('life' in r['params'] for r in rows):
        raise RuntimeError('expected three existing quiescent experiment NPCs')
    cids = [r['cid'] for r in rows]
    demo.save(out/'registry-before.json', rows)
    positions = demo.rpc('Map.new(' + json.dumps(cids) + ',fn cid -> [{pid,_}]=Registry.lookup(NpcServer.Names,cid);{cid,NpcServer.Body.observe(pid).position} end)')
    demo.save(out/'positions-before.json', positions)
    demo.save(out/'execution.json', {
        **demo.server.execution_identity(demo.SERVER, demo.CONTAINER),
        'npc_loaded_beam_md5': demo.rpc(demo.NPC_MD5),
        'driver_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()})
    goals = life.goals_for(rows)
    demo.save(out/'protocol.json', {'scenario': '邻里植物散步', 'tasks': TASKS, 'cids': cids,
                                  'phase_seconds': phase_seconds, 'phase_steps': phase_steps,
                                  'scope': '连续既有人生的短场景；真实模型、World、Body、记忆，无替身，无故障注入。',
                                  'evidence': '观察实际移动、已接纳对话与写入笔记，人工阅读是否使用经验；不做理论归因。',
                                  'time': '真实时间；steps 中沿用的 hour 字段只表示阶段编号，不表示模拟小时。'})

    # 桥接是已有服务；场景只使用它，不按每次实验重建或重试。
    with urllib.request.urlopen('http://127.0.0.1:27365/health', timeout=2) as response:
        health = json.load(response)
    demo.save(out/'bridge-process.json', health)

    trace_prefix = 'happy-' + life.run_id(out)
    enabled = []
    trace_started = False
    errors = []
    baseline_memory = None
    origin = datetime.now(timezone.utc)
    try:
        trace = (Path(__file__).with_name('decision_trace.exs')).read_text(encoding='utf8')
        trace = trace.replace('/demo/long-horizon-', '/demo/' + trace_prefix + '-')
        demo.save(out/'trace-start.json', demo.server.rpc(demo.SERVER, demo.CONTAINER, trace))
        trace_started = True
        for row in rows:
            params = {'goal': goals[row['cid']] + '当前参加邻里植物散步，具体目标在step_context.task中。',
                      'tools': {'1': '镐'}, 'skills': ['gather', 'travel', 'build'],
                      'life': {'url': demo.URL}, 'cadence': 'manual', 'max_requests_per_hour': 'unlimited'}
            life.register(row, 'life', params, positions[str(row['cid'])])
            enabled.append(row)
        deadline = time.monotonic() + 120
        while True:
            states = [life.runtime(cid)['life'] for cid in cids]
            if any(s['error'] for s in states):
                raise RuntimeError('Life initialization error')
            if all(s['state'] is not None for s in states):
                break
            if time.monotonic() >= deadline:
                raise TimeoutError('Life initialization')
            time.sleep(.5)
        baseline_memory, memory = life.memory_usage(cids)
        demo.save(out/'memory-before.json', memory)
        life.checkpoint(out, 0, cids)

        def account(answer):
            result = answer['result']
            response = result[1] if result[0] == 'ok' else result[2] if len(result) > 2 else None
            if isinstance(response, dict) and isinstance(response.get('usage'), dict):
                progress['decision_tokens'] += response['usage']['total_tokens']
            else:
                progress['usage_unknown_requests'] = progress.get('usage_unknown_requests', 0) + 1
            life.atomic_json(out/'progress.json', progress)

        for phase, task in enumerate(TASKS, 1):
            deadline = time.monotonic() + phase_seconds
            remaining = phase_steps
            ready = {cid: 0.0 for cid in cids}
            heard = {cid: [] for cid in cids}
            while remaining and time.monotonic() < deadline:
                if (out/'STOP').exists():
                    raise InterruptedError('operator stopped experiment')
                acted = False
                for cid in life.actor_order(cids, phase):
                    if not remaining or time.monotonic() >= deadline:
                        break
                    if time.monotonic() < ready[cid] and not life.addressed_since(cid, heard[cid]):
                        continue
                    progress.update(status='running', phase=phase, active_cid=cid, updated_at=life.now())
                    life.atomic_json(out/'progress.json', progress)
                    context = {'experiment': life.run_id(out), 'phase': phase, 'task': task,
                               'time_semantics': '真实时间的短场景，没有模拟年份。'}
                    proof = life.step(cid, phase, out, origin, account,
                                      sequence=progress['completed_steps'] + 1, context=context)
                    ready[cid] = life.next_decision_at(proof, time.monotonic())
                    heard[cid] = proof['heard']
                    progress['completed_steps'] += 1
                    progress.update(last_tool=proof['calls'][0]['name'], updated_at=life.now())
                    life.atomic_json(out/'progress.json', progress)
                    print(json.dumps({k: progress[k] for k in ['phase', 'completed_steps', 'active_cid', 'last_tool']}, ensure_ascii=False), flush=True)
                    remaining -= 1
                    acted = True
                if not acted:
                    time.sleep(2)
            life.checkpoint(out, phase, cids)
        progress['status'] = 'completed'
    except BaseException as error:
        progress['status'] = 'stopped' if isinstance(error, InterruptedError) else 'failed'
        errors.append({'type': type(error).__name__, 'message': str(error)})
    finally:
        if enabled:
            try:
                total = life.checkpoint(out, progress['phase'], cids,
                                        flush=progress['status'] == 'completed', suffix='-final')
                if baseline_memory is not None:
                    progress['memory_tokens_since_start'] = total - baseline_memory
            except Exception as error:
                errors.append({'type': 'checkpoint', 'message': str(error)})
        for row in enabled:
            try:
                position = life.runtime(row['cid'])['body']['position']
                life.register(row, row['brain'], row['params'], position)
            except Exception as error:
                errors.append({'type': 'restore', 'cid': row['cid'], 'message': str(error)})
        if trace_started:
            try:
                demo.rpc(':erlang.trace_pattern({NpcServer.Http,:request,2},false,[:global]); :erlang.trace(:all,false,[:call]); if pid=Process.whereis(:npc_long_horizon_trace),do: Process.exit(pid,:kill); :ok')
            except Exception as error:
                errors.append({'type': 'trace_stop', 'message': str(error)})
        progress.update(errors=errors, finished_at=life.now(), bridge_pid=health['pid'],
                        decision_trace=str(demo.SERVER/(trace_prefix+'-requests.jsonl')))
        if errors and progress['status'] == 'completed':
            progress['status'] = 'failed_cleanup'
        life.atomic_json(out/'progress.json', progress)
    if errors:
        raise SystemExit(json.dumps(errors, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    run(args.out)
