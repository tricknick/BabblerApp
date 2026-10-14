import Foundation

/// Persistence used by `UserLexicon`. A protocol so the tests can drive it
/// against an in-memory fake instead of the real `UserDefaults` — same split as
/// `AutoSwitchMemoryStore`.
protocol UserLexiconStore: AnyObject {
  func userLexiconKeeps() -> [String: Int]
  func setUserLexiconKeeps(_ keeps: [String: Int])
  func userLexiconLearned() -> [String]
  func setUserLexiconLearned(_ entries: [String])
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

  init(store: UserLexiconStore) {
    self.store = store
    self.keepCounts = store.userLexiconKeeps()
    self.pendingOrder = keepCounts.keys.sorted()
    self.learned = store.userLexiconLearned()
    self.learnedSet = Set(learned)
  }

  /// Reads `userLexiconEnabledKey` (PreferenceStore.swift); absent means on.
  static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    if defaults.object(forKey: userLexiconEnabledKey) == nil { return true }
    return defaults.bool(forKey: userLexiconEnabledKey)
  }

  var learnedCount: Int { learned.count }

  /// Case-insensitive membership test for a word in a layout.
  func contains(_ word: String, in layout: Layout) -> Bool {
    learnedSet.contains(compositeKey(word, layout))
  }

  /// A word was typed in `layout`, reached a word boundary, and was not
  /// corrected. Counts towards promotion; invalid words are ignored.
  func noteKept(word: String, layout: Layout) {
    guard Self.isValidWord(word) else { return }
    let key = compositeKey(word, layout)
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
    let key = compositeKey(word, layout)
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

  /// Clears every learned word and keep count.
  func reset() {
    keepCounts = [:]
    pendingOrder = []
    learned = []
    learnedSet = []
    store.setUserLexiconKeeps(keepCounts)
    store.setUserLexiconLearned(learned)
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
}

private let userLexiconKeepsKey = "userLexiconKeeps"
private let userLexiconLearnedKey = "userLexiconLearned"

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
    }
  }
}

private enum UserLexiconEngineStorage {
  static var lexicon: UserLexicon?
}

/// Shared by Settings and AppDelegate; owns persisted state that must not be duplicated.
let userLexicon = UserLexicon(store: preferenceStore)
