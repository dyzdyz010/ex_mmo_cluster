"""只测试：配对干预只改变自传内容，不能改变 World 或覆盖原证据。"""
import copy
import json
import unittest
import tempfile
import time
from pathlib import Path
from unittest.mock import patch
import long_horizon as subject
from long_horizon import permute_biography


class PairingTest(unittest.TestCase):
    def test_permutation_leaves_authority_tools_goal_and_trait_identical(self):
        context = {'self': {'entity_id': 7, 'position': [1, 2, 3]},
                   'entities': [{'entity_id': 101}], 'outcomes': [{'actor': 101}], 'goal': 'Choose freely',
                   'mind': {'cid': 7, 'traits': {'caution': .36}, 'relationships': {'101': {'trust': -1}, '202': {'trust': 1}}},
                   'mental_models': {'relationships': 'Actor 101 damaged; Actor 202 repaired.'},
                   'memories': [{'text': 'Actor 202 helped.'}], 'current_plan': None, 'recent_notes': []}
        body = {'input': json.dumps(context), 'tools': [{'name': 'move_to'}, {'name': 'set_plan'}]}
        original = copy.deepcopy(body)
        swapped = permute_biography(body, 101, 202)
        changed = json.loads(swapped['input'])
        for key in ('self', 'entities', 'outcomes', 'goal'):
            self.assertEqual(changed[key], context[key])
        self.assertEqual(changed['mind']['traits'], context['mind']['traits'])
        self.assertEqual(swapped['tools'], body['tools'])
        self.assertEqual(changed['mind']['relationships']['202']['trust'], -1)
        self.assertEqual(changed['mental_models']['relationships'], 'Actor 202 damaged; Actor 101 repaired.')
        self.assertEqual(changed['memories'][0]['text'], 'Actor 101 helped.')
        self.assertEqual(body, original)
        self.assertEqual(json.loads(permute_biography(swapped, 101, 202)['input']), context)


class LiveCleanupTest(unittest.TestCase):
    """离线外部替身：运行观察失败也必须恢复后端，且清理失败不能覆盖首因。"""
    def test_http_completion_does_not_complete_last_action(self):
        records = [{'calls': [{'name': 'wait'}]}, {'calls': [{'name': 'gather'}]}]
        self.assertFalse(subject.last_action_done(records, [{'id': 1, 'status': 'done'}]))
        self.assertTrue(subject.last_action_done(records, [{'id': 2, 'status': 'done'}]))
        self.assertTrue(subject.last_action_done(records[:1], []))

    def test_unique_run_keeps_old_evidence_and_uses_declared_profile(self):
        import threading
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            server_dir = out / 'server'
            server_dir.mkdir()
            old = server_dir / 'long-horizon-requests.jsonl'
            old.write_text('old evidence', encoding='utf8')
            stopped = threading.Event()
            stopped.set()
            observation = {'body': {'position': [1, 2, 3]}, 'life': {'error': None}}
            def rpc(code):
                return {'cid': 7} if 'Registry.put' in code else {}
            with patch.object(subject.demo, 'SERVER', server_dir), \
                 patch.object(subject.demo.server, 'rpc', return_value={}) as trace, \
                 patch.object(subject.demo, 'rpc', side_effect=rpc) as calls, \
                 patch.object(subject.demo, 'observe', return_value=observation):
                subject.live(7, out, 1, run_id='autonomy-01',
                             params=subject.profile_params('A declared goal', 30), stop=stopped)
            self.assertIn('/demo/autonomy-01-requests.jsonl', trace.call_args.args[2])
            self.assertEqual(old.read_text(), 'old evidence')
            registration = next(c.args[0] for c in calls.call_args_list if 'brain: "life"' in c.args[0])
            self.assertIn(subject.packed(subject.profile_params('A declared goal', 30)), registration)
            self.assertTrue((out / 'restore.json').exists())

    def run_failure(self, restore_error=False):
        import threading
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            initial = {'body': {'position': [1, 2, 3]}}
            calls = []
            stopped = threading.Event()
            def rpc(code):
                calls.append(code)
                if 'Registry.put' in code:
                    if 'settler' in code:
                        self.assertTrue(stopped.is_set(), 'acceptance window must close before backend restoration')
                    return ['error', 'restore_failed'] if restore_error and 'settler' in code else {'cid': 7}
                if 'Registry.remove' in code:
                    return 'ok'
                return {'stopped': True}
            with patch.object(subject.demo, 'SERVER', out / 'server'), \
                 patch.object(subject.demo.server, 'rpc', return_value={'started': True}), \
                 patch.object(subject.demo, 'rpc', side_effect=rpc), \
                 patch.object(subject.demo, 'observe', side_effect=[initial, RuntimeError('Life unavailable'), ValueError('final observation failed')]):
                with self.assertRaisesRegex(RuntimeError, 'Life unavailable'):
                    subject.live(7, out, 1, stop=stopped)
            self.assertTrue(any('settler' in code for code in calls), calls)
            self.assertTrue(any('brain: "life"' in code for code in calls), 'live must use the standalone life backend')
            self.assertTrue(any('trace_pattern' in code for code in calls), calls)
            errors = json.loads((out / 'cleanup-errors.json').read_text(encoding='utf8'))
            self.assertEqual('restore' in errors, restore_error)
            self.assertIn('observe', errors)
            self.assertEqual(any('Registry.remove' in code for code in calls), restore_error)

    def test_observation_failure_still_restores_and_stops_trace(self):
        self.run_failure()

    def test_restore_error_is_recorded_and_trace_still_stops(self):
        self.run_failure(restore_error=True)


class StageGateTest(unittest.TestCase):
    """离线日志契约替身：未确认本轮同角色同格破坏，不能发放修复令牌。"""
    def sample(self):
        events, world = [], []
        for n in range(3):
            events += [{'event': 'intent.sent', 'client_seq': 70+n, 'coord': subject.demo.CELL},
                       {'event': 'intent.result', 'client_seq': 70+n, 'result': 0, 'txn': 43+n}]
            world.append({'seq': 43+n, 'kind': 'destroy' if n == 2 else 'damage',
                          'actor': subject.ACTORS[0], 'cell': subject.demo.CELL})
        return events, world

    def check_release(self, events, world, expected):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            if expected:
                subject.release_damage(out, events, world, 42)
                self.assertEqual((out/'a/replay.done').read_text().strip(), 'harm-confirmed')
            else:
                with self.assertRaises(AssertionError):
                    subject.release_damage(out, events, world, 42)
                self.assertFalse((out/'a/replay.done').exists())

    def test_rejection_cannot_release_repair(self):
        events, world = self.sample()
        events[1]['result'] = 7
        self.check_release(events, world, False)

    def test_old_world_history_cannot_release_repair(self):
        events, world = self.sample()
        for i, row in enumerate(world): row['seq'] = 36+i
        self.check_release(events, world, False)

    def test_damage_without_destruction_cannot_release_repair(self):
        events, world = self.sample()
        world[-1]['kind'] = 'damage'
        self.check_release(events, world, False)

    def test_wrong_actor_or_cell_cannot_release_repair(self):
        for field, value in [('actor', subject.ACTORS[1]), ('cell', [0,0,0])]:
            events, world = self.sample()
            world[-1][field] = value
            self.check_release(events, world, False)

    def test_matching_new_destroy_releases_repair(self):
        self.check_release(*self.sample(), True)

    def test_driver_uses_named_gates_and_actual_world_cursor_contract(self):
        """替换进程/网络，保留真实时间轴、监控器和日志解析器，检验门禁接线。"""
        events, world = self.sample()
        repair = [{'event': 'intent.sent', 'client_seq': 136, 'coord': subject.demo.CELL},
                  {'event': 'intent.result', 'client_seq': 136, 'result': 0, 'txn': 47}]
        world += [{'seq': 47, 'kind': 'build', 'actor': subject.ACTORS[1], 'cell': subject.demo.CELL}]
        def run(scenario, out, server_dir, inputs, timeout):
            for role, token in [('a', 'repair-confirmed'), ('b', 'harm-confirmed')]:
                steps = json.loads(inputs[role].read_text(encoding='utf8'))['steps']
                self.assertIn('@await_peer '+token, [s['command'] for s in steps])
                (out/role).mkdir(parents=True)
            for role, records in [('a', events), ('b', repair)]:
                (out/role/'client.log').write_text('\n'.join('VoxelEvent '+json.dumps(dict(schema=1,**e)) for e in records), encoding='utf8')
                deadline = time.monotonic()+3
                while not (out/role/'replay.done').exists():
                    if (out/'abort').exists() or time.monotonic()>deadline:
                        self.fail('stage did not open: '+str(out))
                    time.sleep(.01)
            return {r: {'replay': 'success'} for r in ('a','b')}
        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(subject.demo.server, 'character', side_effect=subject.ACTORS), \
             patch.object(subject.demo, 'rpc', return_value=['ok', {'cursor': 42, 'world_id':'same-world','events': world}]), \
             patch.object(subject.demo.checks, 'character_identity'), \
             patch.object(subject.demo.clients, 'run', side_effect=run):
            subject.clients(Path(tmp))

    def test_deadline_aborts_without_release(self):
        import threading
        with tempfile.TemporaryDirectory() as tmp:
            out, failures = Path(tmp), []
            subject.monitor_stages(out, 42, threading.Event(), failures, 0)
            self.assertEqual(failures[0]['type'], 'TimeoutError')
            self.assertTrue((out/'abort').exists())
            self.assertFalse((out/'a/replay.done').exists())


if __name__ == '__main__':
    unittest.main()
