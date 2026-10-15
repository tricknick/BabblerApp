import Foundation

// Typo-on-wrong-layout tests (run via tests/typo_test.sh). Uses only the existing engine API:
//   AutoSwitchEngine.matchTier(word:currentLayout:) -> Tier?   (nil = keep)
//   AutoSwitchEngine.evaluate(word:currentLayout:) -> .keep | .switchLayout
//   AutoSwitchEngine.convert(_:to:)
//
// Model: the user meant V in layout I, but typed the typo T of V, so the keys produced are
// typed = convert(T, to: I.other). The engine is asked with currentLayout = I.other.
//
// Typo classes (applied to the intended word V, giving T):
//   A  vowel        one vowel swapped for a confusable one (RU о<->а, е<->и; EN a<->e, i<->e, o<->u)
//   A2 vowel-opt    RU е<->я, и<->ы (measured only)
//   B  doubled      one letter typed twice
//   C  swap         two adjacent letters transposed
//   D  missing      one letter missing (existing typo tier; baseline)
//
// Not yet implemented in the engine: classes A, A2, B, C. Their positives fail until implemented.
// Negatives (FP-derived and Title-case) must stay .keep.
//
// Env: BABBLER_RESOURCES, BABBLER_DICT_CACHE, BABBLER_TEST_DATA (set by typo_test.sh).

let env = ProcessInfo.processInfo.environment
let resources = env["BABBLER_RESOURCES"] ?? ""
let cacheDir = env["BABBLER_DICT_CACHE"] ?? ""
let dataDir = env["BABBLER_TEST_DATA"] ?? ""

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

func plainLines(_ path: String) -> [String] {
  let text = try! String(contentsOfFile: path, encoding: .utf8)
  return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

let ruLetters: ClosedRange<Character> = "а"..."я"
func isCyrillicWord(_ word: String) -> Bool {
  !word.isEmpty && word.allSatisfy { ruLetters.contains($0) || $0 == "ё" }
}
func isLatinWord(_ word: String) -> Bool {
  !word.isEmpty && word.allSatisfy { $0 >= "a" && $0 <= "z" }
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

// MARK: - Word lists

let ruFreq = frequencyWords("\(cacheDir)/ru_freq.txt", limit: 20000, accept: isCyrillicWord)
let enFreq = frequencyWords("\(cacheDir)/en_freq.txt", limit: 20000, accept: isLatinWord)
var ruRank: [String: Int] = [:]
for (i, w) in ruFreq.enumerated() where ruRank[w] == nil { ruRank[w] = i + 1 }
var enRank: [String: Int] = [:]
for (i, w) in enFreq.enumerated() where enRank[w] == nil { enRank[w] = i + 1 }
let properNouns = plainLines("\(dataDir)/proper-nouns.lst").map { $0.lowercased() }
let enCollisions = plainLines("\(dataDir)/en-collisions.lst").map { $0.lowercased() }

// Intended-word sources for measurement: top-N, neutral context.
let measureN = 2000

// MARK: - Typo classes

enum TypoClass: String, CaseIterable {
  case vowel = "A vowel"
  case vowelOpt = "A2 vowel-opt"
  case doubled = "B doubled"
  case swap = "C swap"
  case missing = "D missing"
}

func vowelTargets(_ c: Character, _ layout: Layout, optional: Bool) -> [Character] {
  if layout == .russian {
    if optional {
      switch c {
      case "е": return ["я"]
      case "я": return ["е"]
      case "и": return ["ы"]
      case "ы": return ["и"]
      default: return []
      }
    }
    switch c {
    case "о": return ["а"]
    case "а": return ["о"]
    case "е": return ["и"]
    case "и": return ["е"]
    default: return []
    }
  }
  if optional { return [] }
  switch c {
  case "a": return ["e"]
  case "e": return ["a", "i"]
  case "i": return ["e"]
  case "o": return ["u"]
  case "u": return ["o"]
  default: return []
  }
}

// Forward typos of intended word `w` (in `layout`'s alphabet) for class `cls`.
func forwardTypos(_ w: String, _ cls: TypoClass, _ layout: Layout) -> [String] {
  let chars = Array(w)
  var out = Set<String>()
  switch cls {
  case .vowel, .vowelOpt:
    for i in chars.indices {
      for t in vowelTargets(chars[i], layout, optional: cls == .vowelOpt) {
        var c = chars
        c[i] = t
        out.insert(String(c))
      }
    }
  case .doubled:
    for i in chars.indices {
      var c = chars
      c.insert(chars[i], at: i)
      out.insert(String(c))
    }
  case .swap:
    for i in 0..<max(0, chars.count - 1) where chars[i] != chars[i + 1] {
      var c = chars
      c.swapAt(i, i + 1)
      out.insert(String(c))
    }
  case .missing:
    for i in chars.indices {
      var c = chars
      c.remove(at: i)
      out.insert(String(c))
    }
  }
  out.remove(w)
  return out.sorted()
}

// Intended words that the typo `t` could be a single class-edit of (what a guarded tier would look up).
func intendedCandidates(_ t: String, _ cls: TypoClass, _ layout: Layout) -> [String] {
  switch cls {
  case .vowel, .vowelOpt, .swap:
    return forwardTypos(t, cls, layout)
  case .doubled:
    let chars = Array(t)
    var out = Set<String>()
    for i in 0..<max(0, chars.count - 1) where chars[i] == chars[i + 1] {
      var c = chars
      c.remove(at: i)
      out.insert(String(c))
    }
    return out.sorted()
  case .missing:
    return []
  }
}

// MARK: - Engine and dictionary helpers

func dictHas(_ w: String, _ layout: Layout) -> Bool {
  LayoutDictionary.shared.contains(w, in: layout)
}

func engineSwitches(typed: String, currentLayout: Layout) -> Bool {
  AutoSwitchEngine.matchTier(word: typed, currentLayout: currentLayout) != nil
}

// Typing the typo T of an intended word in `intended` yields this typed string on the other layout.
func typedFor(typo t: String, intended: Layout) -> String {
  AutoSwitchEngine.convert(t, to: intended.other)
}

// MARK: - Guards (simulated; not in the engine)

struct Guard {
  let minLength: Int
  let maxRank: Int
  var label: String { "len>=\(minLength) rank<=\(maxRank)" }

  // `target` is the intended word in `intended`'s language.
  func passes(target: String, intended: Layout, typoLength: Int) -> Bool {
    guard typoLength >= minLength else { return false }
    let rank = intended == .russian ? ruRank[target] : enRank[target]
    guard let r = rank else { return false }
    return r <= maxRank
  }
}

// Class-typo explanation for a string typed on `typedOn`: the intended word in the other layout's
// dictionary that the converted string is one class-edit away from. Only consulted when the
// engine would not already switch via the exact tier.
func classTarget(typedOn layout: Layout, typed s: String, _ cls: TypoClass) -> (target: String, typoLength: Int)? {
  let c = AutoSwitchEngine.convert(s, to: layout.other)
  for v in intendedCandidates(c, cls, layout.other) where dictHas(v, layout.other) {
    return (v, c.count)
  }
  return nil
}

// MARK: - Measurement

struct Tally {
  var total = 0
  var switched = 0
  var pct: Double { total == 0 ? 0 : 100.0 * Double(switched) / Double(total) }
  var text: String { "\(switched)/\(total) (\(String(format: "%.1f", pct))%)" }
}

// Intended words in `intended` layout; typos of each, typed on the other layout.
// Per-tier attribution for the real engine. `typo` is the typo tier alone (the class-agnostic
// one-insertion rule); `languageModel` is the n-gram tier that fires when the typo tier does not.
struct TierTally {
  var total = 0
  var exact = 0
  var typo = 0
  var languageModel = 0
  var switched: Int { exact + typo + languageModel }
}

func measureTiers(words: [String], intended: Layout, _ cls: TypoClass, minLength: Int) -> TierTally {
  var t = TierTally()
  for v in words where v.count >= minLength {
    for typo in forwardTypos(v, cls, intended) {
      t.total += 1
      let typed = typedFor(typo: typo, intended: intended)
      switch AutoSwitchEngine.matchTier(word: typed, currentLayout: intended.other) {
      case .exact?: t.exact += 1
      case .typo?: t.typo += 1
      case .languageModel?: t.languageModel += 1
      case nil: break
      }
    }
  }
  return t
}

// Ignores the engine's own tiers: the raw rule "a class-edit of the converted string lands in the dictionary".
func measureRecall(words: [String], intended: Layout, _ cls: TypoClass, guardRule: Guard?) -> Tally {
  var tally = Tally()
  for v in words {
    for t in forwardTypos(v, cls, intended) {
      tally.total += 1
      let typed = typedFor(typo: t, intended: intended)
      if engineSwitches(typed: typed, currentLayout: intended.other) {
        tally.switched += 1
        continue
      }
      if let g = guardRule {
        if let hit = classTarget(typedOn: intended.other, typed: typed, cls),
           g.passes(target: hit.target, intended: intended, typoLength: hit.typoLength) {
          tally.switched += 1
        }
      } else if classTarget(typedOn: intended.other, typed: typed, cls) != nil {
        tally.switched += 1
      }
    }
  }
  return tally
}

// Raw FP: a correctly typed string S (not in its own layout's dictionary, so the typo tier is reachable)
// whose conversion is not already an exact hit, but would switch if the class were accepted.
struct FPHit {
  let typed: String
  let target: String
}

// A string already a word in its own layout is protected by the exact-keep tier, so it is not an FP candidate.
// A conversion that is already an exact word in the other layout switches today, so it is not new FP either.
func falsePositives(typedWords: [String], typedOn layout: Layout, _ cls: TypoClass, guardRule: Guard?) -> (raw: [FPHit], guarded: [FPHit]) {
  var raw: [FPHit] = []
  var guarded: [FPHit] = []
  for s in typedWords {
    if dictHas(s, layout) { continue }
    let c = AutoSwitchEngine.convert(s, to: layout.other)
    if dictHas(c, layout.other) { continue }
    guard let hit = classTarget(typedOn: layout, typed: s, cls) else { continue }
    raw.append(FPHit(typed: s, target: hit.target))
    if let g = guardRule, g.passes(target: hit.target, intended: layout.other, typoLength: c.count) {
      guarded.append(FPHit(typed: s, target: hit.target))
    }
  }
  return (raw, guarded)
}

// MARK: - Report

let measureSets: [(name: String, intended: Layout, words: [String])] = [
  ("RU words typed on EN", .russian, Array(ruFreq.prefix(measureN))),
  ("EN words typed on RU", .english, Array(enFreq.prefix(measureN))),
]

print("=== MEASURE: switch rate today (neutral context), top \(measureN) words")
for set in measureSets {
  for minLen in [4, 5] {
    print("-- \(set.name), length >= \(minLen)")
    for cls in TypoClass.allCases {
      let t = measureTiers(words: set.words, intended: set.intended, cls, minLength: minLen)
      let pct = t.total == 0 ? "n/a" : String(format: "%.1f%%", 100.0 * Double(t.switched) / Double(t.total))
      let typoPct = t.total == 0 ? "n/a" : String(format: "%.1f%%", 100.0 * Double(t.typo) / Double(t.total))
      print("   \(cls.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) switched \(t.switched)/\(t.total) (\(pct))"
        + "  exact=\(t.exact) typoTier=\(t.typo) (\(typoPct)) lm=\(t.languageModel)")
    }
  }
}

print("=== FALSE-POSITIVE POPULATIONS (typed correctly; raw = class accepted, S not in own dict)")
let populations: [(name: String, typedOn: Layout, words: [String])] = [
  ("RU top-20k typed on RU", .russian, ruFreq),
  ("EN top-20k typed on EN", .english, enFreq),
  ("proper-nouns typed on EN", .english, properNouns),
  ("en-collisions typed on EN", .english, enCollisions),
]
for cls in TypoClass.allCases where cls != .missing {
  print("-- \(cls.rawValue)")
  for pop in populations {
    let r = falsePositives(typedWords: pop.words, typedOn: pop.typedOn, cls, guardRule: nil)
    print("   \(pop.name): raw=\(r.raw.count)")
    for h in r.raw.prefix(8) {
      print("      \(h.typed) -> \(AutoSwitchEngine.convert(h.typed, to: pop.typedOn.other)) ~ \(h.target)")
    }
  }
}

print("=== GUARD SIMULATION (FP raw -> guarded; recall on top-\(measureN), len>=4)")
let guards: [Guard] = [
  Guard(minLength: 4, maxRank: 2000), Guard(minLength: 5, maxRank: 2000),
  Guard(minLength: 4, maxRank: 5000), Guard(minLength: 5, maxRank: 5000),
  Guard(minLength: 5, maxRank: 20000),
]
for cls in TypoClass.allCases where cls != .missing {
  print("-- \(cls.rawValue)")
  for g in guards {
    var fpLine = ""
    for pop in populations {
      let r = falsePositives(typedWords: pop.words, typedOn: pop.typedOn, cls, guardRule: g)
      fpLine += " \(pop.name.prefix(12))=\(r.raw.count)->\(r.guarded.count)"
    }
    var recLine = ""
    for set in measureSets {
      let rec = measureRecall(words: set.words.filter { $0.count >= 4 }, intended: set.intended, cls, guardRule: g)
      recLine += " \(set.name.prefix(8))=\(rec.text)"
    }
    print("   \(g.label):\(fpLine) | recall:\(recLine)")
  }
}

// MARK: - Checks

var failCount = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
  if ok { return }
  failCount += 1
  if failCount <= 60 { print("  FAIL [\(label)] \(detail())") }
}

func switchesCorrectly(typed: String, layout: Layout, expected: String) -> Bool {
  AutoSwitchEngine.evaluate(word: typed, currentLayout: layout) == .switchLayout
    && AutoSwitchEngine.convert(typed, to: layout.other) == expected
}

print("=== CHECKS")

// Intended word typed with class typo `typo` on the wrong layout. Positives assert the full engine switches
// and the output is the plain converted typo (no spelling fix).
struct Fixture {
  let intended: String
  let typo: String
  let cls: TypoClass
}

func checkFixture(_ f: Fixture, _ layout: Layout) {
  check("fixture \(f.cls.rawValue) \(f.intended)->\(f.typo)",
    dictHas(f.intended, layout) && !dictHas(f.typo, layout) && forwardTypos(f.intended, f.cls, layout).contains(f.typo),
    "intended/typo fixture invalid for \(layout)")
}

func checkPositives(_ fixtures: [Fixture], _ layout: Layout) {
  for f in fixtures {
    checkFixture(f, layout)
    let typed = typedFor(typo: f.typo, intended: layout)
    let ok = switchesCorrectly(typed: typed, layout: layout.other, expected: f.typo)
    check("\(f.cls.rawValue) switches \(f.typo)", ok, "typed=\(typed) intended=\(f.intended)")
  }
}

func checkKeep(_ word: String, _ layout: Layout, _ label: String) {
  let r = AutoSwitchEngine.evaluate(word: word, currentLayout: layout)
  check("keep \(label)", r == .keep, "\(word) on \(layout) -> \(r)")
}

func titleCased(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

let ruFixtures: [Fixture] = [
  Fixture(intended: "работа", typo: "работо", cls: .vowel),
  Fixture(intended: "никогда", typo: "никагда", cls: .vowel),
  Fixture(intended: "сегодня", typo: "сигодня", cls: .vowel),
  Fixture(intended: "человек", typo: "челавек", cls: .vowel),
  Fixture(intended: "вечером", typo: "вичером", cls: .vowel),
  Fixture(intended: "вопрос", typo: "вапрос", cls: .vowel),
  Fixture(intended: "программа", typo: "праграмма", cls: .vowel),
  Fixture(intended: "дорога", typo: "дарога", cls: .vowel),
  Fixture(intended: "неделя", typo: "ниделя", cls: .vowel),
  Fixture(intended: "деньги", typo: "диньги", cls: .vowel),
  Fixture(intended: "город", typo: "гарод", cls: .vowel),
  Fixture(intended: "голова", typo: "галова", cls: .vowel),
  Fixture(intended: "привет", typo: "прривет", cls: .doubled),
  Fixture(intended: "подряд", typo: "поддряд", cls: .doubled),
  Fixture(intended: "спасибо", typo: "сппасибо", cls: .doubled),
  Fixture(intended: "работа", typo: "рработа", cls: .doubled),
  Fixture(intended: "проверка", typo: "проверрка", cls: .doubled),
  Fixture(intended: "конечно", typo: "конечнно", cls: .doubled),
  Fixture(intended: "сегодня", typo: "сеггодня", cls: .doubled),
  Fixture(intended: "немного", typo: "немноого", cls: .doubled),
  Fixture(intended: "вместе", typo: "вместее", cls: .doubled),
  Fixture(intended: "работа", typo: "раобта", cls: .swap),
  Fixture(intended: "привет", typo: "приевт", cls: .swap),
  Fixture(intended: "подряд", typo: "пдоряд", cls: .swap),
  Fixture(intended: "сегодня", typo: "сеогдня", cls: .swap),
  Fixture(intended: "вопрос", typo: "ворпос", cls: .swap),
  Fixture(intended: "вместе", typo: "мвесте", cls: .swap),
  Fixture(intended: "конечно", typo: "коненчо", cls: .swap),
  Fixture(intended: "человек", typo: "ечловек", cls: .swap),
  Fixture(intended: "проблема", typo: "пролбема", cls: .swap),
  Fixture(intended: "общество", typo: "бощество", cls: .swap),
  Fixture(intended: "перемешаны", typo: "пермешаны", cls: .missing),
  Fixture(intended: "привет", typo: "првет", cls: .missing),
  Fixture(intended: "работа", typo: "рабта", cls: .missing),
  Fixture(intended: "вопрос", typo: "вопрс", cls: .missing),
]

let enFixtures: [Fixture] = [
  Fixture(intended: "world", typo: "wurld", cls: .vowel),
  Fixture(intended: "house", typo: "huuse", cls: .vowel),
  Fixture(intended: "music", typo: "musec", cls: .vowel),
  Fixture(intended: "information", typo: "informetion", cls: .vowel),
  Fixture(intended: "problem", typo: "problam", cls: .vowel),
  Fixture(intended: "letter", typo: "lettar", cls: .vowel),
  Fixture(intended: "minute", typo: "menute", cls: .vowel),
  Fixture(intended: "orange", typo: "orenge", cls: .vowel),
  Fixture(intended: "level", typo: "livel", cls: .vowel),
  Fixture(intended: "ground", typo: "gruund", cls: .vowel),
  Fixture(intended: "interest", typo: "intirest", cls: .vowel),
  Fixture(intended: "message", typo: "messsage", cls: .doubled),
  Fixture(intended: "because", typo: "becausse", cls: .doubled),
  Fixture(intended: "really", typo: "reallly", cls: .doubled),
  Fixture(intended: "address", typo: "adddress", cls: .doubled),
  Fixture(intended: "quickly", typo: "quiickly", cls: .doubled),
  Fixture(intended: "people", typo: "peopple", cls: .doubled),
  Fixture(intended: "little", typo: "littlle", cls: .doubled),
  Fixture(intended: "still", typo: "stilll", cls: .doubled),
  Fixture(intended: "though", typo: "thoough", cls: .doubled),
  Fixture(intended: "receive", typo: "recieve", cls: .swap),
  Fixture(intended: "their", typo: "thier", cls: .swap),
  Fixture(intended: "because", typo: "becuase", cls: .swap),
  Fixture(intended: "beautiful", typo: "beuatiful", cls: .swap),
  Fixture(intended: "people", typo: "poeple", cls: .swap),
  Fixture(intended: "friend", typo: "freind", cls: .swap),
  Fixture(intended: "which", typo: "whihc", cls: .swap),
  Fixture(intended: "through", typo: "throguh", cls: .swap),
  Fixture(intended: "believe", typo: "beleive", cls: .swap),
  Fixture(intended: "should", typo: "shoudl", cls: .swap),
  Fixture(intended: "message", typo: "messge", cls: .missing),
  Fixture(intended: "letter", typo: "lettr", cls: .missing),
  Fixture(intended: "information", typo: "infomation", cls: .missing),
]

// FP examples from the population analysis: typed correctly on their own layout, must stay keep.
let ruFPNegatives = ["лу", "гу", "аш", "уф", "ду", "ун", "лулу", "вау", "кен", "ши"]
let enFPNegatives = ["t", "s", "th", "ve", "pj", "tb", "tvs", "suh", "sp", "nbc", "lsn", "jj", "dd", "cc", "bb", "ee", "cctv", "reece"]
let ruRealWords = ["вода", "дом", "что", "это", "как", "привет", "подряд", "работа", "сегодня"]
let enRealWords = ["the", "and", "world", "letter", "people", "because", "receive", "house", "music"]

checkPositives(ruFixtures, .russian)
checkPositives(enFixtures, .english)

// Title-case typos keep the existing contract (typo/n-gram tiers disabled for Title case).
// Shift is held for the first key, so Title-case the typo before converting to keys.
for f in ruFixtures {
  checkKeep(typedFor(typo: titleCased(f.typo), intended: .russian), .english, "Title \(f.typo)")
}
for f in enFixtures {
  checkKeep(typedFor(typo: titleCased(f.typo), intended: .english), .russian, "Title \(f.typo)")
}

for s in ruFPNegatives { checkKeep(s, .russian, "RU FP \(s)") }
for s in enFPNegatives { checkKeep(s, .english, "EN FP \(s)") }
for s in ruRealWords { checkKeep(s, .russian, "RU real \(s)") }
for s in enRealWords { checkKeep(s, .english, "EN real \(s)") }

// Existing missing-letter baseline (user's ghdtn -> првет).
check("baseline missing ghdtn", switchesCorrectly(typed: "ghdtn", layout: .english, expected: "првет"), "ghdtn")

if failCount == 0 { print("ALL TYPO CHECKS PASS") } else {
  print("TYPO CHECKS FAILED: \(failCount)")
  exit(1)
}
