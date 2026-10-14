import Foundation

// Sentence-context and per-app profile tests. Compiled with the engine sources
// plus Babbler/SentenceContext.swift and Babbler/AutoSwitchAppProfiles*.swift.
// Run with ./tests/context_test.sh.
//
// API contract the implementation must match:
//   Babbler/SentenceContext.swift
//     struct SentenceContextSnapshot: Equatable { let prior: Layout; let strength: Int }
//     final class SentenceContext {
//       init()
//       func note(word: String, finalLayout: Layout)   // word committed, in the layout it ended up in
//       func reset()                                    // app change / Enter / mouse click / context change
//       var prior: Layout?                              // layout of >= 2 of the last 3 noted words; nil otherwise
//       var strength: Int                               // consecutive most recent noted words in prior, counted
//                                                       // back from the newest; 0 when prior is nil. May be 0
//                                                       // while prior is set (newest word in the other layout).
//       var snapshot: SentenceContextSnapshot?          // nil when prior is nil
//     }
//   Babbler/AutoSwitchEngine.swift (static enum)
//     static func evaluate(word:currentLayout:context: SentenceContextSnapshot?,
//                          dictionary: LayoutDictionary = .shared) -> Decision
//       // context nil == evaluate(word:currentLayout:dictionary:) exactly.
//       // exact, pack, and user-lexicon tiers ignore context.
//       // n-gram threshold multiplied by 0.6 when prior == target layout (no strength requirement).
//       // n-gram tier and typo tier disabled when prior == current layout and strength >= 3.
//   Babbler/AutoSwitchAppProfiles.swift
//     enum AutoSwitchAppProfiles {
//       static let defaultExcludedBundleIds: Set<String>    // includes the seven ids listed below
//       static let defaultExcludedBundlePrefixes: [String]  // ["com.jetbrains."]
//       static func isAutoSwitchAllowed(bundleId: String?, userOverrides: [String: Bool]) -> Bool
//         // nil bundleId => false (matches AppDelegate). Override wins. Otherwise an exact id
//         // or prefix match in the defaults => false. Everything else => true.
//     }
//   Babbler/PreferenceStore.swift
//     autoSwitchDefaultExcludedApps (existing global) must be built from
//     AutoSwitchAppProfiles.defaultExcludedBundleIds: same set, single source of truth.

let resources = ProcessInfo.processInfo.environment["BABBLER_RESOURCES"]
  ?? FileManager.default.currentDirectoryPath + "/Babbler/Resources"
let testData = ProcessInfo.processInfo.environment["BABBLER_TEST_DATA"]
  ?? FileManager.default.currentDirectoryPath + "/tests/data"

var failures = 0
func check(_ passed: Bool, _ message: String) {
  if !passed {
    failures += 1
    print("  FAIL  \(message)")
  }
}

func loadWords(_ path: String) -> [String] {
  let data = try! Data(contentsOf: URL(fileURLWithPath: path))
  var words: [String] = []
  LayoutDictionary.testGunzip(data)!.enumerateLines { line, _ in
    if !line.isEmpty { words.append(line) }
  }
  return words
}

func readList(_ path: String) -> [String] {
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
  return text.split(whereSeparator: \.isNewline)
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

// Same dictionary setup as tests/PacksTests.swift.
let englishSet = Set(loadWords("\(resources)/en.txt.gz"))
let russianSet = HashedWordSet(contentsOf: URL(fileURLWithPath: "\(resources)/ru-forms.bin"))!
let russianTypoSet = HashedWordSet(contentsOf: URL(fileURLWithPath: "\(resources)/ru-typo.bin"))!
LayoutDictionary.shared.setForTests(englishSet, russianSet, typo: russianTypoSet)
let shippedEnglishModel = NGramModel(contentsOf: URL(fileURLWithPath: "\(resources)/ngram-en.bin"))
let shippedRussianModel = NGramModel(contentsOf: URL(fileURLWithPath: "\(resources)/ngram-ru.bin"))
LayoutDictionary.shared.setNGramModels(english: shippedEnglishModel, russian: shippedRussianModel)

// MARK: - SentenceContext prior and strength

func context(_ layouts: [Layout]) -> SentenceContext {
  let sentence = SentenceContext()
  for layout in layouts { sentence.note(word: "w", finalLayout: layout) }
  return sentence
}

print("=== SentenceContext prior and strength")
let en = Layout.english
let ru = Layout.russian

let empty = context([])
check(empty.prior == nil && empty.strength == 0 && empty.snapshot == nil, "no notes: prior nil, strength 0, snapshot nil")
let one = context([en])
check(one.prior == nil, "one note must not set a prior")
let mixedPair = context([en, ru])
check(mixedPair.prior == nil, "one english and one russian note must not set a prior")
let pair = context([en, en])
check(pair.prior == en && pair.strength == 2, "two english notes: prior english, strength 2")
let eee = context([en, en, en])
check(eee.prior == en && eee.strength == 3, "eee: prior english, strength 3")
check(eee.snapshot == SentenceContextSnapshot(prior: en, strength: 3), "eee snapshot must be (english, 3)")
let ere = context([en, ru, en])
check(ere.prior == en && ere.strength == 1, "e r e: prior english, strength 1")
let rree = context([ru, ru, en, en])
check(rree.prior == en && rree.strength == 2, "r r e e: last three are r e e, so prior english, strength 2")
let err = context([en, ru, ru])
check(err.prior == ru && err.strength == 2, "e r r: prior russian, strength 2")
let eeer = context([en, en, en, ru])
check(eeer.prior == en && eeer.strength == 0, "e e e r: prior english, strength 0 (newest word is russian)")

let resetContext = context([en, en, en])
resetContext.reset()
check(resetContext.prior == nil && resetContext.strength == 0 && resetContext.snapshot == nil,
      "reset must clear prior, strength, and snapshot")
resetContext.note(word: "w", finalLayout: en)
check(resetContext.prior == nil, "one note after reset must not set a prior")

// MARK: - Engine: discriminating words (typed string = EN-layout keystrokes)

// Words are typed in English layout and are Russian words. Each typed string is
// asserted at nil context first so the rule under test is the only variable.
let nGramBorderline = "drecyzirf"   // вкусняшка: keep at nil, switch when prior is russian (target)
let nGramCurrent = "h.yltkm"        // хрюндель: switch at nil, keep when prior is english (current), strength 3
let exactWord = "ghbdtn"            // привет: exact tier, switches with any context
let typoWord = "ghdtn"              // привет: typo tier, keep when prior is english with strength 3
let typoWordTwo = "hf,jftn"         // работает: typo tier, keep when prior is english with strength 3

func snapshot(_ prior: Layout, _ strength: Int) -> SentenceContextSnapshot {
  SentenceContextSnapshot(prior: prior, strength: strength)
}

print("=== engine: n-gram margin relaxed when prior is target")
check(AutoSwitchEngine.evaluate(word: nGramBorderline, currentLayout: en, context: nil) == .keep,
      "precondition: вкусняшка typed as \(nGramBorderline) must keep at nil context")
check(AutoSwitchEngine.evaluate(word: nGramBorderline, currentLayout: en, context: snapshot(ru, 2)) == .switchLayout,
      "вкусняшка must switch when prior is russian (target), strength 2")
check(AutoSwitchEngine.evaluate(word: nGramBorderline, currentLayout: en, context: snapshot(ru, 3)) == .switchLayout,
      "вкусняшка must switch when prior is russian (target), strength 3")
check(AutoSwitchEngine.evaluate(word: nGramBorderline, currentLayout: en, context: snapshot(en, 2)) == .keep,
      "вкусняшка must keep when prior is english (current), strength 2: margin relaxation only applies to target")

print("=== engine: n-gram tier disabled when prior is current with strength >= 3")
check(AutoSwitchEngine.evaluate(word: nGramCurrent, currentLayout: en, context: nil) == .switchLayout,
      "precondition: хрюндель typed as \(nGramCurrent) must switch at nil context")
check(AutoSwitchEngine.evaluate(word: nGramCurrent, currentLayout: en, context: snapshot(en, 3)) == .keep,
      "хрюндель must keep when prior is english (current) with strength 3")
check(AutoSwitchEngine.evaluate(word: nGramCurrent, currentLayout: en, context: snapshot(en, 2)) == .switchLayout,
      "хрюндель must still switch when prior is english (current) with strength 2")

print("=== engine: typo tier disabled when prior is current with strength >= 3")
check(AutoSwitchEngine.evaluate(word: typoWord, currentLayout: en, context: nil) == .switchLayout,
      "precondition: привет typed as \(typoWord) must switch at nil context (typo tier)")
check(AutoSwitchEngine.evaluate(word: typoWord, currentLayout: en, context: snapshot(en, 3)) == .keep,
      "typo-tier привет must keep when prior is english (current) with strength 3")
check(AutoSwitchEngine.evaluate(word: typoWord, currentLayout: en, context: snapshot(en, 2)) == .switchLayout,
      "typo-tier привет must still switch when prior is english (current) with strength 2")
check(AutoSwitchEngine.evaluate(word: typoWordTwo, currentLayout: en, context: nil) == .switchLayout,
      "precondition: работает typed as \(typoWordTwo) must switch at nil context (typo tier)")
check(AutoSwitchEngine.evaluate(word: typoWordTwo, currentLayout: en, context: snapshot(en, 3)) == .keep,
      "typo-tier работает must keep when prior is english (current) with strength 3")

print("=== engine: exact tier ignores context")
check(AutoSwitchEngine.evaluate(word: exactWord, currentLayout: en, context: nil) == .switchLayout,
      "precondition: привет typed as \(exactWord) must switch at nil context")
check(AutoSwitchEngine.evaluate(word: exactWord, currentLayout: en, context: snapshot(en, 3)) == .switchLayout,
      "exact-tier привет must still switch when prior is english (current) with strength 3")
check(AutoSwitchEngine.evaluate(word: exactWord, currentLayout: en, context: snapshot(ru, 3)) == .switchLayout,
      "exact-tier привет must switch when prior is russian (target) with strength 3")

// MARK: - Engine: nil context equals the two-argument API

print("=== engine: nil context equals the two-argument evaluate")
let colloquial = readList("\(testData)/colloquial-ru.txt")
let brands = readList("\(testData)/brands-en.txt")
check(colloquial.count > 0 && brands.count > 0, "sample lists must load from \(testData)")
var sampleCount = 0
var mismatches: [String] = []
for word in colloquial {
  let typed = AutoSwitchEngine.convert(word, to: .english)
  for (input, layout) in [(typed, en), (word, ru)] {
    sampleCount += 1
    if AutoSwitchEngine.evaluate(word: input, currentLayout: layout)
        != AutoSwitchEngine.evaluate(word: input, currentLayout: layout, context: nil) {
      mismatches.append(input)
    }
  }
}
for word in brands {
  for layout in [en, ru] {
    let typed = layout == en ? word : AutoSwitchEngine.convert(word, to: .russian)
    sampleCount += 1
    if AutoSwitchEngine.evaluate(word: typed, currentLayout: layout)
        != AutoSwitchEngine.evaluate(word: typed, currentLayout: layout, context: nil) {
      mismatches.append(typed)
    }
  }
}
check(sampleCount > 300, "equivalence sample must cover at least 300 decisions, covered \(sampleCount)")
check(mismatches.isEmpty, "nil context diverged from the two-argument evaluate for: \(mismatches.prefix(10))")

// MARK: - Per-app profiles

print("=== per-app profiles: defaults")
let requiredExcluded: Set<String> = [
  "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode", "com.microsoft.VSCode",
  "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
]
check(requiredExcluded.isSubset(of: AutoSwitchAppProfiles.defaultExcludedBundleIds),
      "defaultExcludedBundleIds must include \(requiredExcluded.subtracting(AutoSwitchAppProfiles.defaultExcludedBundleIds).sorted())")
check(AutoSwitchAppProfiles.defaultExcludedBundlePrefixes.contains("com.jetbrains."),
      "defaultExcludedBundlePrefixes must contain com.jetbrains.")
check(Set(autoSwitchDefaultExcludedApps) == AutoSwitchAppProfiles.defaultExcludedBundleIds,
      "PreferenceStore autoSwitchDefaultExcludedApps must equal AutoSwitchAppProfiles.defaultExcludedBundleIds (single source)")

print("=== per-app profiles: isAutoSwitchAllowed")
check(AutoSwitchAppProfiles.isAutoSwitchAllowed(bundleId: "com.apple.Safari", userOverrides: [:]),
      "Safari must be allowed by default")
for id in requiredExcluded {
  check(!AutoSwitchAppProfiles.isAutoSwitchAllowed(bundleId: id, userOverrides: [:]),
        "\(id) must be excluded by default")
}
check(!AutoSwitchAppProfiles.isAutoSwitchAllowed(bundleId: "com.jetbrains.goland", userOverrides: [:]),
      "com.jetbrains.goland must be excluded by prefix")
check(!AutoSwitchAppProfiles.isAutoSwitchAllowed(bundleId: "com.jetbrains.intellij", userOverrides: [:]),
      "com.jetbrains.intellij must be excluded")
check(AutoSwitchAppProfiles.isAutoSwitchAllowed(bundleId: "com.jetbrainsfoo.app", userOverrides: [:]),
      "com.jetbrainsfoo.app must be allowed: prefix is com.jetbrains. with the dot")
check(!AutoSwitchAppProfiles.isAutoSwitchAllowed(bundleId: nil, userOverrides: [:]),
      "nil bundle id must not allow auto-switch")
check(!AutoSwitchAppProfiles.isAutoSwitchAllowed(bundleId: nil, userOverrides: ["com.apple.Safari": true]),
      "nil bundle id must not allow auto-switch even with overrides")

print("=== per-app profiles: user overrides win")
check(AutoSwitchAppProfiles.isAutoSwitchAllowed(bundleId: "com.apple.Terminal", userOverrides: ["com.apple.Terminal": true]),
      "override true must allow Terminal")
check(!AutoSwitchAppProfiles.isAutoSwitchAllowed(bundleId: "com.apple.Safari", userOverrides: ["com.apple.Safari": false]),
      "override false must disallow Safari")
check(AutoSwitchAppProfiles.isAutoSwitchAllowed(bundleId: "com.jetbrains.goland", userOverrides: ["com.jetbrains.goland": true]),
      "override true must allow a prefix-excluded JetBrains app")
check(!AutoSwitchAppProfiles.isAutoSwitchAllowed(bundleId: "com.apple.Terminal", userOverrides: ["com.apple.Safari": true]),
      "an override for another app must not change Terminal")

if failures == 0 {
  print("ALL CONTEXT CHECKS PASS")
} else {
  print("\(failures) CONTEXT CHECKS FAILED")
  exit(1)
}
