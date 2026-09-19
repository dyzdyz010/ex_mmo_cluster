"""只测试：B1 入口复用普通 Mix；不手写 BEAM 图、不连接在线容器。"""
import argparse
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    choice = parser.add_mutually_exclusive_group()
    choice.add_argument('--interaction-only', action='store_true')
    choice.add_argument('--world-file-only', action='store_true')
    args = parser.parse_args()
    tests = ['test/damage_test.exs', 'test/damage_world_test.exs']
    if args.interaction_only:
        tests += ['--only', 'interaction_latency']
    if args.world_file_only:
        tests = ['test/world_test.exs', '--only', 'replica']
    return subprocess.call([sys.executable, str(Path(__file__).with_name('run_voxel_tests.py')),
                            '--out', str(args.out.resolve()), '--', *tests])


if __name__ == '__main__':
    raise SystemExit(main())
