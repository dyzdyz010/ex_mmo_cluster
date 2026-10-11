"""只测试：配对干预只改变自传内容，不能改变 World 或覆盖原证据。"""
import copy
import json
import unittest
from long_horizon import permute_biography


class PairingTest(unittest.TestCase):
    def test_permutation_leaves_authority_tools_goal_and_trait_identical(self):
        context = {'self': {'entity_id': 7, 'position': [1, 2, 3]},
                   'entities': [{'entity_id': 101}], 'outcomes': [{'actor': 101}], 'goal': 'Choose freely',
                   'mind': {'cid': 7, 'traits': {'caution': .36}, 'relationships': {'101': {'trust': -1}, '202': {'trust': 1}}},
                   'mental_models': {'relationships': 'Actor 101 damaged; Actor 202 repaired.'},
                   'memories': [{'text': 'Actor 202 helped.'}], 'current_plan': None, 'recent_notes': []}
        body = {'input': json.dumps(context), 'tools': [{'name': 'move_to'}, {'name': 'set_plan'}]}
        original = copy.deepcopy(body)
        swapped = permute_biography(body, 101, 202)
        changed = json.loads(swapped['input'])
        for key in ('self', 'entities', 'outcomes', 'goal'):
            self.assertEqual(changed[key], context[key])
        self.assertEqual(changed['mind']['traits'], context['mind']['traits'])
        self.assertEqual(swapped['tools'], body['tools'])
        self.assertEqual(changed['mind']['relationships']['202']['trust'], -1)
        self.assertEqual(changed['mental_models']['relationships'], 'Actor 202 damaged; Actor 101 repaired.')
        self.assertEqual(changed['memories'][0]['text'], 'Actor 101 helped.')
        self.assertEqual(body, original)
        self.assertEqual(json.loads(permute_biography(swapped, 101, 202)['input']), context)


if __name__ == '__main__':
    unittest.main()
