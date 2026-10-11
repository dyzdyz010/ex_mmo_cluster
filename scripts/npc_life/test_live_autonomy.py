"""只测试：无玩家开场的逐笔对话门禁及输入阶段边界；不启动客户端、服务器或模型。"""
import copy
import json
import unittest
import tempfile
from pathlib import Path
from unittest.mock import patch
import live_autonomy as a


class ConversationTest(unittest.TestCase):
    def sample(self):
        authority=[dict(conversation_id=123,turn=i+1,speaker_id=a.CIDS[i],target_id=a.CIDS[1-i],text=text,recipients=a.CIDS+list(a.ACTORS))
                   for i,text in enumerate(['你好，邻居。','你好，我想先了解你的看法。'])]
        observed={r:[dict(e,event='dialogue.speech',receiver_id=cid) for e in authority] for r,cid in zip(('a','b'),a.ACTORS)}
        requests=[{'status':'ok','request':{'input':json.dumps({'self':{'entity_id':e['speaker_id']}})},
                   'calls':[{'name':'say','arguments':json.dumps({'text':e['text']})}]} for e in authority]
        return authority,observed,requests

    def test_two_models_and_both_copies_required(self):
        authority,observed,requests=self.sample()
        self.assertIsNotNone(a.conversation(authority,observed,requests))
        for changed in [([],observed,requests),(authority[:1],observed,requests),(authority,observed,requests[:1])]:
            self.assertIsNone(a.conversation(*changed))
        observed['b'].pop()
        self.assertIsNone(a.conversation(authority,observed,requests))

    def test_wrong_conversation_player_trigger_and_corrupt_copy(self):
        authority,observed,requests=self.sample()
        separate=copy.deepcopy(authority);separate[1]['conversation_id']=124
        self.assertIsNone(a.conversation(separate,observed,requests))
        bad=copy.deepcopy(authority);bad[0]['speaker_id']=a.ACTORS[0]
        with self.assertRaises(AssertionError):a.conversation(bad,observed,requests)
        observed['a'][0]['text']='伪造内容'
        with self.assertRaises(AssertionError):a.conversation(authority,observed,requests)

    def test_npc_only_audience_cannot_release_the_dual_client_stage(self):
        authority,observed,requests=self.sample()
        for e in authority:e['recipients']=a.CIDS
        self.assertIsNone(a.conversation(authority,{'a':[],'b':[]},requests))

    def test_gate_close_failure_still_restores_both_npcs_and_stops_trace(self):
        rows=[{'cid':cid,'brain':'settler','params':{'tools':{}},'name':str(cid)} for cid in a.CIDS]
        def budget(action='status'):
            if action=='close':raise OSError('docker close failed')
            return {'in_flight_tokens':0}
        with tempfile.TemporaryDirectory() as tmp, patch.object(a.budget,'budget',side_effect=budget), patch.object(a.budget,'docker') as docker, patch.object(a,'body',return_value={'position':[1,2,3]}), patch.object(a,'register') as register, patch.object(a.demo,'observe',return_value={}), patch.object(a.demo,'rpc',return_value='ok') as rpc:
            errors=[]
            a.shutdown(Path(tmp),rows,a.CIDS,errors)
            self.assertEqual(register.call_count,2)
            for call in register.call_args_list:self.assertNotIn('life',call.args[2])
            self.assertTrue(any('trace_pattern' in c.args[0] for c in rpc.call_args_list))
            self.assertTrue(errors)
            docker.assert_called_once_with('stop','--time','10',a.budget.NAME)

    def test_player_inputs_never_prompt_chat_or_repair_and_gate_damage(self):
        plan=a.plan()
        for role,steps in plan.items():
            commands=[s['command'] for s in steps]
            self.assertFalse(any('Dialogue.Say' in c or 'RightMouseButton' in c or '@type' in c for c in commands))
        commands=[s['command'] for s in plan['a']]
        self.assertLess(commands.index('@await_peer conversation_complete'),commands.index('@press LeftMouseButton'))
        self.assertLess(commands.index('@await_peer npc-repair-1'),commands.index('@await_peer success'))


if __name__=='__main__':unittest.main()
