import Foundation

// Learn-from-manual-swap tests. Compiled with the engine sources plus Babbler/UserLexicon*.swift.
// Run with ./tests/learn_swap_test.sh.
//
// API contract the implementation must match (in addition to tests/LexiconTests.swift):
//   Babbler/UserLexicon.swift
//     protocol UserLexiconStore: AnyObject {
//       func userLexiconForcedPending() -> [String: Int]     // manual-swap counts not yet promoted; keys opaque
//       func setUserLexiconForcedPending(_ pending: [String: Int])
//       func userLexiconForced() -> [String]                 // learned forced-switch entries, oldest first
//       func setUserLexiconForced(_ entries: [String])
//     }
//     final class UserLexicon {
//       var forcedCount: Int { get }                          // learned forced-switch entries (not pending)
//       func noteManualSwap(word: String, layout: Layout)     // user swapped word out of layout with the action key
//         // case-insensitive; only letters (isValidWord); no-op when UserLexicon.isEnabled() is false;
//         // removes a keep entry for the same word and layout; two notes => forced, one note stays pending
//       func forcesSwitch(_ word: String, from layout: Layout) -> Bool   // case-insensitive
//       func dropForcedSwitch(word: String, layout: Layout)   // removes pending and learned forced entries
//       // noteKept for the same word and layout also removes any forced entry;
//       // reset() clears forced entries and pending manual-swap counts too.
//     }
//   Babbler/AutoSwitchEngine.swift
//     matchTier(word:currentLayout:) returns .exact for a word forced from currentLayout, even when
//     no dictionary contains it, and even when it is a real word in currentLayout (forced wins).
//     looksLikeCodeOrAddress still returns nil for URLs and emails, forced or not.
//
// Store keys are treated as opaque. The URL/email cases derive a store key from a real forced entry
// (by substituting the word), because isValidWord rejects URLs and emails through the public API.

let resources = ProcessInfo.processInfo.environment["BABBLER_RESOURCES"]
  ?? FileManager.default.currentDirectoryPath + "/Babbler/Resources"

var failures = 0
var checkCount = 0
func check(_ passed: Bool, _ message: String) {
  checkCount += 1
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

// Same dictionary setup as tests/LexiconTests.swift.
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
  var forcedPending: [String: Int] = [:]
  var forced: [String] = []
  func userLexiconKeeps() -> [String: Int] { keeps }
  func setUserLexiconKeeps(_ keeps: [String: Int]) { self.keeps = keeps }
  func userLexiconLearned() -> [String] { learned }
  func setUserLexiconLearned(_ entries: [String]) { learned = entries }
  func userLexiconForcedPending() -> [String: Int] { forcedPending }
  func setUserLexiconForcedPending(_ pending: [String: Int]) { forcedPending = pending }
  func userLexiconForced() -> [String] { forced }
  func setUserLexiconForced(_ entries: [String]) { forced = entries }
}

func freshLexicon() -> (lexicon: UserLexicon, store: FakeUserLexiconStore) {
  let store = FakeUserLexiconStore()
  return (UserLexicon(store: store), store)
}

// MARK: - Promotion

print("=== two manual swaps force a switch, one stays pending")
let (mOne, mOneStore) = freshLexicon()
mOne.noteManualSwap(word: "ckfdf", layout: .english)
check(!mOne.forcesSwitch("ckfdf", from: .english), "one manual swap must not force ckfdf")
check(mOne.forcedCount == 0, "one manual swap must leave forcedCount at 0, got \(mOne.forcedCount)")
check(!mOneStore.userLexiconForcedPending().isEmpty, "one manual swap must persist a pending count")
check(mOneStore.userLexiconForced().isEmpty, "one manual swap must not persist a learned forced entry")
mOne.noteManualSwap(word: "ckfdf", layout: .english)
check(mOne.forcesSwitch("ckfdf", from: .english), "second manual swap must force ckfdf")
check(mOne.forcedCount == 1, "a promoted forced switch must count once, got \(mOne.forcedCount)")
check(mOneStore.userLexiconForced().count == 1, "a promoted forced switch must be written to the store")

print("=== forced switch is case-insensitive")
let (mCase, _) = freshLexicon()
mCase.noteManualSwap(word: "CkFdf", layout: .english)
mCase.noteManualSwap(word: "ckfdf", layout: .english)
check(mCase.forcesSwitch("CKFDF", from: .english),
      "manual swaps differing only in case must count together, and forcesSwitch must ignore case")

print("=== forced switch is isolated per layout")
let (mLay, _) = freshLexicon()
mLay.noteManualSwap(word: "ghbdtn", layout: .russian)
mLay.noteManualSwap(word: "ghbdtn", layout: .russian)
check(mLay.forcesSwitch("ghbdtn", from: .russian), "two RU manual swaps must force from RU")
check(!mLay.forcesSwitch("ghbdtn", from: .english),
      "a RU-layout force must not apply to the same keys typed in EN")
let (mLay2, _) = freshLexicon()
mLay2.noteManualSwap(word: "ckfdf", layout: .english)
mLay2.noteManualSwap(word: "ckfdf", layout: .russian)
check(!mLay2.forcesSwitch("ckfdf", from: .english) && mLay2.forcedCount == 0,
      "one manual swap in each layout must not combine into a force")

print("=== invalid words are ignored")
let (mValid, mValidStore) = freshLexicon()
let invalidSwaps: [(word: String, layout: Layout)] = [
  ("a", .english), ("я", .russian), ("ab1", .english), ("abc123", .english),
  ("x=y", .english), ("foo_bar", .english), ("a/b", .english),
]
for (word, layout) in invalidSwaps {
  mValid.noteManualSwap(word: word, layout: layout)
  mValid.noteManualSwap(word: word, layout: layout)
  check(!mValid.forcesSwitch(word, from: layout), "\(word) must be ignored by noteManualSwap")
}
check(mValid.forcedCount == 0 && mValidStore.userLexiconForced().isEmpty,
      "invalid words must not be forced")
check(mValidStore.userLexiconForcedPending().isEmpty, "invalid words must not leave pending counts")

// MARK: - Disabled lexicon

print("=== disabled lexicon ignores manual swaps")
let disabledKey = userLexiconEnabledKey
UserDefaults.standard.set(false, forKey: disabledKey)
let (mOff, mOffStore) = freshLexicon()
mOff.noteManualSwap(word: "ckfdf", layout: .english)
mOff.noteManualSwap(word: "ckfdf", layout: .english)
check(!mOff.forcesSwitch("ckfdf", from: .english), "manual swaps must not force while the lexicon is disabled")
check(mOff.forcedCount == 0 && mOffStore.userLexiconForced().isEmpty,
      "manual swaps while disabled must not persist a forced entry")
check(mOffStore.userLexiconForcedPending().isEmpty, "manual swaps while disabled must not leave pending counts")
UserDefaults.standard.removeObject(forKey: disabledKey)
check(UserLexicon.isEnabled(), "removing the stored preference must restore the enabled default")
mOff.noteManualSwap(word: "ckfdf", layout: .english)
check(!mOff.forcesSwitch("ckfdf", from: .english),
      "a swap made while disabled must not count towards a later promotion")

// MARK: - Interaction with keeps

print("=== manual swap removes a learned keep for the same layout")
let (mKeep, _) = freshLexicon()
mKeep.noteKept(word: "xfce", layout: .english)
mKeep.noteKept(word: "xfce", layout: .english)
check(mKeep.contains("xfce", in: .english), "precondition: xfce must be learned")
mKeep.noteManualSwap(word: "xfce", layout: .english)
check(!mKeep.contains("xfce", in: .english), "a manual swap must remove the learned keep for that layout")

print("=== manual swap removes a pending keep")
let (mPend, _) = freshLexicon()
mPend.noteKept(word: "ckfdf", layout: .english)
mPend.noteManualSwap(word: "ckfdf", layout: .english)
mPend.noteKept(word: "ckfdf", layout: .english)
check(!mPend.contains("ckfdf", in: .english),
      "a pending keep cleared by a manual swap must not combine with a later keep to promote")

print("=== keep cancels a forced switch")
let (mKF, mKFStore) = freshLexicon()
mKF.noteManualSwap(word: "ckfdf", layout: .english)
mKF.noteManualSwap(word: "ckfdf", layout: .english)
check(mKF.forcesSwitch("ckfdf", from: .english), "precondition: ckfdf must be forced")
mKF.noteKept(word: "ckfdf", layout: .english)
check(!mKF.forcesSwitch("ckfdf", from: .english), "a keep for the same word and layout must cancel the forced switch")
check(mKF.forcedCount == 0 && mKFStore.userLexiconForced().isEmpty,
      "cancelling a forced switch by keeping must clear the learned entry from the store")

// MARK: - Dropping a forced switch

print("=== dropForcedSwitch removes a learned forced switch for one layout")
let (mDrop, mDropStore) = freshLexicon()
mDrop.noteManualSwap(word: "ckfdf", layout: .english)
mDrop.noteManualSwap(word: "ckfdf", layout: .english)
mDrop.noteManualSwap(word: "ghbdtn", layout: .russian)
mDrop.noteManualSwap(word: "ghbdtn", layout: .russian)
mDrop.dropForcedSwitch(word: "CKFDF", layout: .english)
check(!mDrop.forcesSwitch("ckfdf", from: .english), "dropForcedSwitch must remove the forced switch (case-insensitive)")
check(mDrop.forcedCount == 1, "dropForcedSwitch must decrement forcedCount, got \(mDrop.forcedCount)")
check(!mDropStore.userLexiconForced().contains { $0.hasSuffix("ckfdf") },
      "dropForcedSwitch must clear the learned entry from the store")
check(mDrop.forcesSwitch("ghbdtn", from: .russian), "dropForcedSwitch in EN must not touch the RU forced switch")

print("=== dropForcedSwitch removes a pending swap count")
let (mDropP, _) = freshLexicon()
mDropP.noteManualSwap(word: "qwzxv", layout: .english)
mDropP.dropForcedSwitch(word: "qwzxv", layout: .english)
mDropP.noteManualSwap(word: "qwzxv", layout: .english)
check(!mDropP.forcesSwitch("qwzxv", from: .english),
      "after a drop, one new swap must not force: the pending count must be gone")

// MARK: - Reset

print("=== reset clears forced entries and pending counts")
let (mRes, mResStore) = freshLexicon()
mRes.noteManualSwap(word: "ckfdf", layout: .english)
mRes.noteManualSwap(word: "ckfdf", layout: .english)
mRes.noteManualSwap(word: "qwzxv", layout: .english)
mRes.reset()
check(mRes.forcedCount == 0, "reset must clear forced switches, got \(mRes.forcedCount)")
check(!mRes.forcesSwitch("ckfdf", from: .english), "reset must forget forced switches")
check(mResStore.userLexiconForced().isEmpty, "reset must clear the store's forced entries")
check(mResStore.userLexiconForcedPending().isEmpty, "reset must clear the store's pending manual-swap counts")
mRes.noteManualSwap(word: "qwzxv", layout: .english)
check(!mRes.forcesSwitch("qwzxv", from: .english), "reset must also clear pending manual-swap counts")

// MARK: - Persistence round-trip

print("=== persistence round-trip")
let storeRT = FakeUserLexiconStore()
let writerRT = UserLexicon(store: storeRT)
writerRT.noteManualSwap(word: "ckfdf", layout: .english)
let midRT = UserLexicon(store: storeRT)
midRT.noteManualSwap(word: "ckfdf", layout: .english)
check(midRT.forcesSwitch("ckfdf", from: .english),
      "pending manual-swap counts must persist: a swap from a new instance must complete the promotion")
let readerRT = UserLexicon(store: storeRT)
check(readerRT.forcesSwitch("ckfdf", from: .english), "a forced switch must survive re-initialisation")
check(readerRT.forcedCount == 1, "forcedCount must survive re-initialisation, got \(readerRT.forcedCount)")

// MARK: - Engine decisions

print("=== engine: forced non-dictionary word")
AutoSwitchEngine.userLexicon = nil
check(AutoSwitchEngine.matchTier(word: "gjzqr", currentLayout: .english) == nil,
      "precondition: gjzqr must not be switched without a force")
check(AutoSwitchEngine.matchTier(word: "hello", currentLayout: .english) == nil,
      "precondition: hello must be kept without a force")

let (mE, _) = freshLexicon()
mE.noteManualSwap(word: "gjzqr", layout: .english)
mE.noteManualSwap(word: "gjzqr", layout: .english)
AutoSwitchEngine.userLexicon = mE
check(AutoSwitchEngine.matchTier(word: "gjzqr", currentLayout: .english) == .exact,
      "a forced non-dictionary word typed in its layout must be an exact match")
check(AutoSwitchEngine.evaluate(word: "gjzqr", currentLayout: .english) == .switchLayout,
      "a forced non-dictionary word must switch")

print("=== engine: forced word that is a real word in its layout")
mE.noteManualSwap(word: "hello", layout: .english)
mE.noteManualSwap(word: "hello", layout: .english)
check(AutoSwitchEngine.matchTier(word: "hello", currentLayout: .english) == .exact,
      "a forced dictionary word in its own layout must switch: forced wins over the dictionary")

print("=== engine: forced URLs and emails stay untouched")
let keySource = FakeUserLexiconStore()
let lexKeySource = UserLexicon(store: keySource)
lexKeySource.noteManualSwap(word: "ckfdf", layout: .english)
lexKeySource.noteManualSwap(word: "ckfdf", layout: .english)
let sampleKey = keySource.forced.first ?? "ckfdf"
func storeKey(for word: String) -> String { sampleKey.replacingOccurrences(of: "ckfdf", with: word) }
let storeURL = FakeUserLexiconStore()
storeURL.forced = [storeKey(for: "ckfdf"), storeKey(for: "www.ckfdf"), storeKey(for: "a@b.co")]
let lexURL = UserLexicon(store: storeURL)
AutoSwitchEngine.userLexicon = lexURL
check(AutoSwitchEngine.matchTier(word: "ckfdf", currentLayout: .english) == .exact,
      "control: a forced entry seeded in the store must switch ckfdf, so the URL checks below are meaningful")
check(AutoSwitchEngine.matchTier(word: "www.ckfdf", currentLayout: .english) == nil,
      "a forced www. address must still be left alone")
check(AutoSwitchEngine.matchTier(word: "a@b.co", currentLayout: .english) == nil,
      "a forced email address must still be left alone")

print("=== engine: unforced words match the no-lexicon baseline")
let unforcedProbes: [(word: String, layout: Layout)] = [
  ("hello", .english), ("ckfdf", .english), ("xfce", .english), ("ghbdtn", .russian),
  ("привет", .russian), ("rfr", .english), ("www.ckfdf", .english), ("a@b.co", .english),
]
AutoSwitchEngine.userLexicon = nil
let baseline = unforcedProbes.map { AutoSwitchEngine.matchTier(word: $0.word, currentLayout: $0.layout) }
let (mU, _) = freshLexicon()
mU.noteManualSwap(word: "ckfdf", layout: .english)
AutoSwitchEngine.userLexicon = mU
for (index, probe) in unforcedProbes.enumerated() {
  check(AutoSwitchEngine.matchTier(word: probe.word, currentLayout: probe.layout) == baseline[index],
        "\(probe.word) must keep its baseline decision when only a single manual swap is recorded")
}

print("=== engine: dropped and cancelled forces revert")
AutoSwitchEngine.userLexicon = mE
check(AutoSwitchEngine.matchTier(word: "gjzqr", currentLayout: .english) == .exact,
      "precondition: gjzqr must be forced in the engine")
mE.dropForcedSwitch(word: "gjzqr", layout: .english)
check(AutoSwitchEngine.matchTier(word: "gjzqr", currentLayout: .english) == nil,
      "after dropForcedSwitch the engine must stop switching gjzqr")
mE.noteManualSwap(word: "gjzqr", layout: .english)
mE.noteManualSwap(word: "gjzqr", layout: .english)
check(AutoSwitchEngine.matchTier(word: "gjzqr", currentLayout: .english) == .exact,
      "re-forcing after a drop must work in the engine")
mE.noteKept(word: "gjzqr", layout: .english)
check(AutoSwitchEngine.matchTier(word: "gjzqr", currentLayout: .english) == nil,
      "a keep after a force must stop the engine switching gjzqr")
AutoSwitchEngine.userLexicon = nil

print("=== engine: no lexicon")
check(AutoSwitchEngine.matchTier(word: "gjzqr", currentLayout: .english) == nil,
      "with the lexicon removed, gjzqr must return to the baseline keep")

if failures == 0 {
  print("ALL LEARN-SWAP CHECKS PASS (\(checkCount) checks)")
} else {
  print("\(failures) of \(checkCount) LEARN-SWAP CHECKS FAILED")
  exit(1)
}
