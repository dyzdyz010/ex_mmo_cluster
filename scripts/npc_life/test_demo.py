"""只测试：真实场景判定器的最小反例，不替代产品模块测试。"""
import copy
import sys
import unittest
sys.dont_write_bytecode = True
from demo import behavior_evidence, approach_evidence


class BehaviorJudgeTest(unittest.TestCase):
    def rows(self):
        first = {'at_ms': 0, 'interactions': {'events': [{'seq': 7, 'actor': 2, 'cell': [61,416,-517]}]},
                 'body': {'position': [3,1,0], 'entities': {'2': {'position': [0,1,0]}}},
                 'life': {'decision': {'social': {'mode': 'avoid', 'source_seq': 7, 'actor': 2, 'target': [7,1,0]},
                                       'last_outcome': None}}}
        last = copy.deepcopy(first)
        last['at_ms'] = 1000
        last['body']['position'] = [7,3,0]
        last['life']['decision'] = {'social': None, 'last_outcome': {'id': ['social',1], 'verb': 'move_to', 'status': 'done',
                                   'data': {'position': [7,3,0], 'within_tolerance': True,'settled': True}}}
        return [first,last]

    def test_authority_outcome_on_slope_proves_xyz_distance_change(self):
        result, = behavior_evidence(self.rows(), {'a': 2,'b': 3})
        self.assertTrue(result['accepted'])

    def test_count_or_mode_without_terminal_is_rejected(self):
        result, = behavior_evidence(self.rows()[:1], {'a': 2,'b': 3})
        self.assertFalse(result['accepted'])

    def test_wrong_actor_is_rejected(self):
        result, = behavior_evidence(self.rows(), {'a': 99,'b': 3})
        self.assertFalse(result['accepted'])

    def test_rejected_authority_movement_is_rejected(self):
        rows = self.rows()
        rows[-1]['life']['decision']['last_outcome']['status'] = 'rejected'
        result, = behavior_evidence(rows, {'a': 2,'b': 3})
        self.assertFalse(result['accepted'])

    def test_unrelated_transaction_is_rejected(self):
        rows = self.rows()
        rows[0]['interactions']['events'][0]['cell'] = [60,416,-517]
        result, = behavior_evidence(rows, {'a': 2,'b': 3})
        self.assertFalse(result['accepted'])

    def test_previous_move_terminal_cannot_prove_new_source(self):
        rows = self.rows()
        rows[0]['life']['decision']['last_outcome'] = copy.deepcopy(rows[-1]['life']['decision']['last_outcome'])
        result, = behavior_evidence(rows, {'a': 2,'b': 3})
        self.assertFalse(result['accepted'])

    def test_cancelled_opportunity_cannot_borrow_next_same_source_terminal(self):
        rows = self.rows()
        social = copy.deepcopy(rows[0]['life']['decision']['social'])
        cancel = {'id':['social',1],'verb':'move_to','status':'cancelled',
                  'data':{'position':[3,1,0],'settled':True}}
        release = copy.deepcopy(rows[0])
        release['at_ms'] = 1000
        release['life']['decision'] = {'social':None,'last_outcome':cancel}
        retry = copy.deepcopy(rows[0])
        retry['at_ms'] = 2000
        retry['life']['decision'] = {'social':social,'last_outcome':cancel}
        done = copy.deepcopy(rows[1])
        done['at_ms'] = 3000
        done['life']['decision']['social'] = social
        done['life']['decision']['last_outcome']['id'] = ['social',2]
        result = behavior_evidence([rows[0],release,retry,done],{'a':2,'b':3})
        self.assertEqual([r['accepted'] for r in result],[False,True])
        self.assertEqual(result[1]['terminal_at_ms'],3000)
        self.assertEqual(result[1]['terminal']['id'],['social',2])
        self.assertNotEqual(result[0]['opportunity_id'],result[1]['opportunity_id'])

    def test_terminal_after_declared_approach_window_is_rejected(self):
        rows = self.rows()
        rows[-1]['at_ms'] = 30000
        result, = behavior_evidence(rows,{'a':2,'b':3},fixture_windows={'avoid':[(0,10000)],'thank':[]})
        self.assertFalse(result['accepted'])
        self.assertEqual(result['terminal_at_ms'],30000)
        self.assertFalse(result['terminal_in_approach_window'])

    def test_thank_terminal_on_immediate_nil_release_row_is_accepted(self):
        rows = self.rows()
        rows[0]['body']['position'] = [7,1,0]
        rows[0]['body']['entities'] = {'3':{'position':[0,1,0]}}
        rows[0]['interactions']['events'][0]['actor'] = 3
        rows[0]['life']['decision']['social'].update(mode='thank',actor=3,target=[3,1,0])
        rows[1]['body']['position'] = [3,3,0]
        rows[1]['life']['decision']['last_outcome']['data']['position'] = [3,3,0]
        result, = behavior_evidence(rows,{'a':2,'b':3},fixture_windows={'avoid':[],'thank':[(0,2000)]})
        self.assertTrue(result['accepted'])
        self.assertEqual(result['terminal_at_ms'],1000)
        self.assertEqual(result['terminal']['id'],['social',1])

    def test_personality_nearby_but_unmatched_distance_is_rejected(self):
        rows = self.rows()
        for i,row in enumerate(rows):
            row['at_ms'] = i*1000
            row['life']['state'] = {'relationships':{}}
        rows[0]['life']['decision']['social'].update(mode='cautious',source_seq=40)
        rows[1]['life']['decision']['social'] = copy.deepcopy(rows[0]['life']['decision']['social'])
        result = approach_evidence(rows,2,[0,1,0],500,2000)
        self.assertFalse(result['matching_distance_accepted'])
        self.assertFalse(result['accepted'])

    def test_personality_cannot_reuse_a_previous_move_outcome(self):
        rows = self.rows()
        for i,row in enumerate(rows):
            row['at_ms'] = i*1000
            row['life']['state'] = {'relationships':{}}
        rows[0]['body']['position'] = [3.4,1,0]
        rows[0]['life']['decision']['last_outcome'] = copy.deepcopy(rows[-1]['life']['decision']['last_outcome'])
        rows[1]['life']['decision']['social'] = copy.deepcopy(rows[0]['life']['decision']['social'])
        rows[1]['life']['decision']['social'].update(mode='cautious',source_seq=40)
        result = approach_evidence(rows,2,[0,1,0],500,2000)
        self.assertTrue(result['matching_distance_accepted'])
        self.assertFalse(result['accepted'])


if __name__ == '__main__':
    unittest.main()
