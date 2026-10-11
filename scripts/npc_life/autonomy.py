"""只测试：有限天然材料、两次玩家破坏、同一 Life NPC 自主修复；不替 NPC 发动作。"""
import argparse
import json
from pathlib import Path
import re
import threading
import time

import demo
import long_horizon as horizon

OUT = demo.ROOT / '.demo/observe/npc-autonomy-20261011'
CID = 607440080896
SOURCES = [[71, y, -517] for y in range(419, 425)]
GOAL = (horizon.LIVE_GOAL + ' My maintenance responsibility is the wooden construction at [61,416,-517]. '
        'Keep it present when circumstances permit, using finite resources frugally. The permitted natural wood '
        'collection area is [71,419,-517] through [71,424,-517]; do not mine outside it or damage player constructions. '
        'I have no promised deliveries. Decide and carry out my own next actions from current evidence; '
        'a plan or a failed attempt is not a completed repair. Keep the ongoing purpose and blocking conditions in my plan.')


def repair_receipt(world, baseline, snapshot, initial_units):
    """World 事务、材料增减与当前格一起对账；旧史、玩家修复、凭空余额均不能放行下一阶段。"""
    events = [e for e in world if e['seq'] > baseline]
    builds = [e for e in events if e['cell'] == demo.CELL and e['kind'] == 'build']
    if not builds:
        return None
    assert len(builds) == 1 and builds[0]['actor'] == CID and builds[0]['material'] == 19, 'repair is not this NPC'
    gathered = [e for e in events if e['actor'] == CID and e['kind'] == 'destroy']
    assert gathered and all(e['cell'] in SOURCES and e['material'] == 19 and e['placed_by'] is None for e in gathered), 'no permitted NPC gather'
    assert all(e['seq'] < builds[0]['seq'] for e in gathered), 'gather did not precede consumption'
    receipts = gathered + builds
    assert len({e['seq'] for e in receipts}) == len(receipts), 'duplicate transaction'
    target = next(e for e in snapshot['probe_occupancy'] if e['cell'] == demo.CELL)
    assert target['material'] == 19 and target['placed_by'] == CID, 'canonical target not NPC repair'
    units = next(e['units'] for e in snapshot['material_balances'] if e['character'] == CID and e['material'] == 19)
    expected = initial_units + snapshot['capacity_units'] * (len(gathered) - 1)
    assert units == expected, 'gather/consumption balance mismatch'
    return {'gather': gathered, 'build': builds[0], 'units_before': initial_units, 'units_after': units, 'snapshot_seq': snapshot['seq']}


def input_steps():
    a, b = demo.Timeline(), demo.Timeline()
    for t in (a, b):
        t.add(25, '@place ' + demo.FAR)
    for phase, start in [(1, 60), (2, 80)]:
        a.add(start, '@place ' + demo.NEAR)
        a.click(start + 1, 'One')
        a.add(start + 2, '@aim 61.5 416.5 -516.5')
        for n in range(3):
            a.hit(start + 4 + 1.2*n)
        a.add(start + 8, '@await_intents')
        a.add(start + 9, '@place ' + demo.FAR)
        a.add(start + 10, '@await_peer ' + ('npc-repair-1' if phase == 1 else 'success'))
    a.add(95, 'Voxel.Production.Status')
    b.add(30, '@await_peer npc-repairs-complete')
    b.add(96, 'Voxel.Production.Status')
    return {'a': a.steps, 'b': b.steps}


def copied(out, transactions):
    for role in ('a', 'b'):
        log = out / role / 'client.log'
        lines = log.read_text(encoding='utf8', errors='replace').splitlines() if log.exists() else []
        applied = {int(m.group(1)) for line in lines if (m := re.search(r'canonical_applied.*?txn=(\d+)', line))}
        if not set(transactions) <= applied:
            return False
    return True


def monitor(out, baseline, stop, failures, seconds):
    deadline = time.monotonic() + seconds
    cursor, units = baseline, 0
    try:
        for phase in (1, 2):
            destroyed = False
            receipt = None
            while not stop.is_set() and time.monotonic() < deadline:
                log = out / 'a/client.log'
                events = demo.events.read(log) if log.exists() else []
                sent = [e for e in events if e['event'] == 'intent.sent']
                results = [e for e in events if e['event'] == 'intent.result']
                row = demo.observe(CID)
                assert not row['life']['error'], 'Life explicit failure'
                world = row['interactions']['events']
                if not destroyed and len(results) >= phase * 3:
                    selected = sent[(phase-1)*3:phase*3]
                    keys = {e['client_seq'] for e in selected}
                    matching = selected + [e for e in results if e['client_seq'] in keys]
                    matched = horizon.confirmed_stage(matching, world, cursor, horizon.ACTORS[0], 3, 'destroy')
                    demo.save(out / f'harm-{phase}.json', matched)
                    destroyed = True
                if destroyed:
                    if receipt is None:
                        receipt = repair_receipt(world, cursor, row['material'], units)
                    transactions = [e['seq'] for e in receipt['gather'] + [receipt['build']]] if receipt else []
                    if receipt and copied(out, transactions) and not stop.is_set():
                        demo.save(out / f'repair-{phase}.json', receipt)
                        demo.save(out / f'repaired-state-{phase}.json', row)
                        units, cursor = receipt['units_after'], receipt['build']['seq']
                        (out / 'b/replay.done').write_text(f'npc-repair-{phase}\n', encoding='utf8')
                        break
                time.sleep(2)
            else:
                raise TimeoutError(f'phase {phase}: NPC autonomous repair not confirmed before deadline')
        (out / 'a/replay.done').write_text('npc-repairs-complete\n', encoding='utf8')
    except BaseException as error:
        failures.append({'type': type(error).__name__, 'reason': str(error)})
        demo.save(out / 'stage-failure.json', failures[-1])
        (out / 'abort').write_text('first stage failure; later inputs stopped\n', encoding='utf8')
        stop.set()


def execute(out, seconds=560):
    assert 120 <= seconds <= 560
    users = {'a': 'npc_life_a_20261011', 'b': 'npc_life_b_20261011'}
    actors = {r: demo.server.character(demo.SERVER, u) for r, u in users.items()}
    assert tuple(actors.values()) == horizon.ACTORS
    before = demo.observe(CID)
    demo.save(out / 'initial.json', before)
    assert before['material']['material_balances'] == [{'character': CID, 'units': 0, 'material': 19}]
    assert before['material']['probe_occupancy'][0]['material'] == 19
    params = horizon.profile_params(GOAL, 30)
    params['skills'] = ['gather', 'travel']
    steps = input_steps()
    inputs = {}
    for role, values in steps.items():
        inputs[role] = out / (role + '-inputs.json')
        demo.save(inputs[role], {'classification': 'Test-only', 'steps': values})
    demo.save(out / 'protocol.json', {'classification': 'Test-only', 'cid': CID, 'actors': actors,
        'goal': GOAL, 'params': params, 'source_cells': SOURCES, 'steps': steps, 'seconds': seconds,
        'request_limit': 30, 'prior_external_tokens': 1243611, 'external_task_cap': 2000000,
        'run_allocation': 450000, 'verdict': 'Two new NPC gathers followed by NPC repairs; exact actor/txn/balance/canonical; both clients consume each txn. No player repair or resource supply. First stage failure stops later stages.'})
    stop, failures = threading.Event(), []
    def run_life():
        try:
            horizon.live(CID, out / 'life', seconds, run_id=out.name, params=params, stop=stop, token_limit=350000)
        except BaseException as error:
            failures.append({'type': type(error).__name__, 'reason': str(error)})
            (out / 'abort').write_text('Life runner failed\n', encoding='utf8')
        finally:
            stop.set()
    (out / 'life').mkdir()
    life = threading.Thread(target=run_life)
    gate = threading.Thread(target=monitor, args=(out, before['interactions']['cursor'], stop, failures, seconds))
    scenario = {'level': '/Game/Voxel/Gameplay/L_GameplayDemo', 'roles': {r: {'user': u} for r, u in users.items()},
                'server': {'container': demo.CONTAINER}, 'measurement': {'seconds': .6}}
    demo.save(out / 'execution.json', demo.server.execution_identity(demo.SERVER, demo.CONTAINER))
    life.start()
    gate.start()
    try:
        result = demo.clients.run(scenario, out, demo.SERVER, inputs, seconds + 10)
        demo.save(out / 'clients.json', result)
    finally:
        stop.set()
        life.join(timeout=45)
        gate.join(timeout=15)
        demo.save(out / 'failures.json', failures)
    assert not life.is_alive() and not gate.is_alive(), 'lifecycle did not finish'
    assert not failures, failures
    assert all(r['replay'] == 'success' for r in result.values()), 'client replay failed'
    txns = []
    for phase in (1, 2):
        receipt = json.loads((out / f'repair-{phase}.json').read_text(encoding='utf8'))
        txns.extend(e['seq'] for e in receipt['gather'] + [receipt['build']])
    for role in ('a', 'b'):
        lines = (out / role / 'client.log').read_text(encoding='utf8', errors='replace').splitlines()
        demo.checks.character_identity(lines, actors[role], expected_sessions=1)
        applied = {int(m.group(1)) for line in lines if (m := re.search(r'canonical_applied.*?txn=(\d+)', line))}
        assert set(txns) <= applied, f'{role}: missing NPC canonical transactions'
    demo.save(out / 'verdict.json', {'accepted': True, 'transactions': txns, 'stages': 2})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    parser.add_argument('--seconds', type=int, default=560)
    args = parser.parse_args()
    output = OUT / args.out
    output.mkdir(parents=True, exist_ok=False)
    execute(output, args.seconds)
