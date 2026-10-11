"""只测试：离线反例验证自主资源判定与阶段输入；不调用模型或真实进程。"""
import copy
import unittest
import tempfile
import threading
import time
import json
from pathlib import Path
from unittest.mock import patch
import autonomy as a


class ReceiptTest(unittest.TestCase):
    def sample(self):
        world = [{'seq': 51, 'cell': a.SOURCES[-1], 'kind': 'destroy', 'actor': a.CID, 'material': 19, 'placed_by': None},
                 {'seq': 53, 'cell': a.demo.CELL, 'kind': 'build', 'actor': a.CID, 'material': 19, 'placed_by': None}]
        snapshot = {'seq': 54, 'capacity_units': 2097152,
                    'probe_occupancy': [{'cell': a.demo.CELL, 'material': 19, 'placed_by': a.CID}],
                    'material_balances': [{'character': a.CID, 'material': 19, 'units': 0}]}
        return world, snapshot

    def test_valid_receipt_and_old_history(self):
        world, snapshot = self.sample()
        self.assertEqual(a.repair_receipt(world, 50, snapshot, 0)['units_after'], 0)
        self.assertIsNone(a.repair_receipt(world, 53, snapshot, 0))

    def test_wrong_actor_source_missing_gather_or_canonical_rejected(self):
        world, snapshot = self.sample()
        bad = []
        for index, field, value in [(1, 'actor', 123), (0, 'actor', 123), (0, 'placed_by', 123),
                                    (0, 'cell', [0, 0, 0]), (0, 'seq', 53)]:
            changed = copy.deepcopy(world)
            changed[index][field] = value
            bad.append((changed, snapshot))
        bad.append((world[1:], snapshot))
        wrong = copy.deepcopy(snapshot)
        wrong['probe_occupancy'][0]['placed_by'] = 123
        bad.append((world, wrong))
        wrong = copy.deepcopy(snapshot)
        wrong['material_balances'][0]['units'] = 512
        bad.append((world, wrong))
        for events, current in bad:
            with self.assertRaises(AssertionError):
                a.repair_receipt(events, 50, current, 0)

    def test_inputs_gate_second_harm_and_never_repair(self):
        steps = a.input_steps()
        commands = [s['command'] for s in steps['a']]
        self.assertLess(commands.index('@await_peer npc-repair-1'), commands.index('@await_peer success'))
        for role in steps:
            self.assertFalse(any('RightMouseButton' in s['command'] for s in steps[role]))
        self.assertEqual(sum(s['command'] == '@press LeftMouseButton' for s in steps['a']), 6)


class DriverTest(unittest.TestCase):
    def phase(self, phase):
        base = 48 + (phase-1)*7
        world = [{'seq': base+n, 'cell': a.demo.CELL, 'kind': 'destroy' if n == 3 else 'damage',
                  'actor': a.horizon.ACTORS[0], 'material': 19, 'placed_by': a.CID} for n in (1, 2, 3)]
        world += [{'seq': base+4, 'cell': a.SOURCES[-phase], 'kind': 'destroy', 'actor': a.CID, 'material': 19, 'placed_by': None},
                  {'seq': base+6, 'cell': a.demo.CELL, 'kind': 'build', 'actor': a.CID, 'material': 19, 'placed_by': None}]
        events = []
        for n in (1, 2, 3):
            events += [{'event': 'intent.sent', 'client_seq': base+n, 'coord': a.demo.CELL},
                       {'event': 'intent.result', 'client_seq': base+n, 'result': 0, 'txn': base+n}]
        _, snapshot = ReceiptTest().sample()
        snapshot['seq'] = base+6
        row = {'life': {'error': None}, 'material': snapshot, 'interactions': {'cursor': base+6, 'events': world}}
        return row, events, [base+4, base+6]

    def write(self, out, events, txns, both=True):
        for role in ('a', 'b'):
            (out / role).mkdir(exist_ok=True)
            lines = [('VoxelEvent '+json.dumps(dict(schema=1, **e))) for e in events] if role == 'a' else []
            if role == 'a' or both:
                lines += ['Voxel canonical_applied txn='+str(txn) for txn in txns]
            (out / role / 'client.log').write_text('\n'.join(lines), encoding='utf8')

    def test_missing_client_copy_cannot_release_second_harm(self):
        row, events, txns = self.phase(1)
        with tempfile.TemporaryDirectory() as tmp, patch.object(a.demo, 'observe', return_value=row):
            out = Path(tmp)
            self.write(out, events, txns, both=False)
            failures = []
            a.monitor(out, 48, threading.Event(), failures, .1)
            self.assertTrue(failures)
            self.assertFalse((out / 'b/replay.done').exists())
            self.assertFalse((out / 'repair-1.json').exists())

    def test_real_driver_two_gates_and_cleanup_with_external_stubs(self):
        first, events1, txns1 = self.phase(1)
        second, events2, txns2 = self.phase(2)
        second['interactions']['events'] = first['interactions']['events'] + second['interactions']['events']
        initial = copy.deepcopy(first)
        initial['interactions'] = {'cursor': 48, 'events': []}
        current = [initial]
        def clients(scenario, out, server, inputs, timeout):
            current[0] = first
            self.write(out, events1, txns1)
            deadline = time.monotonic()+8
            while not (out / 'b/replay.done').exists():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.02)
            self.assertEqual((out / 'b/replay.done').read_text().strip(), 'npc-repair-1')
            current[0] = second
            self.write(out, events1+events2, txns1+txns2)
            while not (out / 'a/replay.done').exists():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.02)
            return {role: {'replay': 'success'} for role in ('a', 'b')}
        def life(cid, out, seconds, **kwargs):
            self.assertEqual(kwargs['token_limit'], 350000)
            self.assertTrue(kwargs['stop'].wait(10))
        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(a.demo.server, 'character', side_effect=lambda directory, username: a.horizon.ACTORS[0 if '_a_' in username else 1]), \
             patch.object(a.demo.server, 'execution_identity', return_value={}), \
             patch.object(a.demo.checks, 'character_identity'), \
             patch.object(a.demo, 'observe', side_effect=lambda cid: copy.deepcopy(current[0])), \
             patch.object(a.demo.clients, 'run', side_effect=clients), \
             patch.object(a.horizon, 'live', side_effect=life):
            out = Path(tmp)
            a.execute(out, 120)
            self.assertTrue(json.loads((out/'verdict.json').read_text())['accepted'])


if __name__ == '__main__':
    unittest.main()
