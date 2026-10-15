import Foundation

// Real-text probe (run via tests/corpus_probe.sh). Prints counts; asserts nothing.
//
// Input: build/corpus/{pikabu,habr}.txt, one sentence per line, from
// scripts/corpus_extract.py. The corpus is gitignored and must never be copied into
// tracked files; this probe prints aggregate counts, missed words, and FP fragments.
//
// Setup matches tests/en_probe.swift: theme packs on, no user lexicon, nil context.
//
// Mode A (recall): each sentence starts on the EN layout (wrong for Russian text).
// Cyrillic tokens are typed on the current layout; Latin tokens are typed on the
// current layout too, so they are wrong only after auto-switch flips to RU. The layout
// follows auto-switch and the phrase sweep, as in en_probe's e-realistic mode.
// Per-word-only: each token alone, typed on its wrong layout, with no state.
//
// Mode B (false positives): every token typed on its own script's layout. Counts the
// tokens where evaluate() returns .switchLayout.

let env = ProcessInfo.processInfo.environment
let resources = env["BABBLER_RESOURCES"] ?? ""
let cacheDir = env["BABBLER_DICT_CACHE"] ?? ""
let corpusDir = env["BABBLER_CORPUS"] ?? ""

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
// BABBLER_SPELL_ORACLE=1 (full) or =veto wires the real NSSpellChecker-backed
// oracle, to compare recall/FP against the baseline without it. Off by
// default so a bare `bash tests/corpus_probe.sh` reproduces the pre-existing
// numbers.
if let spellOracleMode = env["BABBLER_SPELL_ORACLE"] {
  AutoSwitchEngine.spellOracle = SystemSpellOracle()
  if spellOracleMode == "veto" { AutoSwitchEngine.spellCheckerConfirmEnabled = false }
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
      print("      \(cause): \(n)  e.g. \(examples[cause, default: []].joined(separator: ", "))")
    }
  }
}

func pct(_ part: Int, _ whole: Int) -> String {
  whole == 0 ? "n/a" : String(format: "%.1f%%", Double(part) * 100 / Double(whole))
}

func describe<T>(_ value: T?) -> String {
  value.map { String(describing: $0) } ?? "nil"
}

func hasLetters(_ s: String) -> Bool { s.contains(where: { $0.isLetter }) }
func hasDigit(_ s: String) -> Bool { s.contains(where: { $0.isNumber }) }

func core(_ token: String) -> String {
  token.trimmingCharacters(in: .punctuationCharacters)
}

// Dominant script decides the intended layout. Latin-only tokens are English.
func languageOf(_ token: String) -> Layout {
  var cyrillic = 0, latin = 0
  for scalar in token.unicodeScalars {
    if (0x0400...0x04FF).contains(scalar.value) {
      cyrillic += 1
    } else if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) {
      latin += 1
    }
  }
  return cyrillic >= latin ? .russian : .english
}

// Keystrokes produced for `token` when the keyboard is on `layout`.
func typedOn(_ layout: Layout, _ token: String, lang: Layout) -> String {
  layout == lang ? token : AutoSwitchEngine.convert(token, to: layout)
}

func isTitleCaseWord(_ token: String) -> Bool {
  guard let first = token.first, first.isUppercase, token.filter({ $0.isLetter }).count >= 3 else {
    return false
  }
  return !token.dropFirst().contains(where: { $0.isUppercase })
}

// Mirrors en_probe's rejection order, for a word whose intended layout is `word`'s script.
func enCause(_ word: String, typed: String) -> String {
  if word.contains("'") { return "apostrophe" }
  if word.contains(where: { !$0.isLetter }) { return "non-letter" }
  if word.count < 3 { return "short" }
  if word != word.lowercased() { return "capital" }
  if ruFull.contains(typed) { return ruCore.contains(typed) ? "collision-core" : "collision-morph" }
  if !englishSet.contains(word) { return "not-in-en" }
  return "other"
}

func missCause(_ word: String, lang: Layout, typed: String) -> String {
  if lang == .english { return enCause(word, typed: typed) }
  if word.count < 3 { return "short" }
  if word.contains(where: { $0 == "-" || $0 == "'" }) { return "hyphen-or-apostrophe" }
  if englishSet.contains(typed.lowercased()) { return "collision-en" }
  if word.first?.isUppercase == true {
    return ruFull.contains(word.lowercased()) ? "capital-known" : "capital-unknown"
  }
  return ruFull.contains(word) ? "other" : "not-in-ru"
}

func fragment(_ words: [String], _ i: Int) -> String {
  var parts: [String] = []
  if i > 0 { parts.append(String(words[i - 1].suffix(20))) }
  parts.append("[\(words[i])]")
  if i + 1 < words.count { parts.append(String(words[i + 1].prefix(20))) }
  return String(parts.joined(separator: " ").prefix(60))
}

func runRecall(_ sentences: [String]) {
  var tokens = 0, correct = 0, wrongSwitch = 0, punctTokens = 0, punctMissed = 0, perWordCorrect = 0
  var paths: [String: Int] = [:]
  let causes = Tally()
  var missed: [String: (count: Int, cause: String)] = [:]

  for sentence in sentences {
    let words = sentence.split(separator: " ").map(String.init)
    var layout = Layout.english
    var tail: [(index: Int, typed: String, keys: Int)] = []
    var lang = [Layout](repeating: .russian, count: words.count)
    var typedAt = [String](repeating: "", count: words.count)
    var layoutAt = [Layout](repeating: .english, count: words.count)
    var kind = [String?](repeating: nil, count: words.count)
    var ok = [Bool](repeating: false, count: words.count)

    for (i, token) in words.enumerated() {
      guard hasLetters(token), !hasDigit(token) else { continue }
      let l = languageOf(token)
      let typed = typedOn(layout, token, lang: l)
      lang[i] = l
      typedAt[i] = typed
      layoutAt[i] = layout
      let lowerTyped = typedOn(layout, token.lowercased(), lang: l)
      let capsSwitch = layout != l && isTitleCaseWord(token)
        && AutoSwitchEngine.matchTier(word: lowerTyped, currentLayout: layout) == .exact
      let switched = capsSwitch
        || AutoSwitchEngine.evaluate(word: typed, currentLayout: layout) == .switchLayout
      if !switched {
        ok[i] = layout == l
        kind[i] = ok[i] ? "typed-ok" : "kept"
        tail.append((i, typed, typed.count + 1))
        if tail.count > 4 { tail.removeFirst() }
        continue
      }
      ok[i] = AutoSwitchEngine.convert(typed, to: layout.other) == token
      kind[i] = ok[i] ? "switched" : "wrong-switch"
      var swept: [(index: Int, typed: String, keys: Int)] = []
      if AutoSwitchEngine.isExactMatch(word: typed, currentLayout: layout) {
        var keys = 0
        for unit in tail.reversed() {
          guard swept.count < 4, keys + unit.keys <= 28,
                AutoSwitchEngine.qualifiesForPhraseExtension(word: unit.typed, currentLayout: layout)
          else { break }
          swept.append(unit)
          keys += unit.keys
        }
      }
      for unit in swept {
        ok[unit.index] = AutoSwitchEngine.convert(unit.typed, to: layout.other) == words[unit.index]
        kind[unit.index] = "swept"
      }
      tail = []
      layout = layout.other
    }

    for (i, token) in words.enumerated() {
      guard let k = kind[i] else { continue }
      tokens += 1
      let c = core(token)
      let isPunct = c != token
      if isPunct { punctTokens += 1 }
      let l = lang[i]

      let wl = l.other
      let typedW = typedOn(wl, token, lang: l)
      let lowerW = typedOn(wl, token.lowercased(), lang: l)
      let capsW = isTitleCaseWord(token)
        && AutoSwitchEngine.matchTier(word: lowerW, currentLayout: wl) == .exact
      if (capsW || AutoSwitchEngine.evaluate(word: typedW, currentLayout: wl) == .switchLayout)
        && AutoSwitchEngine.convert(typedW, to: l) == token {
        perWordCorrect += 1
      }

      if ok[i] {
        correct += 1
        paths[k, default: 0] += 1
        continue
      }
      if isPunct { punctMissed += 1 }
      var cause: String
      var tierNote = ""
      if k == "wrong-switch" {
        wrongSwitch += 1
        cause = "wrong-switch"
        tierNote = " tier=" + describe(AutoSwitchEngine.matchTier(word: typedAt[i], currentLayout: layoutAt[i]))
      } else {
        cause = missCause(c, lang: l, typed: typedOn(layoutAt[i], c, lang: l))
      }
      if isPunct { cause = "punct+" + cause }
      causes.add(cause, token)
      let key = token.lowercased()
      let prev = missed[key]
      missed[key] = (count: (prev?.count ?? 0) + 1, cause: prev?.cause ?? (cause + tierNote))
    }
  }

  print("  A RECALL: word tokens \(tokens) (tokens containing digits skipped)")
  print("    correct \(correct) (\(pct(correct, tokens)))  per-word-only correct \(perWordCorrect) (\(pct(perWordCorrect, tokens)))  wrong-switch \(wrongSwitch)")
  print("    punctuated tokens \(punctTokens), missed \(punctMissed)")
  print("    correct by path: " + paths.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
  print("    misses by cause:")
  causes.report()
  print("    top 40 missed words (word xcount, cause):")
  let top = missed.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
  for (word, entry) in top.prefix(40) {
    print("      \(word) x\(entry.count)  \(entry.cause)")
  }
}

func runFalsePositives(_ sentences: [String]) {
  var tokens = 0, fps = 0, ruTokens = 0, ruFps = 0, enTokens = 0, enFps = 0
  var lines: [String] = []
  for sentence in sentences {
    let words = sentence.split(separator: " ").map(String.init)
    for (i, token) in words.enumerated() where hasLetters(token) {
      let l = languageOf(token)
      tokens += 1
      if l == .russian { ruTokens += 1 } else { enTokens += 1 }
      let capsSwitch = isTitleCaseWord(token)
        && AutoSwitchEngine.matchTier(word: token.lowercased(), currentLayout: l) == .exact
      guard capsSwitch || AutoSwitchEngine.evaluate(word: token, currentLayout: l) == .switchLayout else {
        continue
      }
      fps += 1
      if l == .russian { ruFps += 1 } else { enFps += 1 }
      let tier = describe(AutoSwitchEngine.matchTier(word: token, currentLayout: l))
      lines.append("    \(token)  lang=\(l == .russian ? "RU" : "EN")  tier=\(tier)  | \(fragment(words, i))")
    }
  }
  print("  B FALSE POSITIVES: word tokens \(tokens) (digit-containing tokens included)")
  print("    FP \(fps) (\(pct(fps, tokens)))  RU tokens FP \(ruFps)/\(ruTokens) (\(pct(ruFps, ruTokens)))  EN tokens FP \(enFps)/\(enTokens) (\(pct(enFps, enTokens)))")
  print("    FP list:")
  for line in lines { print(line) }
}

for name in ["pikabu", "habr"] {
  let path = "\(corpusDir)/\(name).txt"
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("== \(name): missing \(path)")
    continue
  }
  let sentences = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  print("== \(name): \(sentences.count) sentences")
  runRecall(sentences)
  runFalsePositives(sentences)
}
