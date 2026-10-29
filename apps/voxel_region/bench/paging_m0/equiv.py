"""只测试（Test-only）：M2a 迁移等价（m2a-page-store.md §7、§8 第 9 项）。

  python equiv.py <deploy> <out_dir> --dump /tmp/backup.dump --historical-repo <18f6cb4c-checkout>

H 在确定序前的真实源码恢复同一旧日志，A 在当前源码首发布前采集，B 为当前同切点的真实冷恢复。
H→B 逐身份核 Q5，A→B 严格核全部字段与载荷；首发布闸不暂停 World 物理，任何序号漂移都失败。
任何一步失败即停止（不重试）；系统可用内存低于 20 GB 时只杀本脚本进程树内的 erl 进程并中止。
"""
from pathlib import Path
from contextlib import contextmanager
import argparse
import hashlib
import json
import math
import os
import subprocess
import sys
import threading
import time

import psutil

import m0
from run_m0 import restore, source_identity

HERE = Path(__file__).resolve().parent
FLOOR_GB = 20
HISTORICAL_COMMIT = "18f6cb4c52107d2123c19da9948add2a401c370e"
# 原M2a判定的固定真值字段；覆盖检查不允许双方同时漏字段后仍以摘要相等通过。
AUDIT_FIELDS = frozenset("""overlay region_bases refined attachments liquid_units macro_owners damage
instances attachment_owners material_balances caster_energy material_supplies craft_ledger food_ledger
food_receipts beacons beacon_attunements phase_inventory epochs placed_by seq attachment_serial
material_units_per_micro interaction_history interaction_floor liquid_active sources thermal protection""".split())


class MemoryWatchdog:
    """本轮护栏的唯一生命周期与失败 owner；收齐线程结果后交回主编排。"""

    def __init__(self, out, meta):
        self.out = out
        self.meta = meta
        self.stop = threading.Event()
        self.tripped = threading.Event()
        self.error = None
        self.thread = threading.Thread(target=self._run, name="m0-memory-watchdog", daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def _run(self):
        try:
            watchdog(self.stop, self.tripped)
        except BaseException as error:
            # 只运输原始失败；主编排收尾会先 join，再读取完整结果并决定向外抛错。
            self.error = error

    def __exit__(self, exc_type, exc, traceback):
        """停止并收齐本轮结果，在抛错前保留护栏证据。"""
        self.stop.set()
        self.thread.join()
        error = self.error
        status = {"tripped": self.tripped.is_set(),
                  "error": {"type": type(error).__name__, "reason": str(error)} if error else None}
        (self.out / "memory_watchdog.json").write_text(json.dumps(status, indent=2))
        if status["tripped"]:
            (self.out / "memory_watchdog_tripped").write_text("1")
        self.meta["memory_watchdog_tripped"] = status["tripped"]
        self.meta["memory_watchdog_error"] = status["error"]
        (self.out / "meta.json").write_text(json.dumps(self.meta, indent=2, default=str))
        if exc is None:
            self.check()
        return False

    def check(self):
        """护栏已失败或触发时显式中止，不依赖 daemon 的 stderr traceback。"""
        if (error := self.error) is not None:
            raise RuntimeError(f"memory watchdog failed: {type(error).__name__}: {error}") from error
        if self.tripped.is_set():
            raise MemoryError("memory watchdog: available memory fell below 20 GB")


def watchdog(stop, tripped):
    root = psutil.Process()
    while not stop.is_set():
        if psutil.virtual_memory().available < FLOOR_GB * 2**30:
            tripped.set()
            killed = False
            for process in root.children(recursive=True):
                try:
                    if process.name().lower().startswith("erl"):
                        # 沿用枚举得到的进程身份；kill 自带 PID 复用校验，不能按裸 PID 重建。
                        process.kill()
                        killed = True
                except psutil.NoSuchProcess:
                    pass
            if killed:
                return
            # 还原期间尚无 BEAM 时继续守候，不能提前退出留下无人监视的启动阶段。
        stop.wait(1)


def capture(deploy, out, side):
    path = (out / f"{side}.json").as_posix()
    summary = m0.rpc(deploy, f'Code.require_file("{(HERE / "equiv.ex").as_posix()}")\n'
                             f'VoxelRegion.Bench.PagingEquiv.capture_static("{path}", VoxelRegion.World, "{side}")', 3_600_000)
    return json.loads(summary.strip().splitlines()[-1])


def capture_errors(value, side):
    """接纳固定审计产物；页／身份目录须来自live持久owner，不能由已采样结果反推。"""
    errors = []
    if set(value["digests"]) != AUDIT_FIELDS:
        errors.append("persistent_fields_incomplete")
    coverage = value.get("coverage", {})
    if coverage.get("schema") != "paging-live-audit-v1" or coverage.get("side") != side:
        errors.append("live_audit_contract_missing")
    seq = value.get("seq")
    if type(seq) is not int or coverage.get("start_seq") != seq or coverage.get("end_seq") != seq:
        errors.append("sequence_changed")
    start, end = coverage.get("published_start"), coverage.get("published_end")
    initialization = coverage.get("initialization")
    if initialization is not None and (not isinstance(initialization, dict) or
            initialization.get("complete") is not True or initialization.get("selected_cut") != seq):
        errors.append("static_initialization_incomplete")
    if side in ("H", "A"):
        initial = initialization
        initial_cut = start is None and end is None
        selected_cut = (type(start) is int and start == end and type(seq) is int and start < seq and
                        isinstance(initial, dict) and initial.get("complete") is True and
                        initial.get("selected_cut") == seq and initial.get("initial_cut") == start)
        if "published_start" not in coverage or "published_end" not in coverage or not (initial_cut or selected_cut):
            errors.append("a_not_before_selected_publication")
    elif type(start) is not int or start != end or type(seq) is not int or start != seq:
        errors.append("b_not_at_stable_published_prefix")
    regions = coverage.get("expected_regions")
    if not isinstance(regions, list) or len(regions) != len(set(regions)) or set(regions) != set(value["reads"]):
        errors.append("region_coverage_incomplete")
    identities = coverage.get("expected_identities")
    key = lambda identity: json.dumps(identity, sort_keys=True, separators=(",", ":"))
    actual = [key(row["identity"]) for row in value["q5"]["properties"]]
    expected = [key(identity) for identity in identities] if isinstance(identities, list) else None
    if expected is None or len(expected) != len(set(expected)) or len(actual) != len(set(actual)) or set(expected) != set(actual):
        errors.append("property_identity_coverage_incomplete")
    return [{"side": side, "reason": error} for error in errors]


def representative_errors(capture, entry):
    """仅测试侧核对独立的canonical点见证；不从被比属性行制造期望。"""
    identity, row = entry["identity"], entry["property"]
    witness = entry.get("representative_witness")
    if not isinstance(witness, dict) or witness.get("schema") != "canonical_g2_point_v1":
        return ["representative_witness_missing"]
    point = witness.get("target")
    if not isinstance(point, dict) or point.get("granularity") != 2 or point.get("material", 0) <= 0:
        return ["representative_not_occupied_component"]
    errors = []
    if witness.get("seq") != capture["seq"] or witness.get("content_version") != capture["content_version"]:
        errors.append("representative_witness_wrong_cut")
    owner = identity.get("owner")
    if (identity.get("granularity") != 2 or row.get("granularity") != 2 or
            not isinstance(owner, list) or len(owner) != 2 or
            point.get("owner") != owner or row.get("owner") != owner or
            point.get("incarnation") != owner[0] or row.get("incarnation") != owner[0]):
        errors.append("representative_wrong_owner")
    micro = point.get("micro")
    if (not isinstance(micro, list) or len(micro) != 3 or
            any(type(axis) is not int for axis in micro) or row.get("micro") != micro):
        errors.append("representative_wrong_position")
    if row.get("material") != point.get("material"):
        errors.append("representative_wrong_material")
    defense = witness.get("catalog_defense")
    if (type(defense) not in (int, float) or not math.isfinite(defense) or
            row.get("defense") != defense):
        errors.append("representative_wrong_defense")
    digest = witness.get("property_digest")
    if not isinstance(digest, str) or len(digest) != 64 or row.get("digest") != digest:
        errors.append("representative_wrong_catalog")
    return errors


def compare(a, b, *, historical_representatives=False):
    fields = sorted(set(a["digests"]) | set(b["digests"]))
    field_diff = [f for f in fields if a["digests"].get(f) != b["digests"].get(f)]
    keys = sorted(set(a["reads"]) | set(b["reads"]))
    read_diff = [k for k in keys if a["reads"].get(k) != b["reads"].get(k)]
    def indexed(side):
        rows = side["q5"]["properties"]
        result = {json.dumps(row["identity"], sort_keys=True, separators=(",", ":")): row for row in rows}
        if len(result) != len(rows):
            raise ValueError("duplicate Q5 identity")
        return result

    left, right = indexed(a), indexed(b)
    missing = sorted(set(left) - set(right))
    added = sorted(set(right) - set(left))
    property_diff, max_hp_differences, disallowed_max_hp = [], [], []
    witness_errors, representative_differences = [], []
    for key in sorted(set(left) & set(right)):
        before, after = left[key]["property"], right[key]["property"]
        identity = left[key]["identity"]
        excluded = {"max_hp"}
        if historical_representatives and identity["granularity"] == 2:
            found = [{"side": side, "identity": identity, "reason": reason}
                     for side, capture, entry in (("H", a, left[key]), ("B", b, right[key]))
                     for reason in representative_errors(capture, entry)]
            witness_errors.extend(found)
            if not found:
                excluded.update(("micro", "material", "defense"))
                changes = {field: {"before": before[field], "after": after[field]}
                           for field in ("micro", "material", "defense") if before[field] != after[field]}
                if changes:
                    representative_differences.append({"identity": identity, "fields": changes})
        if {k: v for k, v in before.items() if k not in excluded} != {k: v for k, v in after.items() if k not in excluded}:
            property_diff.append(identity)
        x, y = before["max_hp"], after["max_hp"]
        if x != y:
            difference = {"identity": identity, "before_max_hp": x, "after_max_hp": y, "delta": y - x}
            max_hp_differences.append(difference)
            if identity["granularity"] != 2 or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in (x, y)) or math.nextafter(x, y) != y:
                disallowed_max_hp.append(identity)
    projected_equal = a["q5"]["damage_without_max_hp"] == b["q5"]["damage_without_max_hp"]
    version_equal = a["content_version"] == b["content_version"]
    q5_equal = not (missing or added or property_diff or disallowed_max_hp or witness_errors) and projected_equal and version_equal
    if "damage" in field_diff and q5_equal:
        field_diff.remove("damage")
    coverage_errors = capture_errors(a, "A") + capture_errors(b, "B")
    if a.get("seq") != b.get("seq"):
        coverage_errors.append({"side": "A/B", "reason": "different_capture_sequence"})
    return {"fields": len(fields), "field_diff": field_diff, "regions": len(keys), "read_diff": read_diff[:50],
            "capture_complete": not coverage_errors, "capture_errors": coverage_errors,
            "read_diff_count": len(read_diff),
            "q5_equal": q5_equal, "q5_missing": [left[k]["identity"] for k in missing],
            "q5_added": [right[k]["identity"] for k in added], "q5_property_diff": property_diff,
            "q5_disallowed_max_hp": disallowed_max_hp, "q5_damage_without_max_hp_equal": projected_equal,
            "q5_content_version_equal": version_equal,
            "max_hp_differences": max_hp_differences,
            "representative_witness_errors": witness_errors, "representative_differences": representative_differences,
            "counts": {f: a["digests"][f].split(":")[0] for f in fields if f in a["digests"]}}


def compare_three(history, before, cold):
    """当前迁移精确；历史代表变化须独立实占见证，几何/材质载荷与其余状态仍严格。"""
    current = compare(before, cold)
    current["strict_field_diff"] = sorted(field for field in AUDIT_FIELDS
                                          if before["digests"].get(field) != cold["digests"].get(field))
    historical = compare(history, cold, historical_representatives=True)
    errors = capture_errors(history, "H")
    if history.get("seq") != cold.get("seq"):
        errors.append({"side": "H/B", "reason": "different_capture_sequence"})
    current_equal = (current["capture_complete"] and current["q5_equal"] and
                     not current["strict_field_diff"] and not current["read_diff_count"] and
                     not current["max_hp_differences"])
    history_equal = (not errors and historical["q5_equal"] and
                     not historical["field_diff"] and not historical["read_diff_count"])
    return {"equal": current_equal and history_equal, "current_migration_equal": current_equal,
            "historical_q5_equal": history_equal, "historical_capture_errors": errors,
            "current_migration": current,
            "historical_q5": {key: value for key, value in historical.items()
                              if key.startswith("q5_") or key in ("max_hp_differences", "field_diff",
                                  "read_diff", "read_diff_count", "representative_witness_errors", "representative_differences")},
            "historical_source_commit": HISTORICAL_COMMIT,
            "counts": {"historical_identities": len(history["q5"]["properties"]),
                       "current_identities": len(cold["q5"]["properties"]),
                       "max_hp_differences": len(historical["max_hp_differences"])}}


def verify_historical_repo(path):
    """只接纳原历史 checkout 与已声明的组合根 DI 一行；不重写旧求和函数。"""
    repo = Path(path).resolve()
    def git(*args):
        return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True,
                              text=True, encoding="utf-8").stdout
    if git("rev-parse", "HEAD").strip() != HISTORICAL_COMMIT:
        raise ValueError("historical source must be the frozen pre-order-change commit")
    application = "apps/voxel_region/lib/voxel_region/application.ex"
    original = git("show", f"{HISTORICAL_COMMIT}:{application}")
    expected = original.replace("log: VoxelRegion.OverlayLog.Db",
                                "log: Application.get_env(:voxel_region, :log_backend, VoxelRegion.OverlayLog.Db)")
    if expected == original or (repo / application).read_text(encoding="utf-8") != expected:
        raise ValueError("historical application must contain only the declared log backend injection")
    if set(git("diff", "--name-only", "HEAD").splitlines()) != {application}:
        raise ValueError("unexpected historical tracked source changes")
    return repo


@contextmanager
def runtime_source(repo, side):
    """正常 Mix 构建图在选定 checkout 工作；控制端和同一测试启动器仍复用当前入口。"""
    previous_repo, previous_side = m0.REPO, os.environ.get("M0_Q5_SIDE")
    m0.REPO = Path(repo)
    os.environ["M0_Q5_SIDE"] = side
    try:
        yield
    finally:
        m0.REPO = previous_repo
        if previous_side is None:
            os.environ.pop("M0_Q5_SIDE", None)
        else:
            os.environ["M0_Q5_SIDE"] = previous_side


def run_side(deploy, out, side, repo, guard, meta, dump=None):
    """一次实际启动／采集／停止；失败由 finally 关闭本轮节点，不自动重试。"""
    with runtime_source(repo, side):
        frozen = source_identity()
        source_path = out / f"source-{side}.json"
        source_path.write_text(json.dumps(frozen, indent=2), encoding="utf-8")
        meta[f"source_{side}"] = {"manifest": source_path.name,
                                 "sha256": hashlib.sha256(source_path.read_bytes()).hexdigest()}
        try:
            if dump is not None:
                meta[f"restored_{side}"] = restore(m0.config(deploy), dump)
            guard.check()
            started = m0.start(deploy)
            meta[f"start_{side}"] = {key: started[key] for key in ("ready_seconds", "startup_peak_rss_sum", "log")}
            guard.check()
            summary = capture(deploy, out, side)
            meta[side] = summary
            if side in ("H", "A"):
                published = json.loads(m0.rpc(deploy,
                    f"VoxelRegion.Bench.PagingEquiv.await_published({summary['seq']}, 1800)",
                    1_900_000).strip().splitlines()[-1])
                if published["seq"] != summary["seq"] or published["published_seq"] != summary["seq"]:
                    raise ValueError("publication did not preserve the captured exact sequence")
                meta[f"published_{side}"] = published
            if frozen != source_identity():
                raise RuntimeError("runtime source changed during Q5 capture")
            return summary
        finally:
            if m0.status(deploy)["running"]:
                meta[f"stop_{side}"] = m0.stop(deploy)["after"]
            (out / "meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("deploy")
    ap.add_argument("out")
    ap.add_argument("--dump", required=True)
    ap.add_argument("--historical-repo", required=True)
    a = ap.parse_args()
    historical_repo = verify_historical_repo(a.historical_repo)
    deploy, out = Path(a.deploy), Path(a.out)
    cfg = m0.config(deploy)
    if not cfg["pg"]["db"].startswith("paging_q5_") or cfg["env"]["MMO_DB_NAME"] != cfg["pg"]["db"]:
        raise ValueError("Q5 requires an explicitly isolated paging_q5_ database")
    if "M0_Q5_SIDE" in cfg["env"]:
        raise ValueError("Q5 side belongs to this runner, not deployment environment")
    if m0.status(deploy)["running"]:
        raise ValueError("Q5 deployment is already running")
    out.mkdir(parents=True, exist_ok=False)
    meta = {"args": vars(a), "started_utc": time.time()}
    current_repo = m0.REPO
    with MemoryWatchdog(out, meta) as guard:
        meta["control_source_sha256"] = {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
            for name in ("equiv.py", "equiv.ex", "boot.exs", "code_ready.exs", "m0.py", "run_m0.py")}
        run_side(deploy, out, "H", historical_repo, guard, meta, a.dump)
        run_side(deploy, out, "A", current_repo, guard, meta, a.dump)
        run_side(deploy, out, "B", current_repo, guard, meta)
        result = compare_three(*(json.loads((out / f"{side}.json").read_text()) for side in ("H", "A", "B")))
        (out / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        print(json.dumps(result), flush=True)
        if not result["equal"]:
            sys.exit(1)


if __name__ == "__main__":
    main()
