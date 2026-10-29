"""只测试：真实控制端 start 消费受控 ready/OS/子进程，不启动 VM。"""
import copy
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import m0


def ready_fixture():
    return {
        "os_pid": 321, "node": "fixture@127.0.0.1", "ready_utc": "2026-10-28T00:00:00Z",
        "startup_profile": "m0_manifest_ready_v1", "code_mode": "interactive",
        "code_ready": {
            "profile": "m0_manifest_ready_v1", "status": "ready", "module_count": 1, "loaded_count": 1,
            "ensure_modules_loaded_result": "ok", "code_mode": "interactive",
            "app_manifests": [{"app": app, "vsn": "0.1.0", "modules": ["Elixir.Fixture"],
                               "application_load_result": "already_loaded"}
                              for app in ["voxel_region", "mmo_contracts", "data_service"]],
            "loaded_before": [{"module": "Elixir.Fixture", "status": "not_loaded"}],
            "loaded_after": [{"module": "Elixir.Fixture", "status": "loaded", "beam": "fixture.beam"}],
            "phases": {"started_us": 2, "manifest_completed_us": 3, "load_started_us": 4,
                       "load_completed_us": 5, "completed_us": 6},
            "started_utc": "2026-10-28T00:00:00Z", "completed_utc": "2026-10-28T00:00:00Z"},
        "startup_phases": {"migration_started_us": 0, "migration_completed_us": 1,
                           "application_starts": [{"app": "voxel_region", "started_us": 7, "completed_us": 8}],
                           "ready_us": 9}}


class M0ReadyTest(unittest.TestCase):
    def start_with_ready(self, ready):
        with tempfile.TemporaryDirectory() as tmp:
            deploy = Path(tmp)
            child = Mock(pid=123, returncode=None)
            child.poll.return_value = None

            def launch(*_args, **_kwargs):
                (deploy / "m0-ready.json").write_text(json.dumps(ready), encoding="utf-8")
                return child

            with patch.object(m0, "status", return_value={"running": False}), \
                 patch.object(m0, "config", return_value={"node": "fixture@127.0.0.1", "cookie": "fake", "schedulers": "1:1", "env": {}}), \
                 patch.object(m0.subprocess, "Popen", side_effect=launch), \
                 patch.object(m0.psutil, "Process", return_value=SimpleNamespace(create_time=lambda: 12)), \
                 patch.object(m0, "mem", return_value=[]):
                return m0.start(deploy)

    def test_old_ready_is_rejected_by_real_start(self):
        with self.assertRaisesRegex(RuntimeError, "M0 readiness.*startup_profile"):
            self.start_with_ready({"os_pid": 321, "node": "fixture@127.0.0.1", "ready_utc": "old"})

    def test_qualified_ready_is_returned_with_explicit_profile_and_actual_mode(self):
        ready = ready_fixture()
        started = self.start_with_ready(ready)
        self.assertEqual(started["ready"], ready)
        self.assertEqual(started["startup_profile"], "m0_manifest_ready_v1")
        self.assertEqual(started["code_mode"], "interactive")

    def test_missing_or_unqualified_new_ready_is_rejected(self):
        mutations = [
            ("actual mode", lambda r: r.pop("code_mode")),
            ("code facts", lambda r: r.pop("code_ready")),
            ("loader failure", lambda r: r["code_ready"].update(ensure_modules_loaded_result="error")),
            ("not ready", lambda r: r["code_ready"].update(status="failed")),
            ("incomplete loaded", lambda r: r["code_ready"].update(loaded_count=0)),
            ("missing manifest", lambda r: r["code_ready"].pop("app_manifests")),
            ("missing version", lambda r: r["code_ready"]["app_manifests"][0].pop("vsn")),
            ("missing loaded results", lambda r: r["code_ready"].pop("loaded_after")),
            ("module still not loaded", lambda r: r["code_ready"]["loaded_after"][0].update(status="not_loaded")),
            ("missing phases", lambda r: r["code_ready"].pop("phases")),
            ("World before code ready", lambda r: r["startup_phases"]["application_starts"][0].update(started_us=5)),
            ("wrong node", lambda r: r.update(node="other@127.0.0.1"))]
        for name, mutate in mutations:
            with self.subTest(name=name):
                ready = copy.deepcopy(ready_fixture())
                mutate(ready)
                with self.assertRaisesRegex(RuntimeError, "M0 readiness"):
                    self.start_with_ready(ready)


if __name__ == "__main__":
    unittest.main()
