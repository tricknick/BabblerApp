#!/bin/zsh
#
# Miss-log checks: JSONL line format, the enabled preference, secure-input
# suppression, and the 2,000-line cap (see the API contract in
# tests/MissLogTests.swift).
#
#   ./tests/miss_log_test.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$ROOT_DIR/build/miss-log-test-work"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/data"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0

# MissLog only needs the preference-key constant it reads by default, so
# compile it unpatched alongside its small dependencies.
sources=("$ROOT_DIR/Babbler/Key.swift" "$ROOT_DIR/Babbler/PreferenceStore.swift" \
         "$ROOT_DIR/Babbler/MissLog.swift")
cp "$ROOT_DIR/tests/MissLogTests.swift" "$WORK_DIR/main.swift"

echo "=== compile and run tests/MissLogTests.swift"
if ! swiftc -O -o "$WORK_DIR/miss-log-tests" "$WORK_DIR/main.swift" "${sources[@]}"; then
  echo "  FAIL  MissLogTests.swift did not compile (MissLog implementation missing or incomplete)"
  failures=$((failures + 1))
else
  BABBLER_TEST_WORK="$WORK_DIR/data" "$WORK_DIR/miss-log-tests" || failures=$((failures + 1))
fi

if (( failures == 0 )); then
  echo "ALL MISS-LOG CHECKS PASS"
else
  echo "$failures MISS-LOG CHECK GROUP(S) FAILED"
  exit 1
fi
