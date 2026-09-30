#!/usr/bin/env bash
# Build the Voxim server image. Usage: deploy/build-image.sh <version> [voxim_repo]
# The Voxim client repository supplies the shared spatial header and movement crate (named build context).
set -euo pipefail
version=${1:?usage: deploy/build-image.sh <version> [voxim_repo]}
root=$(cd "$(dirname "$0")/.." && pwd)
voxim=${2:-$root/../Voxim}
docker build --build-context voxim="$voxim" -t "voxim-server:$version" "$root"
docker image inspect "voxim-server:$version" --format '{{.Id}}'
