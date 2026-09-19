"""只测试：按实际 umbrella 依赖和跨仓库契约选择已有 CI job。"""
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
APP_JOBS = {
    "gate_server": "test-gate-server", "beacon_server": "test-beacon-server",
    "data_service": "test-data-service", "scene_server": "test-scene-server",
    "world_server": "test-standalone", "auth_server": "test-auth-server",
    "visualize_server": "test-visualize-server", "voxel_region": "test-voxel-region",
    "mmo_contracts": "test-mmo-contracts",
}
ALL = set(APP_JOBS.values()) | {"compile", "format", "test-native-rust", "smoke-ws-dual"}


def select(paths):
    jobs, changed = set(), set()
    local_voxel = {"phase.ex", "thermal.ex", "thermal_native.ex", "thermal_geometry.ex", "thermal_settlement.ex",
                   "thermal_attachments.ex", "combustion.ex", "dc_network.ex", "circuit.ex"}
    graph = {p.parent.name: set(re.findall(r"\{:(\w+),\s*in_umbrella:\s*true", p.read_text(encoding="utf-8")))
             for p in (ROOT / "apps").glob("*/mix.exs")}
    for name in paths:
        path = Path(name)
        if name.startswith(("clients/web_client/", "clients/bevy_client/", "clients/Voxia/")):
            continue
        if path.suffix in {".md", ".png", ".jpg", ".svg"}:
            continue
        if name.startswith("apps/"):
            app = path.parts[1]
            if app not in graph:
                raise ValueError("未映射 app：" + name)
            if name == "apps/data_service/test/support/database.exs":
                jobs.update(APP_JOBS[a] for a in ("data_service", "gate_server", "scene_server", "world_server", "voxel_region"))
            elif name == "apps/voxel_region/test/support/prefab_fixture.exs":
                jobs.update(("test-voxel-region", "test-scene-server"))
            elif name == "apps/voxel_region/test/support/world_fixtures.exs":
                jobs.update(("test-voxel-region", "test-scene-server", "test-gate-server"))
            elif "/test/" in name and app in APP_JOBS:
                jobs.add(APP_JOBS[app])
            elif app == "voxel_region" and path.name in local_voxel:
                jobs.add(APP_JOBS[app])
            else:
                changed.add(app)
            if path.suffix in {".ex", ".exs"}:
                jobs.add("format")
            if "/native/" in name:
                jobs.add("test-native-rust")
        elif name.startswith(".github/") or name in {"mix.exs", "mix.lock"} or name.startswith("config/"):
            jobs |= ALL
        elif name == ".formatter.exs":
            jobs.add("format")
        elif name.startswith(("tools/", "scripts/")):
            # 运维/联调入口的直接接缝：正式双端入口，不默认带材料性能。
            jobs.add("smoke-ws-dual")
        elif name.startswith("docs/") and path.suffix in {".py", ".exs", ".sh", ".ps1", ".js"}:
            jobs.add("smoke-ws-dual")
        elif name.startswith(("docs/", ".demo/")) or name in {".gitignore", ".gitattributes"}:
            continue
        else:
            raise ValueError("变更未分类，请补映射：" + name)
    affected = set(changed)
    while True:
        consumers = {app for app, deps in graph.items() if deps & affected}
        if consumers <= affected:
            break
        affected |= consumers
    for app in affected:
        if app in APP_JOBS:
            jobs.add(APP_JOBS[app])
    if changed:
        jobs.add("compile")
    if affected & {"gate_server", "auth_server", "world_server", "scene_server", "mmo_contracts"}:
        jobs.add("smoke-ws-dual")
    return sorted(jobs)


if __name__ == "__main__":
    base = os.environ["SCOPE_BASE"]
    # 首次 push 是完整构建，不要求历史保留的每个非运行时路径重新分类。
    if set(base) == {"0"}:
        paths = ["mix.exs"]
    else:
        paths = subprocess.check_output(["git", "diff", "--name-only", base, "HEAD"], cwd=ROOT, text=True).splitlines()
    result = json.dumps(select(paths))
    print(result)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write("jobs=" + result + "\n")
