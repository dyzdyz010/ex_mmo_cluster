"""只测试：保留普通 Mix 编译图，在独立 VM 运行显式文件/标签并保存日志。"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'apps/voxel_region'


def validate_selection(selected, app):
    """文件存在性由入口校验；标签和行号的具体选择仍完全交给 Mix。"""
    files = []
    for value in selected:
        match = re.fullmatch(r'(.+\.exs)(?::\d+(?:-\d+)?)*', value)
        if match:
            path = match[1]
            if not (app / path).is_file():
                raise ValueError('测试文件不存在：' + path)
            files.append(path)
    if not files and not any(value == '--only' or value.startswith('--only=') for value in selected):
        raise ValueError('必须显式选择测试文件或 --only 标签')


def passed_count(output):
    """读取本机 Elixir 1.20 与 CI 1.18 的 CLI 完成摘要，不改变 ExUnit 运行方式。"""
    output = re.sub(r'\x1b\[[0-9;]*m', '', output)
    current = re.search(r'^Result: (\d+)(?:/\d+)? passed\b', output, re.MULTILINE)
    if current:
        return int(current[1])
    if re.search(r'^Result: 0 tests\b', output, re.MULTILINE):
        return 0
    legacy = re.search(r'^\d+ (?:doctests?|tests?), .*\bfailures?\b.*$', output, re.MULTILINE)
    if legacy:
        counts = dict((kind, int(count)) for count, kind in re.findall(
            r'(\d+) (doctests?|tests?|failures?|excluded|skipped)\b', legacy[0]))
        return sum(counts.get(k, 0) for k in ('doctest', 'doctests', 'test', 'tests')) - sum(
            counts.get(k, 0) for k in ('failure', 'failures', 'excluded', 'skipped'))
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('tests', nargs=argparse.REMAINDER, help='Mix 文件/标签参数；以 -- 分隔')
    args = parser.parse_args()
    selected = args.tests[1:] if args.tests[:1] == ['--'] else args.tests
    try:
        validate_selection(selected, APP)
    except ValueError as error:
        parser.error(str(error))
    args.out.mkdir(parents=True, exist_ok=False)
    command = [shutil.which('mix'), 'test', '--no-start', *selected]
    with (args.out / 'run.log').open('wb') as log:
        mix_code = subprocess.call(command, cwd=APP, stdout=log, stderr=subprocess.STDOUT)
    passed = passed_count((args.out / 'run.log').read_text(encoding='utf-8', errors='replace'))
    error = None
    if mix_code == 0 and not passed:
        error = '没有通过的测试' if passed == 0 else '缺少 ExUnit 完成摘要'
    code = mix_code or (1 if error else 0)
    result = {'classification': 'Test-only', 'command': command, 'exit_code': code,
              'mix_exit_code': mix_code, 'passed': passed, 'validation_error': error,
              'source_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'source_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip())}
    (args.out / 'result.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print('Mix exit', mix_code, 'verified exit', code, args.out / 'run.log')
    if error:
        print(error)
    return code


if __name__ == '__main__':
    raise SystemExit(main())
