import Foundation

// Punctuation tests (run via tests/punct_test.sh). Uses only the existing engine API:
//   AutoSwitchEngine.evaluate(word:currentLayout:) -> .keep | .switchLayout
//   AutoSwitchEngine.convert(_:to:)
//
// Two miss clusters from build/fuzz/FINDINGS.md / cluster_table.md, both realistic
// and low-risk:
//
// A) Dotted abbreviations ("т.д.", "e.g.") typed on the wrong layout. "." is a
//    disqualifying character for an EN-layout word (it is the key under RU "/"),
//    so these are rejected by isEligible before ever reaching a dictionary tier.
//    Fixed with a small explicit whitelist, exact match only, checked before the
//    ordinary eligibility gate.
//      Positives: every whitelisted RU abbreviation typed on the EN layout, and
//        every whitelisted EN abbreviation typed on the RU layout.
//      Negatives: the same abbreviations typed on their OWN (correct) layout stay
//        put; unrelated short runs containing "/" (a path, "n/a") stay put.
//
// B) A word wrapped in brackets/quotes, or followed by trailing punctuation, whose
//    wrapper character is a real letter on the OTHER layout ("[" / "]" / "," / ";"
//    / ":" / "." are х / ъ / б / ж / Ж / ю on the RU layout; RU-layout "[" / "]"
//    are typed as "~" / "`" on the EN layout) is never stripped before the tiers,
//    so "(filter," and "GitHub," never resolve to a clean dictionary word. Fixed
//    with a fallback tier that strips at most one extra leading and one extra
//    trailing wrapper character (after the ordinary universal trim), then re-judges
//    the core through the exact tiers only.
//      Positives: the bracket/quote/trailing-punctuation examples from the fuzz
//        findings, in both directions.
//      Negatives: normal EN/RU words with brackets typed on their own layout; short
//        real RU words whose first or last letter only looks like a wrapper marker
//        (их, уж, объ, люб, хз, ж, вдох,); EN code-like tokens (foo(), arr[0], a;b).
//
// Env: BABBLER_RESOURCES, BABBLER_DICT_CACHE, BABBLER_TEST_DATA (set by punct_test.sh).

let env = ProcessInfo.processInfo.environment
let resources = env["BABBLER_RESOURCES"] ?? ""
let cacheDir = env["BABBLER_DICT_CACHE"] ?? ""
let dataDir = env["BABBLER_TEST_DATA"] ?? ""
_ = cacheDir
_ = dataDir

func loadWords(_ path: String) -> [String] {
  let data = try! Data(contentsOf: URL(fileURLWithPath: path))
  var words: [String] = []
  LayoutDictionary.testGunzip(data)!.enumerateLines { line, _ in
    if !line.isEmpty { words.append(line) }
  }
  return words
}

let englishSet = Set(loadWords("\(resources)/en.txt.gz"))
let ruFull = HashedWordSet(contentsOf: URL(fileURLWithPath: "\(resources)/ru-forms.bin"))!
let ruTypo = HashedWordSet(contentsOf: URL(fileURLWithPath: "\(resources)/ru-typo.bin"))!
LayoutDictionary.shared.setForTests(englishSet, ruFull, typo: ruTypo)
LayoutDictionary.shared.setNGramModels(
  english: NGramModel(contentsOf: URL(fileURLWithPath: "\(resources)/ngram-en.bin")),
  russian: NGramModel(contentsOf: URL(fileURLWithPath: "\(resources)/ngram-ru.bin")))
AutoSwitchEngine.themePacks = ThemePacks.load(
  ids: Set(ThemePacks.allIds), resourceDir: URL(fileURLWithPath: resources))

var failCount: [String: Int] = [:]
var caseCount: [String: Int] = [:]
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
  caseCount[label, default: 0] += 1
  if ok { return }
  failCount[label, default: 0] += 1
  if failCount[label]! <= 8 { print("  FAIL [\(label)] \(detail())") }
}

func switchesCorrectly(typed: String, layout: Layout, expected: String) -> Bool {
  AutoSwitchEngine.evaluate(word: typed, currentLayout: layout) == .switchLayout
    && AutoSwitchEngine.convert(typed, to: layout.other) == expected
}

func keeps(typed: String, layout: Layout) -> Bool {
  AutoSwitchEngine.evaluate(word: typed, currentLayout: layout) == .keep
}

// MARK: - A) RU dotted abbreviations typed on the EN layout (positives)

print("=== RU dotted abbreviations typed on EN layout")
let ruAbbreviations = ["т.д.", "т.п.", "т.е.", "т.к.", "см.", "ул.", "г.", "др.", "пр."]
for word in ruAbbreviations {
  let typed = AutoSwitchEngine.convert(word, to: .english)
  check("ru-abbr-pos", switchesCorrectly(typed: typed, layout: .english, expected: word),
        "\(word) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .english))")
}

// MARK: - A) EN dotted abbreviations typed on the RU layout (positives)

print("=== EN dotted abbreviations typed on RU layout")
let enAbbreviations = ["e.g.", "i.e.", "etc.", "vs."]
for word in enAbbreviations {
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  check("en-abbr-pos", switchesCorrectly(typed: typed, layout: .russian, expected: word),
        "\(word) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian))")
}

// MARK: - A) abbreviations typed on their OWN layout stay put (negative)

print("=== abbreviations typed on their own (correct) layout (negative)")
for word in ruAbbreviations {
  check("abbr-own-layout-neg", keeps(typed: word, layout: .russian), "\(word) switched when typed on RU")
}
for word in enAbbreviations {
  check("abbr-own-layout-neg", keeps(typed: word, layout: .english), "\(word) switched when typed on EN")
}

// MARK: - A) unrelated short runs with "/" stay put (negative)

print("=== unrelated runs containing / (negative)")
for (word, layout) in [("n/a", Layout.english), ("a/b", .english), ("w/e", .english)] {
  check("slash-neg", keeps(typed: word, layout: layout), "\(word) switched on \(layout)")
}

// MARK: - B) bracket/quote/trailing-punctuation words, found in the wild (positives)

print("=== bracketed/trailing-punctuation words typed on the wrong layout")
// (typed, layout, expected) - expected is the full original token, punctuation included;
// convert(typed, to: layout.other) must reconstruct it exactly.
let wrapperPositives: [(typed: String, layout: Layout, expected: String)] = [
  ("~rjkbxtcndj", .english, "[количество"),
  ("xbctk`", .english, "чисел]"),
  ("(ашдеукб", .russian, "(filter,"),
  ("ПшеРгиб", .russian, "GitHub,"),
  ("(ИдгузкштеЖ)", .russian, "(Blueprint:)"),
  ("ФЗШж", .russian, "API;"),
]
for (typed, layout, expected) in wrapperPositives {
  check("wrapper-pos", switchesCorrectly(typed: typed, layout: layout, expected: expected),
        "\(expected) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: layout))")
}

// MARK: - B) normal EN/RU words with brackets typed correctly (negative)

print("=== normal words with correctly-typed brackets/quotes (negative)")
for word in ["(hello)", "\"world\"", "«привет»", "(привет)", "“quoted”"] {
  let layout: Layout = word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } ? .russian : .english
  check("wrapper-correct-neg", keeps(typed: word, layout: layout), "\(word) switched on \(layout)")
}

// MARK: - B) short RU words that merely start/end with a marker letter (negative)

print("=== short RU words that look like wrapper markers (negative)")
// х/ъ/ж/б/ю are the extra wrapper markers (б -> , , ж -> ; , ю -> . , х -> [ , ъ -> ]);
// these real (or plausible) short words must survive stripping — at 3 letters or
// fewer, removing one marker from an edge always leaves fewer than 3, below
// isEligible's floor, so wrapperStrippedTier's own core-length guard protects them.
let ruMarkerLookalikes = ["хз", "ж", "их", "уж", "объ", "люб"]
for word in ruMarkerLookalikes {
  check("marker-lookalike-fixture", word.count <= 3, "\(word) is longer than expected")
  check("marker-lookalike-neg", keeps(typed: word, layout: .russian), "\(word) switched when typed on RU")
}
// Trailing ASCII comma (not a Cyrillic marker letter) on a real word.
check("marker-lookalike-neg", keeps(typed: "вдох,", layout: .russian), "вдох, switched when typed on RU")

// MARK: - B) EN code-like tokens stay put (negative)

print("=== EN code-like tokens (negative)")
for word in ["foo()", "arr[0]", "a;b"] {
  check("code-neg", keeps(typed: word, layout: .english), "\(word) switched when typed on EN")
}

// MARK: - Summary

let labels = [
  "ru-abbr-pos", "en-abbr-pos", "abbr-own-layout-neg", "slash-neg",
  "wrapper-pos", "wrapper-correct-neg",
  "marker-lookalike-fixture", "marker-lookalike-neg", "code-neg",
]
print("=== SUMMARY (failing / cases)")
var totalFailures = 0
let extraLabels = caseCount.keys.filter { !labels.contains($0) }.sorted()
for label in labels + extraLabels {
  let failed = failCount[label, default: 0]
  totalFailures += failed
  print("  \(label): \(failed) / \(caseCount[label, default: 0])")
}
if totalFailures == 0 {
  print("ALL PUNCT CHECKS PASS")
} else {
  print("\(totalFailures) PUNCT CHECKS FAILED")
  exit(1)
}
