#!/usr/bin/env bash
#
# Headless fuzz probe (throwaway; no pass/fail). Runs mode A (recall) and mode B (false
# positives) over a TSV of cases and appends one JSON object per bad token to a JSONL file.
# See tests/fuzz_probe.swift for the input format and the finding fields.
#
#   bash tests/fuzz_probe.sh <cases.tsv> <findings.jsonl> [--cell <source×breaker>]
#
# The compiled binary is cached at build/fuzz/bin/fuzz-probe and rebuilt only when a
# Babbler/*.swift or this script or tests/fuzz_probe.swift is newer than it.

set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "usage: bash tests/fuzz_probe.sh <cases.tsv> <findings.jsonl> [--cell <source×breaker>]" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES="$ROOT_DIR/Babbler/Resources"
CACHE_DIR="$ROOT_DIR/build/dict-cache"
FUZZ_DIR="$ROOT_DIR/build/fuzz"
BIN_DIR="$FUZZ_DIR/bin"
BIN="$BIN_DIR/fuzz-probe"
WORK_DIR="$FUZZ_DIR/work"

absolute() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$PWD/$1" ;;
  esac
}

CASES="$(absolute "$1")"
FINDINGS="$(absolute "$2")"
shift 2

CELL_ARGS=()
if [[ $# -gt 0 ]]; then
  if [[ $# -ne 2 || "$1" != "--cell" ]]; then
    echo "usage: bash tests/fuzz_probe.sh <cases.tsv> <findings.jsonl> [--cell <source×breaker>]" >&2
    exit 2
  fi
  CELL_ARGS=("$2")
fi

if [[ ! -f "$CASES" ]]; then
  echo "missing cases file: $CASES" >&2
  exit 2
fi

mkdir -p "$(dirname "$FINDINGS")" "$BIN_DIR"

needs_build() {
  [[ ! -x "$BIN" ]] && return 0
  [[ "$ROOT_DIR/tests/fuzz_probe.swift" -nt "$BIN" ]] && return 0
  [[ "$ROOT_DIR/tests/fuzz_probe.sh" -nt "$BIN" ]] && return 0
  [[ -n "$(find "$ROOT_DIR/Babbler" -name '*.swift' -newer "$BIN" -print -quit)" ]] && return 0
  return 1
}

if needs_build; then
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  trap 'rm -rf "$WORK_DIR"' EXIT

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
  cp "$ROOT_DIR/tests/fuzz_probe.swift" "$WORK_DIR/main.swift"

  echo "compiling fuzz probe..." >&2
  if ! swiftc -O -o "$BIN.new" "$WORK_DIR/main.swift" "${sources[@]}"; then
    rm -f "$BIN.new"
    echo "fuzz probe did not compile" >&2
    exit 1
  fi
  mv "$BIN.new" "$BIN"
fi

BABBLER_RESOURCES="$RESOURCES" BABBLER_DICT_CACHE="$CACHE_DIR" \
  "$BIN" "$CASES" "$FINDINGS" ${CELL_ARGS[@]+"${CELL_ARGS[@]}"}
