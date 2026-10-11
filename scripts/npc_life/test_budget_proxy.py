"""只测试：真实SQLite与本地HTTP上游替身；不访问外部模型。"""
import concurrent.futures
import json
from pathlib import Path
import tempfile
import threading
import urllib.error
import urllib.request
import unittest
from unittest.mock import Mock, patch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import budget_proxy as b


class LedgerTest(unittest.TestCase):
    def test_duplicate_serve_cannot_mark_live_reservations_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'ledger.db'
            ledger=b.Ledger(path,baseline=0,cap=100)
            ledger.reserve(10,10,'decision')
            with patch('sys.argv',['proxy','serve','--db',str(path)]), patch.dict('os.environ',{'NPC_BUDGET_UPSTREAM':'http://stub/responses'}), patch.object(b,'ThreadingHTTPServer',side_effect=OSError('port occupied')):
                with self.assertRaises(OSError):b.main()
            self.assertIsNone(ledger.status()['halted'])
            self.assertEqual(ledger.status()['in_flight_tokens'],20)

    def test_concurrent_reservations_cannot_spend_the_same_balance(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = b.Ledger(Path(tmp)/'ledger.db', baseline=100, cap=200)
            def reserve(_):
                try:
                    return ledger.reserve(40, 20, 'decision')
                except b.BudgetError:
                    return None
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                ids = list(pool.map(reserve, range(2)))
            self.assertEqual(sum(i is not None for i in ids), 1)
            self.assertEqual(ledger.status()['committed_tokens'], 160)

    def test_settlement_restart_and_uncertain_cost_keep_cumulative_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'ledger.db'
            ledger = b.Ledger(path, baseline=2010947, cap=3000000)
            first = ledger.reserve(100, 80, 'decision')
            ledger.settle(first, {'input_tokens': 100, 'output_tokens': 5, 'total_tokens': 105})
            second = ledger.reserve(200, 80, 'memory')
            reopened = b.Ledger(path, baseline=2010947, cap=3000000)
            self.assertEqual(reopened.status()['committed_tokens'], 2010947+105+280)
            reopened.recover_pending()
            self.assertEqual(reopened.status()['unknown_reserved_tokens'], 280)
            with self.assertRaises(b.BudgetError):
                reopened.reserve(1, 1, 'memory retry')
            with self.assertRaises(b.BudgetError):
                b.Ledger(path, baseline=0, cap=3000000)

    def test_readonly_status_does_not_recover_a_running_owner(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'ledger.db'
            ledger = b.Ledger(path, baseline=0, cap=100)
            ledger.reserve(10, 10, 'decision')
            self.assertIsNone(b.Ledger(path).status()['halted'])

    def test_input_count_mismatch_halts_even_when_total_fits_reservation(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = b.Ledger(Path(tmp)/'ledger.db', baseline=0, cap=100)
            rid = ledger.reserve(10, 50, 'decision')
            with self.assertRaises(b.BudgetError):
                ledger.settle(rid, {'input_tokens': 20, 'output_tokens': 1, 'total_tokens': 21})
            self.assertEqual(ledger.status()['actual_tokens'], 21)
            self.assertTrue(ledger.status()['halted'])

    def test_usage_contract_violation_is_visible_and_closes_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = b.Ledger(Path(tmp)/'ledger.db', baseline=0, cap=100)
            rid = ledger.reserve(10, 10, 'decision')
            with self.assertRaises(b.BudgetError):
                ledger.settle(rid, {'input_tokens': 10, 'output_tokens': 15, 'total_tokens': 25})
            self.assertEqual(ledger.status()['actual_tokens'], 25)
            self.assertTrue(ledger.status()['halted'])


class TransportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.requests = []
        self.count_status = 200
        self.response = {'status': 'completed', 'output': [],
                         'usage': {'input_tokens': 10, 'output_tokens': 2, 'total_tokens': 12}}
        owner = self
        class Upstream(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                owner.requests.append((self.path, payload, self.headers['Authorization']))
                count = self.path.endswith('/input_tokens')
                self.send_response(owner.count_status if count else 200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                response = {'object': 'response.input_tokens', 'input_tokens': 10} if count else owner.response
                self.wfile.write(json.dumps(response).encode())
        self.upstream = ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        thread = threading.Thread(target=self.upstream.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.upstream.server_close)
        self.addCleanup(self.upstream.shutdown)
        self.ledger = b.Ledger(Path(self.tmp.name)/'ledger.db', baseline=90, cap=200)
        self.proxy = b.Proxy(self.ledger, f'http://127.0.0.1:{self.upstream.server_port}/v1/responses', 20)
        self.body = {'model': 'local-test', 'input': '你好', 'instructions': '用中文回答',
                     'tools': [{'type': 'function', 'name': 'say'}], 'stream': False}

    def test_count_then_reserve_then_generate_and_settle_exact_usage(self):
        response = self.proxy.request(self.body, 'Bearer test-only-not-a-key', 'decision')
        self.assertEqual(response['usage']['total_tokens'], 12)
        self.assertEqual([r[0] for r in self.requests], ['/v1/responses/input_tokens', '/v1/responses'])
        self.assertEqual(self.requests[0][1]['input'], self.body['input'])
        self.assertEqual(self.requests[0][1]['tools'], self.body['tools'])
        self.assertEqual(self.requests[1][1]['max_output_tokens'], 20)
        self.assertEqual(self.ledger.status()['committed_tokens'], 102)
        raw = (Path(self.tmp.name)/'ledger.db').read_bytes()
        self.assertNotIn(b'test-only-not-a-key', raw)
        self.assertNotIn('你好'.encode(), raw)

    def test_count_failure_or_insufficient_budget_never_generates(self):
        self.count_status = 500
        with self.assertRaises(b.BudgetError):
            self.proxy.request(self.body, 'Bearer test', 'memory')
        self.assertEqual(len(self.requests), 1)
        self.count_status = 200
        with self.assertRaises(b.BudgetError):
            self.proxy.request(self.body, 'Bearer test', 'memory retry')
        self.assertEqual(len(self.requests), 1)

    def test_insufficient_shared_balance_does_not_reach_model(self):
        self.ledger.reserve(70, 20, 'other pending work')
        with self.assertRaises(b.BudgetError):
            self.proxy.request(self.body, 'Bearer test', 'decision')
        self.assertFalse(any(path.endswith('/responses') for path, _, _ in self.requests))

    def test_missing_usage_or_incomplete_response_halts_before_any_retry(self):
        self.response.pop('usage')
        with self.assertRaises(b.BudgetError):
            self.proxy.request(self.body, 'Bearer test', 'decision')
        self.assertEqual(self.ledger.status()['unknown_reserved_tokens'], 30)
        count = len(self.requests)
        with self.assertRaises(b.BudgetError):
            self.proxy.request(self.body, 'Bearer test', 'decision retry')
        self.assertEqual(len(self.requests), count)

    def test_incomplete_response_keeps_actual_usage_but_blocks_retry(self):
        self.response['status'] = 'incomplete'
        with self.assertRaises(b.BudgetError):
            self.proxy.request(self.body, 'Bearer test', 'memory')
        self.assertEqual(self.ledger.status()['actual_tokens'], 102)
        self.assertTrue(self.ledger.status()['halted'])

    def test_settlement_storage_failure_blocks_generation_retries(self):
        with patch.object(self.ledger, 'settle', side_effect=b.sqlite3.OperationalError('test-only disk failure')):
            with self.assertRaises(b.BudgetError):
                self.proxy.request(self.body, 'Bearer test', 'memory')
        calls = len(self.requests)
        with self.assertRaises(b.BudgetError):
            self.proxy.request(self.body, 'Bearer test', 'memory retry')
        self.assertEqual(len(self.requests), calls)
        self.assertEqual(self.ledger.status()['committed_tokens'], 120)

    def test_downstream_loss_after_generation_closes_paid_gate(self):
        response = self.proxy.request(self.body, 'Bearer test', 'decision')
        handler = b.handler(self.proxy).__new__(b.handler(self.proxy))
        handler.send_response = Mock()
        handler.send_header = Mock()
        handler.end_headers = Mock()
        handler.wfile = Mock()
        handler.wfile.write.side_effect = BrokenPipeError('test-only lost client')
        handler.path = '/decision/v1/responses'
        handler.reply(200, response)
        calls = len(self.requests)
        with self.assertRaises(b.BudgetError):
            self.proxy.request(self.body, 'Bearer test', 'decision retry')
        self.assertEqual(len(self.requests), calls)
        self.assertEqual(self.ledger.status()['actual_tokens'], 102)

    def test_real_http_proxy_routes_scopes_and_returns_budget_failure(self):
        gateway = ThreadingHTTPServer(('127.0.0.1', 0), b.handler(self.proxy))
        thread = threading.Thread(target=gateway.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(gateway.server_close)
        self.addCleanup(gateway.shutdown)
        url = f'http://127.0.0.1:{gateway.server_port}/memory/v1/responses'
        request = urllib.request.Request(url, data=json.dumps(self.body).encode(),
                                         headers={'Authorization': 'Bearer test'})
        with urllib.request.urlopen(request) as response:
            self.assertEqual(json.load(response)['usage']['total_tokens'], 12)
        self.assertEqual(self.ledger.status()['requests'][0]['scope'], 'memory')
        self.ledger.halt('test_complete')
        try:
            urllib.request.urlopen(request)
            self.fail('closed gate accepted HTTP request')
        except urllib.error.HTTPError as error:
            with error:
                self.assertEqual(error.code, 429)
                self.assertEqual(json.load(error)['error']['message'], 'budget_gate_closed')

    def test_stateful_or_streaming_requests_are_rejected_before_egress(self):
        for field, value in [('stream', True), ('background', True), ('previous_response_id', 'hidden')]:
            with self.assertRaises(b.BudgetError):
                self.proxy.request({**self.body, field: value}, 'Bearer test', 'decision')
        self.assertEqual(self.requests, [])


if __name__ == '__main__':
    unittest.main()
