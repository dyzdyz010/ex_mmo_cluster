import copy
import math
import unittest
import equiv


def capture(side="A"):
    fields = "overlay region_bases refined attachments liquid_units macro_owners damage instances attachment_owners material_balances caster_energy material_supplies craft_ledger food_ledger food_receipts beacons beacon_attunements phase_inventory epochs placed_by seq attachment_serial material_units_per_micro interaction_history interaction_floor liquid_active sources thermal protection".split()
    return {"content_version": 4, "seq": 9,
            "coverage": {"schema": "paging-live-audit-v1", "side": side, "start_seq": 9, "end_seq": 9,
                         "published_start": None if side in ("H", "A") else 9,
                         "published_end": None if side in ("H", "A") else 9,
                         "expected_regions": ["0,0,0,0"],
                         "expected_identities": [{"granularity": 2, "owner": [4, 7]}]},
            "digests": dict.fromkeys(fields, "0:0") | {"damage": "1:old", "material_balances": "1:same"},
            "reads": {"0,0,0,0": "same"},
            "q5": {"damage_without_max_hp": "1:exact", "properties": [
                {"identity": {"granularity": 2, "owner": [4, 7]},
                 "property": {"granularity": 2, "owner": [4, 7], "incarnation": 4,
                              "micro": [0, 0, 0], "hp": 5.0, "max_hp": 10.0, "material": 9,
                              "defense": 2.0, "digest": "aa" * 32},
                 "representative_witness": {"schema": "canonical_g2_point_v1", "seq": 9, "content_version": 4,
                     "target": {"micro": [0, 0, 0], "granularity": 2, "owner": [4, 7],
                                "incarnation": 4, "material": 9}, "catalog_defense": 2.0,
                     "property_digest": "aa" * 32}}]}}


class EquivTest(unittest.TestCase):
    def test_complete_same_sequence_live_a_and_cold_b_are_eligible(self):
        self.assertTrue(equiv.compare(capture("A"), capture("B"))["capture_complete"])

    def test_same_missing_private_field_cannot_pass_both_sides(self):
        a, b = capture("A"), capture("B")
        del a["digests"]["food_receipts"]
        del b["digests"]["food_receipts"]
        self.assertFalse(equiv.compare(a, b)["capture_complete"])

    def test_same_omitted_cold_page_cannot_pass_both_sides(self):
        a, b = capture("A"), capture("B")
        for value in (a, b):
            value["coverage"]["expected_regions"].append("0,-1,2,3")
        self.assertFalse(equiv.compare(a, b)["capture_complete"])

    def test_missing_attachment_in_both_snapshots_is_not_complete(self):
        a, b = capture("A"), capture("B")
        for value in (a, b):
            value["coverage"]["expected_identities"].append({"granularity": 3, "incarnation": 17})
        self.assertFalse(equiv.compare(a, b)["capture_complete"])

    def test_sequence_change_and_published_a_are_rejected(self):
        for field, value in [("end_seq", 10), ("published_start", 9), ("published_end", 9)]:
            with self.subTest(field=field):
                a = capture("A")
                a["coverage"][field] = value
                self.assertFalse(equiv.compare(a, capture("B"))["capture_complete"])

    def test_unpublished_b_and_legacy_capture_are_rejected(self):
        b = capture("B")
        b["coverage"]["published_start"] = None
        self.assertFalse(equiv.compare(capture("A"), b)["capture_complete"])
        a = capture("A")
        del a["coverage"]
        self.assertFalse(equiv.compare(a, capture("B"))["capture_complete"])

    def test_two_individually_stable_but_different_sequences_are_rejected(self):
        b = capture("B")
        b["seq"] = 10
        b["coverage"].update(start_seq=10, end_seq=10)
        self.assertFalse(equiv.compare(capture("A"), b)["capture_complete"])

    def compare_change(self, change):
        a = capture()
        b = copy.deepcopy(a)
        change(b)
        return equiv.compare(a, b)

    def test_one_last_bit_max_hp_difference_is_reported(self):
        def change(b):
            b["digests"]["damage"] = "1:new"
            b["q5"]["properties"][0]["property"]["max_hp"] = math.nextafter(10.0, math.inf)
        result = self.compare_change(change)
        self.assertTrue(result["q5_equal"])
        self.assertEqual(result["field_diff"], [])
        self.assertEqual(result["max_hp_differences"], [{"identity": {"granularity": 2, "owner": [4, 7]},
            "before_max_hp": 10.0, "after_max_hp": math.nextafter(10.0, math.inf),
            "delta": math.nextafter(10.0, math.inf) - 10.0}])

    def test_current_hp_difference_is_rejected(self):
        r = self.compare_change(lambda b: b["q5"]["properties"][0]["property"].__setitem__("hp", 5.000000000000001))
        self.assertFalse(r["q5_equal"])

    def test_missing_identity_is_rejected(self):
        self.assertFalse(self.compare_change(lambda b: b["q5"]["properties"].clear())["q5_equal"])

    def test_added_identity_is_rejected(self):
        def change(b):
            row = copy.deepcopy(b["q5"]["properties"][0])
            row["identity"]["owner"] = [8, 9]
            row["property"]["owner"] = [8, 9]
            b["q5"]["properties"].append(row)
        self.assertFalse(self.compare_change(change)["q5_equal"])

    def test_other_property_difference_is_rejected(self):
        self.assertFalse(self.compare_change(lambda b: b["q5"]["properties"][0]["property"].__setitem__("material", 10))["q5_equal"])

    def test_more_than_one_last_bit_is_rejected(self):
        def change(b):
            b["q5"]["properties"][0]["property"]["max_hp"] = 11.0
        self.assertFalse(self.compare_change(change)["q5_equal"])

    def test_attachment_max_hp_difference_is_rejected(self):
        def change(b):
            for obj in (b["q5"]["properties"][0]["identity"], b["q5"]["properties"][0]["property"]):
                obj["granularity"] = 3
                obj["incarnation"] = 17
                del obj["owner"]
        a = capture()
        change(a)
        b = copy.deepcopy(a)
        b["q5"]["properties"][0]["property"]["max_hp"] = math.nextafter(10.0, math.inf)
        self.assertFalse(equiv.compare(a, b)["q5_equal"])

    def test_other_damage_fields_cannot_be_hidden_by_summary_exception(self):
        def change(b):
            b["digests"]["damage"] = "1:new"
            b["q5"]["damage_without_max_hp"] = "1:changed"
        result = self.compare_change(change)
        self.assertFalse(result["q5_equal"])
        self.assertIn("damage", result["field_diff"])

    def test_content_version_difference_is_rejected(self):
        self.assertFalse(self.compare_change(lambda b: b.__setitem__("content_version", 5))["q5_equal"])


class ThreeCaptureTest(unittest.TestCase):
    """只测试新三产物门禁；不重复既有逐字段/身份反例。"""

    def test_historical_last_bit_is_listed_but_current_migration_is_exact(self):
        h, a, b = capture("H"), capture("A"), capture("B")
        h["q5"]["properties"][0]["property"]["max_hp"] = math.nextafter(10.0, -math.inf)
        result = equiv.compare_three(h, a, b)
        self.assertTrue(result["equal"])
        self.assertEqual(result["counts"]["max_hp_differences"], 1)
        self.assertEqual(result["historical_q5"]["max_hp_differences"][0]["after_max_hp"], 10.0)

    def test_current_migration_cannot_borrow_the_historical_exception(self):
        h, a, b = capture("H"), capture("A"), capture("B")
        b["q5"]["properties"][0]["property"]["max_hp"] = math.nextafter(10.0, math.inf)
        result = equiv.compare_three(h, a, b)
        self.assertFalse(result["current_migration_equal"])
        self.assertFalse(result["equal"])

    def test_current_raw_damage_difference_is_never_removed_by_q5_mask(self):
        h, a, b = capture("H"), capture("A"), capture("B")
        b["digests"]["damage"] = "1:new"
        result = equiv.compare_three(h, a, b)
        self.assertFalse(result["current_migration_equal"])
        self.assertEqual(result["current_migration"]["strict_field_diff"], ["damage"])

    def test_historical_representative_and_actual_hp_remain_strict(self):
        for key, value in (("micro", [1, 2, 3]), ("hp", 5.000000000000001)):
            with self.subTest(field=key):
                h, a, b = capture("H"), capture("A"), capture("B")
                h["q5"]["properties"][0]["property"][key] = value
                result = equiv.compare_three(h, a, b)
                self.assertFalse(result["historical_q5_equal"])
                self.assertEqual(result["historical_q5"]["q5_property_diff"], [{"granularity": 2, "owner": [4, 7]}])

    def test_historical_capture_must_share_the_current_cut(self):
        h, a, b = capture("H"), capture("A"), capture("B")
        h["seq"] = 8
        h["coverage"].update(start_seq=8, end_seq=8)
        result = equiv.compare_three(h, a, b)
        self.assertFalse(result["equal"])
        self.assertIn({"side": "H/B", "reason": "different_capture_sequence"}, result["historical_capture_errors"])


class StaticCutContractTest(unittest.TestCase):
    """只验证新增的C0→X资格；不能靠已有published前缀冒充选中切点发布前。"""
    def test_static_cut_requires_actual_completion_and_exact_selected_sequence(self):
        h, a, b = capture("H"), capture("A"), capture("B")
        for value in (h, a):
            value["coverage"].update(published_start=8, published_end=8,
                initialization={"complete": True, "initial_cut": 8, "selected_cut": 9})
        self.assertTrue(equiv.compare_three(h, a, b)["equal"])
        for key, invalid in (("complete", False), ("initial_cut", 7), ("selected_cut", 10)):
            with self.subTest(field=key):
                changed = copy.deepcopy(a)
                changed["coverage"]["initialization"][key] = invalid
                self.assertFalse(equiv.compare_three(h, changed, b)["equal"])


if __name__ == "__main__":
    unittest.main()
