import Foundation

/// Immutable snapshot of a `SentenceContext` (SentenceContext.swift) at one
/// moment, handed to `AutoSwitchEngine.evaluate`/`matchTier` as a cheap,
/// thread-safe value. Declared here rather than alongside the class so this
/// file — and the test harnesses that compile it standalone — never need to
/// pull in SentenceContext.swift just to spell the type of an optional,
/// always-nil-by-default parameter.
struct SentenceContextSnapshot: Equatable {
  let prior: Layout
  let strength: Int
}

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

  /// Punctuation that can end an English word typed on the Russian layout
  /// ("hello." is "руддщю"). The apostrophe is left out on purpose: "dont'"
  /// must stay as typed.
  private static let englishTrailingPunctuation = CharacterSet(charactersIn: ".,;:?!\"")

  /// Common English contractions, lowercase. Only these apostrophe forms are
  /// switched; anything else with an apostrophe ("tho'ts", "y'all") stays put.
  private static let englishContractions: Set<String> = [
    "don't", "can't", "won't", "isn't", "aren't", "wasn't", "weren't", "didn't", "doesn't",
    "haven't", "hasn't", "hadn't", "shouldn't", "wouldn't", "couldn't", "mustn't", "needn't",
    "shan't", "ain't", "it's", "that's", "what's", "there's", "here's", "where's", "who's",
    "when's", "why's", "how's", "let's", "i'm", "i'll", "i've", "i'd", "you're", "you've",
    "you'll", "you'd", "we're", "we've", "we'll", "we'd", "they're", "they've", "they'll",
    "they'd", "he's", "she's", "he'll", "she'll", "he'd", "she'd", "it'll", "that'll",
    "who'll", "there'll", "that'd", "who'd", "what'll", "what'd", "there'd",
  ]

  /// Which rule decided to switch, strongest evidence first.
  enum Tier: Equatable {
    /// The conversion is a word in the other layout's dictionary.
    case exact
    /// The conversion is a word with one keystroke missing.
    case typo
    /// Neither form is in our own lists, but the local system spell-checker
    /// (NSSpellChecker) knows the conversion in the target language and does not
    /// know the typed form where it stands. See SpellOracle.swift.
    case spellChecker
    /// Neither form is a word anywhere, but the conversion reads like the other
    /// language and the typed form does not read like this one.
    case languageModel
  }

  static func evaluate(
    word rawWord: String,
    currentLayout: Layout,
    context: SentenceContextSnapshot? = nil,
    dictionary: LayoutDictionary = .shared
  ) -> Decision {
    matchTier(word: rawWord, currentLayout: currentLayout, context: context, dictionary: dictionary) == nil
      ? .keep
      : .switchLayout
  }

  /// The tier that would switch `rawWord`, or nil if it is left alone.
  ///
  /// `context` is the sentence context at the moment this word is judged, or
  /// nil for the plain per-word decision. It only touches the bottom two
  /// tiers: a target-layout context relaxes the n-gram margin, and a strong
  /// current-layout context disables both the n-gram and typo tiers outright.
  /// Exact, pack, and user-lexicon hits are confident enough that context
  /// cannot override them either way.
  static func matchTier(
    word rawWord: String,
    currentLayout: Layout,
    context: SentenceContextSnapshot? = nil,
    dictionary: LayoutDictionary = .shared
  ) -> Tier? {
    guard dictionary.isReady else { return nil }

    if currentLayout == .russian, isPunctuatedEnglishHit(rawWord, dictionary: dictionary) {
      return .exact
    }

    let (trimmed, titleCase) = titleCaseCandidate(rawWord, currentLayout: currentLayout)

    // A mixed-case run ("шЗрщту") only ever switches as one of a small curated
    // set of EN brand/tech names typed with the RU layout active: see
    // mixedCaseBrandTier. Checked before the hyphen split below (some of these
    // names, e.g. "FreeBSD", never contain one, but the gate is cheap and must
    // run before isEligible would otherwise reject the mixed case outright).
    if currentLayout == .russian, let tier = mixedCaseBrandTier(trimmed) {
      return tier
    }

    // Dictionaries never index the hyphen itself ("-" is disqualifying below), so a
    // hyphenated token ("где-то", "python-telegram-bot") is judged side by side
    // instead of as a whole: see hyphenTier.
    if trimmed.contains("-") {
      return hyphenTier(trimmed, titleCase: titleCase, currentLayout: currentLayout, dictionary: dictionary)
    }

    // ALL-CAPS ("GHBDTN", "ФЗШ") reads as Caps Lock left on in the wrong
    // layout. Evaluated the same as Title-case below — lowercase form, exact
    // tiers only — never typo or language model, which are far likelier to
    // misfire on a short acronym than catch a genuine layout mistake.
    let allCaps = isAllCaps(trimmed)

    guard isEligible(trimmed, allowTitleCase: titleCase || allCaps), !looksLikeCodeOrAddress(trimmed) else {
      return nil
    }

    let word = trimmed.lowercased()

    // The user has manually swapped this exact word out of this layout often
    // enough to force it: skip the dictionary tiers below entirely, since a
    // forced switch overrides even a word that reads fine where it stands.
    if isUserLexiconForced(word, from: currentLayout) {
      let forcedTarget = convert(word, to: currentLayout.other)
      if forcedTarget != word, forcedTarget.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil {
        return .exact
      }
    }

    // Already a real word where it stands — leave it alone.
    if dictionary.contains(word, in: currentLayout) { return nil }

    // A word the user has typed and kept often enough in this layout to have
    // learned — treat it the same as a dictionary word.
    if isUserLexiconHit(word, target: currentLayout) { return nil }

    let converted = convert(word, to: currentLayout.other)
    guard converted != word else { return nil }

    // The candidate must be a plain run of letters in the target layout.
    // Anything else means these keys do not spell a word over there.
    guard converted.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil else {
      return nil
    }

    // See shortAllCapsRuAcronyms: a short ALL-CAPS run converting to Russian
    // is far likelier to be an obscure inflected-form collision than a real
    // Caps Lock mistake, so it needs either enough letters or the curated list.
    if allCaps, currentLayout == .english, converted.count < 5,
       !shortAllCapsRuAcronyms.contains(converted) {
      return nil
    }

    // Theme-pack forms are checked before the trailing-punctuation rule below:
    // "ye," is the English "ye" plus a comma, but it types "нуб".
    if isThemePackHit(converted, target: currentLayout.other) { return .exact }

    // Likewise a word the user has learned in the other layout: a confident
    // user signal, not merely a dictionary match.
    if isUserLexiconHit(converted, target: currentLayout.other) { return .exact }

    // "it." is a real word plus a full stop; "ndj." is the Russian "твою". Tell
    // them apart by asking whether dropping the trailing punctuation leaves a
    // word in the layout the user is already using.
    if hasAmbiguousTrailing(word), dictionary.contains(stem(of: word), in: currentLayout) {
      return nil
    }

    if dictionary.contains(converted, in: currentLayout.other) { return .exact }

    // Check и→й substitutions for Russian target. When typed on EN layout,
    // if the converted Cyrillic word is not found but replacing и with й(s)
    // yields a word in ru-forms, treat as exact match (layout switch only).
    // Guard: Cyrillic word must be ≥ 3 chars to avoid false positives like "tb"→"еи"→"ей".
    if currentLayout == .english, tryYotSubstitutions(converted, dictionary: dictionary) {
      return .exact
    }

    // A Title-case or ALL-CAPS word is evaluated as its lowercase form, but
    // only the exact tiers above may switch it: a typo or n-gram guess about
    // a capitalized word is far likelier to be a name, brand, or acronym than
    // a layout mistake.
    if titleCase || allCaps { return nil }

    // A sentence firmly anchored in the current layout (three or more words
    // running) is strong enough evidence on its own that the bottom two tiers,
    // which are the ones prone to misreading a real word in this layout as a
    // mistyped one in the other, are held back entirely.
    if contextStronglyFavorsCurrentLayout(context, currentLayout: currentLayout) {
      return nil
    }

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
    if dictionary.hasCommonWordOneTypoAway(converted, in: currentLayout.other) {
      return .typo
    }

    // The local system spell-checker (NSSpellChecker) covers proper nouns, recent
    // loanwords and brand names our own lists have not caught up with. It is only
    // ever consulted this late, after every dictionary and typo tier has already
    // found nothing. `typedKnownToSpeller` doubles as a veto on the n-gram tier
    // below: a word the system speller already recognises where it stands is not
    // the n-gram model's to second-guess. See SpellOracle.swift.
    let typedKnownToSpeller = isKnownToSpeller(word, in: currentLayout)
    if spellCheckerConfirmEnabled, !typedKnownToSpeller, word.count >= 4,
       isKnownToSpeller(converted, in: currentLayout.other) {
      return .spellChecker
    }

    // Colloquial, derived and invented words are in no list. Fall back to asking
    // which language the letters look like.
    if !typedKnownToSpeller, let score = languageModelScore(
      typed: word, converted: converted, currentLayout: currentLayout, dictionary: dictionary
    ), languageModelScorePasses(score, context: context, currentLayout: currentLayout) {
      return .languageModel
    }

    return nil
  }

  /// Three or more trailing words already committed to `currentLayout` is
  /// strong enough evidence that the n-gram and typo tiers are held back:
  /// at that point a lone odd-looking word is far more likely to be a brand,
  /// a name, or slang than a layout mistake.
  private static func contextStronglyFavorsCurrentLayout(
    _ context: SentenceContextSnapshot?, currentLayout: Layout
  ) -> Bool {
    guard let context else { return false }
    return context.prior == currentLayout && context.strength >= 3
  }

  /// Whether a language-model score clears the bar to switch, given the
  /// sentence context. A context anchored in the target layout relaxes the
  /// margin a conversion must beat the typed text by: the threshold used at
  /// nil context already keeps false positives rare, so this only needs to
  /// forgive borderline cases sentence-level evidence already supports.
  private static func languageModelScorePasses(
    _ score: LanguageModelScore, context: SentenceContextSnapshot?, currentLayout: Layout
  ) -> Bool {
    var threshold = languageModelMargin(forLength: score.length)
    if let context, context.prior == currentLayout.other {
      threshold *= 0.6
    }
    return score.margin >= threshold && score.plausibility >= languageModelFloor(for: score.target)
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
      || isUserLexiconHit(converted, target: currentLayout.other)
  }

  /// Membership test for enabled theme-pack forms. Packs hold Russian forms only,
  /// so this applies when the target is Russian. Set through `AutoSwitchEngine.themePacks`
  /// (ThemePacks.swift); nil means no packs.
  static var themePackContains: ((String) -> Bool)?

  private static func isThemePackHit(_ converted: String, target: Layout) -> Bool {
    guard target == .russian, let contains = themePackContains else { return false }
    return contains(converted)
  }

  /// Whether a word is known to the local system spell-check service in a given
  /// layout. Set through `AutoSwitchEngine.spellOracle` (SpellOracle.swift); nil
  /// means no oracle, which keeps this file — and the dictionary test harnesses
  /// that compile it standalone — buildable without that one, same reasoning as
  /// `themePackContains` above.
  static var spellOracleIsKnown: ((String, Layout) -> Bool)?

  /// Whether a known-converted, unknown-typed word may switch through the
  /// `.spellChecker` tier (the "confirm" half; see `matchTier` above). The veto
  /// half — holding back the n-gram tier for a word the speller already
  /// recognises in its own layout — always applies once an oracle is set and
  /// does not depend on this flag.
  ///
  /// Defaults to true (so tests using a fake oracle exercise the confirm tier
  /// by default); production wiring in AppDelegate.finishApplicationSetup sets
  /// it false. Measured on tests/run.sh's 231k-word out-of-vocabulary English
  /// suite: confirming added 7 new misfires (rare real words whose
  /// layout-converted gibberish NSSpellChecker's Russian dictionary happened to
  /// recognise) for a recall gain of only 3-5 words on the colloquial/brand
  /// lists — not a trade worth making. The veto alone added zero misfires on
  /// every suite measured. See docs/DICTIONARY.md.
  static var spellCheckerConfirmEnabled = true

  private static func isKnownToSpeller(_ word: String, in layout: Layout) -> Bool {
    spellOracleIsKnown?(word, layout) ?? false
  }

  /// Membership test for the user's learned lexicon in a given layout. Set
  /// through `AutoSwitchEngine.userLexicon` (UserLexicon.swift); nil means no
  /// lexicon, which keeps this file buildable without that one.
  static var userLexiconContains: ((String, Layout) -> Bool)?

  private static func isUserLexiconHit(_ word: String, target: Layout) -> Bool {
    userLexiconContains?(word, target) ?? false
  }

  /// Forced-switch test for the user's learned lexicon: a word the user keeps
  /// manually swapping out of a layout, typed in that same layout. Set
  /// through `AutoSwitchEngine.userLexicon` (UserLexicon.swift); nil means no
  /// lexicon.
  static var userLexiconForces: ((String, Layout) -> Bool)?

  private static func isUserLexiconForced(_ word: String, from layout: Layout) -> Bool {
    userLexiconForces?(word, layout) ?? false
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

  /// English-target only. A Russian-layout run that converts to an English word
  /// with up to two trailing punctuation marks, or to a whitelisted contraction.
  /// Judged on the exact dictionary alone, so no typo or n-gram tier applies.
  /// The stem may be all-lowercase or Title-case ("Hello,", "I'm") — the lookup
  /// always happens on its lowercase form, but ALL-CAPS and mixed case ("JSON,")
  /// are rejected so they fall through to the usual eligibility checks and stay put.
  private static func isPunctuatedEnglishHit(_ rawWord: String, dictionary: LayoutDictionary) -> Bool {
    // A real Russian word keeps the usual answer, even if it ends in ю, б, ж, э or х.
    // On the Russian layout `,` and `.` are real punctuation, so "руки," is "руки".
    let russianWord = rawWord.trimmingCharacters(in: trimmableCharacters).lowercased()
    let russianStem = russianWord.trimmingCharacters(in: englishTrailingPunctuation)
    for candidate in Set([russianWord, russianStem]) where !candidate.isEmpty {
      if dictionary.contains(candidate, in: .russian) { return false }
      if isUserLexiconHit(candidate, target: .russian) { return false }
    }
    guard rawWord.rangeOfCharacter(from: disqualifyingCharacters) == nil else { return false }

    var scalars = Array(convert(rawWord, to: .english).unicodeScalars)
    var stripped = 0
    while stripped < 2, let last = scalars.last, englishTrailingPunctuation.contains(last) {
      scalars.removeLast()
      stripped += 1
    }
    let stem = String(String.UnicodeScalarView(scalars))
    guard stem == stem.lowercased() || isTitleCase(stem) else { return false }
    let lowerStem = stem.lowercased()

    if englishContractions.contains(lowerStem) { return true }

    guard stripped > 0,
          lowerStem.count >= 3,
          lowerStem.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil,
          !looksLikeCodeOrAddress(lowerStem)
    else { return false }
    return dictionary.contains(lowerStem, in: .english)
  }

  /// Short particles that commonly form one side of a Russian hyphen compound —
  /// "кто-то", "во-первых", "что-ж" — but are themselves too short, or too
  /// specialised, to sit in the main word list at its usual frequency threshold.
  /// Used only when the hyphen side is judged against Russian: see `hyphenTier`.
  private static let russianHyphenParticles: Set<String> = [
    "то", "либо", "нибудь", "таки", "ка", "де", "же", "ж", "кое", "во",
  ]

  /// Whether every part of an already hyphen-split word reads as a word in
  /// `layout`. Russian trusts `russianHyphenParticles` as a fallback for a
  /// dictionary miss; English does not, since there is no equivalent closed
  /// set of short English hyphen-formants — every part there must be a full
  /// dictionary word, which is what keeps code-ish tokens from qualifying.
  private static func hyphenPartsAreWords(
    _ parts: [String], layout: Layout, dictionary: LayoutDictionary
  ) -> Bool {
    parts.allSatisfy { part in
      guard part.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil else { return false }
      if dictionary.contains(part, in: layout) { return true }
      return layout == .russian && russianHyphenParticles.contains(part)
    }
  }

  /// Whether a hyphenated token ("где-то", "python-telegram-bot") should switch
  /// layout as a whole. Checked before the ordinary eligibility gate in
  /// `matchTier`, since "-" is one of `disqualifyingCharacters` and would
  /// otherwise rule every hyphenated word out immediately.
  ///
  /// Each side of each hyphen is judged independently with `hyphenPartsAreWords`,
  /// first against the word as typed (so an already-legitimate hyphenation —
  /// "well-known", "e-mail", or a correctly-typed Russian one like "кто-то" —
  /// is left alone even where a part would also happen to convert), then
  /// against the converted form. Only an `.exact` match is ever returned: a
  /// typo or n-gram guess about one half of a hyphenated word is far likelier
  /// to be noise than a layout mistake.
  private static func hyphenTier(
    _ trimmed: String, titleCase: Bool, currentLayout: Layout, dictionary: LayoutDictionary
  ) -> Tier? {
    guard trimmed.count >= 3,
          trimmed == trimmed.lowercased() || titleCase,
          trimmed.rangeOfCharacter(from: .decimalDigits) == nil,
          !looksLikeCodeOrAddress(trimmed)
    else { return nil }

    let word = trimmed.lowercased()
    let parts = word.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }

    guard !hyphenPartsAreWords(parts, layout: currentLayout, dictionary: dictionary) else {
      return nil
    }

    let target = currentLayout.other
    let convertedParts = parts.map { convert($0, to: target) }
    return hyphenPartsAreWords(convertedParts, layout: target, dictionary: dictionary) ? .exact : nil
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
      || isUserLexiconHit(converted, target: currentLayout.other)
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

  private static func isEligible(_ word: String, allowTitleCase: Bool) -> Bool {
    // Too short to judge: "ok", "hi", "и", "не". Also the gate that keeps a
    // 2-letter ALL-CAPS run ("KB", "СО") from ever being judged: too ambiguous
    // to risk even through the exact tiers.
    if word.count < 3 { return false }

    // Digits mean an identifier, a version, a password.
    if word.rangeOfCharacter(from: .decimalDigits) != nil { return false }

    if word.rangeOfCharacter(from: disqualifyingCharacters) != nil { return false }

    // Proper nouns and acronyms are often missing from the word lists, and
    // rewriting a name is very visible. Any capital disqualifies, except a
    // Title-case word ("Hello", "Привет") or an ALL-CAPS one ("GHBDTN",
    // "ФЗШ"), both of which the caller evaluates as their lowercase form
    // through the exact tiers only (see `allowTitleCase` callers in
    // `matchTier`). Mixed case ("iPhone", "GitHub") is handled separately, by
    // `mixedCaseBrandTier`, before this gate is ever reached, and stays
    // disqualified here.
    if word != word.lowercased() && !allowTitleCase { return false }

    return true
  }

  /// True when `word` has at least one letter and every letter in it is
  /// uppercase — "GHBDTN", "ФЗШ", "API". False for Title-case ("Hello"),
  /// mixed case ("iPhone"), and all-lowercase words. Digits and punctuation
  /// are ignored here; `isEligible`'s own digit and disqualifying-character
  /// checks reject those separately, the same as they do for a lowercase word.
  private static func isAllCaps(_ word: String) -> Bool {
    let letters = word.filter { $0.isLetter }
    guard !letters.isEmpty else { return false }
    return letters.allSatisfy { $0.isUppercase }
  }

  /// True when `word` mixes uppercase and lowercase letters without being
  /// Title-case — "iPhone", "GitHub", "OAuth" — as opposed to all-lowercase,
  /// ALL-CAPS, or a single leading capital.
  private static func isMixedCase(_ word: String) -> Bool {
    let hasUpper = word.contains { $0.isUppercase }
    let hasLower = word.contains { $0.isLowercase }
    return hasUpper && hasLower && !isTitleCase(word)
  }

  /// A curated, canonical-cased set of mixed-case EN tech/brand names. A run
  /// typed with the RU layout active reads as Cyrillic letters whose case
  /// pattern survives untouched ("шЗрщту" is physically the same shift
  /// sequence as "iPhone"), so the case-preserving conversion of a mixed-case
  /// typed word is checked against this set letter-for-letter — not merely
  /// case-insensitively — before anything is allowed to switch. Dictionary
  /// lookups elsewhere in this file are all lowercase-only and cannot stand
  /// in for this: "iphone" is not a word, only "iPhone" spelled exactly is.
  private static let mixedCaseBrandTerms: Set<String> = [
    "macOS", "iOS", "iPadOS", "iPhone", "iPad", "iMac", "iCloud", "iTunes",
    "AirPods", "MacBook", "GitHub", "GitLab", "YouTube", "WordPress",
    "PayPal", "TypeScript", "JavaScript", "PostgreSQL", "MongoDB", "OAuth",
    "GeForce", "FreeBSD", "OpenAI", "ChatGPT", "TikTok", "WeChat",
  ]

  /// A 3-4 letter ALL-CAPS run checked against the full Russian inflected
  /// dictionary (3M+ forms) collides too easily with ordinary English
  /// acronyms that are not common enough to be in en.txt.gz ("RFC" -> "кас",
  /// "JCB" -> "оси", "LTPS" -> "дезы" are all real but obscure inflected
  /// forms). Below 5 letters the exact-tier RU match is restricted to this
  /// small curated set of well-known short Russian acronyms instead of the
  /// blanket dictionary, bounding the false-positive risk to names chosen by
  /// hand. 5+ letter collisions were not observed and are left unrestricted.
  private static let shortAllCapsRuAcronyms: Set<String> = ["мвд", "мгу", "ссср"]

  /// The exact tier for a mixed-case EN brand/tech name typed with the RU
  /// layout active, or nil if `trimmed` is not mixed case or does not convert
  /// to one of `mixedCaseBrandTerms`. Checked ahead of `isEligible`, which
  /// would otherwise reject any mixed-case run outright; everything other
  /// than this curated set stays disqualified exactly as before.
  private static func mixedCaseBrandTier(_ trimmed: String) -> Tier? {
    guard isMixedCase(trimmed),
          trimmed.rangeOfCharacter(from: .decimalDigits) == nil,
          trimmed.rangeOfCharacter(from: disqualifyingCharacters) == nil
    else { return nil }
    let converted = convert(trimmed, to: .english)
    return mixedCaseBrandTerms.contains(converted) ? .exact : nil
  }

  /// True when `word` starts with an uppercase letter and has no other
  /// uppercase letters — "Hello", "I'm", "Привет". False for ALL-CAPS
  /// ("JSON"), mixed case ("iPhone", "GitHub"), and all-lowercase words.
  private static func isTitleCase(_ word: String) -> Bool {
    guard let first = word.first, first.isUppercase else { return false }
    return word.dropFirst().allSatisfy { !$0.isUppercase }
  }

  /// б, ю, ж, э, х, ъ sit on the keys that type , . ; ' [ ] on the English
  /// layout (see `KeyDictionary.swift`). Their capitals are therefore the
  /// *shifted* symbol above those keys — < > : " { } — not an uppercase Latin
  /// letter, so a Title-case Russian word starting with one of them arrives,
  /// misread as English, as that symbol followed by lowercase letters. Maps
  /// each symbol back to the key's unshifted (lowercase) form.
  private static let shiftedCyrillicLeadMarkers: [Character: Character] = [
    "<": ",", ">": ".", ":": ";", "\"": "'", "{": "[", "}": "]",
  ]

  /// Try и→й substitutions for a Russian target. Returns true if any substitution
  /// yields a word in the full ru-forms dictionary. Only tries if the word has ≤ 3 и's
  /// (to keep the search space small) and is ≥ 3 chars (guard against false positives).
  private static func tryYotSubstitutions(
    _ word: String, dictionary: LayoutDictionary
  ) -> Bool {
    // Normalize ё→е consistently with exact lookup.
    let normalized = word.replacingOccurrences(of: "ё", with: "е")

    guard normalized.count >= 3 else { return false }

    let chars = Array(normalized)
    let positions = chars.indices.filter { chars[$0] == "и" }

    // Skip if more than 3 и's: combinatorial search space becomes too large.
    guard positions.count <= 3, positions.count > 0 else { return false }

    // Generate all 2^n - 1 non-empty substitution combinations.
    // For each position set where и→й, build the candidate and check.
    for mask in 1..<(1 << positions.count) {
      var candidate = chars
      for (bitIndex, iPos) in positions.enumerated() {
        if (mask & (1 << bitIndex)) != 0 {
          candidate[iPos] = "й"
        }
      }
      let word = String(candidate)
      if dictionary.contains(word, in: .russian) {
        return true
      }
    }

    return false
  }

  /// The trimmed word and whether it should be read as Title-case, handling
  /// the `shiftedCyrillicLeadMarkers` case before the generic punctuation trim
  /// (which would otherwise either discard the leading `"` outright or have
  /// `isEligible` reject `<`/`>`/`{`/`}`/`:` as code).
  private static func titleCaseCandidate(
    _ rawWord: String, currentLayout: Layout
  ) -> (trimmed: String, titleCase: Bool) {
    if currentLayout == .english, let first = rawWord.first,
       let unshifted = shiftedCyrillicLeadMarkers[first] {
      let rest = rawWord.dropFirst().trimmingCharacters(in: trimmableCharacters)
      if rest.count >= 2, rest.allSatisfy({ ("a"..."z").contains($0) }) {
        return (String(unshifted) + rest, true)
      }
    }
    let marked = stripRussianLayoutSentenceMarks(rawWord, currentLayout: currentLayout)
    let trimmed = marked.trimmingCharacters(in: trimmableCharacters)
    // A run that only reads as Russian once a code symbol is dropped is judged
    // like a Title-case word: exact tiers only, never typo or language model.
    return (trimmed, isTitleCase(trimmed) || marked != rawWord)
  }

  /// Keys that type sentence punctuation on the Russian layout but code symbols
  /// on the English one: Shift+7 is "?", Shift+6 ":", Shift+4 ";", Shift+2 `"`,
  /// and "/" is ".". "cltkfnm&" is "сделать?", so up to two such trailing marks
  /// are dropped before judging an English-layout run, if letters remain.
  private static let russianLayoutSentenceMarks = CharacterSet(charactersIn: "&^$@/")

  private static func stripRussianLayoutSentenceMarks(
    _ rawWord: String, currentLayout: Layout
  ) -> String {
    guard currentLayout == .english else { return rawWord }
    var scalars = Array(rawWord.unicodeScalars)
    var stripped = 0
    while stripped < 2, let last = scalars.last,
          russianLayoutSentenceMarks.contains(last) || trimmableCharacters.contains(last) {
      scalars.removeLast()
      stripped += 1
    }
    let stem = String(String.UnicodeScalarView(scalars))
    guard stripped > 0, stem.rangeOfCharacter(from: disqualifyingCharacters) == nil else {
      return rawWord
    }
    return stem
  }
}
