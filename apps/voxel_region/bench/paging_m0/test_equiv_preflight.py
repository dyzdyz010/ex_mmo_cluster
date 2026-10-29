"""只测试：真实历史源码与隔离环境资格在任何还原/启动前接纳。"""
from unittest import TestCase, mock
from pathlib import Path
import equiv


class EquivPreflightTest(TestCase):
    def test_unverified_historical_source_does_not_restore_or_start(self):
        with mock.patch("sys.argv", ["equiv.py", "unused", "unused-output", "--dump", "unused", "--historical-repo", "wrong"]), \
             mock.patch.object(equiv, "verify_historical_repo", side_effect=ValueError("historical source rejected")), \
             mock.patch.object(equiv.m0, "config") as config, \
             mock.patch.object(equiv, "restore") as restore, \
             mock.patch.object(equiv.m0, "start") as start, \
             mock.patch.object(equiv, "MemoryWatchdog"), \
             mock.patch.object(equiv.Path, "write_text"), \
             mock.patch.object(equiv.Path, "mkdir") as mkdir:
            with self.assertRaisesRegex(ValueError, "historical source rejected"):
                equiv.main()
            config.assert_not_called()
            restore.assert_not_called()
            start.assert_not_called()
            mkdir.assert_not_called()

    def test_non_isolated_database_does_not_restore_or_start(self):
        cfg = {"pg": {"db": "protected_world"}, "env": {"MMO_DB_NAME": "protected_world"}}
        with mock.patch("sys.argv", ["equiv.py", "unused", "unused-output", "--dump", "unused", "--historical-repo", "history"]), \
             mock.patch.object(equiv, "verify_historical_repo", return_value=Path("history")), \
             mock.patch.object(equiv.m0, "config", return_value=cfg), \
             mock.patch.object(equiv, "restore") as restore, \
             mock.patch.object(equiv.m0, "start") as start, \
             mock.patch.object(equiv.Path, "mkdir") as mkdir:
            with self.assertRaisesRegex(ValueError, "explicitly isolated"):
                equiv.main()
            restore.assert_not_called()
            start.assert_not_called()
            mkdir.assert_not_called()

    def test_historical_checkout_only_accepts_declared_di_change(self):
        original = "log: VoxelRegion.OverlayLog.Db\n"
        patched = "log: Application.get_env(:voxel_region, :log_backend, VoxelRegion.OverlayLog.Db)\n"
        application = "apps/voxel_region/lib/voxel_region/application.ex"
        for changed, accepted in ((application, True), (application + "\napps/voxel_region/lib/voxel_region/world/canonical.ex", False)):
            with self.subTest(changed=changed), \
                 mock.patch.object(equiv.subprocess, "run", side_effect=[
                     mock.Mock(stdout=equiv.HISTORICAL_COMMIT), mock.Mock(stdout=original), mock.Mock(stdout=changed)]), \
                 mock.patch.object(Path, "read_text", return_value=patched):
                if accepted:
                    self.assertEqual(equiv.verify_historical_repo("history"), Path("history").resolve())
                else:
                    with self.assertRaisesRegex(ValueError, "unexpected historical"):
                        equiv.verify_historical_repo("history")
