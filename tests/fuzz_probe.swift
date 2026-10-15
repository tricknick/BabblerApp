import Foundation

// Headless fuzz probe (run via tests/fuzz_probe.sh). Asserts nothing. For each cell
// (source×breaker) it prints one summary line and appends one JSON object per bad token
// to the findings JSONL file.
//
// Input TSV: source<TAB>breaker<TAB>sentence. The sentence is the intended (correct) text
// and may mix Cyrillic and Latin. Blank lines and lines starting with "#" are skipped.
//
// Mode A (miss) uses the same realistic typing simulation as corpus_probe.swift: each
// sentence starts on the EN layout, Cyrillic tokens are typed on the wrong layout, Latin
// tokens are wrong only once auto-switch flips to RU, and the layout follows auto-switch
// and the phrase sweep. A token that does not come out as intended is a "miss".
// Mode B (fp) types every token on its own script's layout; a token the engine switches
// is an "fp".
// Tokens without letters and tokens containing digits are skipped in both modes.
//
// Setup matches corpus_probe.swift: theme packs on, no user lexicon, nil context.
//
// Usage: fuzz-probe <cases.tsv> <findings.jsonl> [source×breaker]

let env = ProcessInfo.processInfo.environment
let resources = env["BABBLER_RESOURCES"] ?? ""

func fail(_ message: String, code: Int32 = 2) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4 else {
  fail("usage: fuzz-probe <cases.tsv> <findings.jsonl> [source×breaker]")
}
let casesPath = args[1]
let findingsPath = args[2]
let cellFilter: String? = args.count == 4 ? args[3] : nil

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
// BABBLER_SPELL_ORACLE=1 (full) or =veto wires the real NSSpellChecker-backed oracle,
// as in corpus_probe.swift. Off by default.
if let spellOracleMode = env["BABBLER_SPELL_ORACLE"] {
  AutoSwitchEngine.spellOracle = SystemSpellOracle()
  if spellOracleMode == "veto" { AutoSwitchEngine.spellCheckerConfirmEnabled = false }
}

struct Sentence {
  let source: String
  let breaker: String
  let text: String
  var cell: String { "\(source)×\(breaker)" }
}

struct Finding {
  let sentence: Sentence
  let mode: String
  let typed: String
  let expected: String
  let got: String
  let tier: String
  let cause: String
  let context: String
}

struct CellStats {
  var sentences = 0
  var tokens = 0
  var miss = 0
  var fp = 0
}

func pct(_ part: Int, _ whole: Int) -> String {
  whole == 0 ? "n/a" : String(format: "%.1f%%", Double(part) * 100 / Double(whole))
}

func tierName(_ tier: AutoSwitchEngine.Tier?) -> String {
  tier.map { String(describing: $0) } ?? "none"
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

// Mirrors corpus_probe's rejection order for a word whose intended layout is `word`'s script.
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

// Mode A. Appends one finding per token that does not come out as intended.
func simulateRecall(_ sentence: Sentence, into findings: inout [Finding]) -> (tokens: Int, misses: Int) {
  let words = sentence.text.split(separator: " ").map(String.init)
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

  var tokens = 0, misses = 0
  for (i, token) in words.enumerated() {
    guard let k = kind[i] else { continue }
    tokens += 1
    if ok[i] { continue }
    misses += 1
    let c = core(token)
    let l = lang[i]
    let typed = typedAt[i]
    let got = k == "kept" ? typed : AutoSwitchEngine.convert(typed, to: layoutAt[i].other)
    let tier = k == "wrong-switch"
      ? tierName(AutoSwitchEngine.matchTier(word: typed, currentLayout: layoutAt[i]))
      : "none"
    var cause = k == "wrong-switch"
      ? "wrong-switch"
      : missCause(c, lang: l, typed: typedOn(layoutAt[i], c, lang: l))
    if c != token { cause = "punct+" + cause }
    findings.append(Finding(
      sentence: sentence, mode: "miss", typed: typed, expected: token, got: got,
      tier: tier, cause: cause, context: fragment(words, i)))
  }
  return (tokens, misses)
}

// Mode B. Every token typed on its own layout; appends one finding per switched token.
func simulateFalsePositives(_ sentence: Sentence, into findings: inout [Finding]) -> (tokens: Int, fps: Int) {
  let words = sentence.text.split(separator: " ").map(String.init)
  var tokens = 0, fps = 0
  for (i, token) in words.enumerated() where hasLetters(token) && !hasDigit(token) {
    tokens += 1
    let l = languageOf(token)
    let capsSwitch = isTitleCaseWord(token)
      && AutoSwitchEngine.matchTier(word: token.lowercased(), currentLayout: l) == .exact
    guard capsSwitch
      || AutoSwitchEngine.evaluate(word: token, currentLayout: l) == .switchLayout
    else { continue }
    let tier = AutoSwitchEngine.matchTier(word: token, currentLayout: l)
    fps += 1
    findings.append(Finding(
      sentence: sentence, mode: "fp", typed: token, expected: token,
      got: AutoSwitchEngine.convert(token, to: l.other), tier: tierName(tier),
      cause: capsSwitch ? "fp-title-case" : "fp-" + tierName(tier),
      context: fragment(words, i)))
  }
  return (tokens, fps)
}

func loadSentences(_ path: String) -> [Sentence] {
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
    fail("cannot read \(path)")
  }
  var sentences: [Sentence] = []
  // components(separatedBy: .newlines) also splits CRLF, which Swift's Character view would not.
  for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
    let trimmedLine = raw.trimmingCharacters(in: .whitespaces)
    if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") { continue }
    let fields = raw.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      .map { String($0).trimmingCharacters(in: .whitespaces) }
    guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty }) else {
      fail("\(path):\(index + 1): expected source<TAB>breaker<TAB>sentence")
    }
    sentences.append(Sentence(source: fields[0], breaker: fields[1], text: fields[2]))
  }
  return sentences
}

func jsonLine(_ f: Finding) -> String {
  let object: [String: String] = [
    "cell": f.sentence.cell,
    "source": f.sentence.source,
    "breaker": f.sentence.breaker,
    "mode": f.mode,
    "typed": f.typed,
    "expected": f.expected,
    "got": f.got,
    "tier": f.tier,
    "cause": f.cause,
    "context": f.context,
  ]
  let data = try! JSONSerialization.data(
    withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
  return String(data: data, encoding: .utf8)!
}

func appendFindings(_ findings: [Finding], to path: String) {
  let text = findings.map { jsonLine($0) + "\n" }.joined()
  if !FileManager.default.fileExists(atPath: path) {
    FileManager.default.createFile(atPath: path, contents: nil)
  }
  do {
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
  } catch {
    fail("cannot append to \(path): \(error)", code: 1)
  }
}

let sentences = loadSentences(casesPath)
if sentences.isEmpty { fail("no sentences in \(casesPath)") }
let selected: [Sentence]
if let cell = cellFilter {
  selected = sentences.filter { $0.cell == cell }
  if selected.isEmpty { fail("no rows for cell \(cell) in \(casesPath)") }
} else {
  selected = sentences
}

var findings: [Finding] = []
var cellOrder: [String] = []
var stats: [String: CellStats] = [:]
for sentence in selected {
  if stats[sentence.cell] == nil { cellOrder.append(sentence.cell) }
  var st = stats[sentence.cell] ?? CellStats()
  let recall = simulateRecall(sentence, into: &findings)
  let fp = simulateFalsePositives(sentence, into: &findings)
  st.sentences += 1
  st.tokens += recall.tokens
  st.miss += recall.misses
  st.fp += fp.fps
  stats[sentence.cell] = st
}

appendFindings(findings, to: findingsPath)
for cell in cellOrder {
  let st = stats[cell]!
  print("cell=\(cell) sentences=\(st.sentences) tokens=\(st.tokens) miss=\(st.miss) (\(pct(st.miss, st.tokens))) fp=\(st.fp) (\(pct(st.fp, st.tokens)))")
}
