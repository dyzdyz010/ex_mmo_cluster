"""只测试：本任务NPC与Hindsight共用的Responses预算出口；凭证和请求正文只在内存。"""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import sqlite3
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class BudgetError(RuntimeError):
    """可公开记录的预算/外部契约失败分类，不含上游响应或凭证。"""


class Ledger:
    """SQLite事务拥有累计基线、每笔预留与结算；重启不会释放未知支出。"""
    def __init__(self, path, *, baseline=None, cap=None):
        self.path = Path(path)
        self.failure = None
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.execute('CREATE TABLE IF NOT EXISTS budget (id INTEGER PRIMARY KEY CHECK(id=1), baseline INTEGER, cap INTEGER, halted TEXT)')
            db.execute('CREATE TABLE IF NOT EXISTS requests (id INTEGER PRIMARY KEY, scope TEXT, started REAL, finished REAL, input_count INTEGER, output_limit INTEGER, charged INTEGER, actual INTEGER, status TEXT, reason TEXT)')
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT baseline,cap FROM budget WHERE id=1').fetchone()
            if row is None:
                if type(baseline) is not int or type(cap) is not int or not 0 <= baseline < cap:
                    raise BudgetError('explicit_initial_budget_required')
                db.execute('INSERT INTO budget VALUES (1,?,?,NULL)', (baseline, cap))
            elif (baseline is not None and baseline != row[0]) or (cap is not None and cap != row[1]):
                raise BudgetError('existing_budget_cannot_be_reset')
            db.commit()

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=30, isolation_level=None)
        db.execute('PRAGMA synchronous=FULL')
        try:
            with db:
                yield db
        finally:
            db.close()

    def status(self):
        with self.connect() as db:
            db.execute('BEGIN')
            baseline, cap, halted = db.execute('SELECT baseline,cap,halted FROM budget WHERE id=1').fetchone()
            rows = db.execute('SELECT id,scope,input_count,output_limit,charged,actual,status,reason FROM requests ORDER BY id').fetchall()
            items = [dict(zip(('id','scope','input_count','output_limit','charged','actual','status','reason'), row)) for row in rows]
            return {'baseline_tokens': baseline, 'cap': cap, 'halted': halted,
                    'actual_tokens': baseline + sum(r['actual'] or 0 for r in items),
                    'committed_tokens': baseline + sum(r['charged'] for r in items),
                    'in_flight_tokens': sum(r['charged'] for r in items if r['status']=='reserved'),
                    'unknown_reserved_tokens': sum(r['charged'] for r in items if r['status']=='uncertain'),
                    'remaining_tokens': cap-baseline-sum(r['charged'] for r in items), 'requests': items}

    def check_open(self):
        if self.failure:
            raise BudgetError('budget_gate_closed')
        with self.connect() as db:
            if db.execute('SELECT halted FROM budget WHERE id=1').fetchone()[0]:
                raise BudgetError('budget_gate_closed')

    def halt(self, reason):
        # 存储本身故障时，本进程仍关闸；下次serve从未结算预留恢复未知费用。
        self.failure = self.failure or reason
        with self.connect() as db:
            db.execute('UPDATE budget SET halted=COALESCE(halted,?) WHERE id=1', (reason,))

    def recover_pending(self):
        """仅独占serve启动调用；前一owner未结算的预留不能在重启后重试。"""
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            pending = db.execute("SELECT COUNT(*) FROM requests WHERE status='reserved'").fetchone()[0]
            if pending:
                db.execute("UPDATE requests SET status='uncertain',reason='owner_restarted',finished=? WHERE status='reserved'", (time.time(),))
                db.execute("UPDATE budget SET halted=COALESCE(halted,'owner_restarted') WHERE id=1")
            db.commit()

    def reserve(self, input_count, output_limit, scope):
        self.check_open()
        if type(input_count) is not int or input_count < 0 or type(output_limit) is not int or output_limit <= 0:
            raise BudgetError('invalid_token_count')
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            baseline, cap, halted = db.execute('SELECT baseline,cap,halted FROM budget WHERE id=1').fetchone()
            if halted:
                raise BudgetError('budget_gate_closed')
            used = db.execute('SELECT COALESCE(SUM(charged),0) FROM requests').fetchone()[0]
            amount = input_count + output_limit
            if baseline + used + amount > cap:
                db.execute('UPDATE budget SET halted=? WHERE id=1', ('insufficient_token_budget',))
                db.commit()
                raise BudgetError('insufficient_token_budget')
            cursor = db.execute('INSERT INTO requests(scope,started,input_count,output_limit,charged,status) VALUES(?,?,?,?,?,?)',
                                (scope, time.time(), input_count, output_limit, amount, 'reserved'))
            db.commit()
            return cursor.lastrowid

    def settle(self, request_id, usage):
        values = [usage.get(k) for k in ('input_tokens','output_tokens','total_tokens')]
        if any(type(v) is not int or v < 0 for v in values) or values[0]+values[1] != values[2]:
            self.uncertain(request_id, 'invalid_usage')
            raise BudgetError('invalid_usage')
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            reserved, limit, status, counted = db.execute('SELECT charged,output_limit,status,input_count FROM requests WHERE id=?', (request_id,)).fetchone()
            if status != 'reserved':
                raise BudgetError('request_already_settled')
            violation = values[2] > reserved or values[1] > limit or values[0] != counted
            db.execute('UPDATE requests SET charged=?,actual=?,status=?,finished=?,reason=? WHERE id=?',
                       (values[2], values[2], 'settled', time.time(), 'usage_exceeded_reservation' if violation else None, request_id))
            if violation:
                db.execute('UPDATE budget SET halted=? WHERE id=1', ('usage_exceeded_reservation',))
            db.commit()
        if violation:
            raise BudgetError('usage_exceeded_reservation')

    def uncertain(self, request_id, reason):
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            db.execute('UPDATE requests SET status=?,finished=?,reason=? WHERE id=? AND status=?',
                       ('uncertain', time.time(), reason, request_id, 'reserved'))
            db.execute('UPDATE budget SET halted=COALESCE(halted,?) WHERE id=1', (reason,))
            db.commit()


class Proxy:
    """先向同一供应方精确计输入，再共享预留；仅支持无隐式会话的同步文本Responses。"""
    COUNT_FIELDS = ('model','input','instructions','tools','tool_choice','text','reasoning','parallel_tool_calls','truncation')

    def __init__(self, ledger, upstream, output_limit=8192):
        self.ledger, self.upstream, self.output_limit = ledger, upstream, output_limit

    def post(self, url, payload, authorization):
        request = urllib.request.Request(url, data=json.dumps(payload, ensure_ascii=False).encode(),
                                         headers={'Authorization': authorization, 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=30 if url.endswith('/input_tokens') else 120) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            error.close()
            raise

    def request(self, body, authorization, scope):
        try:
            return self._request(body, authorization, scope)
        except sqlite3.Error:
            try:
                self.ledger.halt('ledger_write_failed')
            except sqlite3.Error:
                # halt已锁住内存闸门；错误向调用方显式返回，遗留预留留待恢复。
                pass
            raise BudgetError('ledger_write_failed') from None

    def _request(self, body, authorization, scope):
        self.ledger.check_open()
        if any(body.get(key) for key in ('stream','background','previous_response_id','conversation')):
            self.ledger.halt('unsupported_stateful_or_streaming_request')
            raise BudgetError('unsupported_stateful_or_streaming_request')
        limit = body.get('max_output_tokens') or self.output_limit
        if type(limit) is not int or limit <= 0:
            self.ledger.halt('invalid_output_limit')
            raise BudgetError('invalid_output_limit')
        limit = min(limit, self.output_limit)
        payload = {**body, 'max_output_tokens': limit, 'store': False}
        try:
            count = self.post(self.upstream+'/input_tokens', {k:payload[k] for k in self.COUNT_FIELDS if k in payload}, authorization)
            if count.get('object') != 'response.input_tokens' or type(count.get('input_tokens')) is not int or count['input_tokens'] < 0:
                raise BudgetError('invalid_input_token_count')
        except Exception:
            self.ledger.halt('input_count_failed')
            raise BudgetError('input_count_failed') from None
        rid = self.ledger.reserve(count['input_tokens'], limit, scope)
        try:
            response = self.post(self.upstream, payload, authorization)
        except Exception:
            self.ledger.uncertain(rid, 'upstream_result_unknown')
            raise BudgetError('upstream_result_unknown') from None
        if not isinstance(response.get('usage'), dict):
            self.ledger.uncertain(rid, 'usage_missing')
            raise BudgetError('usage_missing')
        self.ledger.settle(rid, response['usage'])
        if response.get('status') != 'completed':
            self.ledger.halt('response_not_completed')
            raise BudgetError('response_not_completed')
        return response


def handler(proxy):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, payload):
            data = json.dumps(payload, ensure_ascii=False).encode()
            try:
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except OSError:
                if status == 200 and self.path.endswith('/responses'):
                    proxy.ledger.halt('downstream_delivery_unknown')

        def do_GET(self):
            self.reply(200, proxy.ledger.status()) if self.path == '/budget' else self.reply(404, {'error': 'not_found'})

        def do_POST(self):
            paths = {'/decision/v1/responses': 'decision', '/memory/v1/responses': 'memory'}
            if self.path not in paths:
                return self.reply(404, {'error': 'unsupported_endpoint'})
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 2_000_000:
                    raise BudgetError('invalid_request_size')
                body = json.loads(self.rfile.read(size))
                result = proxy.request(body, self.headers.get('Authorization', ''), paths[self.path])
                self.reply(200, result)
            except BudgetError as error:
                self.reply(429, {'error': {'type': 'npc_budget_gate', 'message': str(error)}})
            except (ValueError, TypeError, AttributeError):
                proxy.ledger.halt('invalid_request')
                self.reply(400, {'error': {'type': 'npc_budget_gate', 'message': 'invalid_request'}})
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['serve','status','close'])
    parser.add_argument('--db', required=True)
    parser.add_argument('--baseline', type=int)
    parser.add_argument('--cap', type=int)
    parser.add_argument('--port', type=int, default=8080)
    args = parser.parse_args()
    ledger = Ledger(args.db, baseline=args.baseline, cap=args.cap)
    if args.action == 'close':
        ledger.halt('operator_closed')
    if args.action != 'serve':
        print(json.dumps(ledger.status(), ensure_ascii=False))
        return
    proxy = Proxy(ledger, os.environ['NPC_BUDGET_UPSTREAM'])
    # 本任务仅一个固定容器/端口拥有账本；先绑定，重复serve不得触碰活跃预留。
    with ThreadingHTTPServer(('0.0.0.0', args.port), handler(proxy)) as server:
        ledger.recover_pending()
        server.serve_forever()


if __name__ == '__main__':
    main()
