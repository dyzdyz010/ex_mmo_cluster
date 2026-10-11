"""只测试：独立 Hindsight 0.10.3 NPC life 服务，不属于生产部署。"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / '.demo/observe/npc-life-20261011/hindsight'
IMAGE = 'voxim-npc-evolve-hindsight:0.10.3-flashrank'
NAME = 'voxim-npc-life-loop-20261011'
API = 'http://127.0.0.1:18908'
NETWORK = 'caplib-20261008-net'


def config():
    # 凭证只在内存与子进程环境中传递，docker 参数不含值。
    source = ROOT.parent / 'ex_mmo_cluster/.env'
    auth = dict(line.split('=', 1) for line in source.read_text(encoding='utf-8-sig').splitlines()
                if line.startswith('NPC_LLM_') and '=' in line)
    return {
        'HINDSIGHT_API_LLM_PROVIDER': 'openai-responses',
        'HINDSIGHT_API_LLM_BASE_URL': auth['NPC_LLM_URL'].removesuffix('/responses'),
        'HINDSIGHT_API_LLM_API_KEY': auth['NPC_LLM_KEY'],
        'HINDSIGHT_API_LLM_MODEL': 'gpt-5.6-terra',
        'HINDSIGHT_API_LLM_REASONING_EFFORT': 'low',
        'HINDSIGHT_API_EMBEDDINGS_PROVIDER': 'onnx',
        'HINDSIGHT_API_EMBEDDINGS_ONNX_MODEL_ID': 'BAAI/bge-small-en-v1.5',
        'HINDSIGHT_API_EMBEDDINGS_ONNX_DIMENSIONS': '384',
        'HINDSIGHT_API_EMBEDDINGS_ONNX_DEVICE': 'cpu',
        'HINDSIGHT_API_EMBEDDINGS_ONNX_POOLING': 'cls',
        'HINDSIGHT_API_EMBEDDINGS_ONNX_QUERY_PREFIX': 'Represent this sentence for searching relevant passages: ',
        'HINDSIGHT_API_EMBEDDINGS_ONNX_PASSAGE_PREFIX': '',
        'HINDSIGHT_API_RERANKER_PROVIDER': 'flashrank',
        'HINDSIGHT_API_RERANKER_FLASHRANK_CACHE_DIR': '/home/hindsight/.cache/huggingface/flashrank',
        'HINDSIGHT_API_ENABLE_BANK_CONFIG_API': 'true',
        'HINDSIGHT_API_WORKER_ID': NAME,
        'HINDSIGHT_API_LLM_TRACE_ENABLED': 'true',
    }


def ready(timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(API + '/health/ready', timeout=5) as response:
                if response.status == 200:
                    return
        except (OSError, TimeoutError):
            pass
        time.sleep(3)
    raise SystemExit('NPC life Hindsight readiness timeout')


def start(timeout):
    cfg = config()
    found = subprocess.run(['docker', 'inspect', '--format', '{{.Config.Image}}', NAME], capture_output=True, text=True)
    if found.returncode == 0:
        if found.stdout.strip() != IMAGE:
            raise SystemExit('owned container image mismatch')
        subprocess.run(['docker', 'start', NAME], check=True, capture_output=True)
    else:
        subprocess.run(['docker', 'run', '--rm', '--user', '0', '-v', NAME + '-hf:/cache',
                        '--entrypoint', 'python', IMAGE, '-c',
                        "import os,pwd; p=pwd.getpwnam('hindsight'); os.chown('/cache',p.pw_uid,p.pw_gid)"],
                       check=True, capture_output=True)
        command = ['docker', 'run', '-d', '--name', NAME, '--shm-size=1g',
                   '--network', NETWORK,
                   '-p', '127.0.0.1:18908:8888',
                   '-v', NAME + '-pg:/home/hindsight/.pg0',
                   '-v', NAME + '-hf:/home/hindsight/.cache/huggingface']
        for key in cfg:
            command += ['-e', key]
        subprocess.run(command + [IMAGE], env={**os.environ, **cfg}, check=True, capture_output=True)
    attached = subprocess.run(['docker', 'inspect', '--format', '{{json .NetworkSettings.Networks}}', NAME],
                              check=True, capture_output=True, text=True)
    if NETWORK not in json.loads(attached.stdout):
        subprocess.run(['docker', 'network', 'connect', NETWORK, NAME], check=True, capture_output=True)
    # 只检查公开隔离元数据，不读取或打印完整 inspect / 环境。
    ports = json.loads(subprocess.run(['docker', 'inspect', '--format', '{{json .HostConfig.PortBindings}}', NAME],
                                     check=True, capture_output=True, text=True).stdout)
    mounts = json.loads(subprocess.run(['docker', 'inspect', '--format', '{{json .Mounts}}', NAME],
                                      check=True, capture_output=True, text=True).stdout)
    expected_mounts = {NAME + '-pg': '/home/hindsight/.pg0', NAME + '-hf': '/home/hindsight/.cache/huggingface'}
    actual_mounts = {m.get('Name'): m['Destination'] for m in mounts if m['Type'] == 'volume'}
    if ports.get('8888/tcp') != [{'HostIp': '127.0.0.1', 'HostPort': '18908'}] or actual_mounts != expected_mounts:
        raise SystemExit('owned container isolation mismatch')
    ready(timeout)
    identity = subprocess.run(['docker', 'inspect', '--format', '{{.Image}}', NAME],
                              check=True, capture_output=True, text=True).stdout.strip()
    manifest = {'classification': 'Test-only', 'container': NAME, 'image': IMAGE,
                'image_id': identity, 'api': API, 'network': NETWORK, 'volumes': [NAME + '-pg', NAME + '-hf'],
                'configuration': {k: v for k, v in cfg.items() if 'KEY' not in k and 'URL' not in k}}
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'service.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(json.dumps(manifest))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['start', 'stop', 'restart'])
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    if args.command in ('stop', 'restart'):
        subprocess.run(['docker', 'stop', NAME], check=True, capture_output=True)
    if args.command in ('start', 'restart'):
        start(args.timeout)
