#!/usr/bin/env python
"""失败原因直白英文的离线对照（探索）：发送器。只发请求，不判。

是什么
  规格是 .demo/observe/npc-reason-wording-20261119/plan.md（发问前写定）。请求由同目录 reason_wording.exs 用产品代码渲染
  （render old / render new / manifest，写在 <运行目录>/requests/advance/）。发送整套复用 task_k0_replay.py
  （同一请求体形状、一个 httpx 客户端、并发 2、超时 120 s、不重试、401/402/403/429 或额度类字样即停、key 只读进本进程），
  这里只换两处：运行目录，以及本轮只有推进一段、硬上限 12（不读 K-0 的 sent-review.json）。
怎么运行（Git Bash；仓库根下）
  /c/ProgramData/miniconda3/python.exe -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/reason_wording_replay.py --dry-run
  /c/ProgramData/miniconda3/python.exe -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/reason_wording_replay.py
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import task_k0_replay as k0  # noqa: E402

OUT = k0.ROOT / ".demo" / "observe" / "npc-reason-wording-20261119"
# plan.md “发送”：3 个用例 × 2 版 × 2 次 = 12，硬上限 12。
CAP = 12


def plan_calls(phase):
    """本轮只有 advance 一段：manifest 的次序，超过上限即拒绝运行。"""
    assert phase == "advance"
    calls = json.loads((OUT / "requests" / phase / "manifest.json").read_text(encoding="utf-8"))["calls"]
    if len(calls) > CAP:
        sys.exit(f"manifest {len(calls)} 次超过上限 {CAP}，停")
    return calls, CAP, 0


def main():
    k0.set_run(OUT, CAP)
    k0.plan_calls = plan_calls
    if sys.argv[1:] == ["--dry-run"]:
        k0.dry_run("advance")
    elif sys.argv[1:] == []:
        k0.run("advance")
    else:
        sys.exit("用法：reason_wording_replay.py [--dry-run]")


if __name__ == "__main__":
    main()
