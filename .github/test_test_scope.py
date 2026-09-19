"""只测试：CI 范围的独立变更和共享契约边界。"""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("scope", Path(__file__).with_name("test-scope.py"))
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)


class ScopeTests(unittest.TestCase):
    def test_docs_do_not_start_runtime(self):
        self.assertEqual(scope.select(["docs/README.md"]), [])

    def test_phase_does_not_require_auth(self):
        jobs = scope.select(["apps/voxel_region/lib/voxel_region/phase.ex"])
        self.assertIn("test-voxel-region", jobs)
        self.assertNotIn("test-auth-server", jobs)
        self.assertNotIn("smoke-ws-dual", jobs)

    def test_wire_selects_producer_and_consumers(self):
        jobs = scope.select(["apps/mmo_contracts/lib/mmo_contracts/voxel/codec.ex"])
        self.assertTrue({"test-mmo-contracts", "test-voxel-region", "test-gate-server", "test-scene-server"} <= set(jobs))

    def test_unknown_mapping_is_not_success(self):
        with self.assertRaises(ValueError):
            scope.select(["new_runtime/runtime.ex"])

    def test_shared_fixture_selects_actual_consumers(self):
        self.assertEqual(scope.select(["apps/voxel_region/test/support/prefab_fixture.exs"]),
                         ["format", "test-scene-server", "test-voxel-region"])
        jobs = scope.select(["apps/data_service/test/support/database.exs"])
        self.assertTrue({"test-data-service", "test-gate-server", "test-scene-server", "test-standalone", "test-voxel-region"} <= set(jobs))

    def test_world_fixture_selects_gate_route_consumer(self):
        self.assertEqual(scope.select(["apps/voxel_region/test/support/world_fixtures.exs"]),
                         ["format", "test-gate-server", "test-scene-server", "test-voxel-region"])

    def test_moved_tests_select_their_owning_apps(self):
        self.assertEqual(scope.select(["apps/gate_server/test/movement_route_test.exs"]),
                         ["format", "test-gate-server"])
        self.assertEqual(scope.select(["apps/world_server/test/world_server/scene_interface_announce_test.exs"]),
                         ["format", "test-standalone"])

    def test_executable_document_is_not_prose(self):
        self.assertEqual(scope.select(["docs/acceptance/run.py"]), ["smoke-ws-dual"])


if __name__ == "__main__":
    unittest.main()
