import Foundation

// EN-back measurement probe (run via tests/en_probe.sh). Prints counts; asserts nothing.
//
// Setup matches the shipped app: theme packs on, no user lexicon, nil sentence
// context. "Typed on the wrong layout" means convert(intended, to: otherLayout),
// i.e. the keystrokes that produce the intended word on the wrong keyboard.
//
// Frequency source: build/dict-cache/{en,ru}_freq.txt ("word count" per line,
// most frequent first, FrequencyWords 2018 as used by scripts/build_dictionaries.sh).

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

let englishSet = Set(loadWords("\(resources)/en.txt.gz"))
let ruFull = HashedWordSet(contentsOf: URL(fileURLWithPath: "\(resources)/ru-forms.bin"))!
let ruCore = HashedWordSet(contentsOf: URL(fileURLWithPath: "\(resources)/ru-typo.bin"))!
LayoutDictionary.shared.setForTests(englishSet, ruFull, typo: ruCore)
LayoutDictionary.shared.setNGramModels(
  english: NGramModel(contentsOf: URL(fileURLWithPath: "\(resources)/ngram-en.bin")),
  russian: NGramModel(contentsOf: URL(fileURLWithPath: "\(resources)/ngram-ru.bin")))
AutoSwitchEngine.themePacks = ThemePacks.load(
  ids: Set(ThemePacks.allIds), resourceDir: URL(fileURLWithPath: resources))

enum Outcome { case correct, wrong, kept }

// Typed = what the keyboard produces; intended = the word the user meant.
func outcome(typed: String, layout: Layout, intended: String) -> Outcome {
  guard AutoSwitchEngine.evaluate(word: typed, currentLayout: layout) == .switchLayout else {
    return .kept
  }
  return AutoSwitchEngine.convert(typed, to: layout.other) == intended ? .correct : .wrong
}

// Mirrors the engine's rejection order: non-letters, length, capitals, then the
// current-layout dictionary (collision), then the target dictionary.
func enCause(_ word: String, typed: String, coreSet: HashedWordSet) -> String {
  if word.contains("'") { return "apostrophe" }
  if word.contains(where: { !$0.isLetter }) { return "non-letter" }
  if word.count < 3 { return "short" }
  if word != word.lowercased() { return "capital" }
  if ruFull.contains(typed) { return coreSet.contains(typed) ? "collision-core" : "collision-morph" }
  if !englishSet.contains(word) { return "not-in-en" }
  return "other"
}

func ruCause(_ word: String, typed: String) -> String {
  if word.count < 3 { return "short" }
  if englishSet.contains(typed) { return "collision-en" }
  if !ruFull.contains(word) { return "not-in-ru" }
  return "other"
}

final class Tally {
  var counts: [String: Int] = [:]
  var examples: [String: [String]] = [:]
  func add(_ cause: String, _ word: String) {
    counts[cause, default: 0] += 1
    if examples[cause, default: []].count < 5 { examples[cause, default: []].append(word) }
  }
  func report() {
    for (cause, n) in counts.sorted(by: { $0.value > $1.value }) {
      print("    \(cause): \(n)  e.g. \(examples[cause, default: []].joined(separator: ", "))")
    }
  }
}

let ruLetters: ClosedRange<Character> = "а"..."я"
let enFreq = frequencyWords("\(cacheDir)/en_freq.txt", limit: 20000) { word in
  word.allSatisfy { $0 >= "a" && $0 <= "z" }
}
let ruFreq = frequencyWords("\(cacheDir)/ru_freq.txt", limit: 20000) { word in
  word.allSatisfy { ruLetters.contains($0) || $0 == "ё" }
}

// (a) EN words typed on RU layout, full morphology vs. core-only (ru-typo.bin).
print("(a) EN->RU: \(enFreq.count) most frequent EN words typed on RU layout")
let enTyped = enFreq.map { AutoSwitchEngine.convert($0, to: .russian) }
var fullEN: [Outcome] = []
for (i, word) in enFreq.enumerated() {
  fullEN.append(outcome(typed: enTyped[i], layout: .russian, intended: word))
}
LayoutDictionary.shared.setForTests(englishSet, ruCore, typo: ruCore)
var coreEN: [Outcome] = []
for (i, word) in enFreq.enumerated() {
  coreEN.append(outcome(typed: enTyped[i], layout: .russian, intended: word))
}
LayoutDictionary.shared.setForTests(englishSet, ruFull, typo: ruCore)

let enCauses = Tally()
var enCorrect = 0, enWrong = 0, lost = 0, gained = 0
for (i, word) in enFreq.enumerated() {
  switch fullEN[i] {
  case .correct: enCorrect += 1
  case .wrong: enWrong += 1
  case .kept: enCauses.add(enCause(word, typed: enTyped[i], coreSet: ruCore), word)
  }
  if case .correct = coreEN[i], case .correct = fullEN[i] {} else if case .correct = coreEN[i] { lost += 1 }
  if case .correct = fullEN[i], case .correct = coreEN[i] {} else if case .correct = fullEN[i] { gained += 1 }
}
print("    full: correct \(enCorrect) (\(enCorrect * 100 / enFreq.count)%)  wrong \(enWrong)  kept \(enFreq.count - enCorrect - enWrong)")
print("    core-only (ru-typo): correct \(coreEN.filter { if case .correct = $0 { return true }; return false }.count)  lost-to-morphology \(lost)  gained \(gained)")
enCauses.report()

// (b) Contractions on RU layout (apostrophe key = э).
print("(b) contractions typed on RU layout")
for word in ["don't", "I'm", "it's", "can't", "won't", "I'll", "you're", "that's", "didn't", "isn't", "we're", "they're", "let's"] {
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  let back = AutoSwitchEngine.convert(typed, to: .english)
  let raw = outcome(typed: typed, layout: .russian, intended: word)
  let lowerTyped = AutoSwitchEngine.convert(word.lowercased(), to: .russian)
  let lower = outcome(typed: lowerTyped, layout: .russian, intended: word.lowercased())
  print("    \(word)  typed=\(typed)  back=\(back)  raw=\(raw)  lower=\(lower)  cause=\(enCause(word, typed: typed, coreSet: ruCore))")
}

// (c) Capitalized / Shift words on RU layout.
print("(c) capitalized words typed on RU layout")
for word in ["Hello", "Monday", "London", "iPhone", "GitHub", "JSON", "API", "PR", "OK"] {
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  let raw = outcome(typed: typed, layout: .russian, intended: word)
  let lowerTyped = AutoSwitchEngine.convert(word.lowercased(), to: .russian)
  let lower = outcome(typed: lowerTyped, layout: .russian, intended: word.lowercased())
  print("    \(word)  raw=\(raw)  lower=\(lower)  cause(raw)=\(enCause(word, typed: typed, coreSet: ruCore))")
}

// (d) Tech and chat vocabulary on RU layout.
print("(d) tech/chat vocabulary typed on RU layout")
for word in ["github", "jira", "slack", "api", "lgtm", "asap", "wfh", "devops", "k8s", "json", "yaml", "frontend", "backend", "kubernetes", "repo", "merge", "deploy", "commit"] {
  let typed = AutoSwitchEngine.convert(word, to: .russian)
  let result = outcome(typed: typed, layout: .russian, intended: word)
  let inEN = englishSet.contains(word)
  let cause = result == .kept ? enCause(word, typed: typed, coreSet: ruCore) : "-"
  print("    \(word)  \(result)  inEN=\(inEN)  cause=\(cause)")
}

// (e) Everyday sentences typed on RU layout, word level.
let sentences = [
  "I think we should move the meeting to tomorrow morning.",
  "Can you send me the report before lunch today?",
  "The weather looks great, so let's go for a walk.",
  "She bought a new bicycle and rode it to the park.",
  "We need to finish the project before the end of the month.",
  "Please remember to lock the door when you leave.",
  "My brother works as a doctor in a small hospital.",
  "The train was late again, so we missed the first show.",
  "Could you help me carry these boxes upstairs?",
  "There are many interesting places to visit in this city.",
  "He always drinks coffee with milk and two sugars.",
  "Let us know if you need anything else from the store.",
  "The children played in the garden until it got dark.",
  "I will call you back as soon as I finish this call.",
  "Our team won the game because everyone worked hard.",
  "Turn left at the second light and park near the bridge.",
  "This book is much better than the movie was.",
  "Do you want to join us for dinner on Friday night?",
  "The new phone has a larger screen and a better camera.",
  "Water boils at one hundred degrees Celsius at sea level.",
  "Thanks for the quick reply, I really appreciate it.",
  "We should get some fresh bread and cheese on the way home.",
  "My favorite season is autumn because the leaves turn red.",
  "Make sure everything is saved before you close the window.",
  "The meeting was cancelled, so we went home early.",
  "They moved to a quiet town near the mountains last year.",
  "Can someone check whether the printer is working again?",
  "It was raining all day, so we stayed inside and read.",
  "Every morning I walk the dog before I eat breakfast.",
  "Please write down the address so I do not forget it.",
]
print("(e) 30 sentences typed on RU layout")
let punctuation = CharacterSet(charactersIn: ".,!?;:\"()")
let sentenceCauses = Tally()
var tokens = 0, tokCorrect = 0, tokWrong = 0, tokLowerCorrect = 0
var punctTokens = 0, punctSwitched = 0, shortTokens = 0, shortSwitched = 0
for sentence in sentences {
  for token in sentence.split(separator: " ").map(String.init) {
    tokens += 1
    let hasPunct = token.unicodeScalars.last.map { punctuation.contains($0) } ?? false
    if hasPunct {
      punctTokens += 1
      if case .correct = outcome(typed: AutoSwitchEngine.convert(token, to: .russian), layout: .russian, intended: token) {
        punctSwitched += 1
      }
    }
    let core = token.trimmingCharacters(in: punctuation)
    let typed = AutoSwitchEngine.convert(core, to: .russian)
    if core.count < 3 { shortTokens += 1 }
    switch outcome(typed: typed, layout: .russian, intended: core) {
    case .correct:
      tokCorrect += 1
      if core.count < 3 { shortSwitched += 1 }
    case .wrong:
      tokWrong += 1
      print("    wrong switch: \(core)")
    case .kept:
      sentenceCauses.add(enCause(core, typed: typed, coreSet: ruCore), core)
    }
    let lower = core.lowercased()
    if case .correct = outcome(typed: AutoSwitchEngine.convert(lower, to: .russian), layout: .russian, intended: lower) {
      tokLowerCorrect += 1
    }
  }
}
print("    tokens \(tokens)  correct \(tokCorrect)  correct-if-lowercased \(tokLowerCorrect)  wrong \(tokWrong)")
print("    short tokens (<3) \(shortTokens), switched \(shortSwitched)")
print("    tokens with trailing punctuation \(punctTokens), switched when fed whole \(punctSwitched)")
sentenceCauses.report()

// (f) RU words typed on EN layout, same metric in the other direction.
print("(f) RU->EN: \(ruFreq.count) most frequent RU words typed on EN layout")
let ruTyped = ruFreq.map { AutoSwitchEngine.convert($0, to: .english) }
let ruCauses = Tally()
var ruCorrect = 0, ruWrong = 0
for (i, word) in ruFreq.enumerated() {
  switch outcome(typed: ruTyped[i], layout: .english, intended: word) {
  case .correct: ruCorrect += 1
  case .wrong: ruWrong += 1
  case .kept: ruCauses.add(ruCause(word, typed: ruTyped[i]), word)
  }
}
print("    correct \(ruCorrect) (\(ruCorrect * 100 / ruFreq.count)%)  wrong \(ruWrong)  kept \(ruFreq.count - ruCorrect - ruWrong)")
ruCauses.report()

// (e-realistic) Sentences replayed as AppDelegate runs them. The layout starts RU;
// a switch flips it to EN for the following words, which are then typed correctly.
// A switch on an exact-tier anchor sweeps up to 4 preceding words (<= 28 keys) that
// qualify, using the tail since the last switch (AppDelegate.handleAutoSwitch, phrasePrefix).
print("(e-realistic) 30 sentences, layout starts RU, follows auto-switch and phrase sweep")
func realisticCause(_ token: String, typed: String) -> String {
  if let last = token.last, ".,;:!?".contains(last) { return "trailing-punct" }
  return enCause(token, typed: typed, coreSet: ruCore)
}
let realCauses = Tally()
var realTokens = 0, realCorrect = 0
var realByKind: [String: Int] = [:]
var realWrongSwitches: [String] = []
// Title-case contract (STEP 2): a Title-case word switches only via exact tiers, on its lowercase form.
func isTitleCaseWord(_ token: String) -> Bool {
  guard let first = token.first, first.isUppercase, token.filter({ $0.isLetter }).count >= 3 else { return false }
  return !token.dropFirst().contains(where: { $0.isUppercase })
}
var realCapsPasses = 0
for sentence in sentences {
  let tokensList = sentence.split(separator: " ").map(String.init)
  var layout = Layout.russian
  var tail: [(index: Int, typed: String, keys: Int)] = []
  var correct = [Bool](repeating: false, count: tokensList.count)
  var kind = [String](repeating: "", count: tokensList.count)
  var typedOf = [String](repeating: "", count: tokensList.count)
  for (index, token) in tokensList.enumerated() {
    let typed = layout == .russian ? AutoSwitchEngine.convert(token, to: .russian) : token
    typedOf[index] = typed
    let lowerTyped = AutoSwitchEngine.convert(token.lowercased(), to: .russian)
    let capsSwitch = layout == .russian && isTitleCaseWord(token)
      && AutoSwitchEngine.matchTier(word: lowerTyped, currentLayout: .russian) == .exact
    if capsSwitch { realCapsPasses += 1 }
    let switched = capsSwitch || AutoSwitchEngine.evaluate(word: typed, currentLayout: layout) == .switchLayout
    if !switched {
      if layout == .english {
        correct[index] = true
        kind[index] = "typed-EN"
      } else {
        kind[index] = "kept-RU"
      }
      tail.append((index, typed, typed.count + 1))
      if tail.count > 4 { tail.removeFirst() }
      continue
    }
    correct[index] = AutoSwitchEngine.convert(typed, to: layout.other) == token
    kind[index] = correct[index] ? "switched" : "wrong-switch"
    var swept: [(index: Int, typed: String, keys: Int)] = []
    if AutoSwitchEngine.isExactMatch(word: typed, currentLayout: layout) {
      var keys = 0
      for unit in tail.reversed() {
        guard swept.count < 4, keys + unit.keys <= 28,
              AutoSwitchEngine.qualifiesForPhraseExtension(word: unit.typed, currentLayout: layout) else { break }
        swept.append(unit)
        keys += unit.keys
      }
    }
    for unit in swept {
      correct[unit.index] = AutoSwitchEngine.convert(unit.typed, to: layout.other) == tokensList[unit.index]
      kind[unit.index] = "swept"
    }
    tail = []
    layout = layout.other
  }
  for index in tokensList.indices {
    realTokens += 1
    if correct[index] {
      realCorrect += 1
      realByKind[kind[index], default: 0] += 1
    } else if kind[index] == "wrong-switch" {
      realWrongSwitches.append(tokensList[index])
    } else {
      realCauses.add(realisticCause(tokensList[index], typed: typedOf[index]), tokensList[index])
    }
  }
}
print("    tokens \(realTokens)  correct \(realCorrect) (\(realCorrect * 100 / realTokens)%)  wrong-switch \(realWrongSwitches.count)")
print("    Title-case words passing via exact tiers under the caps contract: \(realCapsPasses)")
print("    correct by path: \(realByKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
print("    wrong switches: \(realWrongSwitches.joined(separator: ", "))")
realCauses.report()
