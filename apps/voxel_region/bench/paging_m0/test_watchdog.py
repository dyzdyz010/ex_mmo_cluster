"""只测试：用假的 OS 进程树验证护栏；不启动、终止任何真实进程。"""
import threading
import tempfile
import json
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import equiv
import migrate
import run_m0


class WatchdogTest(unittest.TestCase):
    def test_all_entrypoints_fail_after_guard_tree_access_denied(self):
        root = Mock()
        root.children.side_effect = equiv.psutil.AccessDenied(123)
        real_thread = threading.Thread

        def joined_thread(*args, **kwargs):
            worker = real_thread(*args, **kwargs)
            start = worker.start

            def start_and_join():
                start()
                worker.join(1)
                self.assertFalse(worker.is_alive(), "fake OS failure did not finish")

            worker.start = start_and_join
            return worker

        # equiv完整采集在资源操作前拒绝，其入口由test_equiv_preflight单独覆盖。
        for module in [run_m0, migrate]:
            with self.subTest(entrypoint=module.__name__), tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp) / "run"
                with patch("sys.argv", [module.__name__ + ".py", "deploy", str(out), "--dump", "fake.dump"]), \
                     patch.object(module.m0, "config", return_value={}), \
                     patch.object(module, "restore", return_value="restored"), \
                     patch.object(module.m0, "start") as start, \
                     patch.object(module.m0, "status", return_value={"running": False}), \
                     patch.object(run_m0.subprocess, "run", return_value=SimpleNamespace(stdout="")), \
                     patch.object(equiv.psutil, "Process", return_value=root), \
                     patch.object(equiv.psutil, "virtual_memory", return_value=SimpleNamespace(available=19 * 2**30)), \
                     patch.object(threading, "Thread", side_effect=joined_thread):
                    with self.assertRaisesRegex(RuntimeError, "memory watchdog.*AccessDenied"):
                        module.main()

                start.assert_not_called()
                state = json.loads((out / "memory_watchdog.json").read_text())
                self.assertTrue(state["tripped"])
                self.assertEqual(state["error"]["type"], "AccessDenied")
                meta = json.loads((out / "meta.json").read_text())
                self.assertEqual(meta["memory_watchdog_error"], state["error"])

    def test_guard_records_root_name_and_kill_failures(self):
        for where in ["root", "name", "kill"]:
            with self.subTest(boundary=where), tempfile.TemporaryDirectory() as tmp:
                failed = threading.Event()
                error = equiv.psutil.AccessDenied(222)

                def deny(*_args):
                    failed.set()
                    raise error

                owned = Mock()
                owned.name.return_value = "erl.exe"
                root = Mock()
                root.children.return_value = [owned]
                if where == "name":
                    owned.name.side_effect = deny
                elif where == "kill":
                    owned.kill.side_effect = deny
                process = Mock(return_value=root, side_effect=deny if where == "root" else None)
                out, meta = Path(tmp), {}
                with patch.object(equiv.psutil, "Process", process), \
                     patch.object(equiv.psutil, "virtual_memory", return_value=SimpleNamespace(available=19 * 2**30)):
                    with self.assertRaisesRegex(RuntimeError, "memory watchdog.*AccessDenied") as caught:
                        with equiv.MemoryWatchdog(out, meta):
                            self.assertTrue(failed.wait(1), "fake OS failure was not reached")
                self.assertIs(caught.exception.__cause__, error)
                self.assertEqual(meta["memory_watchdog_error"]["type"], "AccessDenied")
                self.assertEqual(meta["memory_watchdog_tripped"], where != "root")

    def test_guard_preserves_primary_failure_and_records_secondary_guard_error(self):
        error = equiv.psutil.AccessDenied(333)
        primary = RuntimeError("original restore failed")
        with tempfile.TemporaryDirectory() as tmp, patch.object(equiv, "watchdog", side_effect=error):
            out, meta = Path(tmp), {}
            with self.assertRaises(RuntimeError) as caught:
                with equiv.MemoryWatchdog(out, meta):
                    raise primary
            self.assertIs(caught.exception, primary)
            self.assertEqual(meta["memory_watchdog_error"]["type"], "AccessDenied")

    def test_successful_guard_exit_records_clean_status(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(equiv, "watchdog"):
            out, meta = Path(tmp), {}
            with equiv.MemoryWatchdog(out, meta):
                pass
            self.assertEqual(meta, {"memory_watchdog_tripped": False, "memory_watchdog_error": None})
            self.assertFalse((out / "memory_watchdog_tripped").exists())

    def test_trip_cannot_be_reported_as_a_successful_run(self):
        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(equiv, "watchdog", side_effect=lambda _stop, tripped: tripped.set()):
            out, meta = Path(tmp), {}
            with self.assertRaisesRegex(MemoryError, "memory watchdog"):
                with equiv.MemoryWatchdog(out, meta):
                    pass
            self.assertTrue(meta["memory_watchdog_tripped"])
            self.assertIsNone(meta["memory_watchdog_error"])

    def test_restore_failure_preserves_original_exception_and_trip_evidence(self):
        for module in [migrate]:
            with self.subTest(entrypoint=module.__name__), tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp) / "run"
                observed = threading.Event()
                failure = RuntimeError("original restore failed")

                def trip(_stop, tripped):
                    tripped.set()
                    observed.set()

                def fail_restore(*_args):
                    self.assertTrue(observed.wait(1), "guard did not trip before restore failure")
                    raise failure

                with patch("sys.argv", [module.__name__ + ".py", "deploy", str(out), "--dump", "fake.dump"]), \
                     patch.object(module.m0, "config", return_value={}), \
                     patch.object(module, "restore", side_effect=fail_restore), \
                     patch.object(module.m0, "status", return_value={"running": False}), \
                     patch.object(equiv, "watchdog", side_effect=trip), \
                     patch.object(migrate, "watchdog", side_effect=trip, create=True):
                    with self.assertRaises(RuntimeError) as caught:
                        module.main()

                self.assertIs(caught.exception, failure)
                meta = out / "meta.json"
                self.assertTrue(meta.exists(), "restore failure lost watchdog metadata")
                self.assertTrue(json.loads(meta.read_text())["memory_watchdog_tripped"])

    def test_unrelated_new_erl_is_not_killed(self):
        owned = Mock(pid=21)
        owned.info = {"name": "erl.exe"}
        owned.name.return_value = "erl.exe"
        unrelated = Mock(pid=22)
        unrelated.info = {"name": "erl.exe"}
        unrelated.name.return_value = "erl.exe"
        wrapper = Mock(pid=20)
        wrapper.name.return_value = "cmd.exe"
        root = Mock(pid=10)
        root.children.return_value = [wrapper, owned]
        stop, tripped = threading.Event(), threading.Event()

        with patch.object(equiv.psutil, "process_iter", return_value=[owned, unrelated]), \
             patch.object(equiv.psutil, "Process", return_value=root) as process, \
             patch.object(equiv.psutil, "virtual_memory", return_value=SimpleNamespace(available=19 * 2**30)):
            equiv.watchdog(stop, tripped)

        owned.kill.assert_called_once_with()
        wrapper.kill.assert_not_called()
        unrelated.kill.assert_not_called()
        process.assert_called_once_with()
        root.children.assert_called_once_with(recursive=True)
        self.assertTrue(tripped.is_set())

    def test_descendants_exiting_during_name_or_kill_do_not_hide_trip(self):
        gone_name = Mock(pid=31)
        gone_name.name.side_effect = equiv.psutil.NoSuchProcess(31)
        gone_kill = Mock(pid=32)
        gone_kill.name.return_value = "erl.exe"
        gone_kill.kill.side_effect = equiv.psutil.NoSuchProcess(32)
        owned = Mock(pid=33)
        owned.name.return_value = "erl.exe"
        root = Mock()
        root.children.return_value = [gone_name, gone_kill, owned]
        tripped = threading.Event()

        with patch.object(equiv.psutil, "Process", return_value=root), \
             patch.object(equiv.psutil, "virtual_memory", return_value=SimpleNamespace(available=19 * 2**30)):
            equiv.watchdog(threading.Event(), tripped)

        gone_name.kill.assert_not_called()
        gone_kill.kill.assert_called_once_with()
        owned.kill.assert_called_once_with()
        self.assertTrue(tripped.is_set())

    def test_exactly_twenty_gb_does_not_trip(self):
        root = Mock()
        stop = Mock()
        stop.is_set.side_effect = [False, True]
        tripped = threading.Event()

        with patch.object(equiv.psutil, "Process", return_value=root), \
             patch.object(equiv.psutil, "virtual_memory", return_value=SimpleNamespace(available=20 * 2**30)):
            equiv.watchdog(stop, tripped)

        self.assertFalse(tripped.is_set())
        root.children.assert_not_called()
        stop.wait.assert_called_once_with(1)

    def test_low_memory_before_beam_start_keeps_watching_the_owned_tree(self):
        owned = Mock(pid=41)
        owned.name.return_value = "erl.exe"
        root = Mock()
        root.children.side_effect = [[], [owned]]
        stop = Mock()
        stop.is_set.side_effect = [False, False]
        tripped = threading.Event()

        with patch.object(equiv.psutil, "Process", return_value=root), \
             patch.object(equiv.psutil, "virtual_memory", return_value=SimpleNamespace(available=19 * 2**30)):
            equiv.watchdog(stop, tripped)

        self.assertTrue(tripped.is_set())
        owned.kill.assert_called_once_with()
        stop.wait.assert_called_once_with(1)

    def test_stopped_guard_neither_samples_nor_kills(self):
        stop = threading.Event()
        stop.set()
        tripped = threading.Event()
        root = Mock()
        with patch.object(equiv.psutil, "Process", return_value=root), \
             patch.object(equiv.psutil, "virtual_memory") as memory:
            equiv.watchdog(stop, tripped)

        self.assertFalse(tripped.is_set())
        root.children.assert_not_called()
        memory.assert_not_called()

    def test_startup_failure_keeps_memory_trip_marker(self):
        observed = threading.Event()
        starting = threading.Event()

        def trip(_stop, tripped):
            self.assertTrue(starting.wait(1), "startup did not begin")
            tripped.set()
            observed.set()

        def fail_start(_deploy):
            starting.set()
            self.assertTrue(observed.wait(1), "guard did not trip before startup failure")
            raise RuntimeError("startup failed after guard")

        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "run"
            with patch("sys.argv", ["run_m0.py", "deploy", str(out)]), \
                 patch.object(run_m0.m0, "config", return_value={}), \
                 patch.object(run_m0.m0, "start", side_effect=fail_start), \
                 patch.object(run_m0.m0, "status", return_value={"running": False}), \
                 patch.object(equiv.psutil, "process_iter", return_value=[]), \
                 patch.object(run_m0.subprocess, "run", return_value=SimpleNamespace(stdout="")), \
                 patch.object(equiv, "watchdog", side_effect=trip):
                with self.assertRaisesRegex(RuntimeError, "startup failed after guard"):
                    run_m0.main()

            marker = out / "memory_watchdog_tripped"
            self.assertTrue(marker.exists(), "startup failure lost the memory trip marker")
            self.assertEqual(marker.read_text(), "1")


if __name__ == "__main__":
    unittest.main()
