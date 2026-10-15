import Foundation

// Hyphen tests (run via tests/hyphen_test.sh). Uses only the existing engine API:
//   AutoSwitchEngine.evaluate(word:currentLayout:) -> .keep | .switchLayout
//   AutoSwitchEngine.convert(_:to:)
//
// Contract: a hyphenated token switches layout as a whole when every hyphen-separated
// part (>= 1 letter) converts to a known word or a known Russian hyphen particle
// (то, либо, нибудь, ка, таки, де, за, по, во, ж...) in the other layout, AND the token
// is not already a legitimate hyphenation where it stands.
//
// POS-RU: Russian hyphen words typed on the EN layout (the common direction) must
//   switch, e.g. "где-то" typed as "ult-nj" -> .switchLayout, converts back to "где-то".
// POS-RU-CAPS: same, Title-case ("Нам-то").
// NEG-EN: English hyphen words/compounds typed correctly on the EN layout
//   (well-known, e-mail, x-ray, aircrack-ng, python-telegram-bot) must stay .keep.
// NEG-RU-NATIVE: Russian hyphen words typed correctly on the RU layout must stay .keep.
// POS-EN-MIRROR: an English hyphen word typed on the RU layout (every part a full EN
//   dictionary word) switches to English. Kept conservative: no particle fallback.
//
// Env: BABBLER_RESOURCES, BABBLER_DICT_CACHE (set by hyphen_test.sh).

let env = ProcessInfo.processInfo.environment
let resources = env["BABBLER_RESOURCES"] ?? ""
let cacheDir = env["BABBLER_DICT_CACHE"] ?? ""

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
let ruCore = HashedWordSet(contentsOf: URL(fileURLWithPath: "\(resources)/ru-typo.bin"))!
LayoutDictionary.shared.setForTests(englishSet, ruFull, typo: ruCore)
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

func staysPut(_ word: String, layout: Layout) -> Bool {
  AutoSwitchEngine.evaluate(word: word, currentLayout: layout) == .keep
}

// MARK: - POS-RU: Russian hyphen words, typed on the EN layout

let ruHyphenWords = [
  "где-то", "кто-то", "из-за", "по-немецки", "сентябре-октябре",
  "так-то", "как-то", "какой-то", "во-первых", "во-вторых", "что-ж",
  "в-восьмых", "кросс-платформенная", "когда-то", "по-моему",
]

print("=== POS-RU: Russian hyphen words typed on the EN layout")
for word in ruHyphenWords {
  check("fixture-ru", ruFull.contains(word.split(separator: "-").first.map(String.init) ?? word)
          || word.contains("-"), "not a plausible RU fixture: \(word)")
  let typed = AutoSwitchEngine.convert(word, to: .english)
  check("pos-ru", switchesCorrectly(typed: typed, layout: .english, expected: word),
        "\(word) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .english))")
}

// MARK: - POS-RU-CAPS: Title-case Russian hyphen words

let ruHyphenTitleCase = ["Нам-то", "Где-то", "По-немецки", "Кто-то", "Во-первых", "Кросс-платформенная"]

print("=== POS-RU-CAPS: Title-case Russian hyphen words typed on the EN layout")
for word in ruHyphenTitleCase {
  let typed = AutoSwitchEngine.convert(word, to: .english)
  check("pos-ru-caps", switchesCorrectly(typed: typed, layout: .english, expected: word),
        "\(word) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .english))")
}

// MARK: - NEG-EN: English hyphen words/compounds, typed correctly on the EN layout

let enHyphenNegatives = [
  "well-known", "e-mail", "x-ray", "aircrack-ng", "python-telegram-bot",
  "father-in-law", "check-in", "co-worker", "state-of-the-art",
]

print("=== NEG-EN: English hyphen words typed on the EN layout must stay")
for word in enHyphenNegatives {
  check("neg-en", staysPut(word, layout: .english),
        "\(word) switched to \(AutoSwitchEngine.convert(word, to: .russian))")
}

// MARK: - NEG-RU-NATIVE: Russian hyphen words, typed correctly on the RU layout

print("=== NEG-RU-NATIVE: Russian hyphen words typed on the RU layout must stay")
for word in ruHyphenWords + ruHyphenTitleCase {
  check("neg-ru-native", staysPut(word, layout: .russian),
        "\(word) switched to \(AutoSwitchEngine.convert(word, to: .english))")
}

// MARK: - POS-EN-MIRROR: English hyphen words typed on the RU layout

let enHyphenMirror = ["well-known", "check-in", "self-aware", "wide-eyed", "open-minded"]

print("=== POS-EN-MIRROR: English hyphen words typed on the RU layout")
for word in enHyphenMirror {
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  check("pos-en-mirror", switchesCorrectly(typed: typed, layout: .russian, expected: word),
        "\(word) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian))")
}

// MARK: - NEG: code-like hyphen tokens with digits/underscores must never switch

let codeLikeNegatives = ["utm-source", "value-1", "x-forwarded-for", "my_var-name"]

print("=== NEG-CODE: code-like hyphen tokens must stay in both directions")
for word in codeLikeNegatives {
  check("neg-code-en", staysPut(word, layout: .english),
        "\(word) switched (EN) to \(AutoSwitchEngine.convert(word, to: .russian))")
  let ru = AutoSwitchEngine.convert(word, to: .russian)
  check("neg-code-ru", staysPut(ru, layout: .russian),
        "\(word) (as \(ru)) switched (RU) to \(AutoSwitchEngine.convert(ru, to: .english))")
}

// MARK: - Summary

let labels = ["fixture-ru", "pos-ru", "pos-ru-caps", "neg-en", "neg-ru-native",
              "pos-en-mirror", "neg-code-en", "neg-code-ru"]
print("=== SUMMARY (failing / cases)")
var totalFailures = 0
for label in labels {
  let failed = failCount[label, default: 0]
  totalFailures += failed
  print("  \(label): \(failed) / \(caseCount[label, default: 0])")
}
if totalFailures == 0 {
  print("ALL HYPHEN CHECKS PASS")
  exit(0)
}
print("\(totalFailures) HYPHEN CHECKS FAILED")
exit(1)
