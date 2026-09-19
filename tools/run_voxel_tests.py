"""只测试：保留普通 Mix 编译图，在独立 VM 运行显式文件/标签并保存日志。"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('tests', nargs=argparse.REMAINDER, help='Mix 文件/标签参数；以 -- 分隔')
    args = parser.parse_args()
    selected = args.tests[1:] if args.tests[:1] == ['--'] else args.tests
    if not selected:
        parser.error('必须显式选择测试文件或 --only 标签')
    args.out.mkdir(parents=True, exist_ok=False)
    command = [shutil.which('mix'), 'test', '--no-start', *selected]
    with (args.out / 'run.log').open('wb') as log:
        code = subprocess.call(command, cwd=ROOT / 'apps/voxel_region', stdout=log, stderr=subprocess.STDOUT)
    result = {'classification': 'Test-only', 'command': command, 'exit_code': code,
              'source_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'source_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip())}
    (args.out / 'result.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print('Mix exit', code, args.out / 'run.log')
    return code


if __name__ == '__main__':
    raise SystemExit(main())
