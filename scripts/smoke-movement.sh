#!/usr/bin/env bash
#
# Movement sync smoke test runner (POSIX / Git Bash).
#
# Exercises the in-process end-to-end path
#   client -> PlayerCharacter (real GenServer + movement timer) -> AoiItem -> back
# against the scenarios the rubber-band fix was designed to address.
#
# Run from the repo root:
#   ./scripts/smoke-movement.sh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root/apps/scene_server"

NO_BUILD="${NO_BUILD:-0}"

if [[ "$NO_BUILD" != "1" ]]; then
  echo "==> Ensuring deps & compiled"
  HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120 mix deps.get
  mix compile
fi

echo "==> Running movement smoke (--only smoke --no-start)"
mix test --only smoke --no-start test/smoke/movement_smoke_test.exs

echo
echo "Movement smoke PASSED."
