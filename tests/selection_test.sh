#!/bin/zsh
#
# Selection tests: the action key with nothing recorded must convert the selection and
# never the user's own clipboard. Contract in tests/SelectionTests.swift.
#
#   ./tests/selection_test.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$ROOT_DIR/build/selection-work"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

cp "$ROOT_DIR/tests/SelectionTests.swift" "$WORK_DIR/main.swift"
if ! swiftc -o "$WORK_DIR/selection-tests" "$WORK_DIR/main.swift" "$ROOT_DIR/Babbler/SelectionGuard.swift"; then
  echo "selection tests did not compile"
  exit 1
fi
"$WORK_DIR/selection-tests"
