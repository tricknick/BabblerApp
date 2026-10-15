#!/bin/zsh
#
# Sentence-context and per-app profile checks: SentenceContext prior/strength,
# engine evaluate(word:currentLayout:context:), and AutoSwitchAppProfiles (see
# tests/ContextTests.swift for the API contract).
#
#   ./tests/context_test.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES="$ROOT_DIR/Babbler/Resources"
WORK_DIR="$ROOT_DIR/build/context-test-work"
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
    lock.lock(); english = en; russian = ru; russianTypo = typo; isLoaded = true
    commonEnglish = Self.testLoadWords("common-en"); commonRussian = Self.testLoadWords("common-ru"); lock.unlock()
  }
  static func testLoadWords(_ name: String) -> Set<String> {
    guard let dir = ProcessInfo.processInfo.environment["BABBLER_RESOURCES"],
          let data = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name + ".txt.gz")),
          let text = testGunzipImpl(data) else { return [] }
    return Set(text.split(whereSeparator: { $0.isNewline }).map(String.init))
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

# Optional implementation files: picked up once they exist.
for file in "$ROOT_DIR"/Babbler/SentenceContext.swift(N) "$ROOT_DIR"/Babbler/AutoSwitchAppProfiles*.swift(N); do
  cp "$file" "$WORK_DIR/"
  sources+=("$WORK_DIR/${file:t}")
done

cp "$ROOT_DIR/tests/ContextTests.swift" "$WORK_DIR/main.swift"

echo "=== compile and run tests/ContextTests.swift"
if ! swiftc -O -o "$WORK_DIR/context-tests" "$WORK_DIR/main.swift" "${sources[@]}" 2> "$WORK_DIR/compile.log"; then
  grep 'error:' "$WORK_DIR/compile.log" | head -20
  echo "  FAIL  ContextTests.swift did not compile (SentenceContext / context-aware evaluate / AutoSwitchAppProfiles missing or incomplete)"
  failures=$((failures + 1))
else
  BABBLER_RESOURCES="$RESOURCES" BABBLER_TEST_DATA="$ROOT_DIR/tests/data" "$WORK_DIR/context-tests" || failures=$((failures + 1))
fi

if (( failures == 0 )); then
  echo "ALL CONTEXT CHECKS PASS"
else
  echo "$failures CONTEXT CHECK GROUP(S) FAILED"
  exit 1
fi
