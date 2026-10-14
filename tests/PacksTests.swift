import Foundation

// Theme-pack tests. Compiled with the engine sources plus Babbler/ThemePacks.swift.
// Run with ./tests/packs_test.sh.
//
// API contract the implementation must match:
//   Babbler/ThemePacks.swift
//     struct ThemePacks {
//       static let allIds: [String]                    // ["it", "business", "gaming", "slang", "mat"]
//       static func load(ids: Set<String>, resourceDir: URL) -> ThemePacks
//       func contains(_ ruWord: String) -> Bool        // lowercases its argument
//       static func enabledIds(defaults: UserDefaults = .standard) -> Set<String>
//         // reads enabledThemePacksKey as [String]; key absent => Set(allIds)
//     }
//   Babbler/PreferenceStore.swift
//     let enabledThemePacksKey = "..."                 // top-level constant, any string value
//   Babbler/AutoSwitchEngine.swift (static enum)
//     static var themePacks: ThemePacks?               // nil = no packs. A pack hit on the converted
//                                                      // Russian word is Tier.exact in matchTier.
//   Babbler/Resources/pack-<id>.txt.gz                 // gzipped, one lowercase inflected Cyrillic form per line
//   tests/data/theme-packs.txt                         // "<pack id> <form>" lines: the required forms

let resources = ProcessInfo.processInfo.environment["BABBLER_RESOURCES"]
  ?? FileManager.default.currentDirectoryPath + "/Babbler/Resources"
let testData = ProcessInfo.processInfo.environment["BABBLER_TEST_DATA"]
  ?? FileManager.default.currentDirectoryPath + "/tests/data"
let resourceDir = URL(fileURLWithPath: resources, isDirectory: true)

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
    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// Words of one pack resource, read directly from the gzipped file.
func packWords(_ id: String) -> [String] {
  guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(resources)/pack-\(id).txt.gz")),
        let text = LayoutDictionary.testGunzip(data) else { return [] }
  return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
}

func readRequiredForms() -> [(pack: String, form: String)] {
  guard let text = try? String(contentsOfFile: "\(testData)/theme-packs.txt", encoding: .utf8) else { return [] }
  return text.split(whereSeparator: \.isNewline).compactMap { line -> (pack: String, form: String)? in
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
    let parts = trimmed.split(separator: " ")
    guard parts.count == 2 else { return nil }
    return (String(parts[0]), String(parts[1]).lowercased())
  }
}

// Same dictionary setup as tests/AutoSwitchTests.swift.
let englishWords = loadWords("\(resources)/en.txt.gz")
let englishSet = Set(englishWords)
let russianSet = HashedWordSet(contentsOf: URL(fileURLWithPath: "\(resources)/ru-forms.bin"))!
let russianTypoSet = HashedWordSet(contentsOf: URL(fileURLWithPath: "\(resources)/ru-typo.bin"))!
LayoutDictionary.shared.setForTests(englishSet, russianSet, typo: russianTypoSet)
let shippedEnglishModel = NGramModel(contentsOf: URL(fileURLWithPath: "\(resources)/ngram-en.bin"))
let shippedRussianModel = NGramModel(contentsOf: URL(fileURLWithPath: "\(resources)/ngram-ru.bin"))
LayoutDictionary.shared.setNGramModels(english: shippedEnglishModel, russian: shippedRussianModel)

let packIds = ["it", "business", "gaming", "slang", "mat"]
let requiredForms = readRequiredForms()
check(!requiredForms.isEmpty, "required forms list is missing from \(testData)/theme-packs.txt")

// Pack-only words: real Russian slang that the n-gram tier misses, so only the
// pack can switch them. Each must be absent from the Russian dictionary.
let packOnlyWords: [(word: String, pack: String)] = [
  ("ништяк", "slang"), ("ваще", "slang"), ("щас", "slang"),
  ("вкусняшка", "slang"), ("тусня", "slang"), ("пздц", "mat"),
]

// MARK: - Registry and resources

print("=== pack registry and resources")
check(ThemePacks.allIds == packIds, "allIds must be \(packIds), got \(ThemePacks.allIds)")
for id in packIds {
  check(packWords(id).count >= 5, "pack-\(id).txt.gz must hold at least 5 forms, has \(packWords(id).count)")
}
for (pack, form) in requiredForms {
  check(ThemePacks.load(ids: [pack], resourceDir: resourceDir).contains(form),
        "pack \(pack) must contain \(form)")
}

let allPacks = ThemePacks.load(ids: Set(packIds), resourceDir: resourceDir)
let slangOnly = ThemePacks.load(ids: ["slang"], resourceDir: resourceDir)
check(allPacks.contains("ништяк"), "all packs must contain ништяк")
check(allPacks.contains("НИШТЯК"), "contains must lowercase its argument")
check(slangOnly.contains("ништяк"), "slang-only load must contain ништяк")
check(!slangOnly.contains("пздц"), "slang-only load must not contain the mat form пздц")
check(!ThemePacks.load(ids: [], resourceDir: resourceDir).contains("ништяк"), "no ids must load no forms")

// MARK: - Pack forms typed on the English layout

print("=== pack forms typed on the EN layout, all packs on")
AutoSwitchEngine.themePacks = allPacks
for (pack, form) in requiredForms {
  let typed = AutoSwitchEngine.convert(form, to: .english)
  check(AutoSwitchEngine.matchTier(word: typed, currentLayout: .english) == .exact,
        "\(form) (\(pack)) typed as \(typed) must be an exact match")
  check(AutoSwitchEngine.evaluate(word: typed, currentLayout: .english) == .switchLayout,
        "\(form) typed as \(typed) must switch")
  check(AutoSwitchEngine.convert(typed, to: .russian) == form,
        "\(typed) must convert back to \(form)")
  check(AutoSwitchEngine.evaluate(word: form, currentLayout: .russian) == .keep,
        "\(form) typed correctly must be kept")
}

// MARK: - Pack-only words with their pack disabled

print("=== pack-only words with their pack disabled")
for (word, pack) in packOnlyWords {
  let typed = AutoSwitchEngine.convert(word, to: .english)
  check(!LayoutDictionary.shared.contains(word, in: .russian),
        "\(word) must be absent from the Russian dictionary for this test to mean anything")
  check(allPacks.contains(word), "\(word) must be in pack \(pack)")

  AutoSwitchEngine.themePacks = allPacks
  check(AutoSwitchEngine.matchTier(word: typed, currentLayout: .english) == .exact,
        "\(word) with all packs on must be an exact match")

  let withoutOwn = ThemePacks.load(ids: Set(packIds).subtracting([pack]), resourceDir: resourceDir)
  check(!withoutOwn.contains(word), "\(word) must not be in any pack other than \(pack)")
  AutoSwitchEngine.themePacks = withoutOwn
  check(AutoSwitchEngine.matchTier(word: typed, currentLayout: .english) != .exact,
        "\(word) with \(pack) disabled must not be an exact match")

  AutoSwitchEngine.themePacks = ThemePacks.load(ids: [], resourceDir: resourceDir)
  check(AutoSwitchEngine.matchTier(word: typed, currentLayout: .english) != .exact,
        "\(word) with no packs must not be an exact match")
}

// MARK: - Collisions with English words

print("=== pack forms against the English dictionary")
var collisions: [String] = []
var formCount = 0
for id in packIds {
  for form in packWords(id) {
    formCount += 1
    let typed = AutoSwitchEngine.convert(form, to: .english)
    if englishSet.contains(typed) { collisions.append("\(id):\(form)->\(typed)") }
  }
}
check(formCount > 0, "no pack forms were read from Babbler/Resources")
check(collisions.isEmpty, "pack forms whose EN keystrokes are English words: \(collisions.prefix(10))")

// MARK: - English regression with all packs on

print("=== English regression with all packs on")
AutoSwitchEngine.themePacks = allPacks
let englishFalsePositives = englishWords.filter {
  AutoSwitchEngine.evaluate(word: $0, currentLayout: .english) == .switchLayout
}
print("  EN false positives with packs on: \(englishFalsePositives.count)/\(englishWords.count)")
check(englishFalsePositives.isEmpty, "English false positives with packs on: \(englishFalsePositives.prefix(10))")

let brandWords = readList("\(testData)/brands-en.txt")
AutoSwitchEngine.themePacks = nil
let brandsSwitchedWithoutPacks = Set(brandWords.filter {
  AutoSwitchEngine.evaluate(word: $0, currentLayout: .english) == .switchLayout
})
AutoSwitchEngine.themePacks = allPacks
let brandsSwitchedWithPacks = Set(brandWords.filter {
  AutoSwitchEngine.evaluate(word: $0, currentLayout: .english) == .switchLayout
})
check(brandsSwitchedWithPacks == brandsSwitchedWithoutPacks,
      "packs must not change brand decisions: \(brandsSwitchedWithPacks.symmetricDifference(brandsSwitchedWithoutPacks).prefix(10))")
AutoSwitchEngine.themePacks = nil

// MARK: - Preference

print("=== enabled-packs preference")
let suiteName = "babbler-packs-test-\(getpid())"
let defaults = UserDefaults(suiteName: suiteName)!
defaults.removePersistentDomain(forName: suiteName)
check(ThemePacks.enabledIds(defaults: defaults) == Set(packIds), "all five packs must be enabled by default")
defaults.set(["slang"], forKey: enabledThemePacksKey)
check(ThemePacks.enabledIds(defaults: defaults) == ["slang"], "a stored selection must be read back")
defaults.removePersistentDomain(forName: suiteName)

if failures == 0 {
  print("ALL CHECKS PASS")
} else {
  print("\(failures) CHECKS FAILED")
  exit(1)
}
