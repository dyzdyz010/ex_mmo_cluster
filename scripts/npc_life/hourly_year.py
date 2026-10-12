"""只测试：正式 Registry/Body/Runtime/Llm 上的小时决策采样，不加速 World 物理时钟。"""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True
MODEL = 'gpt-6.1-sol'
EFFORT = 'medium'
TIME_SEMANTICS = ('Real-time hourly opportunities, no accelerated clock. Body, World events and emotion '
                  'retain authoritative real time. 8760 completed hours requires 365 days online; '
                  'decision rounds do not prove physical survival. Nutrition is consumed by repair, not basal hunger.')
LIFE_GOAL = (
    '我的长期目标是：好好探索、了解这个世界，好好生活，好好建设，好好学习。我要为了美好而建设，'
    '让栖居之处更宜居，让自己和邻居的生活更好，也珍惜这个世界已有的美好。'
    '我会自主选择值得探索的问题、值得学习的本领和能改善生活的小目标，通过观察、行动、尝试与交流积累认识。'
    '世界平静时也有值得做的事，不必等到发生破坏或别人下指令才开始生活。'
    '我可以主动认识邻居、分享发现、请教和讨论合作，也可以表达不同意见。'
    '旧的守望或休息计划可以根据这个长期目标修订；完成一件事或休息之后，再选择一个具体、可行的下一步。'
    '把重要打算保存为计划，记下值得保留的经历，根据真实结果学习和调整。'
    '用简洁中文交谈，不反复问已回答的问题。提议、承诺与完成有区别，资源和行为结果以当前World为准；'
    '需要材料时自己通过正常采集取得，不凭空补给。'
)
ROLES = {
    'LifeBuilder': ('建设者', '我侧重宜居与实际改善，有自己的工坊。'),
    '松岚': ('探索者', '我侧重发现世界、尝试探索并分享真实发现。'),
    '知衡': ('学者', '我侧重观察、验证、请教与交流学习，不把猜想说成事实。')
}


def actor_order(cids, hour):
    """全部角色每小时轮换先手。"""
    offset = (hour - 1) % len(cids)
    return cids[offset:] + cids[:offset]


def run_id(out):
    """运行身份包含实验目录，不能与旧实验同名 run 文件冲突。"""
    return out.parent.name + '-' + out.name


def step_tag(out, hour, cid, sequence):
    """每次许可有独立序号；同小时同角色的后续行动不会复用调用身份。"""
    return f'{run_id(out)}/{hour}/{cid}/{sequence}'


def next_decision_at(proof, completed_at):
    """完成行动即继续；只有模型请求的等待才推迟该角色下一次许可。"""
    call = proof['calls'][0]
    if call['name'] == 'wait':
        return completed_at + json.loads(call['arguments'])['seconds']
    return completed_at


def addressed_since(cid, heard):
    """是否有新直接发言由正式 Dialogue 契约判定，不把旁听或本人回声当唤醒。"""
    import demo
    from long_horizon import packed
    return demo.rpc(f'''[{{pid,_}}] = Registry.lookup(NpcServer.Names,{cid})
      seen = {packed(heard)}
      Enum.any?(NpcServer.Body.observe(pid).dialogue,fn speech ->
        NpcServer.Dialogue.direct?(speech,{cid}) and
          (speech |> Jason.encode!() |> Jason.decode!()) not in seen end)''')


def prior_tokens():
    """沿用旧轮已知账本，加此前本机预检与全部已完成 CLI 用量，不重置成本。"""
    root = Path(__file__).resolve().parents[2]
    total = 61306557 + 22927
    for path in (root/'.demo/observe/npc-codex-20261012/wiring-01').glob('bridge*/calls.jsonl'):
        for line in path.read_text(encoding='utf8').splitlines():
            call = json.loads(line)
            for event in call['events']:
                if event['type'] == 'turn.completed':
                    total += event['usage']['input_tokens'] + event['usage']['output_tokens']
    return total


def goals_for(rows):
    return {row['cid']: '我是' + row['name'] + '，我的兴趣角色是' + ROLES[row['name']][0] + '。' +
            ROLES[row['name']][1] + '我的邻居是' + '、'.join(name for name in ROLES if name != row['name']) + '。' + LIFE_GOAL
            for row in rows}


def step_complete(response, command_ids, outcomes):
    """验收侧核对模型身份和同调用终态；被拒动作是已结束的真实经历。"""
    if (response.get('model') != MODEL or response.get('reasoning', {}).get('effort') != EFFORT
            or response.get('status') != 'completed'):
        raise ValueError('model, effort or response status mismatch')
    usage = response.get('usage')
    if not isinstance(usage, dict) or not isinstance(usage.get('total_tokens'), int):
        raise ValueError('missing actual model usage')
    calls = [r for r in response.get('output', []) if r.get('type') == 'function_call']
    if len(calls) != 1:
        raise ValueError('expected exactly one function call')
    if calls[0]['name'] == 'wait':
        if command_ids:
            raise ValueError('wait unexpectedly created a Body command')
        return True
    if not command_ids:
        raise ValueError('non-wait response has no Body command')
    for outcome in outcomes:
        if outcome.get('id') not in command_ids:
            continue
        reason = outcome.get('reason')
        kind = reason[0] if isinstance(reason, list) and reason else reason
        if (kind == 'memory_unavailable' or outcome.get('memory_error')
                or (outcome.get('data') or {}).get('memory_error')):
            raise ValueError('memory persistence unavailable during command')
    terminal = {r['id'] for r in outcomes if r.get('status') in ('done', 'rejected') and isinstance(r.get('id'), int)}
    return set(command_ids) <= terminal


def hour_complete(hour, cids, rows):
    """每小时必须有全部不同角色的一次完整证据，不能用前小时或重复角色填数。"""
    return (len(rows) == len(cids) and {r['cid'] for r in rows} == set(cids)
            and all(r['hour'] == hour and r['completed'] for r in rows))


def atomic_json(path, value):
    path = Path(path)
    tmp = path.with_suffix(path.suffix + '.tmp')
    with tmp.open('w', encoding='utf8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, path)


def append_json(path, value):
    with Path(path).open('a', encoding='utf8') as stream:
        stream.write(json.dumps(value, ensure_ascii=False) + '\n')
        stream.flush()
        os.fsync(stream.fileno())


def now():
    return datetime.now(timezone.utc).isoformat()


def runtime(cid):
    import demo
    return demo.rpc(f'''[{{pid,_}}] = Registry.lookup(NpcServer.Names,{cid})
      {{:ok,life}} = NpcServer.Life.observe({cid})
      %{{body: NpcServer.Body.observe(pid), life: Map.drop(life,[:cache,:hindsight])}}''')


def register(row, brain, params, position):
    import demo
    from long_horizon import packed
    result = demo.ok(demo.rpc(f'''case NpcServer.Registry.put({packed(row['name'])},
      %{{scene_id: {row['scene_id']}, spawn: List.to_tuple({packed(position)}),
         brain: {packed(brain)}, params: {packed(params)}}}) do
        {{:ok,r}} -> {{:ok,Map.take(r,[:cid])}}; e -> e end'''))
    if result['cid'] != row['cid']:
        raise RuntimeError('permanent NPC identity changed')


def step(cid, hour, out, origin, on_response=lambda _answer: None, sequence=1, context=None):
    import demo
    from long_horizon import packed
    tag = step_tag(out, hour, cid, sequence)
    if context is None:
        context = {'experiment': run_id(out), 'simulated_hour': hour, 'target_hours': 8760,
                   'simulated_calendar': (origin + timedelta(hours=hour-1)).isoformat(),
                   'time_semantics': TIME_SEMANTICS}
    # observer 为本次 RPC 进程；关联 tag 不可复用，HTTP 错误不重试或自动重新发许可。
    answer = demo.rpc(f'''[{{pid,_}}] = Registry.lookup(NpcServer.Names,{cid})
      tag = {packed(tag)}
      case NpcServer.Body.step(pid,self(),tag,{packed(context)}) do
        :ok -> receive do
          {{:npc_llm_step,^tag,result}} -> %{{tag: tag, result: result}}
        after 240000 -> %{{tag: tag, result: {{:error,:step_result_timeout}}}} end
        error -> %{{tag: tag, result: error}}
      end''')
    append_json(out/'model-results.jsonl', {'cid': cid, 'hour': hour, 'at': now(), **answer})
    on_response(answer)
    if answer.get('tag') != tag or answer['result'][0] != 'ok':
        raise RuntimeError(f'model step failed: hour={hour} cid={cid} result={answer.get("result")}')
    _, response, command_ids = answer['result']
    deadline = time.monotonic() + 180
    while True:
        snapshot = runtime(cid)
        if snapshot['life']['error']:
            raise RuntimeError(f'Life error: cid={cid} {snapshot["life"]["error"]}')
        if step_complete(response, command_ids, snapshot['body']['outcomes']):
            break
        if time.monotonic() > deadline:
            raise TimeoutError(f'Body terminal missing: cid={cid} ids={command_ids}')
        time.sleep(.25)
    result = {'cid': cid, 'hour': hour, 'sequence': sequence, 'tag': tag, 'completed': True, 'at': now(),
              'usage': response['usage'], 'calls': [r for r in response['output'] if r['type'] == 'function_call'],
              'command_ids': command_ids,
              'outcomes': [r for r in snapshot['body']['outcomes'] if r['id'] in command_ids],
              'position': snapshot['body']['position'], 'heard': snapshot['body']['dialogue'],
              'life': snapshot['life']}
    append_json(out/'steps.jsonl', result)
    return result


def memory_usage(cids):
    import demo
    state = demo.rpc('''Map.new(CID_LIST, fn cid ->
      {:ok,memory} = NpcServer.Life.Hindsight.status(%{url: "http://voxim-npc-life-loop-20261011:8888",bank: "npc-life-#{cid}"})
      {cid,memory} end)'''.replace('CID_LIST', json.dumps(cids)))
    return sum(v['input_tokens'] + v['output_tokens'] for row in state.values() for v in row['usage'].values()), state


def checkpoint(out, hour, cids, *, flush=False, suffix=''):
    import demo
    if flush:
        for cid in cids:
            demo.ok(demo.rpc(f'NpcServer.Life.flush({cid})'))
        deadline = time.monotonic() + 600
        while True:
            rows = [runtime(cid)['life'] for cid in cids]
            if any(row['error'] for row in rows):
                raise RuntimeError('Life checkpoint error')
            if all(row['job'] is None and row['pending_fragments'] == 0 and row['unsaved_speech'] == 0 for row in rows):
                break
            if time.monotonic() > deadline:
                raise TimeoutError('memory checkpoint did not drain')
            time.sleep(2)
    code = '''Map.new(CID_LIST, fn cid ->
      {:ok,life} = NpcServer.Life.observe(cid)
      {:ok,memory} = NpcServer.Life.Hindsight.status(%{url: "http://voxim-npc-life-loop-20261011:8888",bank: "npc-life-#{cid}"})
      {cid,%{life: life,memory: memory,working: NpcServer.Memory.working_context(DataService.NpcMemory,cid)}} end)'''
    state = demo.rpc(code.replace('CID_LIST', json.dumps(cids)))
    world = demo.rpc('VoxelRegion.World.material_snapshot(VoxelRegion.World,' + json.dumps(cids) + ',[{61,416,-517}])')
    destination = out/f'checkpoint-{hour:05d}{suffix}.json'
    if destination.exists():
        raise RuntimeError('refuse checkpoint evidence overwrite')
    demo.save(destination, {'hour': hour, 'at': now(), 'npcs': state, 'world': world})
    totals = sum(v['input_tokens'] + v['output_tokens'] for row in state.values() for v in row['memory']['usage'].values())
    return totals


def run(out, hours=8760):
    import demo
    from long_horizon import packed
    if hours < 8760:
        raise ValueError('the authorized year experiment requires at least 8760 hourly opportunities')
    out = Path(out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    origin = datetime.now(timezone.utc)
    progress = {'classification': 'Test-only', 'status': 'preparing', 'pid': os.getpid(), 'started_at': now(),
                'target_hours': hours, 'completed_hours': 0, 'completed_steps': 0,
                'model': MODEL, 'effort': EFFORT, 'time_semantics': TIME_SEMANTICS,
                'token_cap': None, 'prior_actual_tokens': prior_tokens(), 'prior_usage_unknown_requests': 1,
                'model_preflight_tokens': 0, 'completed_decision_rounds': 0,
                'decision_tokens': 0, 'memory_tokens_since_start': 0}
    atomic_json(out/'progress.json', progress)
    rows = demo.rpc('NpcServer.Registry.list()')
    if {r['name'] for r in rows} != set(ROLES) or any('life' in r['params'] or
            (r['brain'] != 'settler' and not (r['name'] == '知衡' and r['brain'] == 'llm' and r['params'].get('cadence') == 'manual')) for r in rows):
        raise RuntimeError('expected three quiescent owned NPC registrations')
    rows = sorted(rows, key=lambda row: list(ROLES).index(row['name']))
    cids = [row['cid'] for row in rows]
    goals = goals_for(rows)
    demo.save(out/'registry-before.json', rows)
    positions = demo.rpc('Map.new(' + json.dumps(cids) + ',fn cid -> [{pid,_}]=Registry.lookup(NpcServer.Names,cid);{cid,NpcServer.Body.observe(pid).position} end)')
    demo.save(out/'positions-before.json', positions)
    effective = demo.rpc('Map.new(["NPC_LLM_MODEL","NPC_LLM_EFFORT"],fn k -> {k,System.get_env(k)} end)')
    if effective != {'NPC_LLM_MODEL': MODEL, 'NPC_LLM_EFFORT': EFFORT}:
        raise RuntimeError('running model configuration mismatch')
    identity = demo.server.execution_identity(demo.SERVER, demo.CONTAINER)
    identity.update(driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                    driver_path=str(Path(__file__).resolve()), npc_loaded_beam_md5=demo.rpc(demo.NPC_MD5))
    demo.save(out/'execution.json', identity)
    trace_prefix = 'year-' + run_id(out)
    if not all(c.isalnum() or c == '-' for c in trace_prefix):
        raise ValueError('run id must be letters, digits or hyphens')
    for suffix in ('requests.jsonl', 'started.jsonl'):
        if (demo.SERVER/(trace_prefix+'-'+suffix)).exists():
            raise RuntimeError('refuse to overwrite an earlier model trace')
    demo.save(out/'protocol.json', {'hours': hours, 'cids': cids, 'goals': goals,
                                  'roles': {row['cid']: ROLES[row['name']][0] for row in rows}, 'time_semantics': TIME_SEMANTICS,
                                  'no_player_prompt': True, 'no_resource_injection': True,
                                  'decision_trace': str(demo.SERVER/(trace_prefix+'-requests.jsonl'))})
    trace_started = False
    enabled = []
    errors = []
    baseline_memory = None
    try:
        code = (Path(__file__).parent/'decision_trace.exs').read_text(encoding='utf8').replace('/demo/long-horizon-', '/demo/'+trace_prefix+'-')
        demo.save(out/'trace-start.json', demo.server.rpc(demo.SERVER,demo.CONTAINER,code))
        trace_started = True
        for row in rows:
            params = {'goal': goals[row['cid']], 'tools': {'1': '镐'}, 'skills': ['gather','travel','build'],
                      'life': {'url': demo.URL}, 'max_requests_per_hour': 'unlimited', 'cadence': 'manual'}
            register(row, 'life', params, positions[str(row['cid'])])
            enabled.append(row)
        deadline = time.monotonic() + 180
        while True:
            states = [runtime(cid)['life'] for cid in cids]
            if any(s['error'] for s in states):
                raise RuntimeError('Life initialization failed')
            if all(s['state'] is not None and s['job'] is None for s in states):
                break
            if time.monotonic() > deadline:
                raise TimeoutError('Life initialization readiness')
            time.sleep(1)
        # 新角色的独立 bank 由 Life 初始化创建；其 readiness 后才读取三人用量基线。
        baseline_memory, memory_before = memory_usage(cids)
        demo.save(out/'memory-before.json', memory_before)
        checkpoint(out, 0, cids)
        origin = datetime.now(timezone.utc)
        progress.update(status='running', memory_baseline_tokens=baseline_memory, hourly_origin=origin.isoformat())
        atomic_json(out/'progress.json', progress)

        def account(answer):
            result = answer.get('result', [])
            response = result[1] if result and result[0] == 'ok' else result[2] if len(result) > 2 else None
            usage = response.get('usage') if isinstance(response, dict) else None
            if isinstance(usage, dict) and isinstance(usage.get('total_tokens'), int):
                progress['decision_tokens'] += usage['total_tokens']
            else:
                progress['usage_unknown_requests'] = progress.get('usage_unknown_requests', 0) + 1
            atomic_json(out/'progress.json', progress)

        next_ready = {cid: 0.0 for cid in cids}
        heard = {cid: [] for cid in cids}
        sequence = 0
        heartbeat = time.monotonic()+60
        for hour in range(1, hours+1):
            boundary = origin + timedelta(hours=hour)
            while datetime.now(timezone.utc) < boundary:
                if (out/'STOP').exists():
                    raise InterruptedError('operator requested stop; current action already settled')
                acted = False
                for cid in actor_order(cids, hour):
                    if (out/'STOP').exists():
                        raise InterruptedError('operator requested stop; remaining decisions not executed')
                    if time.monotonic() < next_ready[cid] and not addressed_since(cid, heard[cid]):
                        continue
                    sequence += 1
                    progress.update(active_hour=hour, active_cid=cid, status='running', updated_at=now())
                    atomic_json(out/'progress.json', progress)
                    proof = step(cid, hour, out, origin, account, sequence=sequence)
                    next_ready[cid] = next_decision_at(proof, time.monotonic())
                    heard[cid] = proof['heard']
                    progress['completed_steps'] += 1
                    progress.update(elapsed_real_hours=(datetime.now(timezone.utc)-origin).total_seconds()/3600,
                                    updated_at=now())
                    atomic_json(out/'progress.json', progress)
                    acted = True
                if acted:
                    progress['completed_decision_rounds'] += 1
                else:
                    progress.update(status='model_requested_rest', updated_at=now())
                    atomic_json(out/'progress.json', progress)
                    time.sleep(2)
                if time.monotonic() >= heartbeat:
                    if any(runtime(cid)['life']['error'] for cid in cids):
                        raise RuntimeError('Life error during hourly evolution')
                    progress.update(updated_at=now(), elapsed_real_hours=(datetime.now(timezone.utc)-origin).total_seconds()/3600)
                    atomic_json(out/'progress.json', progress)
                    heartbeat = time.monotonic()+60
            if hour % 24 == 0 or hour == hours:
                progress['memory_tokens_since_start'] = checkpoint(out, hour, cids, flush=True) - baseline_memory
            progress.update(completed_hours=hour, status='running', updated_at=now())
            atomic_json(out/'progress.json', progress)
            print(json.dumps({k: progress[k] for k in ['completed_hours','target_hours','decision_tokens','memory_tokens_since_start']},ensure_ascii=False),flush=True)
        progress['status'] = 'completed'
    except BaseException as error:
        errors.append({'type': type(error).__name__, 'message': str(error)})
        progress['status'] = 'stopped' if isinstance(error, InterruptedError) else 'failed'
    finally:
        if enabled:
            try:
                # 失败也保留尾部；不因检查点失败跳过其它 owner 的恢复。
                value = checkpoint(out, progress['completed_hours'], cids, suffix='-final')
                if baseline_memory is not None:
                    progress['memory_tokens_since_start'] = value - baseline_memory
            except BaseException as error:
                errors.append({'type': 'final_checkpoint', 'message': type(error).__name__})
        for row in enabled:
            try:
                position = runtime(row['cid'])['body']['position']
                register(row, row['brain'], row['params'], position)
            except BaseException as error:
                errors.append({'type': 'restore', 'cid': row['cid'], 'message': type(error).__name__})
                try:
                    demo.rpc(f'NpcServer.Registry.remove({packed(row["name"])})')
                except BaseException as disabled:
                    errors.append({'type': 'disable', 'message': type(disabled).__name__})
        if trace_started:
            try:
                demo.rpc(':erlang.trace_pattern({NpcServer.Http,:request,2},false,[:global]); :erlang.trace(:all,false,[:call]); if pid=Process.whereis(:npc_long_horizon_trace),do: Process.exit(pid,:kill); :ok')
            except BaseException as error:
                errors.append({'type': 'trace_stop', 'message': type(error).__name__})
        if errors and progress['status'] == 'completed':
            progress['status'] = 'failed_cleanup'
        progress.update(errors=errors, finished_at=now())
        atomic_json(out/'progress.json', progress)
    if errors:
        raise SystemExit(json.dumps(errors, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['run','status','stop'])
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--hours', default=8760, type=int)
    args = parser.parse_args()
    if args.action == 'run':
        try:
            run(args.out, args.hours)
        except Exception as error:
            destination = args.out/'progress.json'
            if destination.exists():
                progress = json.loads(destination.read_text(encoding='utf8'))
                if progress['status'] == 'preparing':
                    progress.update(status='failed_preparation', finished_at=now(),
                                    errors=[{'type': type(error).__name__, 'message': str(error)}])
                    atomic_json(destination, progress)
            raise
    elif args.action == 'status':
        print((args.out/'progress.json').read_text(encoding='utf8'))
    else:
        (args.out/'STOP').write_text(now(), encoding='utf8')
        print('Stop requested; the current request/action is allowed to settle before restoring registrations.')
