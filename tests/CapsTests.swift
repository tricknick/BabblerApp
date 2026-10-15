import Foundation

// Caps tests (run via tests/caps_test.sh). Uses only the existing engine API:
//   AutoSwitchEngine.evaluate(word:currentLayout:) -> .keep | .switchLayout
//   AutoSwitchEngine.convert(_:to:)
//
// Contract (see Babbler/AutoSwitchEngine.swift: isAllCaps, isMixedCase, mixedCaseBrandTier,
// matchTier, isEligible):
//
// ALL-CAPS (every letter uppercase, >= 3 letters) is evaluated as its lowercase form, through
// the exact tiers only (current-layout dictionary veto, user lexicon, theme packs, exact
// dictionary) — never typo, n-gram, or hyphen. The replacement keeps the case: convert() maps
// upper <-> upper letter by letter, so the retype is still ALL-CAPS.
//   Positives: RU ALL-CAPS words typed on the EN layout (GHBDTN -> ПРИВЕТ), including trailing
//     punctuation; EN ALL-CAPS acronyms typed on the RU layout (API, JSON, URL, HTTP, SQL, USB,
//     CEO -> dictionaries/supplement-en.txt).
//   Negatives: 2-letter ALL-CAPS never switches (isEligible's length floor) - "PR"; real EN
//     ALL-CAPS tokens typed on the EN layout stay put via the current-layout dictionary veto
//     (USA, NASA, OK, TODO, FIXME, README, HTML, CNN, BBC, LOL, WTF, ASAP, FYI, IMHO); digit-bearing
//     codes never switch (XJ9, ABC123); RU ALL-CAPS typed on the RU layout stays put (ПРИВЕТ, МВД,
//     РФ, США, ООО, ЖКХ); ALL-CAPS runs whose conversion is gibberish in both layouts stay .keep.
//
// Mixed case ("iPhone", "GitHub") only ever switches via mixedCaseBrandTier: an exact,
// case-sensitive match (after conversion) against a small curated brand/tech list, and only
// typed on the RU layout.
//   Positives: every member of AutoSwitchEngine's curated brand list, typed on the RU layout.
//   Negatives: mixed-case runs not in that list stay .keep, even when they look brand-like.
//
// Env: BABBLER_RESOURCES, BABBLER_DICT_CACHE, BABBLER_TEST_DATA (set by caps_test.sh).

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

func isCyrillicCaps(_ word: String) -> Bool {
  let ruUpper: ClosedRange<Character> = "А"..."Я"
  return word.allSatisfy { ruUpper.contains($0) || $0 == "Ё" }
}

// MARK: - ALL-CAPS RU words typed on the EN layout (positives)

print("=== ALL-CAPS RU words typed on EN layout")
// Avoids б, ж, э, ю, х, ъ: those sit on keys whose EN-layout shifted symbol is punctuation
// (Б -> "<", Ю -> ">", ...), not a letter, so an ALL-CAPS word containing one can never read
// back as pure letters - a physical-keyboard limit, identical for lowercase/Title-case, and
// out of scope for this fix (see AutoSwitchEngine's shiftedCyrillicLeadMarkers).
let ruCapsWords = [
  "ПРИВЕТ", "МОСКВА", "СЕГОДНЯ", "ВОПРОС", "КОМПАНИЯ", "ИНФОРМАЦИЯ", "СИСТЕМА",
  "ПРОЕКТ", "РЕШЕНИЕ", "КОМАНДА", "КЛИЕНТ", "ВМЕСТЕ",
]
for word in ruCapsWords {
  check("ru-caps-fixture", LayoutDictionary.shared.contains(word.lowercased(), in: .russian),
        "not an RU fixture: \(word)")
  let typed = AutoSwitchEngine.convert(word, to: .english)
  check("ru-caps-pos", switchesCorrectly(typed: typed, layout: .english, expected: word),
        "\(word) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .english))")
}

let ruCapsPunctSuffixes = [".", ",", "?", "!", ";", "?!", "!?"]
for (i, word) in ruCapsWords.enumerated() {
  let intended = word + ruCapsPunctSuffixes[i % ruCapsPunctSuffixes.count]
  let typed = AutoSwitchEngine.convert(intended, to: .english)
  let decision = AutoSwitchEngine.evaluate(word: typed, currentLayout: .english)
  let produced = AutoSwitchEngine.convert(typed, to: .russian)
  check("ru-caps-punct", decision == .switchLayout && produced == intended,
        "\(intended) typed=\(typed) decision=\(decision) produced=\(produced)")
}

// 3-4 letter ALL-CAPS runs collide too easily with the full Russian inflected
// dictionary (see AutoSwitchEngine.shortAllCapsRuAcronyms): only this small
// curated set switches below 5 letters. "VDL" -> "МВД" is the task's own example.
print("=== short (3-4 letter) ALL-CAPS RU acronyms typed on EN layout (curated allowlist)")
for word in ["МВД", "МГУ", "СССР"] {
  let typed = AutoSwitchEngine.convert(word, to: .english)
  check("ru-caps-short-pos", switchesCorrectly(typed: typed, layout: .english, expected: word),
        "\(word) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .english))")
}

// MARK: - ALL-CAPS EN acronyms typed on the RU layout (positives)

print("=== ALL-CAPS EN acronyms typed on RU layout")
let enAcronyms = ["API", "URL", "HTTP", "JSON", "SQL", "USB", "CEO"]
for word in enAcronyms {
  check("en-acronym-fixture", englishSet.contains(word.lowercased()), "not an EN fixture: \(word)")
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  check("en-acronym-pos", switchesCorrectly(typed: typed, layout: .russian, expected: word),
        "\(word) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian))")
}

// MARK: - 2-letter ALL-CAPS never switches

print("=== 2-letter ALL-CAPS (negative)")
for word in ["PR", "KB", "СО"] {
  // Mistyped on the layout other than the word's own alphabet.
  let currentLayout: Layout = isCyrillicCaps(word) ? .english : .russian
  let typed = AutoSwitchEngine.convert(word, to: currentLayout)
  check("short-caps-neg", keeps(typed: typed, layout: currentLayout),
        "\(word) typed=\(typed) switched")
}

// MARK: - Real EN ALL-CAPS tokens typed on EN layout (negatives)

print("=== real EN ALL-CAPS tokens typed on EN layout (negative)")
let enNativeCaps = [
  "USA", "NASA", "OK", "TODO", "FIXME", "README", "HTML", "CNN", "BBC", "LOL", "WTF",
  "ASAP", "FYI", "IMHO",
]
for word in enNativeCaps {
  check("en-native-neg", keeps(typed: word, layout: .english), "\(word) switched when typed on EN")
}

// MARK: - Digit-bearing codes never switch (negative)

print("=== digit-bearing codes (negative)")
for word in ["XJ9", "ABC123"] {
  check("code-neg", keeps(typed: word, layout: .english), "\(word) switched when typed on EN")
  check("code-neg", keeps(typed: word, layout: .russian), "\(word) switched when typed on RU")
}

// MARK: - RU ALL-CAPS typed on the RU layout (negatives)

print("=== RU ALL-CAPS typed on RU layout (negative)")
for word in ["ПРИВЕТ", "МВД", "РФ", "США", "ООО", "ЖКХ"] {
  check("ru-native-neg", keeps(typed: word, layout: .russian), "\(word) switched when typed on RU")
}

// MARK: - ALL-CAPS gibberish in both layouts (negative)

print("=== ALL-CAPS gibberish (negative)")
let gibberishRu = ["ЪЭЖДФ", "ЬЩЗХЦ", "ЦУКЕН"]
for word in gibberishRu {
  check("gibberish-fixture", !LayoutDictionary.shared.contains(word.lowercased(), in: .russian),
        "\(word) is actually an RU fixture")
  let onEN = AutoSwitchEngine.convert(word, to: .english)
  check("gibberish-fixture", !englishSet.contains(onEN.lowercased()), "\(word) converts to an EN word: \(onEN)")
  check("gibberish-neg", keeps(typed: word, layout: .russian), "\(word) switched when typed on RU")
}
let gibberishEn = ["QWZXK", "VBNXZ", "JKLXQ"]
for word in gibberishEn {
  check("gibberish-fixture", !englishSet.contains(word.lowercased()), "\(word) is actually an EN fixture")
  check("gibberish-neg", keeps(typed: word, layout: .english), "\(word) switched when typed on EN")
}

// MARK: - Mixed-case EN brand names typed on the RU layout (positives)

print("=== mixed-case brand names typed on RU layout")
// Mirrors AutoSwitchEngine's private mixedCaseBrandTerms set; kept in sync by hand since the
// engine does not expose it, so a drift here flags a review of both lists.
let mixedCaseBrands = [
  "macOS", "iOS", "iPadOS", "iPhone", "iPad", "iMac", "iCloud", "iTunes",
  "AirPods", "MacBook", "GitHub", "GitLab", "YouTube", "WordPress",
  "PayPal", "TypeScript", "JavaScript", "PostgreSQL", "MongoDB", "OAuth",
  "GeForce", "FreeBSD", "OpenAI", "ChatGPT", "TikTok", "WeChat",
]
for word in mixedCaseBrands {
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  check("brand-pos", switchesCorrectly(typed: typed, layout: .russian, expected: word),
        "\(word) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian))")
}

// MARK: - Mixed-case non-brand runs stay .keep (negative)

print("=== mixed-case non-brand runs (negative)")
let mixedCaseNonBrands = ["McDonald", "DoorDash", "FedEx", "PlayStation", "aBcDe", "mIXeD"]
for word in mixedCaseNonBrands {
  check("brand-fixture", !mixedCaseBrands.contains(word), "\(word) is in the brand list")
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  check("brand-neg", keeps(typed: typed, layout: .russian), "\(word) typed=\(typed) switched")
}

// MARK: - Summary

let labels = [
  "ru-caps-fixture", "ru-caps-pos", "ru-caps-punct", "ru-caps-short-pos",
  "en-acronym-fixture", "en-acronym-pos",
  "short-caps-neg", "en-native-neg", "code-neg", "ru-native-neg",
  "gibberish-fixture", "gibberish-neg",
  "brand-fixture", "brand-pos", "brand-neg",
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
  print("ALL CAPS CHECKS PASS")
} else {
  print("\(totalFailures) CAPS CHECKS FAILED")
  exit(1)
}
