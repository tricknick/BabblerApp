import AppKit

/// Abstraction over a system/local spell-checking service, so `AutoSwitchEngine`
/// can ask "is this word known?" without depending on `NSSpellChecker` directly.
/// Tests substitute a deterministic fake; `SystemSpellOracle` below is the real
/// one, wired into the engine through `AutoSwitchEngine.spellOracle`.
protocol SpellOracle {
  /// Whether `word` is a recognised word in `language`. An implementation must
  /// answer `false` rather than guess when it cannot judge — an unavailable
  /// language, a thread it is unsafe to call from — so the caller's tier stays
  /// inert instead of acting on uncertain evidence.
  func isKnown(_ word: String, language: Layout) -> Bool
}

/// `NSSpellChecker`-backed oracle. Needs no new entitlement or permission: it is
/// the same local, in-process/XPC spell-check service every Cocoa text view
/// already uses, not a network lookup.
///
/// `NSSpellChecker` (`checkSpelling(of:startingAt:language:wrap:inSpellDocumentWithTag:wordCount:)`)
/// is not thread-safe — same rule as the Carbon TIS calls in `InputSourceUtils`
/// (see CLAUDE.md "Threading"). `AutoSwitchEngine.matchTier` runs on the main
/// thread (the global event monitor dispatches there before invoking its
/// callback; see `KeyboardUtils.addGlobalEventListener`), so `isKnown` only
/// asserts that with a cheap guard: an accidental off-main call degrades to an
/// inert tier rather than corrupting `NSSpellChecker`'s internal state or
/// blocking on a synchronous hop to the main queue.
final class SystemSpellOracle: SpellOracle {
  /// The two-letter language tags `NSSpellChecker` accepts for the layouts this
  /// app supports.
  private static let languageTag: [Layout: String] = [.english: "en", .russian: "ru"]

  private let checker: NSSpellChecker
  private let availableLanguages: Set<String>
  private let cache = NSCache<NSString, NSNumber>()

  /// `availableLanguagesOverride` exists only so tests can simulate a language
  /// not being installed without depending on what is actually installed on the
  /// machine running them; production call sites always omit it.
  init(checker: NSSpellChecker = .shared, cacheLimit: Int = 5000, availableLanguagesOverride: Set<String>? = nil) {
    self.checker = checker
    self.availableLanguages = availableLanguagesOverride ?? Set(checker.availableLanguages)
    cache.countLimit = cacheLimit
  }

  func isKnown(_ word: String, language: Layout) -> Bool {
    guard Thread.isMainThread else { return false }
    guard let tag = Self.languageTag[language], availableLanguages.contains(tag) else { return false }
    let key = "\(tag):\(word)" as NSString
    if let cached = cache.object(forKey: key) { return cached.boolValue }
    let misspelledRange = checker.checkSpelling(
      of: word, startingAt: 0, language: tag, wrap: false,
      inSpellDocumentWithTag: 0, wordCount: nil
    )
    let known = misspelledRange.location == NSNotFound
    cache.setObject(NSNumber(value: known), forKey: key)
    return known
  }
}

/// Wires a `SpellOracle` into the engine. Lives here, not in AutoSwitchEngine.swift,
/// so builds of the engine without this file (the dictionary test harnesses) still
/// compile — same reasoning as `AutoSwitchEngine.themePacks` in ThemePacks.swift.
extension AutoSwitchEngine {
  static var spellOracle: SpellOracle? {
    get { SpellOracleStore.oracle }
    set {
      SpellOracleStore.oracle = newValue
      spellOracleIsKnown = newValue.map { oracle in { word, layout in oracle.isKnown(word, language: layout) } }
    }
  }
}

private enum SpellOracleStore {
  static var oracle: SpellOracle?
}
