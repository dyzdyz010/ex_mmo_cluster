"""仅测试：起点／终点跨窗口反例、角色隔离、真实超额和 token 边界。"""
from collections import deque
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import npc_soak_sampler as target


class Recorder(target.Sampler):
    def remove(self, name, why, ts):
        self.actions.append((name, why))


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        self.now = datetime(2026, 10, 10, microsecond=1, tzinfo=timezone.utc)
        self.mono = 4_000_000_000
        for name, value in {'RUN': self.folder, 'STATE': self.folder / 'state.json',
                            'TRACE': self.folder / 'trace.jsonl', 'GUARDS': self.folder / 'guards.jsonl',
                            'DECISION_LIMIT': 20, 'DESIGN_TOKEN_LIMIT': 2_000_000,
                            'now': lambda: self.now, 'rpc': lambda _: self.mono}.items():
            patcher = patch.object(target.base, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.sampler = Recorder()
        self.sampler.actions = []
        self.creator, self.resident = target.base.LLM_NPCS
        self.sampler.cids = {'1': self.creator, '2': self.resident}

    def write_requests(self, rows):
        target.base.TRACE.write_text(''.join(json.dumps(r) + '\n' for r in rows), encoding='utf-8')

    def request(self, cid, ago_s, design=False):
        return {'cid': cid, 'm0_us': self.mono - ago_s * 1_000_000, 'design': design}

    def test_late_response_does_not_turn_twenty_starts_into_twenty_one(self):
        rows = [self.request(1, 3700)] + [self.request(1, i * 10) for i in range(20)]
        self.write_requests(rows)
        self.sampler.decisions[self.creator] = deque([(self.now - timedelta(seconds=100)).isoformat()] * 21)
        self.sampler.guard_decisions()
        self.assertEqual(self.sampler.actions, [])

    def test_real_twenty_one_starts_triggers_guard(self):
        self.write_requests([self.request(1, i * 10) for i in range(21)])
        self.sampler.decisions[self.creator] = deque([self.now.isoformat()] * 21)
        self.sampler.guard_decisions()
        self.assertEqual([a[0] for a in self.sampler.actions], [self.creator])

    def test_other_actor_design_and_old_window_are_not_main_requests(self):
        self.write_requests([self.request(1, i) for i in range(20)] +
                            [self.request(2, i) for i in range(20)] +
                            [self.request(None, 1, design=True), self.request(1, 3595)])
        self.sampler.guard_decisions()
        self.assertEqual(self.sampler.actions, [])

    def test_two_million_tokens_allowed_one_more_rejected(self):
        self.write_requests([])
        self.sampler.trace_design = deque([[self.now.isoformat(), 2_000_000]])
        self.sampler.guard_decisions()
        self.assertEqual(self.sampler.actions, [])
        self.sampler.trace_design.append([self.now.isoformat(), 1])
        self.sampler.guard_decisions()
        self.assertEqual([a[0] for a in self.sampler.actions], [self.resident])


if __name__ == '__main__':
    unittest.main()
