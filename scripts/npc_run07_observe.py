"""仅测试：复用移交的 observe07，修正平台扩大与宏格房屋的观察夹具。

原始客户端回放、鉴权、准星判定与截图入口均来自 observe07.py。
只读副本原样保留；实例身份由 World.instance_cells 公共接口补充。
细化格保守遮挡射线和身体，但不能作为整格高度的落脚面。
依赖同级 Voxim 的 run07 原始驱动及 R7 harness；--run-dir 必须显式指定本次产物目录。
"""
import argparse
import hashlib
import importlib.util
import json
import re
import subprocess
from pathlib import Path

WORKTREE = Path(__file__).resolve().parents[1]
SOURCE = WORKTREE.parent / 'Voxim/Saved/CapabilityLibrary-20261008/observe07.py'
spec = importlib.util.spec_from_file_location('original_observe07', SOURCE)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)

original_load = driver.load
# 只读规划投影的部分占用标记，不是材料 id：非零仍遮挡射线和净空，负数不满足原规划器的完整地面条件。
PARTIAL_OCCUPANCY = -1


def load():
    """细化格投影为部分占用，复用原规划器的遮挡／完整地面判据。"""
    value, world = original_load()
    for row in value['rows']:
        if row[4]:
            world.cells[tuple(row[:3])] = PARTIAL_OCCUPANCY
    return value, world


driver.load = load


def read_instances(value=None):
    """从已接纳的住民放置事务定位实例；可传入已有权威摘要，再读取根实例占用。"""
    from rpc import rpc, CONTAINER
    if value is None:
        value = json.loads((driver.RUN / 'observe-world.json').read_text(encoding='utf-8'))
    resident = next(n['cid'] for n in value['npcs'] if n['name'] == '住民')
    raw = subprocess.run(['docker', 'logs', '--timestamps', CONTAINER], check=True,
                         capture_output=True, timeout=60)
    lines = (raw.stdout + raw.stderr).decode('utf-8', 'replace').splitlines()
    pattern = re.compile(r'character_intent kind=voxel_prefab_place_v1 cid=' + str(resident)
                         + r' .*? result=ok seq=(\d+)')
    commits = [(int(m.group(1)), line) for line in lines if (m := pattern.search(line))
               and int(m.group(1)) <= value['seq']]
    births = sorted(set(seq for seq, _ in commits))
    assert births, '副本前没有住民的已接纳放置事务'
    rows = rpc('Jason.encode!(for birth <- ' + json.dumps(births) + ''' do
      {:ok, cells} = VoxelRegion.World.instance_cells(VoxelRegion.World, {birth, 0})
      %{birth: birth, cells: Enum.map(cells, &Tuple.to_list/1)}
    end)''')
    evidence = {'classification': 'Test-only', 'copy_seq': value['seq'], 'resident': resident,
                'source': 'World.instance_cells/2; prefab root occurrence = 0',
                'commits': [line for _, line in commits], 'instances': rows}
    (driver.RUN / 'observe-house-instances.json').write_text(
        json.dumps(evidence, ensure_ascii=False, indent=1), encoding='utf-8')
    return {'house_instances': len(rows), 'copy_seq': value['seq']}


def plan():
    """选择已整平的首块与一栋真实房屋，复用原来的站位、射线与路线算法。"""
    original_load = driver.load
    extra = json.loads((driver.RUN / 'observe-house-instances.json').read_text(encoding='utf-8'))
    owners = {tuple(c): row['birth'] for row in extra['instances'] for c in row['cells']}

    def load_with_instance_owners():
        value, world = original_load()
        assert value['seq'] == extra['copy_seq']
        for row in value['rows']:
            if row[5] == extra['resident'] and tuple(row[:3]) in owners and not row[7]:
                row[7] = [owners[tuple(row[:3])]]
        return value, world

    driver.load = load_with_instance_owners
    previous_region = driver.CX, driver.CZ
    driver.CX, driver.CZ = (0, 9), (-576, -567)
    try:
        result = driver.plan()
    finally:
        driver.load = original_load
        driver.CX, driver.CZ = previous_region
    result['house_fixture_groups'] = result['house_instances']
    result['house_instances'] = len(extra['instances'])
    result['fixture_adapter'] = {
        'file': str(Path(__file__).relative_to(WORKTREE)),
        'sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'original_sha256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        'platform_focus': [[0, 429, -576], [9, 429, -567]],
        'house_instance_source': 'observe-house-instances.json',
        'scope': '修正观察站位及房屋分组，细化格不作整格地面；O1–O5 与客户端动作不改；完整区域另由长跑样本核对'}
    (driver.RUN / 'observe-plan.json').write_text(
        json.dumps(result, ensure_ascii=False, indent=1), encoding='utf-8')
    return {k: result[k] for k in ('seq', 'present', 'house_cells', 'house_instances', 'panels', 'flat_columns')}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=('fetch', 'instances', 'plan', 'dry', 'run', 'selftest'))
    p.add_argument('--run-dir', type=Path, required=True)
    p.add_argument('--out', type=Path)
    p.add_argument('--captures', type=Path)
    args = p.parse_args()
    driver.RUN = args.run_dir.resolve()
    if args.action == 'fetch':
        result = {'fetch': driver.fetch(), 'instances': read_instances()}
    elif args.action == 'instances':
        result = read_instances()
    elif args.action == 'plan':
        result = plan()
    elif args.action == 'dry':
        result = driver.dry(args.out.resolve())
    elif args.action == 'run':
        return driver.run(args.out.resolve(), args.captures.resolve())
    else:
        result = driver.selftest()
    print(json.dumps(result, ensure_ascii=False, indent=1))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
