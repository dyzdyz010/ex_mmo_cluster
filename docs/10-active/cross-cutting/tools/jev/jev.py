"""只测试：Jev（TypeSafe System One）的最小客户端。凭据取自仓库根目录的 .env；与 Jev 的交互一律用英文。"""
import json, time, urllib.request, urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[5]
ENV = dict(l.split('=', 1) for l in (ROOT / '.env').read_text(encoding='utf-8').splitlines() if '=' in l and not l.startswith('#'))

def ask(state, questions, timeout=60):
    """返回 (answers, usage, seconds)；HTTP 错误返回 ({'error': code, 'body': ...}, None, seconds)。"""
    body = json.dumps({'state': state, 'model': ENV['TYPESAFE_MODEL'], 'questions': questions}).encode()
    req = urllib.request.Request(ENV['TYPESAFE_API_URL'], data=body, headers={
        'authorization': 'Bearer ' + ENV['TYPESAFE_API_KEY'], 'content-type': 'application/json', 'user-agent': 'voxim-npc-eval/1'})
    t = time.perf_counter()
    try:
        r = json.load(urllib.request.urlopen(req, timeout=timeout))
        return r['answers'], r.get('usage'), time.perf_counter() - t
    except urllib.error.HTTPError as e:
        return {'error': e.code, 'body': e.read().decode('utf-8', 'replace')[:300]}, None, time.perf_counter() - t
