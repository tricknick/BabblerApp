#!/bin/zsh
#
# Theme-pack checks: pack resources exist and hold the required forms, and the
# engine treats pack forms as exact Russian matches (see tests/PacksTests.swift
# for the API contract).
#
#   ./tests/packs_test.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES="$ROOT_DIR/Babbler/Resources"
WORK_DIR="$ROOT_DIR/build/packs-test-work"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0

echo "=== pack resources and required forms (shell)"
while read -r pack form; do
  [[ -z "$pack" || "$pack" == \#* ]] && continue
  file="$RESOURCES/pack-$pack.txt.gz"
  if [[ ! -f "$file" ]]; then
    echo "  FAIL  missing resource pack-$pack.txt.gz"
    failures=$((failures + 1))
    continue
  fi
  if ! gzip -dc "$file" | grep -qxF "$form"; then
    echo "  FAIL  pack-$pack.txt.gz lacks form $form"
    failures=$((failures + 1))
  fi
done < "$ROOT_DIR/tests/data/theme-packs.txt"

# Same LayoutDictionary harness patch as tests/run.sh.
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
if [[ -f "$ROOT_DIR/Babbler/ThemePacks.swift" ]]; then
  cp "$ROOT_DIR/Babbler/ThemePacks.swift" "$WORK_DIR/"
  sources+=("$WORK_DIR/ThemePacks.swift")
fi
cp "$ROOT_DIR/tests/PacksTests.swift" "$WORK_DIR/main.swift"

echo "=== compile and run tests/PacksTests.swift"
if ! swiftc -O -o "$WORK_DIR/packs-tests" "$WORK_DIR/main.swift" "${sources[@]}"; then
  echo "  FAIL  PacksTests.swift did not compile (theme-pack implementation missing or incomplete)"
  failures=$((failures + 1))
else
  BABBLER_RESOURCES="$RESOURCES" BABBLER_TEST_DATA="$ROOT_DIR/tests/data" "$WORK_DIR/packs-tests" || failures=$((failures + 1))
fi

if (( failures == 0 )); then
  echo "ALL PACK CHECKS PASS"
else
  echo "$failures PACK CHECK GROUP(S) FAILED"
  exit 1
fi
