import Foundation

/// Persistence used by `UserLexicon`. A protocol so the tests can drive it
/// against an in-memory fake instead of the real `UserDefaults` — same split as
/// `AutoSwitchMemoryStore`.
protocol UserLexiconStore: AnyObject {
  func userLexiconKeeps() -> [String: Int]
  func setUserLexiconKeeps(_ keeps: [String: Int])
  func userLexiconLearned() -> [String]
  func setUserLexiconLearned(_ entries: [String])
  func userLexiconForcedPending() -> [String: Int]
  func setUserLexiconForcedPending(_ pending: [String: Int])
  func userLexiconForced() -> [String]
  func setUserLexiconForced(_ entries: [String])
}

/// Learns words the user keeps typing in a layout that are not in the built-in
/// dictionaries, so recurring jargon, names and brands stop being flagged as
/// typos of the other layout.
///
/// A word is tracked per layout: the same keystrokes mean different things typed
/// on each one, so "kept in English" and "kept in Russian" are independent. Two
/// keeps promote a word to learned; `contains` then reports it like a
/// dictionary word. `importSpelling` learns words immediately, without going
/// through the keep count, since a word already in the system spelling file is
/// already known-good.
final class UserLexicon {
  /// Keeps needed before a word is promoted to learned.
  static let promoteThreshold = 2
  /// Upper bound on learned entries; the oldest are evicted first.
  static let maxEntries = 5000
  /// Upper bound on pending keep counts; the oldest are evicted first.
  static let maxPending = 5000
  /// Upper bound on learned forced-switch entries; the oldest are evicted first.
  static let maxForcedEntries = 5000
  /// Upper bound on pending manual-swap counts; the oldest are evicted first.
  static let maxForcedPending = 5000

  private let store: UserLexiconStore
  // Keyed by a composite "layout:word" string so the same letters typed in
  // different layouts are tracked independently.
  private var keepCounts: [String: Int]
  // Keys of keepCounts, oldest first. Not persisted: after a relaunch it is
  // seeded in sorted order, so eviction is deterministic but not strictly oldest.
  private var pendingOrder: [String]
  // Composite keys, oldest first; drives both membership and eviction order.
  private var learned: [String]
  private var learnedSet: Set<String>
  // Manual-swap counts not yet promoted to a forced switch. Same composite-key
  // scheme and eviction strategy as keepCounts/pendingOrder.
  private var forcedPendingCounts: [String: Int]
  private var forcedPendingOrder: [String]
  // Learned forced-switch entries, oldest first.
  private var forced: [String]
  private var forcedSet: Set<String>

  init(store: UserLexiconStore) {
    self.store = store
    self.keepCounts = store.userLexiconKeeps()
    self.pendingOrder = keepCounts.keys.sorted()
    self.learned = store.userLexiconLearned()
    self.learnedSet = Set(learned)
    self.forcedPendingCounts = store.userLexiconForcedPending()
    self.forcedPendingOrder = forcedPendingCounts.keys.sorted()
    self.forced = store.userLexiconForced()
    self.forcedSet = Set(forced)
  }

  /// Reads `userLexiconEnabledKey` (PreferenceStore.swift); absent means on.
  static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    if defaults.object(forKey: userLexiconEnabledKey) == nil { return true }
    return defaults.bool(forKey: userLexiconEnabledKey)
  }

  var learnedCount: Int { learned.count }
  /// Learned forced-switch entries (not pending).
  var forcedCount: Int { forced.count }

  /// Case-insensitive membership test for a word in a layout.
  func contains(_ word: String, in layout: Layout) -> Bool {
    learnedSet.contains(compositeKey(word, layout))
  }

  /// Case-insensitive test for whether `word` typed in `layout` has been
  /// learned as a manual swap: the user keeps correcting it to the other
  /// layout, so the engine should switch it even when it is a real word
  /// where it stands, or in no dictionary at all.
  func forcesSwitch(_ word: String, from layout: Layout) -> Bool {
    forcedSet.contains(compositeKey(word, layout))
  }

  /// A word was typed in `layout`, reached a word boundary, and was not
  /// corrected. Counts towards promotion; invalid words are ignored. Also
  /// cancels any forced switch learned for the same word and layout — the
  /// user keeping it is evidence it should not be auto-switched any more.
  func noteKept(word: String, layout: Layout) {
    guard Self.isValidWord(word) else { return }
    let key = compositeKey(word, layout)
    removeForcedEntry(key)
    guard !learnedSet.contains(key) else { return }

    let count = (keepCounts[key] ?? 0) + 1
    if count >= Self.promoteThreshold {
      removePending(key)
      promote(key)
    } else {
      if keepCounts[key] == nil { addPending(key) }
      keepCounts[key] = count
    }
    store.setUserLexiconKeeps(keepCounts)
    store.setUserLexiconLearned(learned)
  }

  /// The user manually swapped `word` out of `layout` with the action key, so
  /// it is not a word they want kept. Drops its pending count and its learned
  /// entry for that layout only. A no-op for unknown words.
  func forget(word: String, layout: Layout) {
    removeKeepEntry(compositeKey(word, layout))
  }

  /// The user manually swapped `word` out of `layout` with the action key —
  /// a stronger, opposite signal from `noteKept`: this spelling, in this
  /// layout, is not what they meant. Counts towards forcing an auto-switch;
  /// invalid words and a disabled lexicon are ignored. Also clears any keep
  /// learned for the same word and layout, since the two signals contradict
  /// each other and the more recent one wins.
  func noteManualSwap(word: String, layout: Layout) {
    guard Self.isEnabled() else { return }
    guard Self.isValidWord(word) else { return }
    let key = compositeKey(word, layout)
    removeKeepEntry(key)
    guard !forcedSet.contains(key) else { return }

    let count = (forcedPendingCounts[key] ?? 0) + 1
    if count >= Self.promoteThreshold {
      removeForcedPending(key)
      promoteForced(key)
    } else {
      if forcedPendingCounts[key] == nil { addForcedPending(key) }
      forcedPendingCounts[key] = count
    }
    store.setUserLexiconForcedPending(forcedPendingCounts)
    store.setUserLexiconForced(forced)
  }

  /// Removes a learned or pending forced switch for `word` in `layout`. Used
  /// when an auto-switch the user forced is then undone, so the same mistake
  /// does not immediately re-force itself.
  func dropForcedSwitch(word: String, layout: Layout) {
    removeForcedEntry(compositeKey(word, layout))
  }

  /// Imports a newline-separated spelling file (LF or CRLF). Cyrillic lines are
  /// learned as Russian, Latin lines as English; anything else (mixed script,
  /// digits, too short) is ignored. Imported words are known immediately — no
  /// keep count needed, since the file is itself evidence they are real words.
  func importSpelling(from url: URL) {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8) else { return }

    var didChange = false
    text.enumerateLines { line, _ in
      let word = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !word.isEmpty, Self.isValidWord(word),
            let layout = Self.scriptLayout(of: word) else { return }
      let key = self.compositeKey(word, layout)
      guard !self.learnedSet.contains(key) else { return }
      self.removePending(key)
      self.promote(key)
      didChange = true
    }

    guard didChange else { return }
    store.setUserLexiconKeeps(keepCounts)
    store.setUserLexiconLearned(learned)
  }

  /// Clears every learned word and keep count, and every forced switch and
  /// pending manual-swap count.
  func reset() {
    keepCounts = [:]
    pendingOrder = []
    learned = []
    learnedSet = []
    forcedPendingCounts = [:]
    forcedPendingOrder = []
    forced = []
    forcedSet = []
    store.setUserLexiconKeeps(keepCounts)
    store.setUserLexiconLearned(learned)
    store.setUserLexiconForcedPending(forcedPendingCounts)
    store.setUserLexiconForced(forced)
  }

  // MARK: - Helpers

  private func compositeKey(_ word: String, _ layout: Layout) -> String {
    "\(layout == .english ? "en" : "ru"):\(word.lowercased())"
  }

  /// Starts tracking a new pending key, evicting the oldest pending keys first
  /// so the count stays within `maxPending`.
  private func addPending(_ key: String) {
    while pendingOrder.count >= Self.maxPending, let oldest = pendingOrder.first {
      pendingOrder.removeFirst()
      keepCounts.removeValue(forKey: oldest)
    }
    pendingOrder.append(key)
  }

  private func removePending(_ key: String) {
    keepCounts.removeValue(forKey: key)
    pendingOrder.removeAll { $0 == key }
  }

  /// Appends a newly learned key, evicting the oldest entry once the cap is
  /// exceeded. A no-op if the key is already learned.
  private func promote(_ key: String) {
    guard !learnedSet.contains(key) else { return }
    learned.append(key)
    learnedSet.insert(key)
    if learned.count > Self.maxEntries {
      let evicted = learned.removeFirst()
      learnedSet.remove(evicted)
    }
  }

  /// Removes any pending keep count and any learned keep for `key`, the same
  /// logic `forget` and `noteManualSwap` both need. A no-op if neither exists.
  private func removeKeepEntry(_ key: String) {
    let hadPending = keepCounts[key] != nil
    let wasLearned = learnedSet.contains(key)
    guard hadPending || wasLearned else { return }

    if hadPending { removePending(key) }
    if wasLearned {
      learned.removeAll { $0 == key }
      learnedSet.remove(key)
    }
    store.setUserLexiconKeeps(keepCounts)
    store.setUserLexiconLearned(learned)
  }

  /// Starts tracking a new pending manual-swap key, evicting the oldest
  /// pending keys first so the count stays within `maxForcedPending`.
  private func addForcedPending(_ key: String) {
    while forcedPendingOrder.count >= Self.maxForcedPending, let oldest = forcedPendingOrder.first {
      forcedPendingOrder.removeFirst()
      forcedPendingCounts.removeValue(forKey: oldest)
    }
    forcedPendingOrder.append(key)
  }

  private func removeForcedPending(_ key: String) {
    forcedPendingCounts.removeValue(forKey: key)
    forcedPendingOrder.removeAll { $0 == key }
  }

  /// Appends a newly forced key, evicting the oldest entry once the cap is
  /// exceeded. A no-op if the key is already forced.
  private func promoteForced(_ key: String) {
    guard !forcedSet.contains(key) else { return }
    forced.append(key)
    forcedSet.insert(key)
    if forced.count > Self.maxForcedEntries {
      let evicted = forced.removeFirst()
      forcedSet.remove(evicted)
    }
  }

  /// Removes any pending manual-swap count and any learned forced switch for
  /// `key`. A no-op if neither exists.
  private func removeForcedEntry(_ key: String) {
    let hadPending = forcedPendingCounts[key] != nil
    let wasForced = forcedSet.contains(key)
    guard hadPending || wasForced else { return }

    if hadPending { removeForcedPending(key) }
    if wasForced {
      forced.removeAll { $0 == key }
      forcedSet.remove(key)
    }
    store.setUserLexiconForcedPending(forcedPendingCounts)
    store.setUserLexiconForced(forced)
  }

  /// Short words are too ambiguous to judge, and a word with a digit or a
  /// character that never forms part of either language's spelling is an
  /// identifier, not prose — so requiring every character to be a letter
  /// covers both rules at once.
  private static func isValidWord(_ word: String) -> Bool {
    word.count >= 2 && word.allSatisfy { $0.isLetter }
  }

  /// Which layout `word` is written in, judged purely from its script: ASCII
  /// Latin letters only => English, Cyrillic letters only => Russian. A word
  /// mixing the two, or using letters from neither alphabet, is ambiguous and
  /// returns nil.
  private static func scriptLayout(of word: String) -> Layout? {
    var hasCyrillic = false
    var hasLatin = false
    for scalar in word.unicodeScalars {
      switch scalar.value {
      case 0x0400...0x04FF: hasCyrillic = true
      case 0x0041...0x005A, 0x0061...0x007A: hasLatin = true
      default: return nil
      }
    }
    if hasCyrillic == hasLatin { return nil }  // both or neither
    return hasCyrillic ? .russian : .english
  }
}

extension PreferenceStore: UserLexiconStore {
  /// Keep counts per composite "layout:word" key, not yet promoted to learned.
  func userLexiconKeeps() -> [String: Int] {
    (defaults.dictionary(forKey: userLexiconKeepsKey) as? [String: Int]) ?? [:]
  }

  func setUserLexiconKeeps(_ keeps: [String: Int]) {
    defaults.set(keeps, forKey: userLexiconKeepsKey)
  }

  /// Learned composite keys, oldest first.
  func userLexiconLearned() -> [String] {
    defaults.stringArray(forKey: userLexiconLearnedKey) ?? []
  }

  func setUserLexiconLearned(_ entries: [String]) {
    defaults.set(entries, forKey: userLexiconLearnedKey)
  }

  /// Manual-swap counts per composite "layout:word" key, not yet promoted to
  /// a forced switch.
  func userLexiconForcedPending() -> [String: Int] {
    (defaults.dictionary(forKey: userLexiconForcedPendingKey) as? [String: Int]) ?? [:]
  }

  func setUserLexiconForcedPending(_ pending: [String: Int]) {
    defaults.set(pending, forKey: userLexiconForcedPendingKey)
  }

  /// Learned forced-switch composite keys, oldest first.
  func userLexiconForced() -> [String] {
    defaults.stringArray(forKey: userLexiconForcedKey) ?? []
  }

  func setUserLexiconForced(_ entries: [String]) {
    defaults.set(entries, forKey: userLexiconForcedKey)
  }
}

private let userLexiconKeepsKey = "userLexiconKeeps"
private let userLexiconLearnedKey = "userLexiconLearned"
private let userLexiconForcedPendingKey = "userLexiconForcedPending"
private let userLexiconForcedKey = "userLexiconForced"

/// The lexicon the engine checks. Lives here rather than in AutoSwitchEngine so
/// that engine builds without this file (the dictionary test harness) still
/// compile — same reasoning as `AutoSwitchEngine.themePacks` in ThemePacks.swift.
extension AutoSwitchEngine {
  static var userLexicon: UserLexicon? {
    get { UserLexiconEngineStorage.lexicon }
    set {
      UserLexiconEngineStorage.lexicon = newValue
      let contains: ((String, Layout) -> Bool)? = newValue.map { lexicon in
        { word, layout in lexicon.contains(word, in: layout) }
      }
      userLexiconContains = contains
      let forces: ((String, Layout) -> Bool)? = newValue.map { lexicon in
        { word, layout in lexicon.forcesSwitch(word, from: layout) }
      }
      userLexiconForces = forces
    }
  }
}

private enum UserLexiconEngineStorage {
  static var lexicon: UserLexicon?
}

/// Shared by Settings and AppDelegate; owns persisted state that must not be duplicated.
let userLexicon = UserLexicon(store: preferenceStore)
