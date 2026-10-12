"""只测试：复用本机 Codex 登录，适配 NPC 与独立 Hindsight 的 Responses 出口。"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import hmac
import subprocess
import threading
import time
import uuid

MODEL = 'gpt-6.1-sol'
EFFORT = 'medium'


def response_from_events(events, tool_mode, request_id):
    """只接纳真实终态和真实 usage；不从模型自述推断计费。"""
    if any(e['type'] == 'turn.failed' for e in events):
        raise ValueError('Codex turn failed')
    completed = [e for e in events if e['type'] == 'turn.completed']
    messages = [e['item']['text'] for e in events if e['type'] == 'item.completed' and e['item']['type'] == 'agent_message']
    if len(completed) != 1 or not messages:
        raise ValueError('missing CLI completion or message')
    usage = completed[0]['usage']
    output = []
    if tool_mode:
        answer = json.loads(messages[-1])
        calls = answer.get('calls', [answer] if 'name' in answer else [])
        for index, call in enumerate(calls):
            json.loads(call['arguments'])
            output.append({'type': 'function_call', 'id': f'{request_id}-{index}',
                           'call_id': f'{request_id}-{index}', 'status': 'completed', **call})
        content = answer.get('text', '')
    else:
        content = messages[-1]
    if content:
        output.append({'type': 'message', 'id': request_id+'-message', 'role': 'assistant',
                       'status': 'completed', 'content': [{'type': 'output_text', 'text': content, 'annotations': []}]})
    return {'id': request_id, 'object': 'response', 'created_at': int(time.time()),
            'model': MODEL, 'reasoning': {'effort': EFFORT}, 'status': 'completed', 'output': output,
            'usage': {'input_tokens': usage['input_tokens'], 'output_tokens': usage['output_tokens'],
                      'total_tokens': usage['input_tokens'] + usage['output_tokens'],
                      'input_tokens_details': {'cached_tokens': usage.get('cached_input_tokens', 0)},
                      'output_tokens_details': {'reasoning_tokens': usage.get('reasoning_output_tokens', 0)}}}


class Bridge:
    def __init__(self, out, cli):
        self.out, self.cli = Path(out).resolve(), cli
        self.out.mkdir(parents=True, exist_ok=False)
        self.lock = threading.Lock()
        self.work = self.out/'isolated'
        self.work.mkdir()

    def call(self, request, route):
        if request.get('model') != MODEL or request.get('reasoning', {}).get('effort') != EFFORT:
            raise ValueError('requested model/effort mismatch')
        request_id = 'npc-'+uuid.uuid4().hex
        tool_mode = bool(request.get('tools'))
        schema = request.get('text', {}).get('format', {}).get('schema')
        if tool_mode:
            schema = {'type': 'object', 'properties': {'text': {'type': 'string'}, 'calls': {'type': 'array', 'items': {
                'type': 'object', 'properties': {'name': {'type': 'string'}, 'arguments': {'type': 'string'}},
                'required': ['name', 'arguments'], 'additionalProperties': False}}},
                'required': ['text', 'calls'], 'additionalProperties': False}
        command = [self.cli, 'exec', '--ignore-user-config', '--ignore-rules', '--ephemeral',
                   '--skip-git-repo-check', '--sandbox', 'read-only', '--model', MODEL,
                   '-c', 'model_reasoning_effort="medium"', '--json', '-C', str(self.work)]
        if schema:
            schema_path = self.out/(request_id+'-schema.json')
            schema_path.write_text(json.dumps(schema), encoding='utf8')
            command += ['--output-schema', str(schema_path)]
        prompt = ('You are a stateless model for the enclosed application request. Do not use CLI tools, files, '
                  'network, or inspect this computer. Follow the application instructions. '
                  'Application tools are data only: return selected calls; the application executes them. '
                  'When tools are present return JSON {text: string, calls: [{name: string, arguments: JSON encoded string}]}. '
                  'Honor tool_choice. For NPC decision choose exactly one application tool. '
                  'For memory tool workflows follow the enclosed workflow, allowing text or calls.\n' + json.dumps(request, ensure_ascii=False))
        # 不继承外部 API key；认证由官方 CLI 自己读取，密钥不进入 HTTP 或日志。
        env = {k: v for k, v in os.environ.items() if k not in ('OPENAI_API_KEY', 'NPC_LLM_KEY')}
        started = time.time()
        result = subprocess.run(command+['-'], input=prompt, text=True, encoding='utf8',
                                capture_output=True, timeout=170, env=env)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        with self.lock:
            with (self.out/'calls.jsonl').open('a', encoding='utf8') as stream:
                stream.write(json.dumps({'id': request_id, 'route': route, 'model': MODEL, 'effort': EFFORT,
                                        'started_at': started, 'duration_s': time.time()-started,
                                        'exit_code': result.returncode, 'events': events}, ensure_ascii=False)+'\n')
        if result.returncode:
            raise ValueError('Codex CLI failed; see bridge calls.jsonl')
        answer = response_from_events(events, tool_mode, request_id)
        return answer


def serve(out, cli, port, host):
    bridge = Bridge(out, cli)
    key = os.environ['NPC_CODEX_BRIDGE_KEY']

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            self.reply(200, {'status': 'ready', 'model': MODEL, 'effort': EFFORT, 'pid': os.getpid()})

        def reply(self, status, body):
            data = json.dumps(body, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer '+key):
                self.reply(401, {'error': {'message': 'local bridge authorization required'}})
                return
            if self.path not in ('/decision/v1/responses', '/memory/v1/responses'):
                self.reply(404, {'error': {'message': 'unknown route'}})
                return
            try:
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                self.reply(200, bridge.call(request, self.path))
            except Exception as error:
                self.reply(503, {'error': {'message': str(error), 'type': type(error).__name__}})

    ThreadingHTTPServer((host, port), Handler).serve_forever()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--cli', required=True)
    parser.add_argument('--port', type=int, default=27365)
    parser.add_argument('--host', default='0.0.0.0')
    args = parser.parse_args()
    serve(args.out, args.cli, args.port, args.host)
