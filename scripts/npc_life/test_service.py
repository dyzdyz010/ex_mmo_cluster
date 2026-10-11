"""只测试：生命周期前必须核验容器隔离；所有 Docker 调用由内存替身接管。"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import runpy
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('service.py')
SPEC = importlib.util.spec_from_file_location('npc_life_service', SCRIPT)
service = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(service)


class ServiceLifecycleTest(unittest.TestCase):
    def test_pinned_same_image_can_stop_but_another_digest_cannot(self):
        for actual in ['sha256:probe', 'sha256:other']:
            calls, original = self.docker()
            def run(command, **kwargs):
                if command[:3] == ['docker', 'image', 'inspect']:
                    return SimpleNamespace(returncode=0, stdout='sha256:probe')
                if command[:4] == ['docker', 'inspect', '--format', '{{.Config.Image}}']:
                    return SimpleNamespace(returncode=0, stdout=actual)
                return original(command, **kwargs)
            with patch.object(service.subprocess, 'run', side_effect=run):
                if actual == 'sha256:probe':service.stop()
                else:
                    with self.assertRaisesRegex(SystemExit, 'image mismatch'):service.stop()
            self.assertEqual(self.mutations(calls), [['docker', 'stop', service.NAME]] if actual == 'sha256:probe' else [])

    def docker(self, port='18908', pg=None, network=False):
        calls = []
        fields = {
            '{{.Config.Image}}': service.IMAGE,
            '{{.Image}}': 'sha256:probe',
            '{{json .NetworkSettings.Networks}}': json.dumps({service.NETWORK: {}} if network else {}),
            '{{json .HostConfig.PortBindings}}': json.dumps({
                '8888/tcp': [{'HostIp': '127.0.0.1', 'HostPort': port}]}),
            '{{json .Mounts}}': json.dumps([
                {'Type': 'volume', 'Name': pg or service.NAME + '-pg', 'Destination': '/home/hindsight/.pg0'},
                {'Type': 'volume', 'Name': service.NAME + '-hf', 'Destination': '/home/hindsight/.cache/huggingface'},
            ]),
        }

        def run(command, **_):
            calls.append(command)
            if command[:2] == ['docker', 'inspect']:
                return SimpleNamespace(returncode=0, stdout=fields[command[3]])
            return SimpleNamespace(returncode=0, stdout='')

        return calls, run

    @staticmethod
    def mutations(calls):
        return [c for c in calls if c[1] in ('start', 'run', 'stop', 'network')]

    def test_start_rejects_wrong_port_or_pg_before_any_mutation(self):
        for port, pg in [('18888', None), ('18908', 'voxim-npc-evolve-20261011-pg')]:
            with self.subTest(port=port, pg=pg):
                calls, run = self.docker(port=port, pg=pg)
                with patch.object(service, 'config', return_value={}), patch.object(service.subprocess, 'run', side_effect=run):
                    with self.assertRaisesRegex(SystemExit, 'isolation mismatch'):
                        service.start(1)
                self.assertEqual(self.mutations(calls), [])

    def test_cli_stop_and_restart_reject_isolation_before_any_mutation(self):
        # 直接运行现有 CLI 接纳入口，不绕过 stop/restart 分支；凭证源也是内存替身。
        for action in ('stop', 'restart'):
            for port, pg in [('18898', None), ('18908', 'voxim-npc-evolve-20261011-pg')]:
                with self.subTest(action=action, port=port, pg=pg):
                    calls, run = self.docker(port=port, pg=pg)
                    with patch('subprocess.run', side_effect=run), patch.object(sys, 'argv', [str(SCRIPT), action]), patch.object(Path, 'read_text', return_value='NPC_LLM_URL=http://stub/responses\nNPC_LLM_KEY=stub-key'):
                        with self.assertRaisesRegex(SystemExit, 'isolation mismatch'):
                            runpy.run_path(str(SCRIPT), run_name='__main__')
                    self.assertEqual(self.mutations(calls), [])

    def test_normal_reuse_validates_before_start_and_network_connect(self):
        calls, run = self.docker()
        with tempfile.TemporaryDirectory() as directory, patch.object(service, 'OUT', Path(directory)), patch.object(service, 'config', return_value={}), patch.object(service, 'ready'), patch.object(service.subprocess, 'run', side_effect=run), contextlib.redirect_stdout(io.StringIO()):
            service.start(1)
        mutations = self.mutations(calls)
        self.assertEqual(mutations, [['docker', 'start', service.NAME], ['docker', 'network', 'connect', service.NETWORK, service.NAME]])
        first_mutation = calls.index(mutations[0])
        validated = [c[3] for c in calls[:first_mutation] if c[:2] == ['docker', 'inspect']]
        self.assertIn('{{.Config.Image}}', validated)
        self.assertIn('{{json .HostConfig.PortBindings}}', validated)
        self.assertIn('{{json .Mounts}}', validated)

    def test_normal_stop_validates_before_stop(self):
        calls, run = self.docker(network=True)
        with patch('subprocess.run', side_effect=run), patch.object(sys, 'argv', [str(SCRIPT), 'stop']):
            runpy.run_path(str(SCRIPT), run_name='__main__')
        self.assertEqual(self.mutations(calls), [['docker', 'stop', service.NAME]])
        first_mutation = calls.index(['docker', 'stop', service.NAME])
        validated = [c[3] for c in calls[:first_mutation] if c[:2] == ['docker', 'inspect']]
        self.assertIn('{{.Config.Image}}', validated)
        self.assertIn('{{json .HostConfig.PortBindings}}', validated)
        self.assertIn('{{json .Mounts}}', validated)


if __name__ == '__main__':
    unittest.main()
