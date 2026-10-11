"""只测试：对话验收器的最小反例，不能把共有一条消息当完整复制。"""
import copy
import unittest
import verify


class DialogueVerificationTest(unittest.TestCase):
    def setUp(self):
        self.actors = {"a": 10, "b": 11}
        self.authority = [dict(conversation_id=100, turn=1, speaker_id=10, target_id=20,
                               text="你好", recipients=[10, 11, 20, 21]),
                          dict(conversation_id=100, turn=2, speaker_id=20, target_id=21,
                               text="你怎么看？", recipients=[10, 11, 20, 21]),
                          dict(conversation_id=100, turn=3, speaker_id=21, target_id=20,
                               text="我先看看。", recipients=[10, 11, 20, 21])]
        self.received = {role: [dict(x, receiver_id=cid) for x in self.authority]
                         for role, cid in self.actors.items()}

    def test_exact_authority_delivery_and_two_independent_npc_speakers(self):
        result = verify.delivery(self.authority, self.received, self.actors, [20, 21])
        self.assertEqual(result["npc_to_npc"], [[100, 2], [100, 3]])
        self.assertEqual(result["delivered"], {"a": 3, "b": 3})

    def test_missing_one_of_shared_events_cannot_pass(self):
        self.received["b"].pop(1)
        with self.assertRaisesRegex(AssertionError, "missing"):
            verify.delivery(self.authority, self.received, self.actors, [20, 21])

    def test_wrong_speaker_or_text_cannot_pass_on_equal_event_id(self):
        for field, value in [("speaker_id", 999), ("text", "不一样")]:
            values = copy.deepcopy(self.received)
            values["b"][1][field] = value
            with self.assertRaisesRegex(AssertionError, "content"):
                verify.delivery(self.authority, values, self.actors, [20, 21])

    def test_duplicate_event_and_wrong_recipient_fail(self):
        values = copy.deepcopy(self.received)
        values["b"].append(values["b"][0])
        with self.assertRaisesRegex(AssertionError, "duplicate"):
            verify.delivery(self.authority, values, self.actors, [20, 21])
        self.received["b"][0]["receiver_id"] = 10
        with self.assertRaisesRegex(AssertionError, "receiver"):
            verify.delivery(self.authority, self.received, self.actors, [20, 21])

    def test_out_of_range_must_not_receive_same_conversation(self):
        self.authority[2]["recipients"].remove(11)
        with self.assertRaisesRegex(AssertionError, "unexpected"):
            verify.delivery(self.authority, self.received, self.actors, [20, 21])
        self.received["b"].pop()
        result = verify.delivery(self.authority, self.received, self.actors, [20, 21])
        self.assertEqual(result["delivered"]["b"], 2)

    def test_player_request_requires_matching_result_and_exact_authority_utterance(self):
        sent = {"request_id": 7, "target_id": 20, "text": "你好", "conversation_id": 0}
        result = {"request_id": 7, "reason": "ok", "conversation_id": 100, "turn": 1}
        self.assertEqual(verify.player_request(sent, result, self.authority, 10), [100, 1])
        with self.assertRaisesRegex(AssertionError, "request"):
            verify.player_request(sent, dict(result, request_id=8), self.authority, 10)
        with self.assertRaisesRegex(AssertionError, "confirmed"):
            verify.player_request(sent, dict(result, reason="delivery_unknown"), self.authority, 10)

    def test_authority_log_missing_one_recipient_is_incomplete_evidence(self):
        speech = self.authority[0]
        rows = [dict(speech, event="dialogue.speech", receiver_id=cid) for cid in [10, 11, 20, 21]]
        rows += [dict(event="dialogue.result", reason="ok", conversation_id=100, turn=1, recipients=4)]
        self.assertEqual(verify.authority_events(rows)[0]["recipients"], [10, 11, 20, 21])
        with self.assertRaisesRegex(AssertionError, "recipient evidence"):
            verify.authority_events(rows[1:])

    def test_authority_log_duplicate_delivery_is_not_silently_deduplicated(self):
        rows = [dict(self.authority[0], event="dialogue.speech", receiver_id=10)] * 2
        rows += [dict(event="dialogue.result", reason="ok", conversation_id=100, turn=1, recipients=2)]
        with self.assertRaisesRegex(AssertionError, "duplicate recipient"):
            verify.authority_events(rows)

    def test_memory_ready_does_not_mean_body_entered_world(self):
        row = {"body":{"position":None,"tick":0},"life":{"state":{"cid":20},"cache":{"models":[]},"error":None}}
        self.assertFalse(verify.npc_ready(row))
        row["body"]={"position":[65.5,417.91,-516.5],"tick":3}
        self.assertTrue(verify.npc_ready(row))


if __name__ == "__main__":
    unittest.main()
