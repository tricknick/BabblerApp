import Foundation

// й/и tests (run via tests/yot_test.sh). Uses only the existing engine API:
//   AutoSwitchEngine.evaluate(word:currentLayout:) -> .keep | .switchLayout
//   AutoSwitchEngine.convert(_:to:)
//
// Typed-on-EN means: typed = convert(V, to: .english), where V is the Cyrillic string the user
// meant to type on the RU layout. A case passes when evaluate(typed, currentLayout: .english)
// == .switchLayout AND convert(typed, to: .russian) == V (the user's и stays и: layout switch only).
//
// CONTRACT (fails until the й/и rule is implemented in AutoSwitchEngine):
//   A word typed on EN layout whose RU conversion V is NOT in ru-forms.bin, but where replacing
//   one or more "и" with "й" yields a word W in ru-forms.bin, must return .switchLayout.
//   Title-case words follow the same rule (exact-tier behavior, first letter capitalized).
//   Guard: the replacement candidate must have Cyrillic length >= 3 (see "yot-neg").
//
// yot-fixture: positive preconditions (W in ru-forms and top-20k RU freq, contains й, V not in ru-forms).
// yot-pos:     58 lowercase RU words with й (all й kept), typed with every й -> и.
//              These currently do NOT switch (verified by probe), so they fail until implemented.
// yot-title:   first 8 of the above, title-case.
// yot-user:    the user's examples, partial substitution: какои->какой, краиний->крайний,
//              даваите->давайте, строика->стройка.
// yot-yo:      ё check (pass today): ещё, всё, все, мой typed on EN switch; ещё and еще both in ru-forms.
// yot-neg:     for all top-20k EN words (en_freq.txt, a-z), convert(w, .russian) containing и and
//              not in ru-forms; replacing 1-2 и with й hits ru-forms => must stay .keep.
//              Today's only hit is "tb" -> "еи" -> "ей". The guard (Cyrillic length >= 3) keeps it .keep.
// yot-ru:      RU-on-RU unchanged: the set of top-20k RU words switching on RU layout equals the
//              5 pre-existing words {шшш, куин, вуду, вуд, ашкн}.
//
// Env: BABBLER_RESOURCES, BABBLER_DICT_CACHE, BABBLER_TEST_DATA (set by yot_test.sh).

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

func frequencyWords(_ path: String, limit: Int, accept: (String) -> Bool) -> [String] {
  let text = try! String(contentsOfFile: path, encoding: .utf8)
  var out: [String] = []
  for line in text.split(separator: "\n") {
    guard let first = line.split(separator: " ").first else { continue }
    let word = String(first)
    if accept(word) {
      out.append(word)
      if out.count == limit { break }
    }
  }
  return out
}

let ruLetters: ClosedRange<Character> = "а"..."я"
func isCyrillicWord(_ word: String) -> Bool {
  !word.isEmpty && word.allSatisfy { ruLetters.contains($0) || $0 == "ё" }
}

func withCapitalFirst(_ word: String) -> String {
  guard let first = word.first else { return word }
  return String(first).uppercased() + word.dropFirst()
}

// All strings obtained from `typed` by replacing one or two "и" with "й".
func yCandidates(_ typed: String) -> [String] {
  let chars = Array(typed)
  let positions = chars.indices.filter { chars[$0] == "и" }
  var out: [String] = []
  for (a, i) in positions.enumerated() {
    var one = chars
    one[i] = "й"
    out.append(String(one))
    for j in positions.dropFirst(a + 1) {
      var two = chars
      two[i] = "й"
      two[j] = "й"
      out.append(String(two))
    }
  }
  return out
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

let ruFreq = frequencyWords("\(cacheDir)/ru_freq.txt", limit: 20000, accept: isCyrillicWord)
let ruFreqSet = Set(ruFreq)
let enFreq = frequencyWords("\(cacheDir)/en_freq.txt", limit: 20000) { word in
  word.allSatisfy { $0 >= "a" && $0 <= "z" }
}

// MARK: - POSITIVES (intended W contains й; typed V = W with every й -> и)

let yotPositives = [
  "мной", "моей", "своей", "какой", "твоей", "другой", "пойду", "нашей", "пойти", "вашей",
  "уйти", "дней", "друзей", "вещей", "лейтенант", "выйдет", "войти", "уйду", "рукой", "семьей",
  "найдут", "тупой", "лучшей", "злой", "выйду", "выйдешь", "майор", "выйди", "выйдем", "идеей",
  "едой", "уйдем", "выйдут", "иной", "уйдешь", "зайду", "файлы", "душой", "семейный", "кучей",
  "чьей", "онлайн", "бейсбол", "гавайи", "швейцарии", "индейцы", "китайцы", "ручной", "трейлер",
  "снайпер", "йогурт", "фейерверк", "пулей", "отвечайте", "узнайте", "имейте", "играйте", "скамейке",
]

print("=== POSITIVES (typed EN; RU word with и for й must switch)")
check("yot-fixture", yotPositives.count >= 40, "only \(yotPositives.count) positives")
for w in yotPositives {
  let v = w.replacingOccurrences(of: "й", with: "и")
  check("yot-fixture", ruFull.contains(w) && ruFreqSet.contains(w) && w.contains("й"),
        "W not a RU top-20k ru-forms word with й: \(w)")
  check("yot-fixture", !ruFull.contains(v), "V is already in ru-forms: \(v)")
  let typed = AutoSwitchEngine.convert(v, to: .english)
  check("yot-pos", switchesCorrectly(typed: typed, layout: .english, expected: v),
        "\(v) (for \(w)) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .english))")
}

print("=== TITLE-CASE POSITIVES")
for w in yotPositives.prefix(8) {
  let v = withCapitalFirst(w.replacingOccurrences(of: "й", with: "и"))
  let typed = AutoSwitchEngine.convert(v, to: .english)
  check("yot-title", switchesCorrectly(typed: typed, layout: .english, expected: v),
        "\(v) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .english))")
}

print("=== USER EXAMPLES (partial substitution)")
let userExamples = [
  ("какои", "какой"), ("краиний", "крайний"), ("даваите", "давайте"), ("строика", "стройка"),
]
for (v, w) in userExamples {
  check("yot-user", ruFull.contains(w) && !ruFull.contains(v), "fixture: \(v) / \(w)")
  let typed = AutoSwitchEngine.convert(v, to: .english)
  check("yot-user", switchesCorrectly(typed: typed, layout: .english, expected: v),
        "\(v) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .english))")
}

print("=== YO CHECK (ё -> е spelling already in ru-forms)")
check("yot-yo", ruFull.contains("ещё") && ruFull.contains("еще"), "ещё/еще not both in ru-forms")
for v in ["ещё", "всё", "все", "мой"] {
  let typed = AutoSwitchEngine.convert(v, to: .english)
  check("yot-yo", switchesCorrectly(typed: typed, layout: .english, expected: v),
        "\(v) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .english))")
}

// MARK: - NEGATIVES (false-positive guard)

print("=== NEGATIVES (EN words that must stay .keep)")
var rawHits: [String] = []
for w in enFreq {
  let c = AutoSwitchEngine.convert(w, to: .russian)
  guard c.contains("и"), !ruFull.contains(c) else { continue }
  if yCandidates(c).contains(where: { ruFull.contains($0) }) { rawHits.append(w) }
}
print("  top-20k EN words: \(enFreq.count); raw и->й hits in ru-forms: \(rawHits.count)")
for w in rawHits.prefix(15) {
  let c = AutoSwitchEngine.convert(w, to: .russian)
  print("    \(w) -> \(c) -> \(yCandidates(c).filter { ruFull.contains($0) }.joined(separator: ","))")
}
for w in rawHits {
  check("yot-neg", AutoSwitchEngine.evaluate(word: w, currentLayout: .english) == .keep,
        "EN word \(w) -> \(AutoSwitchEngine.convert(w, to: .russian)) must stay .keep")
}

print("=== RU-ON-RU (unchanged)")
let ruPreExistingSwitch: Set<String> = ["шшш", "куин", "вуду", "вуд", "ашкн"]
let ruSwitched = Set(ruFreq.filter {
  AutoSwitchEngine.evaluate(word: $0, currentLayout: .russian) == .switchLayout
})
check("yot-ru", ruSwitched == ruPreExistingSwitch,
      "extra: \(ruSwitched.subtracting(ruPreExistingSwitch).sorted()) missing: \(ruPreExistingSwitch.subtracting(ruSwitched).sorted())")

// MARK: - Summary

let labels = ["yot-fixture", "yot-pos", "yot-title", "yot-user", "yot-yo", "yot-neg", "yot-ru"]
print("=== SUMMARY (failing / cases)")
var totalFailures = 0
for label in labels {
  let failed = failCount[label, default: 0]
  totalFailures += failed
  print("  \(label): \(failed) / \(caseCount[label, default: 0])")
}
if totalFailures == 0 {
  print("ALL YOT CHECKS PASS")
  exit(0)
}
print("\(totalFailures) YOT CHECKS FAILED")
exit(1)
