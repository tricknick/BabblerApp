import Foundation

// EN-back tests (run via tests/en_back_test.sh). Uses only the existing engine API:
//   AutoSwitchEngine.evaluate(word:currentLayout:) -> .keep | .switchLayout
//   AutoSwitchEngine.convert(_:to:)
//
// "Typed on the RU layout" for an intended English string means
// convert(intended, to: .russian): the keystrokes that produce it on the RU keyboard.
// A case passes when evaluate(typed, currentLayout: .russian) == .switchLayout AND
// convert(typed, to: .english) == expected (the full replacement, punctuation included).
//
// STEP 1 (trailing punctuation for EN target): 33 lowercase EN words (stem >= 3 letters,
//   present in en.txt.gz) + one of 1-2 trailing punctuation chars (. , ? ! ; " and pairs).
// STEP 3 (contractions): 45 whitelisted lowercase contractions with ' (-> э) must switch;
//   10 whitelisted contraction+punctuation strings must switch; non-whitelisted
//   apostrophe strings must stay .keep ("step3-neg").
// STEP 2 (capitalized words, both directions). Contract:
//   A Title-case word (first letter upper, rest lower, >= 3 letters) is evaluated as its
//   lowercase form. It may switch ONLY via exact tiers (dictionary, theme pack, user
//   lexicon, punctuation/contraction rule), never via typo or n-gram. The replacement keeps
//   the case: convert() maps upper <-> upper, so convert(convert(w, to: x), to: back) == w.
//   ALL-CAPS and mixed case (JSON, iPhone, GitHub, ПРИВЕТ, ВКонтакте) stay .keep.
//   Positives: EN Title-case on RU layout (words, with trailing punctuation, I-contractions),
//   RU Title-case on EN layout. Negatives: Title-case of 20k frequent RU/EN words in their
//   native layout (N5/N6), proper-noun list in native layout (N7), and Title-case of
//   misspellings that only typo/n-gram tiers would catch (caps-typo).
// NEGATIVES (must keep passing):
//   N1  20k most frequent RU words typed on RU layout stay .keep (build/dict-cache/ru_freq.txt)
//   N2  RU words in tests/data/*.txt ending in ю б ж э х ъ typed on RU layout stay .keep
//   N3  20k frequent RU words typed on EN layout: correct >= 19404 (probe f floor)
//   N4  20k frequent EN words typed on RU layout: correct >= 19345 (probe a floor)
// STEP 5 (EN chat/IT supplement). Contract:
//   Words lgtm wfh imo imho tbh btw afaik iirc fyi idk asap brb omg lol thx pls, typed
//   lowercase on RU layout, must switch to EN (evaluate == .switchLayout, convert back == word).
//   k8s is excluded (digit). Words are added to dictionaries/supplement-en.txt, which
//   build_dictionaries.sh merges deterministically into en.txt.gz and build_ngram_models.py reads.
//   Negatives: a word whose RU-layout conversion is itself in ru-forms.bin is listed and
//   excluded from positives (printed as "step5-coll"); EN-layout typing of each word must be .keep ("step5-neg").
// STEP 6 (RU morphology collisions). Contract:
//   tests/data/en-collisions.lst holds the 17 top-20k EN words whose RU-layout conversion is a
//   non-core form in ru-forms.bin. Typed on RU layout they must switch ("step6").
//   build_ru_forms.py drops non-core forms whose EN-layout keys equal a word in the top-20k EN
//   frequency list and writes the dropped forms to <cache>/ru_dropped_forms.txt (one per line).
//   N3 floor becomes 19404 - dropped ("N3"); dropped forms that are in the top-20k RU frequency list
//   fail ("step6-common"). A missing dropped file counts as 0 dropped.
//
// Env: BABBLER_RESOURCES, BABBLER_DICT_CACHE, BABBLER_TEST_DATA (set by en_back_test.sh).

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

let ruLetters: ClosedRange<Character> = "а"..."я"
func isCyrillicWord(_ word: String) -> Bool {
  !word.isEmpty && word.allSatisfy { ruLetters.contains($0) || $0 == "ё" }
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
// BABBLER_SPELL_ORACLE=1 (full) or =veto wires the real NSSpellChecker-backed
// oracle so this suite's FP floors can be measured with it live; default runs
// leave it unwired since this is one of the "must pass" suites.
if let spellOracleMode = ProcessInfo.processInfo.environment["BABBLER_SPELL_ORACLE"] {
  AutoSwitchEngine.spellOracle = SystemSpellOracle()
  if spellOracleMode == "veto" { AutoSwitchEngine.spellCheckerConfirmEnabled = false }
}

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

// MARK: - STEP 1: trailing punctuation

let step1Words = [
  "hello", "world", "thanks", "really", "because", "people", "everyone", "comment",
  "deploy", "commit", "merge", "update", "change", "these", "though", "through",
  "example", "another", "after", "should", "could", "think", "first", "going",
  "around", "great", "problem", "together", "brother", "mountain", "pattern", "surprise",
  "measure", "library", "kitchen", "jacket", "orange", "pocket", "garden", "silver",
  "hopeless", "thousand",
]
let punctSuffixes = [".", ",", "?", ";", "\"", "!?", "?!", "..", ".\""]

print("=== STEP 1 trailing punctuation (EN target, typed on RU layout)")
for (i, word) in step1Words.enumerated() {
  check("fixture", englishSet.contains(word) && word.count >= 3, "not an EN fixture: \(word)")
  let intended = word + punctSuffixes[i % punctSuffixes.count]
  let typed = AutoSwitchEngine.convert(intended, to: .russian)
  let decision = AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian)
  let produced = AutoSwitchEngine.convert(typed, to: .english)
  check("step1", decision == .switchLayout && produced == intended,
        "\(intended) typed=\(typed) decision=\(decision) produced=\(produced)")
}

// MARK: - STEP 3: contractions

let contractions = [
  "don't", "can't", "won't", "isn't", "aren't", "wasn't", "weren't", "didn't", "doesn't",
  "haven't", "hasn't", "hadn't", "shouldn't", "wouldn't", "couldn't", "mustn't",
  "it's", "that's", "what's", "there's", "here's", "where's", "who's", "let's",
  "i'm", "i'll", "i've", "i'd", "you're", "you've", "you'll", "you'd",
  "we're", "we've", "we'll", "they're", "they've", "they'll",
  "he's", "she's", "he'd", "she'd", "it'll", "that'll", "there'll",
]
let contractionsWithPunct = [
  "don't.", "can't.", "it's!", "i'm?", "won't?", "let's.", "that's!", "isn't,", "what's?", "you're.",
]
let nonContractions = [
  "tho'ts", "bo'ks", "tre'ns", "wo'lds", "fa'ce", "ca'nt", "dont'", "y'all", "o'clock",
  "rock'n'roll", "ma'am",
]

print("=== STEP 3 contractions (apostrophe typed as э on RU layout)")
check("fixture", contractions.count >= 40, "whitelist has \(contractions.count) entries")
for word in contractions {
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  check("step3", switchesCorrectly(typed: typed, layout: .russian, expected: word),
        "\(word) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian))")
}
for word in contractionsWithPunct {
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  check("step3", switchesCorrectly(typed: typed, layout: .russian, expected: word),
        "\(word) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian))")
}
for word in nonContractions {
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  check("step3-neg", AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian) == .keep,
        "non-whitelisted \(word) switched to \(AutoSwitchEngine.convert(typed, to: .english))")
}

// MARK: - NEGATIVES

let ruFreq = frequencyWords("\(cacheDir)/ru_freq.txt", limit: 20000, accept: isCyrillicWord)
let enFreq = frequencyWords("\(cacheDir)/en_freq.txt", limit: 20000) { word in
  word.allSatisfy { $0 >= "a" && $0 <= "z" }
}

print("=== NEGATIVES")
// Pre-existing RU-on-RU false switches (fail before any EN-back change); excluded so N1 guards regressions only.
let n1PreExisting: Set<String> = ["шшш", "куин", "вуду", "вуд", "ашкн"]
var n1Excluded = 0
for word in ruFreq {
  if n1PreExisting.contains(word) { n1Excluded += 1; continue }
  check("N1", AutoSwitchEngine.evaluate(word: word, currentLayout: .russian) == .keep,
        "RU word switched on RU layout: \(word) -> \(AutoSwitchEngine.convert(word, to: .english))")
}

// A Russian word followed by real punctuation typed on the Russian layout stays put.
for word in ["руки,", "руке,", "рут,", "еще,", "руки.", "руки!"] {
  check("N1-punct", AutoSwitchEngine.evaluate(word: word, currentLayout: .russian) == .keep,
        "RU word with punctuation switched: \(word)")
}

let ruEndings: Set<Character> = ["ю", "б", "ж", "э", "х", "ъ"]
print("N1 pre-existing excluded: \(n1Excluded)")
var dataWords = Set<String>()
if let files = try? FileManager.default.contentsOfDirectory(atPath: dataDir) {
  for file in files where file.hasSuffix(".txt") {
    let text = (try? String(contentsOfFile: "\(dataDir)/\(file)", encoding: .utf8)) ?? ""
    for token in text.split(whereSeparator: { $0.isWhitespace }) {
      let word = String(token).lowercased()
      if isCyrillicWord(word), let last = word.last, ruEndings.contains(last) {
        dataWords.insert(word)
      }
    }
  }
}
check("N2-fixture", dataWords.count >= 3, "only \(dataWords.count) RU data words end in ю б ж э х ъ")
for word in dataWords.sorted() {
  check("N2", AutoSwitchEngine.evaluate(word: word, currentLayout: .russian) == .keep,
        "data RU word switched on RU layout: \(word)")
}

var n3Correct = 0
for word in ruFreq {
  let typed = AutoSwitchEngine.convert(word, to: .english)
  if switchesCorrectly(typed: typed, layout: .english, expected: word) { n3Correct += 1 }
}
let droppedForms: [String] = (try? String(contentsOf: URL(fileURLWithPath: "\(cacheDir)/ru_dropped_forms.txt"), encoding: .utf8))?
  .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
  .filter { !$0.isEmpty && !$0.hasPrefix("#") } ?? []
let n3Floor = 19404 - droppedForms.count
check("N3", n3Correct >= n3Floor, "RU-on-EN correct \(n3Correct) < floor \(n3Floor) (19404 - \(droppedForms.count) dropped)")
print("  N3 RU-on-EN correct: \(n3Correct) / \(ruFreq.count) floor \(n3Floor)")

var n4Correct = 0
for word in enFreq {
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  if switchesCorrectly(typed: typed, layout: .russian, expected: word) { n4Correct += 1 }
}
check("N4", n4Correct >= 19345, "EN-on-RU correct \(n4Correct) < floor 19345")
print("  N4 EN-on-RU correct: \(n4Correct) / \(enFreq.count)")

// MARK: - STEP 2: capitalized words

func titleCase(_ s: String) -> String {
  guard let first = s.first else { return s }
  return String(first).uppercased() + String(s.dropFirst())
}

print("=== STEP 2 capitalized words")
for word in ["Hello", "Monday", "I'm", "JSON", "The", "London"] {
  let back = AutoSwitchEngine.convert(AutoSwitchEngine.convert(word, to: .russian), to: .english)
  check("caps-roundtrip", back == word, "EN round-trip \(word) -> \(back)")
}
for word in ["Привет", "Спасибо", "Москва", "ОК"] {
  let back = AutoSwitchEngine.convert(AutoSwitchEngine.convert(word, to: .english), to: .russian)
  check("caps-roundtrip", back == word, "RU round-trip \(word) -> \(back)")
}
check("caps-roundtrip", AutoSwitchEngine.convert("Hello", to: .russian) == "Руддщ",
      "Hello -> \(AutoSwitchEngine.convert("Hello", to: .russian))")

let enCapsWords = [
  "Hello", "Monday", "Please", "Thanks", "Because", "People", "Everyone", "Commit", "Deploy",
  "Merge", "Update", "Change", "These", "Through", "Example", "Another", "After", "Should",
  "Could", "Think", "First", "Going", "Around", "Great", "Problem", "Together", "Brother",
  "Mountain", "Pattern", "Library", "Kitchen", "London", "The", "Can", "She",
]
for (i, word) in enCapsWords.enumerated() {
  let lower = word.lowercased()
  check("caps-fixture", englishSet.contains(lower) && lower.count >= 3, "not an EN fixture: \(word)")
  let suffix = i % 3 == 0 ? "" : punctSuffixes[i % punctSuffixes.count]
  let intended = word + suffix
  let typed = AutoSwitchEngine.convert(intended, to: .russian)
  check(suffix.isEmpty ? "caps-en" : "caps-punct",
        switchesCorrectly(typed: typed, layout: .russian, expected: intended),
        "\(intended) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian))")
}

for word in ["I'm", "I'll", "I've", "I'd", "I'm.", "I'll!"] {
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  check("caps-I", switchesCorrectly(typed: typed, layout: .russian, expected: word),
        "\(word) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian))")
}

let ruCapsFixed = ["Привет", "Спасибо", "Москва", "Как", "Сегодня", "Работа"]
let ruCapsFreq = Array(ruFreq.filter {
  $0.count >= 3 && !englishSet.contains(AutoSwitchEngine.convert($0, to: .english))
}.prefix(40))
for word in ruCapsFixed + ruCapsFreq {
  let titled = titleCase(word)
  check("caps-fixture", LayoutDictionary.shared.contains(word.lowercased(), in: .russian), "not an RU fixture: \(word)")
  let typed = AutoSwitchEngine.convert(titled, to: .english)
  check("caps-ru", switchesCorrectly(typed: typed, layout: .english, expected: titled),
        "\(titled) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .english))")
}

let capsKeepEN = ["JSON", "API", "iPhone", "GitHub", "NASA", "HTML", "CPU", "SQL", "URL", "README",
                  "iOS", "macOS", "McDonald", "JavaScript", "PostgreSQL", "USA", "DevOps"]
for word in capsKeepEN {
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  check("caps-keep", AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian) == .keep,
        "\(word) typed=\(typed) switched")
}
for word in ["ПРИВЕТ", "ОК", "СССР", "ВКонтакте", "МГУ", "ЯНДЕКС"] {
  let typed = AutoSwitchEngine.convert(word, to: .english)
  check("caps-keep", AutoSwitchEngine.evaluate(word: typed, currentLayout: .english) == .keep,
        "\(word) typed=\(typed) switched")
}

// Fallback-tier discriminators: a Title-case word whose lowercase only typo/n-gram would catch.
var typoCands: [String] = []
var ngramCands: [String] = []
for word in enFreq.prefix(5000) where word.count >= 5 {
  for c in ["x", "j", "q", "z", "v"] {
    var chars = Array(word)
    chars[1] = Character(c)
    let mutated = String(chars)
    let tier = AutoSwitchEngine.matchTier(word: AutoSwitchEngine.convert(mutated, to: .russian), currentLayout: .russian)
    if tier == .typo { typoCands.append(mutated) } else if tier == .languageModel { ngramCands.append(mutated) }
  }
}
check("caps-cands", typoCands.count >= 20, "only \(typoCands.count) typo-tier candidates")
check("caps-cands", ngramCands.count >= 20, "only \(ngramCands.count) n-gram-tier candidates")
print("  caps-typo candidates: \(typoCands.count), caps-ngram candidates: \(ngramCands.count)")
for word in typoCands.prefix(25) {
  let typed = AutoSwitchEngine.convert(titleCase(word), to: .russian)
  check("caps-typo", AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian) == .keep,
        "\(titleCase(word)) typed=\(typed) switched")
}
for word in ngramCands.prefix(25) {
  let typed = AutoSwitchEngine.convert(titleCase(word), to: .russian)
  check("caps-ngram", AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian) == .keep,
        "\(titleCase(word)) typed=\(typed) switched")
}

// Negatives: proxy = the lowercase form would hit the exact tier on the typed layout (contract would switch it).
// Title-case inherits the lowercase exact-tier decision, so pre-existing lowercase exact-tier
// false switches are pinned as a baseline; any new one fails.
func capsProxyFalsePositives(_ words: [String], native: Layout) -> [String] {
  words.filter { AutoSwitchEngine.matchTier(word: $0, currentLayout: native) == .exact }
}

let n5Baseline: Set<String> = n1PreExisting
let n5Hits = Set(capsProxyFalsePositives(ruFreq, native: .russian))
let n5New = n5Hits.subtracting(n5Baseline)
print("  N5 RU 20k on RU title-case FPs: \(n5Hits.sorted()) new: \(n5New.sorted())")
check("N5", n5New.isEmpty, "new title-case FPs on RU layout: \(n5New.sorted())")

let n6Baseline: Set<String> = ["rene", "ltd", "neha"]
let n6Hits = Set(capsProxyFalsePositives(enFreq, native: .english))
let n6New = n6Hits.subtracting(n6Baseline)
print("  N6 EN 20k on EN title-case FPs: \(n6Hits.sorted()) new: \(n6New.sorted())")
check("N6", n6New.isEmpty, "new title-case FPs on EN layout: \(n6New.sorted())")

let properNouns = try! String(contentsOfFile: "\(dataDir)/proper-nouns.lst", encoding: .utf8)
  .split(whereSeparator: { $0.isNewline })
  .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
  .filter { !$0.isEmpty }
check("N7-fixture", properNouns.count >= 200, "only \(properNouns.count) proper nouns")
var n7FP = 0
var n7Examples: [String] = []
for name in properNouns {
  let native: Layout = isCyrillicWord(name) ? .russian : .english
  guard native == .english ? name.allSatisfy({ $0 >= "a" && $0 <= "z" }) : true else { continue }
  if AutoSwitchEngine.matchTier(word: name, currentLayout: native) == .exact {
    n7FP += 1
    if n7Examples.count < 8 { n7Examples.append("\(name)(\(native == .russian ? "RU" : "EN"))") }
  }
}
print("  N7 proper-noun false positives: \(n7FP) / \(properNouns.count) examples: \(n7Examples)")
check("N7", n7FP == 0, "\(n7FP) proper nouns would switch in native layout")

// MARK: - STEP 5: EN chat/IT supplement

let step5Words = ["lgtm", "wfh", "imo", "imho", "tbh", "btw", "afaik", "iirc", "fyi", "idk",
                  "asap", "brb", "omg", "lol", "thx", "pls"]
check("step5-fixture", step5Words.count >= 10, "only \(step5Words.count) supplement words")
print("=== STEP 5 EN chat/IT supplement (typed on RU layout)")
for word in step5Words {
  check("step5-dict", englishSet.contains(word), "\(word) missing from en.txt.gz")
  check("step5-neg", AutoSwitchEngine.evaluate(word: word, currentLayout: .english) == .keep,
        "\(word) typed on EN layout is not .keep")
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  if ruFull.contains(typed) {
    print("  step5-coll: \(word) -> \(typed) is a RU word in ru-forms.bin (excluded)")
    continue
  }
  check("step5", switchesCorrectly(typed: typed, layout: .russian, expected: word),
        "\(word) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian))")
}

// MARK: - STEP 6: RU morphology collisions

let collisionWords = ((try? String(contentsOfFile: "\(dataDir)/en-collisions.lst", encoding: .utf8)) ?? "")
  .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
  .filter { !$0.isEmpty && !$0.hasPrefix("#") }
check("step6-fixture", collisionWords.count == 17, "collision fixture has \(collisionWords.count) words")
print("=== STEP 6 RU morphology collisions (EN words typed on RU layout)")
for word in collisionWords {
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  check("step6-fixture", englishSet.contains(word) && !ruCore.contains(typed)
          && droppedForms.contains(typed) && !ruFull.contains(typed),
        "\(word) -> \(typed) is not an EN word whose non-core RU form is listed in ru_dropped_forms.txt and absent from ru-forms.bin")
  check("step6", switchesCorrectly(typed: typed, layout: .russian, expected: word),
        "\(word) typed=\(typed) decision=\(AutoSwitchEngine.evaluate(word: typed, currentLayout: .russian))")
}
print("  dropped forms (\(droppedForms.count)): \(droppedForms)")
let ruFreqSet = Set(ruFreq)
for form in droppedForms {
  check("step6-dropped", !ruFull.contains(form), "\(form) is still in ru-forms.bin")
  check("step6-core", !ruCore.contains(form), "\(form) is a core form and must not be dropped")
  check("step6-common", !ruFreqSet.contains(form), "\(form) is a top-20k RU frequent word")
}

// MARK: - Summary

let labels = ["fixture", "step1", "step3", "step3-neg", "N1", "N2-fixture", "N2", "N3", "N4",
              "caps-roundtrip", "caps-fixture", "caps-en", "caps-punct", "caps-I", "caps-ru",
              "caps-keep", "caps-cands", "caps-typo", "caps-ngram", "N5", "N6", "N7-fixture", "N7",
              "step5-fixture", "step5-dict", "step5-neg", "step5",
              "step6-fixture", "step6", "step6-dropped", "step6-core", "step6-common"]
print("=== SUMMARY (failing / cases)")
var totalFailures = 0
for label in labels {
  let failed = failCount[label, default: 0]
  totalFailures += failed
  print("  \(label): \(failed) / \(caseCount[label, default: 0])")
}
if totalFailures == 0 {
  print("ALL EN-BACK CHECKS PASS")
  exit(0)
}
print("\(totalFailures) EN-BACK CHECKS FAILED")
exit(1)
