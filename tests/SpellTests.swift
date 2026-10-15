import Foundation

// Spell-checker tier tests (run via tests/spell_test.sh). A deterministic fake
// oracle drives AutoSwitchEngine so these checks never depend on what is
// actually installed on the machine running them; SystemSpellOracle itself is
// exercised separately against the real NSSpellChecker at the bottom.
//
// Contract (Babbler/AutoSwitchEngine.swift matchTier, Babbler/SpellOracle.swift):
//   - CONFIRM (gated by spellCheckerConfirmEnabled, default true): fires only
//     when the typed word is not already a dictionary/typo/pack hit, is >= 4
//     letters, is NOT known to the speller where it stands, AND the converted
//     form IS known to the speller in the target language. Returns .spellChecker.
//   - VETO (unconditional whenever an oracle is set, independent of the confirm
//     flag): if the typed word is known to the speller where it stands, the
//     language-model tier below is suppressed even if it would otherwise fire.
//   - Inert whenever no oracle is wired (AutoSwitchEngine.spellOracle == nil).
//
// Env: BABBLER_RESOURCES, BABBLER_DICT_CACHE (set by spell_test.sh).

let env = ProcessInfo.processInfo.environment
let resources = env["BABBLER_RESOURCES"] ?? ""

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

/// A deterministic stand-in for NSSpellChecker: `known` holds "<tag>:<word>"
/// entries (lowercased), everything else is unknown.
final class FakeSpellOracle: SpellOracle {
  var known: Set<String> = []
  func isKnown(_ word: String, language: Layout) -> Bool {
    let tag = language == .english ? "en" : "ru"
    return known.contains("\(tag):\(word.lowercased())")
  }
}

func resetOracle(_ oracle: SpellOracle?, confirmEnabled: Bool = true) {
  AutoSwitchEngine.spellOracle = oracle
  AutoSwitchEngine.spellCheckerConfirmEnabled = confirmEnabled
}

// MARK: - A: confirm tier fires only under the documented conditions

print("=== A: confirm tier (.spellChecker)")

// A made-up word, 7 letters, that is in none of our dictionaries, not one
// typo away from a real word, and scores below the n-gram floor in both
// directions -- i.e. every earlier and later tier is a genuine miss on its
// own, so a transition to .spellChecker can only be the oracle's doing.
let madeUpWord = "qzvwtlk"
let madeUpConverted = AutoSwitchEngine.convert(madeUpWord, to: .russian)

do {
  // Sanity: with no oracle wired, this word really is a dead end everywhere.
  resetOracle(nil)
  check("a-sanity-inert-baseline", AutoSwitchEngine.matchTier(word: madeUpWord, currentLayout: .english) == nil,
        "\(madeUpWord) unexpectedly matched a tier with no oracle: " +
        "\(String(describing: AutoSwitchEngine.matchTier(word: madeUpWord, currentLayout: .english)))")
}

do {
  // Converted form known in Russian, typed form unknown in English, length
  // >= 4, confirm enabled (default) -> .spellChecker.
  let oracle = FakeSpellOracle()
  oracle.known = ["ru:\(madeUpConverted)"]
  resetOracle(oracle)
  check("a-confirm-fires", AutoSwitchEngine.matchTier(word: madeUpWord, currentLayout: .english) == .spellChecker,
        "\(madeUpWord) -> \(madeUpConverted) did not fire the spell-checker tier")
}

// MARK: - B: inert whenever no oracle is wired

print("=== B: inert without an oracle")
do {
  resetOracle(nil)
  check("b-no-oracle", AutoSwitchEngine.matchTier(word: madeUpWord, currentLayout: .english) == nil,
        "spell-checker tier fired with spellOracle == nil")
}

// MARK: - C: length guard (< 4 letters never fires, regardless of the oracle)

print("=== C: length guard")
do {
  let shortWord = "qzv"
  let shortConverted = AutoSwitchEngine.convert(shortWord, to: .russian)
  let oracle = FakeSpellOracle()
  oracle.known = ["ru:\(shortConverted)"]
  resetOracle(oracle)
  let tier = AutoSwitchEngine.matchTier(word: shortWord, currentLayout: .english)
  check("c-too-short", tier != .spellChecker,
        "\(shortWord) (3 letters) fired the spell-checker tier (\(String(describing: tier)))")
}

// MARK: - D: does not fire when the typed word is itself known to the speller

print("=== D: typed-known guard")
do {
  let oracle = FakeSpellOracle()
  oracle.known = ["ru:\(madeUpConverted)", "en:\(madeUpWord)"]
  resetOracle(oracle)
  let tier = AutoSwitchEngine.matchTier(word: madeUpWord, currentLayout: .english)
  check("d-typed-known", tier != .spellChecker,
        "\(madeUpWord) fired the spell-checker tier despite being known in English (\(String(describing: tier)))")
}

// MARK: - E: spellCheckerConfirmEnabled gates the confirm half only

print("=== E: confirm flag vs. veto")
do {
  // Flag off: the same setup as A no longer confirms...
  let oracle = FakeSpellOracle()
  oracle.known = ["ru:\(madeUpConverted)"]
  resetOracle(oracle, confirmEnabled: false)
  check("e-confirm-disabled", AutoSwitchEngine.matchTier(word: madeUpWord, currentLayout: .english) != .spellChecker,
        "confirm tier fired while spellCheckerConfirmEnabled == false")
}

do {
  // ...but the veto keeps suppressing the n-gram tier regardless of the flag.
  // "жопецкий" (derived from жопа) is a motivating example for the n-gram
  // tier elsewhere in the suite: typed on the English layout with no oracle,
  // it switches through .languageModel.
  let typed = AutoSwitchEngine.convert("жопецкий", to: .english)
  resetOracle(nil)
  check("e-baseline-languagemodel", AutoSwitchEngine.matchTier(word: typed, currentLayout: .english) == .languageModel,
        "\(typed) (жопецкий) no longer switches through the language model; fixture is stale")

  let oracle = FakeSpellOracle()
  oracle.known = ["en:\(typed)"]
  resetOracle(oracle, confirmEnabled: false)
  check("e-veto-independent-of-flag", AutoSwitchEngine.matchTier(word: typed, currentLayout: .english) == nil,
        "\(typed) still switched through the language model despite the speller veto (confirm disabled)")

  resetOracle(oracle, confirmEnabled: true)
  check("e-veto-with-confirm-enabled", AutoSwitchEngine.matchTier(word: typed, currentLayout: .english) == nil,
        "\(typed) still switched through the language model despite the speller veto (confirm enabled)")
}

resetOracle(nil) // leave global state clean for anything appended below.

// MARK: - F: SystemSpellOracle against the real NSSpellChecker

print("=== F: SystemSpellOracle")
do {
  let unavailable = SystemSpellOracle(availableLanguagesOverride: [])
  check("f-unavailable-language-en", !unavailable.isKnown("hello", language: .english),
        "isKnown returned true for an unavailable language")
  check("f-unavailable-language-ru", !unavailable.isKnown("привет", language: .russian),
        "isKnown returned true for an unavailable language")

  let englishOnly = SystemSpellOracle(availableLanguagesOverride: ["en"])
  check("f-known-word", englishOnly.isKnown("hello", language: .english),
        "a real NSSpellChecker install does not recognise \"hello\" in English")
  check("f-language-not-overridden-available", !englishOnly.isKnown("привет", language: .russian),
        "isKnown returned true for a language not in the override set")

  let offMainExpectation = DispatchSemaphore(value: 0)
  var offMainResult = true
  DispatchQueue.global().async {
    offMainResult = englishOnly.isKnown("hello", language: .english)
    offMainExpectation.signal()
  }
  _ = offMainExpectation.wait(timeout: .now() + 5)
  check("f-off-main-guard", !offMainResult, "isKnown returned true when called off the main thread")
}

// MARK: - Summary

let labels = ["a-sanity-inert-baseline", "a-confirm-fires", "b-no-oracle", "c-too-short",
              "d-typed-known", "e-confirm-disabled", "e-baseline-languagemodel",
              "e-veto-independent-of-flag", "e-veto-with-confirm-enabled",
              "f-unavailable-language-en", "f-unavailable-language-ru", "f-known-word",
              "f-language-not-overridden-available", "f-off-main-guard"]
print("=== SUMMARY (failing / cases)")
var totalFailures = 0
for label in labels {
  let failed = failCount[label, default: 0]
  totalFailures += failed
  print("  \(label): \(failed) / \(caseCount[label, default: 0])")
}
if totalFailures == 0 {
  print("ALL SPELL CHECKS PASS")
  exit(0)
}
print("\(totalFailures) SPELL CHECKS FAILED")
exit(1)
