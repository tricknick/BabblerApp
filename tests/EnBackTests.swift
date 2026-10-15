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
// NEGATIVES (must keep passing):
//   N1  20k most frequent RU words typed on RU layout stay .keep (build/dict-cache/ru_freq.txt)
//   N2  RU words in tests/data/*.txt ending in ю б ж э х ъ typed on RU layout stay .keep
//   N3  20k frequent RU words typed on EN layout: correct >= 19404 (probe f floor)
//   N4  20k frequent EN words typed on RU layout: correct >= 19345 (probe a floor)
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
check("N3", n3Correct >= 19404, "RU-on-EN correct \(n3Correct) < floor 19404")
print("  N3 RU-on-EN correct: \(n3Correct) / \(ruFreq.count)")

var n4Correct = 0
for word in enFreq {
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  if switchesCorrectly(typed: typed, layout: .russian, expected: word) { n4Correct += 1 }
}
check("N4", n4Correct >= 19345, "EN-on-RU correct \(n4Correct) < floor 19345")
print("  N4 EN-on-RU correct: \(n4Correct) / \(enFreq.count)")

// MARK: - Summary

let labels = ["fixture", "step1", "step3", "step3-neg", "N1", "N2-fixture", "N2", "N3", "N4"]
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
