"""只测试：独立数据库与生成世界，通过唯一正式 release 验证 NPC / Gate 生命周期。"""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def run(image, out):
    out = out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    name = f'npc-root-{os.getpid()}-{secrets.token_hex(3)}'
    db, server = name + '-db', name + '-server'
    owned = []

    def command(*args, env=None):
        return subprocess.check_output(args, text=True, encoding='utf-8', stderr=subprocess.STDOUT,
                                       env=env, timeout=120).strip()

    def save(filename, data):
        (out / filename).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')

    def rpc(code):
        expression = ('value = (fn -> ' + code + ' end).(); '
                      'IO.puts("NPC_SMOKE:" <> Jason.encode!(NpcServer.Context.plain(value)))')
        output = command('docker', 'exec', server, '/app/bin/voxim_server', 'rpc', expression)
        return json.loads(next(line.removeprefix('NPC_SMOKE:') for line in output.splitlines()
                               if line.startswith('NPC_SMOKE:')))

    def await_ready(predicate, seconds=90, starting=None):
        deadline = time.monotonic() + seconds
        last_error = None
        while True:
            try:
                value = predicate()
                if value:
                    return value
            except subprocess.CalledProcessError as error:
                if not starting:
                    raise RuntimeError(error.output) from error
                last_error = error.output
                running = command('docker', 'inspect', starting, '--format', '{{.State.Running}}')
                if running != 'true':
                    raise RuntimeError(f'正式 release 已退出：{last_error}') from error
            if time.monotonic() >= deadline:
                raise TimeoutError(f'等待正式入口就绪超时：{last_error}')
            time.sleep(0.2)

    try:
        client = ROOT.parent / 'Voxim'
        manifest = json.loads((client / 'Docs/R6/runtime/s4_worldgen_manifest.json').read_text())
        manifest.pop('content_version', None)
        # 沿用 GeneratedStore 集成测试的有限 64 米半径，八项地形参数保持原值。
        manifest['world_half_extent_m'] = 64
        save('worldgen.json', manifest)
        config = json.loads((client / 'Docs/M1/fixtures/demo-config.json').read_text())
        save('scene.json', config)
        # 本用例不连接 UE；显式部署测试用 kernel manifest，profile 仍由正式配置导出。
        (out / 'kernel.bin').write_bytes(b'npc-server-lifecycle-probe-v1')
        env = dict(os.environ, POSTGRES_PASSWORD=secrets.token_hex(24))
        command('docker', 'run', '-d', '--name', db,
                '-e', 'POSTGRES_PASSWORD', '-e', 'POSTGRES_DB=npc_probe', 'postgres:16', env=env)
        owned.append(('container', db))
        await_ready(lambda: command('docker', 'exec', db, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres'), starting=db)
        # 每次独立容器，无端口发布；读取 Docker 分配的默认桥接地址，不消耗额外网段。
        db_host = command('docker', 'inspect', db, '--format', '{{.NetworkSettings.Networks.bridge.IPAddress}}')
        command('docker', 'run', '--rm', '--entrypoint', 'openssl', '-v', f'{out}:/probe', image,
                'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost',
                '-keyout', '/probe/server.key', '-out', '/probe/server.pem')
        settings = {
            'MMO_DB_HOST': db_host, 'MMO_DB_NAME': 'npc_probe', 'MMO_DB_USER': 'postgres',
            'MMO_DB_PASSWORD': env['POSTGRES_PASSWORD'], 'MMO_DB_POOL_SIZE': '5',
            'SECRET_KEY_BASE': secrets.token_hex(64), 'RELEASE_COOKIE': secrets.token_hex(32),
            'ERL_FLAGS': '+S 2:2', 'VOXEL_REGION_ROOT': '/probe/world',
            'VOXEL_REGION_MANIFEST': '/probe/worldgen.json',
            'VOXIM_M1_CONFIG': '/probe/scene.json', 'VOXIM_KERNEL_MANIFEST': '/probe/kernel.bin',
            'VOXIM_QUIC_CERT': '/probe/server.pem', 'VOXIM_QUIC_KEY': '/probe/server.key',
            'VOXEL_REGION_GENERATION_CONCURRENCY': '2', 'VOXEL_REGION_PAYLOAD_CACHE_MB': '64',
        }
        args = ['docker', 'run', '-d', '--name', server, '-v', f'{out}:/probe']
        for key in settings:
            args.extend(['-e', key])
        command(*args, image, env=dict(os.environ, **settings))
        owned.append(('container', server))
        ready = await_ready(lambda: rpc('NpcServer.Bootstrap.status()'), starting=server)
        assert ready == {'status': 'running', 'enabled': 0, 'running': 0}, ready
        registration = rpc('''{:ok, entry} = NpcServer.Registry.put("LifecyclePatrol", %{
          scene_id: 1, spawn: {40.0, 558.0, 40.0}, brain: "patrol",
          params: %{"route" => [[40, 40], [42, 40]]}}); Map.take(entry, [:cid])''')
        cid = registration['cid']
        save('registration.json', registration)

        def observe():
            return rpc(f'''[{{body,_}}] = Registry.lookup(NpcServer.Names,{cid})
              npc = NpcServer.Body.observe(body)
              actor = Enum.find(SceneServer.Movement.Scene.observe(SceneServer.Movement.Scene).characters,
                &(&1.entity_id == {cid}))
              actor = if actor, do: %{{identity: Map.from_struct(actor.identity),
                entity_id: actor.entity_id, active: actor.active, player_pid: inspect(actor.player_pid)}}
              %{{body: inspect(body), session: inspect(Process.whereis(WorldServer.Session)),
                tick: npc.tick, position: npc.position, actor: actor, status: NpcServer.Bootstrap.status()}}''')

        def active():
            state = observe()
            return state if state['tick'] > 0 and state['actor'] and state['actor']['active'] else None

        before = await_ready(active)
        save('before.json', before)
        assert rpc('Application.stop(:gate_server)') == 'ok'
        stopped = await_ready(active)
        save('gate-stopped.json', stopped)
        assert rpc('Process.whereis(GateServer.Supervisor) == nil') is True
        assert rpc('Application.ensure_all_started(:gate_server)') == ['ok', ['gate_server']]
        restarted = await_ready(active)
        save('gate-restarted.json', restarted)
        for state in (stopped, restarted):
            assert state['body'] == before['body']
            assert state['session'] == before['session']
            assert state['actor']['identity'] == before['actor']['identity']
            assert state['actor']['player_pid'] == before['actor']['player_pid']
            assert state['tick'] > before['tick']

        command('docker', 'restart', '--time', '10', server)
        await_ready(lambda: rpc('NpcServer.Bootstrap.status()'), starting=server)
        restored = await_ready(active)
        assert restored['actor']['entity_id'] == cid
        assert restored['actor']['identity'] != before['actor']['identity']
        assert restored['status'] == {'status': 'running', 'enabled': 1, 'running': 1}
        result = {'classification': 'Test-only', 'image': command('docker', 'image', 'inspect', image, '--format', '{{.Id}}'),
                  'cid': cid, 'before': before, 'gate_stopped': stopped, 'gate_restarted': restarted,
                  'release_restarted': restored, 'result': 'passed'}
        save('result.json', result)
        print(json.dumps({'result': 'passed', 'cid': cid, 'out': str(out)}))
    finally:
        if ('container', server) in owned:
            logs = subprocess.run(['docker', 'logs', server], stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, timeout=30).stdout
            (out / 'server.log').write_bytes(logs)
        # 只回收本次创建且已登记的 Docker 资源；保留本次世界与运行证据。
        for _kind, resource in reversed(owned):
            subprocess.run(['docker', 'rm', '-f', resource], capture_output=True, check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    run(args.image, args.out)
