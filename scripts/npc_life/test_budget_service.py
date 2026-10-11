"""只测试：计数契约失败必须在任何容器写入前停止；固定镜像ID重建。"""
import tempfile
from pathlib import Path
from unittest.mock import patch
import unittest
import budget_service as b


class SetupTest(unittest.TestCase):
    def test_count_failure_does_not_touch_running_assets(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(b,'count_preflight',side_effect=RuntimeError('count mismatch')), patch.object(b,'docker') as docker, patch.object(b.service,'preflight') as preflight:
            with self.assertRaisesRegex(RuntimeError,'count mismatch'):b.setup(Path(tmp)/'run')
            docker.assert_not_called();preflight.assert_not_called()

    def test_recreation_uses_original_immutable_image_and_memory_only_env(self):
        old={'Name':'/owned-test','Image':'sha256:frozen','Config':{'Image':'mutable-tag','Env':['KEY=test-only-secret'],'Cmd':['original-entry']}}
        with patch.object(b,'docker') as docker, patch.object(b,'metadata',return_value={'Image':old['Image']}):
            b.configure(old,{'URL':'internal-route'},[])
            command=docker.call_args.args
            self.assertIn('sha256:frozen',command)
            self.assertNotIn('mutable-tag',command)
            self.assertNotIn('test-only-secret',command)
            self.assertEqual(docker.call_args.kwargs['env']['KEY'],'test-only-secret')


if __name__=='__main__':unittest.main()
