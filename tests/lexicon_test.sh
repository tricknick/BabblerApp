#!/bin/zsh
#
# User-lexicon checks: promotion, validity, spelling-file import, cap, persistence,
# reset, the enabled preference, and engine decisions with and without the lexicon
# (see the API contract in tests/LexiconTests.swift).
#
#   ./tests/lexicon_test.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES="$ROOT_DIR/Babbler/Resources"
WORK_DIR="$ROOT_DIR/build/lexicon-test-work"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0

# Same LayoutDictionary harness patch as tests/packs_test.sh.
sed -e 's/private static func gunzip/static func testGunzipImpl/' \
    -e 's/gunzip(compressed)/testGunzipImpl(compressed)/' \
    "$ROOT_DIR/Babbler/LayoutDictionary.swift" > "$WORK_DIR/LayoutDictionary.swift"

python3 - "$WORK_DIR/LayoutDictionary.swift" <<'PY'
import sys
path = sys.argv[1]
source = open(path).read()
hook = """  func setForTests(_ en: Set<String>, _ ru: HashedWordSet, typo: HashedWordSet) {
    lock.lock(); english = en; russian = ru; russianTypo = typo; isLoaded = true; lock.unlock()
  }
  static func testGunzip(_ data: Data) -> String? { testGunzipImpl(data) }

  func contains("""
open(path, "w").write(source.replace("  func contains(", hook, 1))
PY

cp "$ROOT_DIR/Babbler/AutoSwitchEngine.swift" "$ROOT_DIR/Babbler/KeyDictionary.swift" \
   "$ROOT_DIR/Babbler/AutoSwitchMemory.swift" "$ROOT_DIR/Babbler/PreferenceStore.swift" \
   "$ROOT_DIR/Babbler/Key.swift" "$ROOT_DIR/Babbler/NGramModel.swift" "$WORK_DIR/"

sources=("$WORK_DIR/LayoutDictionary.swift" "$WORK_DIR/AutoSwitchEngine.swift" \
         "$WORK_DIR/KeyDictionary.swift" "$WORK_DIR/AutoSwitchMemory.swift" \
         "$WORK_DIR/PreferenceStore.swift" "$WORK_DIR/Key.swift" "$WORK_DIR/NGramModel.swift")
if [[ -f "$ROOT_DIR/Babbler/ThemePacks.swift" ]]; then
  cp "$ROOT_DIR/Babbler/ThemePacks.swift" "$WORK_DIR/"
  sources+=("$WORK_DIR/ThemePacks.swift")
fi
for f in "$ROOT_DIR"/Babbler/UserLexicon*.swift(N); do
  cp "$f" "$WORK_DIR/"
  sources+=("$WORK_DIR/${f:t}")
done
cp "$ROOT_DIR/tests/LexiconTests.swift" "$WORK_DIR/main.swift"

echo "=== compile and run tests/LexiconTests.swift"
if ! swiftc -O -o "$WORK_DIR/lexicon-tests" "$WORK_DIR/main.swift" "${sources[@]}"; then
  echo "  FAIL  LexiconTests.swift did not compile (user-lexicon implementation missing or incomplete)"
  failures=$((failures + 1))
else
  BABBLER_RESOURCES="$RESOURCES" BABBLER_TEST_WORK="$WORK_DIR" "$WORK_DIR/lexicon-tests" || failures=$((failures + 1))
fi

if (( failures == 0 )); then
  echo "ALL LEXICON CHECKS PASS"
else
  echo "$failures LEXICON CHECK GROUP(S) FAILED"
  exit 1
fi
