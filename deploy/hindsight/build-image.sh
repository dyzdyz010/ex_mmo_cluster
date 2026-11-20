#!/usr/bin/env bash
# 构建生产 Hindsight 镜像。用法：deploy/hindsight/build-image.sh <version>，产出 voxim-hindsight:<version>。
# 版本建议写成“上游版本-日期”（如 0.10.3-20261120）。构建时要从 huggingface.co 下载两个模型（见 Dockerfile）。
set -euo pipefail
version=${1:?usage: deploy/hindsight/build-image.sh <version>}
docker build -t "voxim-hindsight:$version" "$(cd "$(dirname "$0")" && pwd)"
docker image inspect "voxim-hindsight:$version" --format '{{.Id}}'
