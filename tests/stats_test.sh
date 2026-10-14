#!/bin/zsh
#
# Local-stats checks: per-tier switch counts, undo and manual-swap counters, precision,
# calendar-day rollover of "today", persistence through the store, and reset
# (see the API contract in tests/StatsTests.swift).
#
#   ./tests/stats_test.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$ROOT_DIR/build/stats-test-work"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0

# The stats tests only need the engine's Tier type, so compile the engine sources unpatched.
sources=("$ROOT_DIR/Babbler/LayoutDictionary.swift" "$ROOT_DIR/Babbler/AutoSwitchEngine.swift" \
         "$ROOT_DIR/Babbler/KeyDictionary.swift" "$ROOT_DIR/Babbler/AutoSwitchMemory.swift" \
         "$ROOT_DIR/Babbler/PreferenceStore.swift" "$ROOT_DIR/Babbler/Key.swift" \
         "$ROOT_DIR/Babbler/NGramModel.swift")
for f in "$ROOT_DIR"/Babbler/AutoSwitchStats*.swift(N); do
  sources+=("$f")
done
cp "$ROOT_DIR/tests/StatsTests.swift" "$WORK_DIR/main.swift"

echo "=== compile and run tests/StatsTests.swift"
if ! swiftc -O -o "$WORK_DIR/stats-tests" "$WORK_DIR/main.swift" "${sources[@]}"; then
  echo "  FAIL  StatsTests.swift did not compile (AutoSwitchStats implementation missing or incomplete)"
  failures=$((failures + 1))
else
  "$WORK_DIR/stats-tests" || failures=$((failures + 1))
fi

if (( failures == 0 )); then
  echo "ALL STATS CHECKS PASS"
else
  echo "$failures STATS CHECK GROUP(S) FAILED"
  exit 1
fi
