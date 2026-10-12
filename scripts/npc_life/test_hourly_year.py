"""只测试：小时推进必须由双方真实请求和对应动作终态支持；不发外部请求。"""
import copy
import unittest
from pathlib import Path
import tempfile
from unittest.mock import patch
import hourly_year as subject


def reply(tool='look'):
    return {'model': 'gpt-6.1-sol', 'reasoning': {'effort': 'medium'}, 'status': 'completed',
            'output': [{'type': 'function_call', 'name': tool, 'arguments': '{}'}],
            'usage': {'input_tokens': 100, 'output_tokens': 20, 'total_tokens': 120}}


class HourEvidenceTest(unittest.TestCase):
    def test_short_experiment_supplies_its_own_step_context(self):
        import demo
        from datetime import datetime, timezone
        from long_horizon import packed
        context = {'experiment': 'happy-path', 'task': '亲自走到邻居介绍的植物点'}
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            tag = subject.step_tag(out, 1, 3, 1)
            snapshot = {'life': {'error': None}, 'body': {
                'outcomes': [{'id': 7, 'status': 'done'}], 'position': [1, 2, 3], 'dialogue': []}}
            with patch.object(demo, 'rpc', return_value={'tag': tag, 'result': ['ok', reply(), [7]]}) as rpc, \
                    patch.object(subject, 'runtime', return_value=snapshot):
                try:
                    result = subject.step(3, 1, out, datetime.now(timezone.utc), context=context)
                except TypeError as error:
                    self.fail(f'短实验上下文尚不能传入正式 step：{error}')
            self.assertIn(packed(context), rpc.call_args.args[0])
            self.assertEqual(result['command_ids'], [7])
            self.assertEqual(result['outcomes'], [{'id': 7, 'status': 'done'}])

    def test_completed_plan_does_not_park_actor_until_next_hour(self):
        proof = {'calls': [{'name': 'set_plan', 'arguments': '{"text":"先勘察"}'}]}
        self.assertEqual(subject.next_decision_at(proof, 100.0), 100.0)
        proof = {'calls': [{'name': 'wait', 'arguments': '{"seconds":1800}'}]}
        self.assertEqual(subject.next_decision_at(proof, 100.0), 1900.0)

    def test_every_decision_in_the_same_hour_has_its_own_tag(self):
        out = Path('experiment/run-04')
        self.assertNotEqual(subject.step_tag(out, 1, 3, 1), subject.step_tag(out, 1, 3, 2))

    def test_new_bank_baseline_is_read_after_all_life_owners_are_ready(self):
        import demo
        names = list(subject.ROLES)
        rows = [{'cid': cid, 'name': name, 'brain': 'settler', 'scene_id': 1, 'params': {}}
                for cid, name in zip([1, 2, 3], names)]
        enabled = []
        baseline_verified = []
        permits = []
        def rpc(code):
            if code == 'NpcServer.Registry.list()':
                return rows
            if 'Body.observe(pid).position' in code:
                return {str(cid): [0, 1, 0] for cid in [1, 2, 3]}
            if 'NPC_LLM_MODEL' in code:
                return {'NPC_LLM_MODEL': subject.MODEL, 'NPC_LLM_EFFORT': subject.EFFORT}
            return {}
        def baseline(cids):
            self.assertEqual(enabled, [1, 2, 3])
            self.assertEqual(cids, [1, 2, 3])
            baseline_verified.append(cids)
            return 0, {}
        def steps(cid, hour, out, origin, account, sequence):
            permits.append((cid, hour, sequence))
            if len(permits) == 5:
                raise InterruptedError('bounded test stops before model')
            return {'calls': [{'name': 'set_plan', 'arguments': '{"text":"继续观察"}'}], 'heard': []}
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(demo, 'rpc', side_effect=rpc), patch.object(demo, 'SERVER', Path(temp)), \
                    patch.object(demo.server, 'execution_identity', return_value={}), \
                    patch.object(demo.server, 'rpc', return_value={}), \
                    patch.object(subject, 'register', side_effect=lambda row, brain, params, position: enabled.append(row['cid']) if brain == 'life' else None), \
                    patch.object(subject, 'runtime', return_value={'life': {'error': None, 'state': {}, 'job': None}, 'body': {'position': [0, 1, 0]}}), \
                    patch.object(subject, 'memory_usage', side_effect=baseline), \
                    patch.object(subject, 'checkpoint', return_value=0), \
                    patch.object(subject, 'step', side_effect=steps):
                with self.assertRaises(SystemExit):
                    subject.run(Path(temp)/'owned'/'fresh-run')
        self.assertEqual(baseline_verified, [[1, 2, 3]])
        self.assertEqual(permits[:4], [(1, 1, 1), (2, 1, 2), (3, 1, 3), (1, 1, 4)])

    def test_distinct_experiment_directories_do_not_share_trace_id(self):
        self.assertNotEqual(subject.run_id(Path('old/run-01')), subject.run_id(Path('new/run-01')))

    def test_three_actor_rotation_and_omitted_scholar(self):
        self.assertEqual(subject.actor_order([1, 2, 3], 1), [1, 2, 3])
        self.assertEqual(subject.actor_order([1, 2, 3], 2), [2, 3, 1])
        self.assertEqual(subject.actor_order([1, 2, 3], 3), [3, 1, 2])
        rows = [{'cid': cid, 'hour': 1, 'completed': True} for cid in [1, 2]]
        self.assertFalse(subject.hour_complete(1, [1, 2, 3], rows))

    def test_real_action_requires_its_own_terminal(self):
        response = reply()
        self.assertTrue(subject.step_complete(response, [14], [{'id': 14, 'status': 'done'}]))
        self.assertFalse(subject.step_complete(response, [14], [{'id': 13, 'status': 'done'}]))
        self.assertFalse(subject.step_complete(response, [14], [{'id': 14, 'status': 'running'}]))

    def test_rejection_is_completed_evidence_but_not_rewritten_as_success(self):
        rows = [{'id': 14, 'status': 'rejected', 'reason': 'no_path', 'data': None}]
        before = copy.deepcopy(rows)
        self.assertTrue(subject.step_complete(reply(), [14], rows))
        self.assertEqual(rows, before)

    def test_memory_write_failure_stops_instead_of_counting_as_daily_life(self):
        rows = [{'id': 14, 'status': 'rejected', 'reason': ['memory_unavailable', 'db_down']}]
        with self.assertRaisesRegex(ValueError, 'memory'):
            subject.step_complete(reply('set_plan'), [14], rows)

    def test_completed_skill_with_unsaved_experience_stops(self):
        rows = [{'id': 14, 'verb': 'travel', 'status': 'done', 'reason': None,
                 'data': {'memory_error': ['memory_unavailable', 'db_down']}}]
        with self.assertRaisesRegex(ValueError, 'memory'):
            subject.step_complete(reply('travel'), [14], rows)

    def test_only_wait_can_finish_without_a_body_command(self):
        self.assertTrue(subject.step_complete(reply('wait'), [], []))
        with self.assertRaisesRegex(ValueError, 'command'):
            subject.step_complete(reply(), [], [])

    def test_model_effort_incomplete_or_missing_usage_cannot_advance(self):
        for changed in [dict(model='wrong'), dict(reasoning={'effort': 'low'}),
                        dict(status='incomplete'), dict(usage=None), dict(output=[])]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                subject.step_complete({**reply(), **changed}, [14], [{'id': 14, 'status': 'done'}])

    def test_both_distinct_actors_and_exact_hour_are_required(self):
        rows = [{'cid': 1, 'hour': 1, 'completed': True}, {'cid': 2, 'hour': 1, 'completed': True}]
        self.assertTrue(subject.hour_complete(1, [1, 2], rows))
        self.assertFalse(subject.hour_complete(1, [1, 2], rows[:1]))
        self.assertFalse(subject.hour_complete(1, [1, 2], [rows[0], rows[0]]))
        self.assertFalse(subject.hour_complete(2, [1, 2], rows))
        self.assertFalse(subject.hour_complete(1, [1, 2], [rows[0], {**rows[1], 'completed': False}]))


if __name__ == '__main__':
    unittest.main()
