import Foundation

/// Tracks the layout recent committed words ended up in, so the engine can
/// lean on sentence-level evidence instead of judging each word alone.
///
/// Call `note` after every word commits, in whichever layout it actually
/// ended up in (after an auto-switch, or after a manual swap). Call `reset`
/// whenever the context stops being meaningful: an active-app change, Enter
/// or Tab, a mouse click, or anywhere the auto-switch learning context is
/// reset.
///
/// Produces `SentenceContextSnapshot` (AutoSwitchEngine.swift) for the engine
/// to consult.
///
/// Main-thread only, like the rest of the auto-switch pipeline.
final class SentenceContext {
  /// Layouts of recently committed words, oldest first. Capped well above the
  /// three words `prior` looks at, so `strength` can still count a longer
  /// run without the array growing without bound.
  private var history: [Layout] = []
  private static let historyLimit = 32

  init() {}

  func note(word: String, finalLayout: Layout) {
    history.append(finalLayout)
    if history.count > Self.historyLimit {
      history.removeFirst(history.count - Self.historyLimit)
    }
  }

  func reset() {
    history.removeAll()
  }

  /// The layout of >= 2 of the last 3 noted words, or nil with fewer than 2
  /// words of history (or an even split).
  var prior: Layout? {
    let recent = history.suffix(3)
    guard recent.count >= 2 else { return nil }
    let englishCount = recent.filter { $0 == .english }.count
    if englishCount >= 2 { return .english }
    if recent.count - englishCount >= 2 { return .russian }
    return nil
  }

  /// Consecutive most-recent words in `prior`, counted back from the newest.
  /// 0 when `prior` is nil, and may be 0 even when `prior` is set, if the
  /// newest word is in the other layout.
  var strength: Int {
    guard let prior else { return 0 }
    var count = 0
    for layout in history.reversed() {
      guard layout == prior else { break }
      count += 1
    }
    return count
  }

  var snapshot: SentenceContextSnapshot? {
    guard let prior else { return nil }
    return SentenceContextSnapshot(prior: prior, strength: strength)
  }
}
