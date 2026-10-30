#!/usr/bin/env python3
"""青岚运维兜底；每分钟由 dyz 的 cron 调用，独占 flock 后采样及受控重启。"""
import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import smtplib
import ssl
import subprocess
import time
from email.message import EmailMessage

# 阈值按原始 memory.current 判断，不扣文件缓存；参考工作集另记。
WARN_MIB = 3400
RESTART_MIB = 3900
HIGH_SECONDS = 180
MAX_SAMPLE_GAP = 90
COOLDOWN_SECONDS = 3600
READY_SECONDS = 300
DAILY_UTC = (21, 0)
LOG_DAYS = 14
LOG_TOTAL_BYTES = 16 * 1024 * 1024
APP = 'voxim_qinglan-app-1'
ROOT = Path('/data/voxim_qinglan/ops')
ENV_FILE = Path('/data/voxim_qinglan/releases/20261029-qinglan/release.env')
MIB = 1024 * 1024


def command(args, timeout=20):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        # 不把命令参数或进程输出中的潜在密钥写进日志。
        raise RuntimeError(f'{args[0]} exit={result.returncode}')
    return result.stdout


def log(level, event, **facts):
    directory = ROOT / 'logs'
    directory.mkdir(exist_ok=True)
    now = dt.datetime.now(dt.timezone.utc)
    line = json.dumps(dict(utc=now.isoformat(), level=level, event=event, **facts), ensure_ascii=False)+'\n'
    path = directory / (now.strftime('%Y-%m-%d')+'.jsonl')
    with path.open('a') as stream:
        stream.write(line)
    files = sorted(directory.glob('????-??-??.jsonl'))
    total = sum(p.stat().st_size for p in files)
    for old in files:
        if (now.date()-dt.date.fromisoformat(old.stem)).days >= LOG_DAYS or total > LOG_TOTAL_BYTES:
            total -= old.stat().st_size
            old.unlink()
    print(line, end='', flush=True)


def sample():
    info = json.loads(command(['docker', 'inspect', APP]))[0]
    state = info['State']
    if not state['Running'] or state['Restarting']:
        raise RuntimeError('container_not_running')
    entry = next(l for l in Path(f"/proc/{state['Pid']}/cgroup").read_text().splitlines() if l.startswith('0::'))
    cg = Path('/sys/fs/cgroup') / entry[3:].lstrip('/')
    current = int((cg/'memory.current').read_text())
    stats = dict(l.split() for l in (cg/'memory.stat').read_text().splitlines())
    inactive = int(stats['inactive_file'])
    events = dict((k, int(v)) for k, v in (l.split() for l in (cg/'memory.events').read_text().splitlines()))
    return dict(current_bytes=current, current_mib=round(current/MIB, 2), inactive_file_bytes=inactive,
                working_set_mib=round(max(0,current-inactive)/MIB,2), oom_killed=state['OOMKilled'],
                restart_count=info['RestartCount'], epoch=info['Id']+'/'+state['StartedAt'],
                started_at=state['StartedAt'], memory_events=events)


def decide(state, reading, now, daily=False):
    state = dict(state)
    continuous = (state.get('epoch') == reading['epoch'] and
                  0 <= now-state.get('sample_at', 0) <= MAX_SAMPLE_GAP)
    if reading['current_bytes'] > RESTART_MIB*MIB:
        since = state.get('high_since') if continuous else None
        state['high_since'] = now if since is None else since
    else:
        state['high_since'] = None
    state.update(sample_at=now, epoch=reading['epoch'])
    high_for = now-state['high_since'] if state['high_since'] is not None else 0
    reason = 'daily' if daily else ('high_memory' if high_for >= HIGH_SECONDS else None)
    cooling = now-state.get('last_restart_attempt', 0) < COOLDOWN_SECONDS
    return state, ('cooldown' if cooling else 'restart') if reason else 'observe', reason, high_for


def save(state):
    temp = ROOT/'state.json.tmp'
    temp.write_text(json.dumps(state))
    os.replace(temp, ROOT/'state.json')


def alert(state, event, facts):
    now = time.time()
    alerts = state.setdefault('alerts', {})
    if now-alerts.get(event, 0) < COOLDOWN_SECONDS:
        return
    alerts[event] = now
    save(state)
    try:
        config = json.loads((ROOT/'notify.json').read_text())
        env = dict(l.split('=',1) for l in ENV_FILE.read_text().splitlines() if l and not l.startswith('#') and '=' in l)
        message = EmailMessage()
        message['From'] = env['VOXIM_MAIL_FROM']
        message['To'] = ', '.join(config['to'])
        message['Subject'] = '[Qinglan memory guard] '+event
        message.set_content(json.dumps(facts, ensure_ascii=False, indent=2))
        with smtplib.SMTP_SSL(env['VOXIM_MAIL_HOST'], int(env['VOXIM_MAIL_PORT']), timeout=10, context=ssl.create_default_context()) as smtp:
            smtp.login(env['VOXIM_MAIL_USER'], env['VOXIM_MAIL_PASSWORD'])
            smtp.send_message(message)
        log('INFO', 'mail_sent', cause=event)
    except Exception as error:
        log('ERROR', 'mail_failed', cause=event, error_type=type(error).__name__)


def ready():
    deadline = time.monotonic()+READY_SECONDS
    expected_epoch = None
    while time.monotonic() < deadline:
        reading = sample()
        if expected_epoch is None:
            expected_epoch = reading['epoch']
        if reading['epoch'] != expected_epoch or reading['oom_killed']:
            raise RuntimeError('restart_or_oom_during_readiness')
        output = subprocess.run(['docker','logs','--since',reading['started_at'],APP],capture_output=True,text=True,timeout=20)
        if output.returncode:
            raise RuntimeError('docker_logs_failed')
        logs = output.stdout+output.stderr
        bakes = re.findall(r'bake ready[^\n]*', logs)
        if any(not re.search(r'\bmissing=0\b.*\bgenerated=0\b', line) for line in bakes):
            raise RuntimeError('bake_not_zero')
        if bakes and 'voxim_topology_ready scenes=[1, 2]' in logs and 'voxim_quic_listener port=20003' in logs:
            return reading
        time.sleep(5)
    raise TimeoutError('readiness_timeout')


def dry_run():
    reading = sample()
    log('INFO','dry_run_live',sample=reading,action='no_restart_no_mail_no_state_write')
    cases = []
    def evaluate(name, values, times, initial=None, daily=False):
        state = initial or {}
        actions = []
        for mib, now in zip(values,times):
            state, action, reason, duration = decide(state,dict(reading,current_bytes=mib*MIB),now,daily)
            actions.append(action)
        cases.append(dict(name=name, actions=actions,high_seconds=duration))
        return actions
    assert evaluate('strict_threshold', [3900]*4, [10000,10060,10120,10180]) == ['observe']*4
    assert evaluate('sustained_180s', [3901]*4, [10000,10060,10120,10180]) == ['observe']*3+['restart']
    assert evaluate('sample_gap_resets', [3901]*3, [10000,10060,10240]) == ['observe']*3
    assert evaluate('low_resets', [3901,3300,3901,3901], [10000,10060,10120,10180]) == ['observe']*4
    assert evaluate('cooldown', [3901]*4, [10000,10060,10120,10180], {'last_restart_attempt':9990})[-1] == 'cooldown'
    assert evaluate('daily', [600], [10000], daily=True) == ['restart']
    assert evaluate('daily_cooldown', [600], [10000], {'last_restart_attempt':9990}, True) == ['cooldown']
    log('INFO','dry_run_passed',cases=cases)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dry-run',action='store_true')
    args = parser.parse_args()
    ROOT.mkdir(exist_ok=True)
    with (ROOT/'memory-guard.lock').open('a') as lock:
        try:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            return
        if args.dry_run:
            dry_run()
            return
        state = {}
        state_valid = False
        try:
            if (ROOT/'state.json').exists():
                state = json.loads((ROOT/'state.json').read_text())
            state_valid = True
            reading = sample()
            now = time.time()
            utc = dt.datetime.fromtimestamp(now,dt.timezone.utc)
            daily = (utc.hour,utc.minute) == DAILY_UTC and state.get('daily_date') != str(utc.date())
            state, action, reason, duration = decide(state,reading,now,daily)
            if daily:
                state['daily_date'] = str(utc.date())
            level = 'WARN' if reading['current_bytes'] > WARN_MIB*MIB else 'INFO'
            log(level,'sample',sample=reading,action=action,reason=reason,high_seconds=duration)
            save(state)
            if reading['oom_killed'] or reading['restart_count']:
                alert(state,'container_restart_or_oom',reading)
            if action == 'cooldown':
                log('WARN','restart_suppressed',reason=reason)
                alert(state,'restart_suppressed',reading)
            elif action == 'restart':
                # 先落盘尝试时间：命令失败也占用冷却，禁止错误时重启风暴。
                state.update(last_restart_attempt=now,high_since=None)
                save(state)
                log('WARN','restart_begin',reason=reason,before=reading)
                command(['docker','restart','--time','60',APP],timeout=90)
                after = ready()
                log('INFO','restart_ready',reason=reason,before=reading,after=after)
                alert(state,'restart_ready',dict(reason=reason,before=reading,after=after))
            elif level == 'WARN':
                alert(state,'memory_warn',reading)
        except Exception as error:
            facts = dict(error_type=type(error).__name__,error=str(error)[:300])
            log('ERROR','guard_failed',**facts)
            # 失败会打断连续高值；保留重启冷却。损坏状态不得覆盖成空状态来绕过冷却。
            if state_valid:
                state.update(high_since=None,epoch=None)
                save(state)
                alert(state,'guard_failed',facts)
            raise SystemExit(1)


if __name__ == '__main__':
    os.umask(0o077)
    main()
