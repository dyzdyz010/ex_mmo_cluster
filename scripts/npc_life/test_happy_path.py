"""只测试：收尾服务失败必须留下最终结构化状态；外部 RPC 与模型使用替身。"""
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import happy_path as subject


class CleanupTest(unittest.TestCase):
    def test_trace_stop_failure_preserves_final_status_and_prior_errors(self):
        rows = [{'cid': cid, 'name': name, 'brain': 'settler', 'scene_id': 1, 'params': {}}
                for cid, name in enumerate(subject.life.ROLES, 1)]

        def rpc(code):
            if code == 'NpcServer.Registry.list()':
                return rows
            if 'Body.observe(pid).position' in code:
                return {str(cid): [0, 1, 0] for cid in [1, 2, 3]}
            if ':erlang.trace_pattern' in code:
                raise ConnectionError('trace service unavailable')
            return {}

        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)/'run'
            with patch.object(subject.demo, 'rpc', side_effect=rpc), \
                    patch.object(subject.demo, 'SERVER', Path(temp)), \
                    patch.object(subject.demo.server, 'execution_identity', return_value={}), \
                    patch.object(subject.demo.server, 'rpc', return_value={}), \
                    patch.object(subject.urllib.request, 'urlopen', return_value=io.BytesIO(b'{"pid": 123}')), \
                    patch.object(subject.life, 'register'), \
                    patch.object(subject.life, 'runtime', return_value={
                        'life': {'error': None, 'state': {}}, 'body': {'position': [0, 1, 0]}}), \
                    patch.object(subject.life, 'memory_usage', return_value=(0, {})), \
                    patch.object(subject.life, 'checkpoint', side_effect=[0, 0, 0, TimeoutError('memory checkpoint did not drain')]):
                try:
                    subject.run(out, phase_steps=0)
                except (SystemExit, ConnectionError):
                    pass
            progress = json.loads((out/'progress.json').read_text(encoding='utf8'))
            self.assertEqual(progress['status'], 'failed_cleanup')
            self.assertEqual(progress['errors'], [
                {'type': 'checkpoint', 'message': 'memory checkpoint did not drain'},
                {'type': 'trace_stop', 'message': 'trace service unavailable'}])
            self.assertIn('finished_at', progress)


if __name__ == '__main__':
    unittest.main()
