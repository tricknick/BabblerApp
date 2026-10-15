#!/bin/zsh
#
# Real-text measurement probe (throwaway; no pass/fail). Reads sentences extracted by
# scripts/corpus_extract.py from build/corpus/{pikabu,habr}.txt and prints recall (mode A)
# and false positives (mode B). See tests/corpus_probe.swift. Corpus text is never copied
# into tracked files; output stays under build/.
#
#   python3 scripts/corpus_extract.py && ./tests/corpus_probe.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES="$ROOT_DIR/Babbler/Resources"
CACHE_DIR="$ROOT_DIR/build/dict-cache"
CORPUS_DIR="$ROOT_DIR/build/corpus"
WORK_DIR="$ROOT_DIR/build/corpus-probe-work"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

for name in pikabu habr; do
  if [[ ! -s "$CORPUS_DIR/$name.txt" ]]; then
    echo "missing $CORPUS_DIR/$name.txt; run: python3 scripts/corpus_extract.py"
    exit 1
  fi
done

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
   "$ROOT_DIR/Babbler/Key.swift" "$ROOT_DIR/Babbler/NGramModel.swift" \
   "$ROOT_DIR/Babbler/ThemePacks.swift" "$ROOT_DIR/Babbler/SpellOracle.swift" "$WORK_DIR/"

sources=("$WORK_DIR/LayoutDictionary.swift" "$WORK_DIR/AutoSwitchEngine.swift" \
         "$WORK_DIR/KeyDictionary.swift" "$WORK_DIR/AutoSwitchMemory.swift" \
         "$WORK_DIR/PreferenceStore.swift" "$WORK_DIR/Key.swift" "$WORK_DIR/NGramModel.swift" \
         "$WORK_DIR/ThemePacks.swift" "$WORK_DIR/SpellOracle.swift")
cp "$ROOT_DIR/tests/corpus_probe.swift" "$WORK_DIR/main.swift"

if ! swiftc -O -o "$WORK_DIR/corpus-probe" "$WORK_DIR/main.swift" "${sources[@]}"; then
  echo "probe did not compile"
  exit 1
fi

BABBLER_RESOURCES="$RESOURCES" BABBLER_DICT_CACHE="$CACHE_DIR" BABBLER_CORPUS="$CORPUS_DIR" \
  "$WORK_DIR/corpus-probe"
