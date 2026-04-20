#!/usr/bin/env bash
# POSIX counterpart to scripts/e2e-stdio-movement.ps1.
#
# The original plan was to drive the smoke via `mix demo.run --stdio`, but that
# Mix task was archived before this refactor landed. Instead this script
# exercises the reconciliation and visual-smoothing invariants through the
# bevy_client's cargo test suite. The tests it asserts on directly cover
# ReplayGovernance (hard_snap paths) and LocalRenderPrediction (drift /
# pending_correction), which is what the PRD acceptance criteria actually
# measure.
set -euo pipefail

DRIFT_TOLERANCE="${DRIFT_TOLERANCE:-2.0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_DIR="$REPO_ROOT/clients/bevy_client"
OBSERVE_DIR="$REPO_ROOT/.demo/e2e-stdio-movement"
TEST_LOG="$OBSERVE_DIR/cargo-test.log"

mkdir -p "$OBSERVE_DIR"
rm -f "$TEST_LOG"

cd "$CLIENT_DIR"

echo "[e2e-stdio-movement] running cargo test --lib (reconcile + smoothing focus)..."
if ! cargo test --lib --no-fail-fast 2>&1 | tee "$TEST_LOG"; then
  echo "cargo test --lib failed" >&2
  exit 1
fi

passed_total=0
failed_total=0
while IFS= read -r line; do
  passed=$(echo "$line" | sed -nE 's/.*test result: [A-Z]+\. ([0-9]+) passed; ([0-9]+) failed;.*/\1 \2/p' | awk '{print $1}')
  failed=$(echo "$line" | sed -nE 's/.*test result: [A-Z]+\. ([0-9]+) passed; ([0-9]+) failed;.*/\1 \2/p' | awk '{print $2}')
  passed_total=$((passed_total + ${passed:-0}))
  failed_total=$((failed_total + ${failed:-0}))
done < <(grep -E 'test result: (ok|FAILED)\.' "$TEST_LOG")

if [[ $failed_total -ne 0 ]]; then
  echo "$failed_total cargo test(s) failed — see $TEST_LOG" >&2
  exit 1
fi

required_tests=(
  "reconcile_hard_snaps_when_correction_is_too_large"
  "reconcile_hard_snaps_when_missing_match_and_drift_is_huge"
  "reconcile_falls_back_gracefully_when_seq_misses_with_small_drift"
  "local_render_prediction_accumulates_correction_without_teleport"
  "local_render_prediction_hard_snaps_on_huge_drift"
  "local_render_prediction_reset_clears_correction"
)

for name in "${required_tests[@]}"; do
  if ! grep -qE "test .*${name}.* \.\.\. ok" "$TEST_LOG"; then
    echo "expected passing test not found in output: $name" >&2
    exit 1
  fi
done

echo ""
echo "E2E stdio movement (unit-test proxy) passed."
echo "cargo test summary: passed=$passed_total failed=$failed_total"
echo "Log: $TEST_LOG"
echo "Drift tolerance (gates for any future real-smoke path): $DRIFT_TOLERANCE"
