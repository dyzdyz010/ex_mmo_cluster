"""只测试：run07 观察站位不能把细化格当成整格地面，不需要服务端或客户端。"""
import json
import tempfile
import unittest
from pathlib import Path

import npc_run07_observe as observe
import smelting_plan as sp


class StandTests(unittest.TestCase):
    def test_import_does_not_change_shared_planner_world_contract(self):
        self.assertTrue(sp.stand_ok(sp.World({(0, 0, 0): 11}), (0, 1, 0)))

    def test_refined_panel_is_an_obstacle_but_not_a_full_height_floor(self):
        # run07 的失败列：下面是天然砾石，其上是一格内仅 64/512 micro 的面板。
        # 相邻列是普通完整砾石，供原有可站条件作正例。
        rows = [[67, 414, -511, 6, 0, 0, [], []],
                [67, 415, -511, 0, 1, 0, [1020788740096], [2060]],
                [68, 415, -511, 6, 0, 0, [], []]]
        previous = observe.driver.RUN
        try:
            with tempfile.TemporaryDirectory() as directory:
                observe.driver.RUN = Path(directory)
                (Path(directory) / 'observe-world.json').write_text(
                    json.dumps({'rows': rows}), encoding='utf-8')
                _, world = observe.driver.load()
                self.assertNotEqual(0, world.get((67, 415, -511)))
                self.assertFalse(sp.stand_ok(world, (67, 416, -511)))
                self.assertFalse(sp.stand_ok(world, (67, 415, -511)))
                self.assertTrue(sp.stand_ok(world, (68, 416, -511)))
        finally:
            observe.driver.RUN = previous


if __name__ == '__main__':
    unittest.main()
