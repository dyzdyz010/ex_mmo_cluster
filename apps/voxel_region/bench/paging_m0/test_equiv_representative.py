"""只测试候选判定器的差异边界；所有见证是两格合法样本的手算值，未运行。"""
import copy
import unittest

import equiv
from test_equiv import capture


def alternate(value):
    # 同一部件可在材质9/防御2或材质10/防御7两格取代表；真值摘要在两边相同。
    row = value['q5']['properties'][0]
    row['property'].update(micro=[8, 0, 0], material=10, defense=7.0)
    row['representative_witness']['target'].update(micro=[8, 0, 0], material=10)
    row['representative_witness']['catalog_defense'] = 7.0


class RepresentativeSemanticsTest(unittest.TestCase):
    def test_legitimate_two_material_representatives_report_all_changed_fields(self):
        h, a, b = capture('H'), capture('A'), capture('B')
        alternate(h)
        result = equiv.compare_three(h, a, b)
        self.assertTrue(result['equal'])
        self.assertEqual(set(result['historical_q5']['representative_differences'][0]['fields']),
                         {'micro', 'material', 'defense'})

    def test_missing_or_wrong_witness_cannot_authorize_changed_property(self):
        mutations = [
            lambda r: r.pop('representative_witness'),
            lambda r: r['property'].update(micro=[99, 0, 0]),
            lambda r: r['property'].update(material=11),
            lambda r: r['property'].update(defense=8.0),
            lambda r: r['representative_witness']['target'].update(owner=[4, 8]),
            lambda r: r['representative_witness'].update(target=None),
            lambda r: r['representative_witness'].update(seq=8),
            lambda r: r['representative_witness'].update(content_version=5),
            lambda r: r['representative_witness'].update(property_digest='bb' * 32),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                h, a, b = capture('H'), capture('A'), capture('B')
                alternate(h)
                mutation(h['q5']['properties'][0])
                result = equiv.compare_three(h, a, b)
                self.assertFalse(result['equal'])
                self.assertTrue(result['historical_q5']['representative_witness_errors'])

    def test_coherent_point_witness_does_not_hide_changed_canonical_material_or_base(self):
        for field in ('refined', 'region_bases', 'damage'):
            with self.subTest(field=field):
                h, a, b = capture('H'), capture('A'), capture('B')
                h['digests'][field] = '1:corrupt'
                if field == 'damage':
                    h['q5']['damage_without_max_hp'] = '1:corrupt'
                self.assertFalse(equiv.compare_three(h, a, b)['equal'])
        h, a, b = capture('H'), capture('A'), capture('B')
        h['reads']['0,0,0,0'] = 'changed_payload'
        self.assertFalse(equiv.compare_three(h, a, b)['equal'])

    def test_hp_and_current_migration_never_borrow_representative_equivalence(self):
        h, a, b = capture('H'), capture('A'), capture('B')
        alternate(h)
        h['q5']['properties'][0]['property']['hp'] = 4.0
        self.assertFalse(equiv.compare_three(h, a, b)['equal'])
        h, a, b = capture('H'), capture('A'), capture('B')
        alternate(b)
        result = equiv.compare_three(h, a, b)
        self.assertFalse(result['current_migration_equal'])
        self.assertFalse(result['equal'])


if __name__ == '__main__':
    unittest.main()
