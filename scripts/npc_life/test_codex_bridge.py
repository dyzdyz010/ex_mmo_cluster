"""只测试：CLI 结果到既有 Responses 消费契约的边界。"""
import unittest
import codex_bridge as bridge


class BridgeTest(unittest.TestCase):
    def test_recovered_transport_error_is_not_a_failed_turn(self):
        events = [{'type': 'error', 'message': 'Reconnecting... tls handshake eof'},
                  {'type': 'item.completed', 'item': {'type': 'agent_message', 'text': '{"name":"look","arguments":"{}"}'}},
                  {'type': 'turn.completed', 'usage': {'input_tokens': 12, 'output_tokens': 4}}]
        self.assertEqual(bridge.response_from_events(events, True, 'r1')['usage']['total_tokens'], 16)

    def test_tool_result_and_real_usage(self):
        events = [{'type': 'item.completed', 'item': {'type': 'agent_message', 'text': '{"name":"say","arguments":"{\\"text\\":\\"你好\\"}"}'}},
                  {'type': 'turn.completed', 'usage': {'input_tokens': 11, 'output_tokens': 3}}]
        result = bridge.response_from_events(events, True, 'r1')
        self.assertEqual(result['output'][0]['name'], 'say')
        self.assertEqual(result['usage']['total_tokens'], 14)

    def test_failed_or_missing_usage_is_not_success(self):
        for events in [[{'type': 'turn.failed'}], [{'type': 'item.completed', 'item': {'type': 'agent_message', 'text': '{}'}}]]:
            with self.assertRaises(ValueError):
                bridge.response_from_events(events, False, 'r1')

    def test_hindsight_text_keeps_json_text(self):
        events = [{'type': 'item.completed', 'item': {'type': 'agent_message', 'text': '{"facts":[]}'}},
                  {'type': 'turn.completed', 'usage': {'input_tokens': 4, 'output_tokens': 2}}]
        self.assertEqual(bridge.response_from_events(events, False, 'r1')['output'][0]['content'][0]['text'], '{"facts":[]}')


if __name__ == '__main__':
    unittest.main()
