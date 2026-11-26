"""生产 Hindsight 镜像（deploy/hindsight/Dockerfile）的 ONNX Runtime 线程补丁：移植上游 Hindsight commit b18f425 的语义。

来源：上游 issue #5725（2 核配额下 300 个候选的重排 343 s，限到 2 线程后 21 s）由 commit b18f425（PR #5779）修复：每个
`ort.SessionOptions` 过一遍 `bound_onnx_session`——intra = `OMP_NUM_THREADS`、inter = 1、`session.intra_op.allow_spinning = "0"`。
0.10.3 之后尚无含它的发布版。代码与 Test-only 驱动的 `.demo/observe/npc-limits-20261118/ort_bound/sitecustomize.py`
（M-3c，`limits3-03` 实跑通过的那份）相同，只改了本文件头。

为什么要补丁：0.10.3 建 ONNX Runtime 会话时（嵌入 `hindsight_api/engine/embeddings.py:595`、flashrank 重排 `flashrank/Ranker.py:68`
与 `hindsight_api/engine/cross_encoder.py:1418` 的替换会话）没设线程数：ORT 的 intra-op 线程池按宿主物理核数开、且线程自旋等活。
`OMP_NUM_THREADS` 对 ORT 的默认线程池无效，也没有别的环境变量能设，只能在 `SessionOptions` 上改。这里在
`InferenceSession.__init__` 外包一层做与 b18f425 同样的事（ORT 1.20.1：`onnxruntime.InferenceSession` 即
`onnxruntime.capi.onnxruntime_inference_collection.InferenceSession`，flashrank 用的是同一个类）。
线程文档：https://onnxruntime.ai/docs/performance/tune-performance/threading.html

怎么生效：镜像把本目录拷到 `/opt/npc-ort-bound`，并在镜像 ENV 里设 `PYTHONPATH=/opt/npc-ort-bound`（基底镜像 `Config.Env`
没有 PYTHONPATH，故不拼接原值）。容器 Python（`/app/api/.venv/bin/python` 3.11，启动不带 -I / -S）的 `site` 处理完 .pth 后自动
`import sitecustomize`，于是本文件在 Hindsight 任何代码之前执行。

可观测：每建一个会话往 stderr 打一行 `{"npc_ort_bound": {...}}`（值从改后的 options 读回）；部署后核对见 deploy/README.md
“Hindsight”一节。导入失败等异常**不吞**：让它抛出，`site` 会打印 “Error in sitecustomize”。

退出条件：Hindsight 升到含 b18f425 的发布版后删掉本目录、Dockerfile 里的 COPY 与 `PYTHONPATH`，只留 `OMP_NUM_THREADS`
（上游补丁读它）。
"""

# 先按 0.10.3 原有顺序定原生线程变量（`hindsight_api/__init__.py` 顶部做的同一件事），再载 onnxruntime（它会带进 numpy，
# OpenBLAS 等只在载入时读这些变量）。本文件在 Hindsight 包之前执行，不先调就会让 numpy 按宿主核数开线程池。
from hindsight_api._thread_limits import apply_default_thread_limits

apply_default_thread_limits()

import json  # noqa: E402
import os  # noqa: E402
import sys  # noqa: E402

import onnxruntime  # noqa: E402

SPINNING_KEY = "session.intra_op.allow_spinning"
_original_init = onnxruntime.InferenceSession.__init__


def _model_name(path_or_bytes):
    """日志里的模型名：路径取文件名；直接给字节的记 "bytes"。"""
    if isinstance(path_or_bytes, (bytes, bytearray)):
        return "bytes"
    return os.path.basename(os.fspath(path_or_bytes))


def _bounded_init(self, path_or_bytes, sess_options=None, *args, **kwargs):
    """同上游 `bound_onnx_session`：没给 options 就新建一份；intra = OMP_NUM_THREADS（至少 1）、inter = 1、不自旋。
    调用方给的 options 原地修改（保留它别的设置，如 `enable_cpu_mem_arena = False`）。"""
    options = onnxruntime.SessionOptions() if sess_options is None else sess_options
    options.intra_op_num_threads = max(1, int(os.environ["OMP_NUM_THREADS"]))
    options.inter_op_num_threads = 1
    options.add_session_config_entry(SPINNING_KEY, "0")
    line = {"npc_ort_bound": {"intra": options.intra_op_num_threads, "inter": options.inter_op_num_threads,
                              "spinning": options.get_session_config_entry(SPINNING_KEY),
                              "model": _model_name(path_or_bytes)}}
    print(json.dumps(line), file=sys.stderr, flush=True)
    _original_init(self, path_or_bytes, options, *args, **kwargs)


onnxruntime.InferenceSession.__init__ = _bounded_init
