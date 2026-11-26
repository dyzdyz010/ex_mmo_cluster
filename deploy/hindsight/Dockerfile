# 生产 Hindsight 镜像：官方 0.10.3 slim + ONNX 嵌入 + FlashRank 重排 + M-3c 同机 2 核配置，两个模型烘进镜像、运行时不联 HuggingFace。
# 构建：deploy/hindsight/build-image.sh <version>（构建机要能访问 huggingface.co；生产主机不需要）。说明见 deploy/README.md“Hindsight”。
#
# 依赖与 Test-only 镜像 voxim-npc-evolve-hindsight:0.10.3-flashrank（../Voxim/Docs/Gameplay/NpcEvolve/Dockerfile，M-3c 实跑所用）
# 一致：那份写的是 "flashrank>=0.2.0"，这里钉死成它实际解析出的版本（2026-11-20 在该镜像里 `uv pip freeze` 与基底逐行比对，
# 多出的只有下面三个包；onnxruntime 1.20.1、huggingface-hub 1.6.0、tokenizers 0.22.2 基底已带）。

# 基底按 digest 钉死（tag 可被重推）：本机 ghcr.io/vectorize-io/hindsight:0.10.3-slim 的 RepoDigest。
FROM ghcr.io/vectorize-io/hindsight:0.10.3-slim@sha256:c0bd6122a1d0d62dc5094ce43150780a28a96ec70109b44c688210231a5ac33a

USER root
RUN uv pip install --python /app/api/.venv/bin/python --no-cache \
      "hindsight-api-slim[local-onnx]==0.10.3" "flashrank==0.2.10" "transformers==5.15.1" "safetensors==0.8.0" \
 && uv pip check --python /app/api/.venv/bin/python

# ---- 模型：构建时下载到镜像内固定路径，运行时只读 ----
# 嵌入走 huggingface_hub 的缓存（HF_HOME 下的 hub/），重排是 flashrank 自己的缓存目录（它用 requests 直接下 zip，不认 HF_HUB_OFFLINE，
# 目录在就不下载：flashrank/Ranker.py `_prepare_model_dir`）。两个模型名在这里定一次，下载与 Hindsight 运行时读同一个变量。
ENV HF_HOME=/opt/hindsight-models/huggingface \
    HINDSIGHT_API_EMBEDDINGS_ONNX_MODEL_ID=BAAI/bge-small-en-v1.5 \
    HINDSIGHT_API_RERANKER_FLASHRANK_MODEL=ms-marco-MiniLM-L-12-v2 \
    HINDSIGHT_API_RERANKER_FLASHRANK_CACHE_DIR=/opt/hindsight-models/flashrank
# 下载调用与 0.10.3 运行时的取法逐项一致，离线时才能命中同一份缓存：
# - 嵌入图：engine/embeddings.py:565 `snapshot_download(repo_id, allow_patterns=[onnx_file, onnx_file + "_data"])`，onnx_file 缺省 onnx/model.onnx；
# - 分词器：engine/embeddings.py:585 `AutoTokenizer.from_pretrained(model_id)`；
# - 重排：engine/cross_encoder.py `Ranker(model_name=…, max_length=…, cache_dir=…)`，建一次即下载并解压。
# 版本钉死（不一致即构建失败）：
# - 嵌入钉 commit 5c38ec7c…（M-3c 实跑所用常驻 hf 卷的同一快照）。运行时不带 revision、离线按 refs/main 找快照，所以这里也按 main 下载
#   （带 revision 下载不写 refs/main，离线会找不到），下载后断言 main 解析到的、以及缓存里唯一的快照就是它；上游 main 前移即构建失败。
# - flashrank 从 huggingface.co/prithivida/flashrank/resolve/main/<模型>.zip 下载（flashrank/Config.py `model_url`），没有版本可选，
#   改为断言 Ranker 读的五个文件的 sha256（2026-11-20 首次构建所得；zip 里另带的 .DS_Store、__MACOSX 不读、不核）。
RUN /app/api/.venv/bin/python - <<'EOF'
import hashlib
import os
from huggingface_hub import snapshot_download
from transformers import AutoTokenizer
from flashrank import Ranker

EMBEDDINGS_COMMIT = "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"
RERANKER_SHA256 = {
    "flashrank-MiniLM-L-12-v2_Q.onnx": "d3dd7b09fcf06b0c070081d6819b5effbb40b667bcad78b2d7543400271141d1",
    "config.json": "2144195e107cd7ea61556478e7add12986ebfbc3085f924fc0b90c2410604879",
    "tokenizer.json": "ce64fce797c24f68df90b40a3f74f579b336a493db14bd583fd520ea0d8c9a98",
    "tokenizer_config.json": "eaf913a687e8eed3010b6479d0d84631038212aa50c14d9b812e08cbc891d925",
    "special_tokens_map.json": "303df45a03609e4ead04bc3dc1536d0ab19b5358db685b6f3da123d05ec200e3",
}

model_id = os.environ["HINDSIGHT_API_EMBEDDINGS_ONNX_MODEL_ID"]
snapshot = snapshot_download(repo_id=model_id, allow_patterns=["onnx/model.onnx", "onnx/model.onnx_data"])
AutoTokenizer.from_pretrained(model_id)
snapshots = sorted(os.listdir(os.path.dirname(snapshot)))
assert os.path.basename(snapshot) == EMBEDDINGS_COMMIT and snapshots == [EMBEDDINGS_COMMIT], (snapshot, snapshots)
print("bake embeddings", snapshot)

reranker = os.environ["HINDSIGHT_API_RERANKER_FLASHRANK_MODEL"]
cache_dir = os.environ["HINDSIGHT_API_RERANKER_FLASHRANK_CACHE_DIR"]
Ranker(model_name=reranker, cache_dir=cache_dir)
digests = {name: hashlib.sha256(open(os.path.join(cache_dir, reranker, name), "rb").read()).hexdigest()
           for name in RERANKER_SHA256}
assert digests == RERANKER_SHA256, digests
print("bake reranker", reranker, "sha256 ok")
EOF
# 缓存里缺文件时宁可启动失败，也不在运行时静默下载（M-3c 私有 Hindsight 的同一取舍）。
ENV HF_HUB_OFFLINE=1

# ---- M-3c：同机 2 核配置（本节是这组取值的唯一事实源；决策与实跑记录见
#      docs/10-active/cross-cutting/2026-11-18-npc-scale-and-qinglan-entry-decision.md 的 E3 / E7 与 §7 2026-11-19 条） ----
# 外部依据：上游 Hindsight issue #5725 与修复 commit b18f425（PR #5779，晚于 0.10.3）；ONNX Runtime 线程文档
# https://onnxruntime.ai/docs/performance/tune-performance/threading.html。名额 2 / 1 与分批 8 是原创初值，3 人实跑 limits3-03 检验通过、非定论。
# 不改 RERANKER_MAX_CANDIDATES、EMBEDDINGS_ONNX_MAX_TOKENS：它们改变召回语义。
# ORT 线程补丁（退出条件见补丁文件头）。
COPY ort-bound/sitecustomize.py /opt/npc-ort-bound/sitecustomize.py
# OMP_NUM_THREADS：补丁按它定 ORT intra-op 线程（同 b18f425），也是 OpenMP 线程数；PYTHONPATH：让容器 Python 启动时载入补丁；
# WORKER_MAX_SLOTS：后台 worker 总名额（缺省 10），召回与 worker 同事件循环、无优先级；CONSOLIDATION_RESERVED_SLOTS：巩固保底（缺省 2）；
# 两项 BATCH_SIZE：嵌入 / 重排每次前向的条数（缺省 32），单批张量峰值约降到 1/4，只改分批不改结果。
ENV PYTHONPATH=/opt/npc-ort-bound \
    OMP_NUM_THREADS=2 \
    HINDSIGHT_API_WORKER_MAX_SLOTS=2 \
    HINDSIGHT_API_WORKER_CONSOLIDATION_RESERVED_SLOTS=1 \
    HINDSIGHT_API_EMBEDDINGS_ONNX_BATCH_SIZE=8 \
    HINDSIGHT_API_RERANKER_FLASHRANK_BATCH_SIZE=8

# ---- 与镜像内模型、NPC 产品契约绑定的非密钥设置（取自 M-3c 实跑所用常驻容器的人为设置；Test-only 证据：
#      .demo/observe/npc-limits-20261118/limits_settings.py 的 RESIDENT_ENV） ----
# 嵌入：bge-small 的 384 维、CLS 池化与查询前缀（该模型的用法）；重排用镜像内的 flashrank。
# ENABLE_BANK_CONFIG_API（花费额度开关自动巩固）与 LLM_TRACE_ENABLED（花费额度读用量）不得关；LLM 追踪保留天数用 0.10.3 缺省 1 天，
# 不得调短（额度按北京自然日读当天用量）。LLM 的地址、模型名、key 属于部署，放 compose / .env。
ENV HINDSIGHT_API_EMBEDDINGS_PROVIDER=onnx \
    HINDSIGHT_API_EMBEDDINGS_ONNX_DEVICE=cpu \
    HINDSIGHT_API_EMBEDDINGS_ONNX_POOLING=cls \
    HINDSIGHT_API_EMBEDDINGS_ONNX_DIMENSIONS=384 \
    HINDSIGHT_API_EMBEDDINGS_ONNX_QUERY_PREFIX="Represent this sentence for searching relevant passages: " \
    HINDSIGHT_API_EMBEDDINGS_ONNX_PASSAGE_PREFIX="" \
    HINDSIGHT_API_RERANKER_PROVIDER=flashrank \
    HINDSIGHT_API_ENABLE_BANK_CONFIG_API=true \
    HINDSIGHT_API_LLM_TRACE_ENABLED=true \
    HINDSIGHT_API_LLM_PROVIDER=openai \
    HINDSIGHT_API_LLM_REASONING_EFFORT=medium \
    HINDSIGHT_API_RETAIN_LLM_REASONING_EFFORT=low \
    HINDSIGHT_API_REFLECT_LLM_REASONING_EFFORT=high

USER hindsight
