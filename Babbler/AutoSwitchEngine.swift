import Foundation

/// Decides whether a word that was just typed should be rewritten in the other
/// keyboard layout.
///
/// The rule is deliberately conservative: it only fires when the typed text is
/// *not* a word in the current layout and *is* a word in the other one. A false
/// positive mangles correct text and is far more annoying than a missed
/// correction, so anything ambiguous is left alone.
enum AutoSwitchEngine {

  enum Decision: Equatable {
    case keep
    case switchLayout
  }

  /// Characters that never form part of a word in either layout, so seeing one
  /// means this is an identifier, email, URL, path or code — not prose.
  ///
  /// Note what is deliberately *absent*: `, . ; ' [ ]` and backtick. Those are
  /// produced by the keys carrying б ю ж э х ъ, so a Russian word typed on the
  /// English layout is full of them — "rjvgm.nth" is "компьютер". Rejecting them
  /// here would blind the engine to the most common case it exists to fix.
  private static let disqualifyingCharacters = CharacterSet(
    charactersIn: "@/\\_+-=#$%^&*(){}|:\"<>~"
  )

  /// Punctuation safe to strip from the ends of a word. Excludes the
  /// layout-bearing characters above, so a word starting with б or ending in ю
  /// survives intact.
  private static let trimmableCharacters = CharacterSet(charactersIn: "!?()\"«»…—")

  /// Sentence punctuation that is also a Russian letter on the English layout:
  /// `,` is б, `.` is ю, `;` is ж, `'` is э. When one of these ends a typed run
  /// the reading is genuinely ambiguous — "ndj." is "твою", but "it." is just
  /// "it" followed by a full stop.
  private static let ambiguousTrailingCharacters = CharacterSet(charactersIn: ",.;'")

  /// Which rule decided to switch, strongest evidence first.
  enum Tier: Equatable {
    /// The conversion is a word in the other layout's dictionary.
    case exact
    /// The conversion is a word with one keystroke missing.
    case typo
    /// Neither form is a word anywhere, but the conversion reads like the other
    /// language and the typed form does not read like this one.
    case languageModel
  }

  static func evaluate(
    word rawWord: String,
    currentLayout: Layout,
    dictionary: LayoutDictionary = .shared
  ) -> Decision {
    matchTier(word: rawWord, currentLayout: currentLayout, dictionary: dictionary) == nil
      ? .keep
      : .switchLayout
  }

  /// The tier that would switch `rawWord`, or nil if it is left alone.
  static func matchTier(
    word rawWord: String,
    currentLayout: Layout,
    dictionary: LayoutDictionary = .shared
  ) -> Tier? {
    guard dictionary.isReady else { return nil }

    let trimmed = rawWord.trimmingCharacters(in: trimmableCharacters)
    guard isEligible(trimmed), !looksLikeCodeOrAddress(trimmed) else { return nil }

    let word = trimmed.lowercased()

    // Already a real word where it stands — leave it alone.
    if dictionary.contains(word, in: currentLayout) { return nil }

    let converted = convert(word, to: currentLayout.other)
    guard converted != word else { return nil }

    // The candidate must be a plain run of letters in the target layout.
    // Anything else means these keys do not spell a word over there.
    guard converted.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil else {
      return nil
    }

    // Theme-pack forms are checked before the trailing-punctuation rule below:
    // "ye," is the English "ye" plus a comma, but it types "нуб".
    if isThemePackHit(converted, target: currentLayout.other) { return .exact }

    // "it." is a real word plus a full stop; "ndj." is the Russian "твою". Tell
    // them apart by asking whether dropping the trailing punctuation leaves a
    // word in the layout the user is already using.
    if hasAmbiguousTrailing(word), dictionary.contains(stem(of: word), in: currentLayout) {
      return nil
    }

    if dictionary.contains(converted, in: currentLayout.other) { return .exact }

    // Last resort: the user typed a real word in the other layout but missed a
    // keystroke, so "ghdtn" is "првет" — obviously Russian, but not a word.
    //
    // The match only informs the decision. The replacement is still built from
    // the keys actually pressed, so the user gets "првет" and fixes the typo
    // themselves. Correcting the layout fixes an encoding error; correcting the
    // spelling would silently rewrite what they wrote, which is a different and
    // much riskier thing to do. It also means an ambiguous match costs nothing,
    // because we never have to choose between candidates.
    if dictionary.hasWordOneInsertionAway(converted, in: currentLayout.other) {
      return .typo
    }

    // Colloquial, derived and invented words are in no list. Fall back to asking
    // which language the letters look like.
    if let score = languageModelScore(
      typed: word, converted: converted, currentLayout: currentLayout, dictionary: dictionary
    ), score.passes {
      return .languageModel
    }

    return nil
  }

  /// The language-model evidence for switching a token.
  struct LanguageModelScore {
    /// Per-character log-likelihood of the conversion in the other language
    /// minus that of the typed text in the current one.
    let margin: Double
    /// Per-character log-likelihood of the conversion alone.
    let plausibility: Double
    let length: Int
    /// The language the conversion would be in.
    let target: Layout

    var passes: Bool {
      margin >= AutoSwitchEngine.languageModelMargin(forLength: length)
        && plausibility >= AutoSwitchEngine.languageModelFloor(for: target)
    }
  }

  /// Letters needed before the language model is consulted. Four-letter strings
  /// are accepted only with a large margin: see docs/DICTIONARY.md.
  static let languageModelMinimumLength = 4

  /// Margin (nats per character) a conversion must beat the typed text by. Short
  /// strings carry little evidence, so they need far more of it: measured on
  /// held-out words, a margin of 1.0 mislabels 1.8% of four-letter Russian words
  /// but 0.01% of six-letter ones.
  static func languageModelMargin(forLength length: Int) -> Double {
    switch length {
    case ..<5: return 2.5
    case 5: return 2.0
    case 6, 7: return 1.5
    default: return 1.25
    }
  }

  /// Lowest per-character log-likelihood the conversion itself may have. It
  /// keeps out strings the typed side merely scores worse on: keyboard mashing,
  /// stray consonant runs. English is held to a stricter floor because Russian
  /// names and transliterations are the likeliest accidental fits.
  static func languageModelFloor(for target: Layout) -> Double {
    target == .english ? -3.5 : -4.5
  }

  static func languageModelScore(
    typed: String,
    converted: String,
    currentLayout: Layout,
    dictionary: LayoutDictionary = .shared
  ) -> LanguageModelScore? {
    let length = converted.count
    guard length >= languageModelMinimumLength,
          let target = dictionary.nGramModel(for: currentLayout.other),
          let source = dictionary.nGramModel(for: currentLayout) else { return nil }

    // A trailing , . ; ' may be a full stop or the letters б ю ж э. Do not hold
    // it against the typed text; the model that reads it as punctuation would
    // otherwise be handed free evidence.
    var typedScalars = Array(typed.unicodeScalars)
    while let last = typedScalars.last, ambiguousTrailingCharacters.contains(last) {
      typedScalars.removeLast()
    }
    let stem = String(String.UnicodeScalarView(typedScalars))
      .replacingOccurrences(of: "ё", with: "е")
    let readTarget = converted.replacingOccurrences(of: "ё", with: "е")

    let normaliser = Double(length + 1)
    let plausibility = target.logProbability(of: readTarget) / normaliser
    let margin = plausibility - source.logProbability(of: stem) / normaliser
    return LanguageModelScore(
      margin: margin, plausibility: plausibility, length: length, target: currentLayout.other
    )
  }

  /// Whether the decision for this word was an exact dictionary hit rather than
  /// a typo match. Only exact hits are confident enough to drag preceding words
  /// along with them.
  static func isExactMatch(
    word rawWord: String,
    currentLayout: Layout,
    dictionary: LayoutDictionary = .shared
  ) -> Bool {
    let trimmed = rawWord.trimmingCharacters(in: trimmableCharacters)
    guard !looksLikeCodeOrAddress(trimmed) else { return false }
    let word = trimmed.lowercased()
    let converted = convert(word, to: currentLayout.other)
    return dictionary.contains(converted, in: currentLayout.other)
      || isThemePackHit(converted, target: currentLayout.other)
  }

  /// Membership test for enabled theme-pack forms. Packs hold Russian forms only,
  /// so this applies when the target is Russian. Set through `AutoSwitchEngine.themePacks`
  /// (ThemePacks.swift); nil means no packs.
  static var themePackContains: ((String) -> Bool)?

  private static func isThemePackHit(_ converted: String, target: Layout) -> Bool {
    guard target == .russian, let contains = themePackContains else { return false }
    return contains(converted)
  }

  /// Whether a typed token is a URL, email, path, mention, hashtag, shell
  /// variable or code identifier. Checks the characters as typed in the current
  /// layout, never a conversion of them.
  ///
  /// `. , ; ' [ ] \`` are not rules here: they are Russian letters on the
  /// English layout, so none of these checks fire on a Russian word typed with
  /// those keys. Any underscore counts, not only one between letters, since no
  /// word in either layout uses it.
  static func looksLikeCodeOrAddress(_ typed: String) -> Bool {
    let lowered = typed.lowercased()
    if lowered.contains("://") || lowered.hasPrefix("www.") { return true }
    if typed.contains("@") { return true }
    if typed.hasPrefix("/") || typed.hasPrefix("~/") || typed.hasPrefix("./")
      || typed.hasPrefix("../") || typed.contains("\\") {
      return true
    }
    if typed.hasPrefix("#") || typed.hasPrefix("$") { return true }
    if typed.contains("_") { return true }
    if ["::", "->", "=>", "=="].contains(where: { typed.contains($0) }) { return true }

    let characters = Array(typed)
    let hasDigit = characters.contains { ("0"..."9").contains($0) }
    let hasLetter = characters.contains { $0.isLetter }
    if hasDigit && hasLetter { return true }

    // camelCase: only a lowercase Latin letter followed by an uppercase one.
    // "GHbdtn" (sticky Shift on "Привет") has no such pair and stays eligible.
    for index in characters.indices.dropFirst()
    where ("a"..."z").contains(characters[index - 1]) && ("A"..."Z").contains(characters[index]) {
      return true
    }
    return false
  }

  private static func hasAmbiguousTrailing(_ word: String) -> Bool {
    guard let last = word.unicodeScalars.last else { return false }
    return ambiguousTrailingCharacters.contains(last)
  }

  private static func stem(of word: String) -> String {
    var scalars = Array(word.unicodeScalars)
    while let last = scalars.last, ambiguousTrailingCharacters.contains(last) {
      scalars.removeLast()
    }
    return String(String.UnicodeScalarView(scalars))
  }

  /// Whether a word that was skipped on its own should be swept up by a
  /// confident correction that follows it.
  ///
  /// One- and two-letter words are far too ambiguous to judge alone — 46% of
  /// them are also a valid word in the other layout, versus 6% at three letters
  /// — so `evaluate` never touches them. But "я не могу" is `z yt vjue`, and
  /// fixing only `могу` is barely worth having. Once a longer word has switched
  /// confidently, the words immediately before it are almost certainly the same
  /// language, and that context is what makes the short ones decidable.
  ///
  /// Still conservative: a word that is already valid where it stands stops the
  /// sweep, so a genuinely mixed-language phrase is left alone.
  static func qualifiesForPhraseExtension(
    word rawWord: String,
    currentLayout: Layout,
    dictionary: LayoutDictionary = .shared
  ) -> Bool {
    guard dictionary.isReady else { return false }

    let trimmed = rawWord.trimmingCharacters(in: trimmableCharacters)
    guard !looksLikeCodeOrAddress(trimmed) else { return false }
    let word = trimmed.lowercased()
    guard !word.isEmpty, word.count <= 4 else { return false }
    guard word == word.lowercased() else { return false }
    guard word.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
    guard word.rangeOfCharacter(from: disqualifyingCharacters) == nil else { return false }

    // Already correct here — the user was writing in this layout. Stop.
    if dictionary.contains(word, in: currentLayout) { return false }

    let converted = convert(word, to: currentLayout.other)
    guard converted != word,
          converted.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil else {
      return false
    }
    return dictionary.contains(converted, in: currentLayout.other)
  }

  /// Lowercased, edge-punctuation-free form used as the identity of a word for
  /// the undo and ignore lists.
  static func normalize(_ word: String) -> String {
    word.trimmingCharacters(in: trimmableCharacters).lowercased()
  }

  /// Maps every character to the other layout using the existing keyboard maps.
  static func convert(_ text: String, to target: Layout) -> String {
    let mapper = target == .russian ? enRuDictionary : ruEnDictionary
    return text.map { mapper[String($0)] ?? String($0) }.joined()
  }

  private static func isEligible(_ word: String) -> Bool {
    // Too short to judge: "ok", "hi", "и", "не".
    if word.count < 3 { return false }

    // Digits mean an identifier, a version, a password.
    if word.rangeOfCharacter(from: .decimalDigits) != nil { return false }

    if word.rangeOfCharacter(from: disqualifyingCharacters) != nil { return false }

    // Proper nouns and acronyms are often missing from the word lists, and
    // rewriting a name is very visible. Any capital disqualifies.
    if word != word.lowercased() { return false }

    return true
  }
}
