import Foundation

// User lexicon tests. Compiled with the engine sources plus Babbler/UserLexicon*.swift.
// Run with ./tests/lexicon_test.sh.
//
// API contract the implementation must match:
//   Babbler/UserLexicon.swift
//     protocol UserLexiconStore: AnyObject {
//       func userLexiconKeeps() -> [String: Int]          // keep counts; tests treat keys as opaque
//       func setUserLexiconKeeps(_ keeps: [String: Int])
//       func userLexiconLearned() -> [String]              // learned entries, oldest first; opaque strings
//       func setUserLexiconLearned(_ entries: [String])
//     }
//     final class UserLexicon {
//       static let promoteThreshold = 2                    // keeps needed before a word is learned
//       static let maxEntries = 5000                       // learned cap; oldest evicted first
//       init(store: UserLexiconStore)                      // loads keep counts and learned entries from store
//       static func isEnabled(defaults: UserDefaults = .standard) -> Bool
//         // reads userLexiconEnabledKey; key absent => true
//       func noteKept(word: String, layout: Layout)        // word typed in layout, committed, not switched
//       func contains(_ word: String, in layout: Layout) -> Bool   // case-insensitive
//       func importSpelling(from url: URL)                 // newline-separated words (LF or CRLF);
//                                                          // Cyrillic => RU, Latin => EN, others ignored;
//                                                          // imported words are known immediately
//       var learnedCount: Int { get }
//       func reset()                                       // clears learned entries and keep counts
//     }
//     func forget(word: String, layout: Layout)          // removes pending keep count AND learned entry
//                                                        // for that layout only (case-insensitive); no-op if unknown
//     static let maxPending = 5000                       // pending keep counts cap; keeps at most this many
//                                                        // (persisted via userLexiconKeeps)
//     Words shorter than 2 characters, or containing digits or code characters, are ignored
//     by noteKept and importSpelling.
//   Babbler/PreferenceStore.swift
//     let userLexiconEnabledKey = "..."                    // top-level constant, any string value
//   Babbler/AutoSwitchEngine.swift (static enum)
//     static var userLexicon: UserLexicon?                 // nil = no lexicon. A lexicon word in the
//                                                          // current layout => keep (before conversion).
//                                                          // A lexicon word in the target layout => Tier.exact.
//   Babbler/UserLexiconPreferences.swift (optional)        // PreferenceStore conformance to UserLexiconStore;
//                                                          // not needed by these tests (they use a fake store)

let resources = ProcessInfo.processInfo.environment["BABBLER_RESOURCES"]
  ?? FileManager.default.currentDirectoryPath + "/Babbler/Resources"
let workDir = ProcessInfo.processInfo.environment["BABBLER_TEST_WORK"]
  ?? FileManager.default.currentDirectoryPath

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

// Same dictionary setup as tests/AutoSwitchTests.swift.
let englishSet = Set(loadWords("\(resources)/en.txt.gz"))
let russianSet = HashedWordSet(contentsOf: URL(fileURLWithPath: "\(resources)/ru-forms.bin"))!
let russianTypoSet = HashedWordSet(contentsOf: URL(fileURLWithPath: "\(resources)/ru-typo.bin"))!
LayoutDictionary.shared.setForTests(englishSet, russianSet, typo: russianTypoSet)
let shippedEnglishModel = NGramModel(contentsOf: URL(fileURLWithPath: "\(resources)/ngram-en.bin"))
let shippedRussianModel = NGramModel(contentsOf: URL(fileURLWithPath: "\(resources)/ngram-ru.bin"))
LayoutDictionary.shared.setNGramModels(english: shippedEnglishModel, russian: shippedRussianModel)

/// In-memory store standing in for PreferenceStore.
final class FakeUserLexiconStore: UserLexiconStore {
  var keeps: [String: Int] = [:]
  var learned: [String] = []
  func userLexiconKeeps() -> [String: Int] { keeps }
  func setUserLexiconKeeps(_ keeps: [String: Int]) { self.keeps = keeps }
  func userLexiconLearned() -> [String] { learned }
  func setUserLexiconLearned(_ entries: [String]) { learned = entries }
}

func freshLexicon() -> (lexicon: UserLexicon, store: FakeUserLexiconStore) {
  let store = FakeUserLexiconStore()
  return (UserLexicon(store: store), store)
}

/// Distinct lowercase ASCII words of four letters, unique for index < 26^4.
func wordFor(_ index: Int) -> String {
  let letters = Array("abcdefghijklmnopqrstuvwxyz")
  var n = index
  var out = ""
  for _ in 0..<4 {
    out.append(letters[n % 26])
    n /= 26
  }
  return out
}

// MARK: - Constants and promotion

print("=== constants and promotion after keeps")
check(UserLexicon.promoteThreshold == 2, "promoteThreshold must be 2")
check(UserLexicon.maxEntries == 5000, "maxEntries must be 5000")

let (lexP, _) = freshLexicon()
lexP.noteKept(word: "xfce", layout: .english)
check(!lexP.contains("xfce", in: .english), "one keep must not promote xfce")
check(lexP.learnedCount == 0, "one keep must leave learnedCount at 0, got \(lexP.learnedCount)")
lexP.noteKept(word: "xfce", layout: .english)
check(lexP.contains("xfce", in: .english), "second keep must promote xfce")
check(lexP.learnedCount == 1, "promoted word must count once, got \(lexP.learnedCount)")
check(lexP.contains("XFCE", in: .english), "contains must be case-insensitive")
check(!lexP.contains("xfce", in: .russian), "a learned EN word must not be known in RU")

let (lexCase, _) = freshLexicon()
lexCase.noteKept(word: "Курсач", layout: .russian)
lexCase.noteKept(word: "курсач", layout: .russian)
check(lexCase.contains("КУРСАЧ", in: .russian), "keeps differing only in case must count together")

// MARK: - Word validity

print("=== word validity")
let (lexV, _) = freshLexicon()
let invalid: [(word: String, layout: Layout)] = [
  ("a", .english), ("я", .russian), ("ab1", .english), ("abc123", .english),
  ("x=y", .english), ("a/b", .english), ("foo_bar", .english), ("a(b)", .english),
]
for (word, layout) in invalid {
  lexV.noteKept(word: word, layout: layout)
  lexV.noteKept(word: word, layout: layout)
  check(!lexV.contains(word, in: layout), "\(word) must be ignored by noteKept")
}
check(lexV.learnedCount == 0, "invalid words must not be learned, got \(lexV.learnedCount)")

// MARK: - Spelling file import

print("=== importing a spelling file")
let spellingPath = "\(workDir)/LocalDictionary-test.txt"
let spellingText = "Тинькофф\r\n\r\nkubectl\r\n  Курсач  \r\nabc123\r\nабв-def\r\nя\r\nxfce\nShopify"
try! spellingText.data(using: .utf8)!.write(to: URL(fileURLWithPath: spellingPath))

let (lexI, _) = freshLexicon()
lexI.importSpelling(from: URL(fileURLWithPath: spellingPath))
check(lexI.contains("Тинькофф", in: .russian), "Cyrillic line must be imported as RU")
check(lexI.contains("тинькофф", in: .russian), "imported RU word must match case-insensitively")
check(lexI.contains("kubectl", in: .english), "Latin line must be imported as EN")
check(lexI.contains("курсач", in: .russian), "padded Cyrillic line must be trimmed and imported")
check(lexI.contains("xfce", in: .english), "LF-terminated line must be imported")
check(lexI.contains("Shopify", in: .english), "last line without a newline must be imported")
check(!lexI.contains("abc123", in: .english), "words containing digits must be ignored on import")
check(!lexI.contains("абв-def", in: .russian) && !lexI.contains("абв-def", in: .english),
      "mixed-script words must be ignored on import")
check(!lexI.contains("я", in: .russian), "single-letter words must be ignored on import")
check(lexI.learnedCount == 5, "imported valid words must number exactly 5, got \(lexI.learnedCount)")

let (lexM, _) = freshLexicon()
lexM.importSpelling(from: URL(fileURLWithPath: "\(workDir)/does-not-exist.txt"))
check(lexM.learnedCount == 0, "a missing spelling file must import nothing")

// MARK: - Cap and eviction

print("=== cap and eviction")
let (lexC, storeC) = freshLexicon()
for i in 0..<(UserLexicon.maxEntries + 1) {
  lexC.noteKept(word: wordFor(i), layout: .english)
  lexC.noteKept(word: wordFor(i), layout: .english)
}
check(lexC.learnedCount == 5000, "learnedCount must cap at 5000, got \(lexC.learnedCount)")
check(!lexC.contains(wordFor(0), in: .english), "the oldest learned word must be evicted")
check(lexC.contains(wordFor(1), in: .english), "the second-oldest word must survive one eviction")
check(lexC.contains(wordFor(5000), in: .english), "the newest word must be learned")
check(storeC.userLexiconLearned().count == 5000, "store must hold at most 5000 entries")

// MARK: - Persistence round-trip

print("=== persistence round-trip")
let storeP = FakeUserLexiconStore()
let writer = UserLexicon(store: storeP)
writer.noteKept(word: "xfce", layout: .english)
let reader = UserLexicon(store: storeP)
reader.noteKept(word: "xfce", layout: .english)
check(reader.contains("xfce", in: .english),
      "keep counts must persist: a keep from a new instance must complete the promotion")
let reloaded = UserLexicon(store: storeP)
check(reloaded.contains("xfce", in: .english), "a learned word must survive re-initialisation")
check(reloaded.learnedCount == 1, "learnedCount must survive re-initialisation, got \(reloaded.learnedCount)")

// MARK: - Reset

print("=== reset")
let (lexR, storeR) = freshLexicon()
lexR.noteKept(word: "xfce", layout: .english)
lexR.noteKept(word: "xfce", layout: .english)
lexR.noteKept(word: "курсач", layout: .russian)
lexR.reset()
check(lexR.learnedCount == 0, "reset must clear learned words, got \(lexR.learnedCount)")
check(!lexR.contains("xfce", in: .english), "reset must forget learned words")
check(storeR.userLexiconLearned().isEmpty, "reset must clear the store's learned entries")
lexR.noteKept(word: "курсач", layout: .russian)
check(!lexR.contains("курсач", in: .russian), "reset must also clear keep counts")

// MARK: - Preference

print("=== enabled preference")
let suiteName = "babbler-lexicon-test-\(getpid())"
let defaults = UserDefaults(suiteName: suiteName)!
defaults.removePersistentDomain(forName: suiteName)
check(UserLexicon.isEnabled(defaults: defaults), "user lexicon must be enabled by default")
defaults.set(false, forKey: userLexiconEnabledKey)
check(!UserLexicon.isEnabled(defaults: defaults), "a stored false must disable the user lexicon")
defaults.removePersistentDomain(forName: suiteName)

// MARK: - Forget (manual action-key swap)

print("=== forget removes learned and pending entries for one layout")
let (lexF, storeF) = freshLexicon()
lexF.noteKept(word: "xfce", layout: .english)
lexF.noteKept(word: "xfce", layout: .english)
check(lexF.contains("xfce", in: .english), "precondition: xfce must be learned in EN")
lexF.forget(word: "XFCE", layout: .english)
check(!lexF.contains("xfce", in: .english),
      "forget must remove a learned word for its layout (case-insensitive)")
check(lexF.learnedCount == 0, "forget must decrement learnedCount, got \(lexF.learnedCount)")
check(storeF.userLexiconLearned().isEmpty,
      "forget must clear the learned entry from the store")

let (lexFP, _) = freshLexicon()
lexFP.noteKept(word: "курсач", layout: .russian)
lexFP.forget(word: "курсач", layout: .russian)
lexFP.noteKept(word: "курсач", layout: .russian)
check(!lexFP.contains("курсач", in: .russian),
      "forget must drop the pending keep count: one keep after forget must not promote")

let (lexFL, _) = freshLexicon()
lexFL.noteKept(word: "курсач", layout: .russian)
lexFL.noteKept(word: "курсач", layout: .russian)
lexFL.forget(word: "курсач", layout: .english)
check(lexFL.contains("курсач", in: .russian),
      "forget in EN must not touch the RU-learned entry for the same letters")

let (lexFM, storeFM) = freshLexicon()
lexFM.forget(word: "neverseen", layout: .english)
check(lexFM.learnedCount == 0 && storeFM.userLexiconKeeps().isEmpty,
      "forgetting an unknown word must be a harmless no-op")

let storeFP = FakeUserLexiconStore()
let writerFP = UserLexicon(store: storeFP)
writerFP.noteKept(word: "xfce", layout: .english)
writerFP.noteKept(word: "xfce", layout: .english)
writerFP.forget(word: "xfce", layout: .english)
let readerFP = UserLexicon(store: storeFP)
check(!readerFP.contains("xfce", in: .english), "forget must persist: a reloaded lexicon must not know the word")

print("=== forget in the engine")
let (lexFE, _) = freshLexicon()
lexFE.noteKept(word: "Курсач", layout: .russian)
lexFE.noteKept(word: "Курсач", layout: .russian)
AutoSwitchEngine.userLexicon = lexFE
check(AutoSwitchEngine.evaluate(word: "rehcfx", currentLayout: .english) == .switchLayout,
      "precondition: learned Курсач must make rehcfx switch")
lexFE.forget(word: "Курсач", layout: .russian)
check(AutoSwitchEngine.evaluate(word: "rehcfx", currentLayout: .english) == .keep,
      "after forget, rehcfx must be kept again (a missed wrong-layout word must not stay learned)")
AutoSwitchEngine.userLexicon = nil

// MARK: - Pending keep cap

print("=== pending keep cap")
check(UserLexicon.maxPending == 5000, "maxPending must be 5000, got \(UserLexicon.maxPending)")

let storePC = FakeUserLexiconStore()
let lexPC = UserLexicon(store: storePC)
for i in 0..<(UserLexicon.maxPending + 1) {
  lexPC.noteKept(word: wordFor(i), layout: .english)
}
check(storePC.userLexiconKeeps().count <= UserLexicon.maxPending,
      "pending keep counts must cap at maxPending, got \(storePC.userLexiconKeeps().count)")
check(storePC.userLexiconKeeps().count == UserLexicon.maxPending,
      "pending keep counts must fill to maxPending before evicting, got \(storePC.userLexiconKeeps().count)")
check(lexPC.learnedCount == 0, "single keeps must never be learned, got \(lexPC.learnedCount)")

let storeCH = FakeUserLexiconStore()
let lexCH = UserLexicon(store: storeCH)
let churnWord = wordFor(20000)
lexCH.noteKept(word: churnWord, layout: .english)
for i in 0..<4000 {
  lexCH.noteKept(word: wordFor(i), layout: .english)
}
lexCH.noteKept(word: churnWord, layout: .english)
check(lexCH.contains(churnWord, in: .english),
      "a word kept once, then kept again after partial churn, must still promote")

let storeCH2 = FakeUserLexiconStore()
let lexCH2 = UserLexicon(store: storeCH2)
for i in 0..<(UserLexicon.maxPending + 1) {
  lexCH2.noteKept(word: wordFor(i), layout: .english)
}
let freshWord = wordFor(30000)
lexCH2.noteKept(word: freshWord, layout: .english)
lexCH2.noteKept(word: freshWord, layout: .english)
check(lexCH2.contains(freshWord, in: .english),
      "a word kept twice after cap churn must still promote normally")

// MARK: - Engine decisions

print("=== engine decisions without a lexicon (baseline)")
AutoSwitchEngine.userLexicon = nil
check(AutoSwitchEngine.evaluate(word: "xfce", currentLayout: .english) == .switchLayout,
      "xfce typed in EN must switch without a lexicon")
check(AutoSwitchEngine.evaluate(word: "rehcfx", currentLayout: .english) == .keep,
      "rehcfx typed in EN must be kept without a lexicon")

print("=== current-layout protection")
let (lexE, _) = freshLexicon()
lexE.noteKept(word: "xfce", layout: .english)
AutoSwitchEngine.userLexicon = lexE
check(AutoSwitchEngine.evaluate(word: "xfce", currentLayout: .english) == .switchLayout,
      "one keep must not protect xfce in the engine")
lexE.noteKept(word: "xfce", layout: .english)
check(AutoSwitchEngine.evaluate(word: "xfce", currentLayout: .english) == .keep,
      "a learned EN word typed in EN must be kept")
AutoSwitchEngine.userLexicon = lexI
check(AutoSwitchEngine.evaluate(word: "xfce", currentLayout: .english) == .keep,
      "an imported EN word typed in EN must be kept")

print("=== layout separation in the engine")
let (lexL, _) = freshLexicon()
lexL.noteKept(word: "xfce", layout: .russian)
lexL.noteKept(word: "xfce", layout: .russian)
AutoSwitchEngine.userLexicon = lexL
check(AutoSwitchEngine.evaluate(word: "xfce", currentLayout: .english) == .switchLayout,
      "a RU-learned word must not protect the same keys typed in EN")

print("=== target-layout exact match")
let (lexT, _) = freshLexicon()
lexT.noteKept(word: "Курсач", layout: .russian)
AutoSwitchEngine.userLexicon = lexT
check(AutoSwitchEngine.evaluate(word: "rehcfx", currentLayout: .english) == .keep,
      "one keep must not make Курсач an exact RU match")
lexT.noteKept(word: "Курсач", layout: .russian)
check(AutoSwitchEngine.evaluate(word: "rehcfx", currentLayout: .english) == .switchLayout,
      "a learned RU word typed on EN must switch")
check(AutoSwitchEngine.matchTier(word: "rehcfx", currentLayout: .english) == .exact,
      "a learned RU word typed on EN must be an exact match")

print("=== disabled lexicon")
AutoSwitchEngine.userLexicon = nil
check(AutoSwitchEngine.evaluate(word: "rehcfx", currentLayout: .english) == .keep,
      "with the lexicon removed, rehcfx must return to the baseline keep")
check(AutoSwitchEngine.evaluate(word: "xfce", currentLayout: .english) == .switchLayout,
      "with the lexicon removed, xfce must return to the baseline switch")

if failures == 0 {
  print("ALL LEXICON CHECKS PASS")
} else {
  print("\(failures) LEXICON CHECKS FAILED")
  exit(1)
}
