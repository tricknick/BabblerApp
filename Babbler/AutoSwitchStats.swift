import Combine
import Foundation

private let autoSwitchStatsTotalKey = "autoSwitchStatsTotal"
private let autoSwitchStatsTodayKey = "autoSwitchStatsToday"
private let autoSwitchStatsDayKey = "autoSwitchStatsDay"

/// Persistence used by `AutoSwitchStats`. Counts are stored as flat `[String: Int]`
/// maps so they stay property-list compatible; the keys are opaque to the store.
protocol AutoSwitchStatsStore: AnyObject {
  func autoSwitchStatsTotal() -> [String: Int]
  func setAutoSwitchStatsTotal(_ counts: [String: Int])
  func autoSwitchStatsToday() -> [String: Int]
  func setAutoSwitchStatsToday(_ counts: [String: Int])
  /// Start of the local day that `today` counts belong to.
  func autoSwitchStatsDay() -> Date?
  func setAutoSwitchStatsDay(_ day: Date?)
}

extension AutoSwitchStats {
  enum Tier: String, CaseIterable, Hashable {
    case exact
    case typo
    case ngram
    case phrase

    /// Short label for the settings breakdown.
    var title: String {
      switch self {
      case .exact: return "Dictionary"
      case .typo: return "Typo"
      case .ngram: return "Language model"
      case .phrase: return "Phrase"
      }
    }
  }
}

extension AutoSwitchStats.Tier {
  init(engine: AutoSwitchEngine.Tier) {
    switch engine {
    case .exact: self = .exact
    case .typo: self = .typo
    case .languageModel: self = .ngram
    }
  }
}

struct StatsSnapshot {
  var switches: Int
  var undos: Int
  var manualSwaps: Int
  var switchesByTier: [AutoSwitchStats.Tier: Int]
  /// (switches - undos) / switches; nil when there were no switches.
  var precision: Double?

  fileprivate init(counts: [String: Int]) {
    switches = counts[AutoSwitchStats.switchesKey] ?? 0
    undos = counts[AutoSwitchStats.undosKey] ?? 0
    manualSwaps = counts[AutoSwitchStats.manualSwapsKey] ?? 0
    var byTier: [AutoSwitchStats.Tier: Int] = [:]
    for tier in AutoSwitchStats.Tier.allCases {
      byTier[tier] = counts[AutoSwitchStats.tierKey(tier)] ?? 0
    }
    switchesByTier = byTier
    precision = switches > 0 ? Double(switches - undos) / Double(switches) : nil
  }
}

extension StatsSnapshot {
  /// Compact summary, e.g. "12 corrections · 1 undo · 92% accurate".
  var summaryLine: String {
    var parts = [
      "\(switches) \(switches == 1 ? "correction" : "corrections")",
      "\(undos) \(undos == 1 ? "undo" : "undos")",
    ]
    if let precision = precision {
      parts.append("\(Int((min(max(precision, 0), 1) * 100).rounded()))% accurate")
    }
    return parts.joined(separator: " · ")
  }
}


/// Local counters for auto-switch activity: switches, undos, manual swaps.
/// Kept in the store, never sent anywhere. Today's counts roll over at local midnight.
final class AutoSwitchStats: ObservableObject {
  fileprivate static let switchesKey = "switches"
  fileprivate static let undosKey = "undos"
  fileprivate static let manualSwapsKey = "manualSwaps"
  fileprivate static func tierKey(_ tier: Tier) -> String { "tier.\(tier.rawValue)" }

  private let store: AutoSwitchStatsStore
  private let now: () -> Date

  init(store: AutoSwitchStatsStore, now: @escaping () -> Date) {
    self.store = store
    self.now = now
  }

  var today: StatsSnapshot {
    StatsSnapshot(counts: currentDayCounts(startOfToday: Calendar.current.startOfDay(for: now())))
  }

  var total: StatsSnapshot {
    StatsSnapshot(counts: store.autoSwitchStatsTotal())
  }

  func recordSwitch(tier: Tier) {
    record([AutoSwitchStats.switchesKey, AutoSwitchStats.tierKey(tier)])
  }

  func recordUndo() {
    record([AutoSwitchStats.undosKey])
  }

  func recordManualSwap() {
    record([AutoSwitchStats.manualSwapsKey])
  }

  /// A manual swap counts as a missed auto-switch only when auto-switch had its
  /// chance: it is active here, the word was finished with a space or Enter, and
  /// auto-switch looked at it and kept it. Pressing the action key mid-word, on
  /// an empty buffer, or right after our own correction (an undo) is not a miss.
  static func isMissedAutoSwitch(autoSwitchActive: Bool, wordInProgress: Bool, keptWordPending: Bool) -> Bool {
    autoSwitchActive && !wordInProgress && keptWordPending
  }

  /// The action key undoes our last correction only when it is pressed before
  /// anything else was typed, clicked or deleted. Pressed later — say, to fix
  /// the next word mid-way — it is a manual swap of that word, not an undo.
  static func isUndoOfCorrection(typedSinceCorrection: Bool) -> Bool {
    !typedSinceCorrection
  }

  func reset() {
    store.setAutoSwitchStatsTotal([:])
    store.setAutoSwitchStatsToday([:])
    store.setAutoSwitchStatsDay(nil)
    objectWillChange.send()
  }

  private func currentDayCounts(startOfToday: Date) -> [String: Int] {
    guard let day = store.autoSwitchStatsDay(),
          Calendar.current.isDate(day, inSameDayAs: startOfToday) else {
      return [:]
    }
    return store.autoSwitchStatsToday()
  }

  private func record(_ keys: [String]) {
    let startOfToday = Calendar.current.startOfDay(for: now())
    var todayCounts = currentDayCounts(startOfToday: startOfToday)
    var totalCounts = store.autoSwitchStatsTotal()
    for key in keys {
      todayCounts[key, default: 0] += 1
      totalCounts[key, default: 0] += 1
    }
    store.setAutoSwitchStatsDay(startOfToday)
    store.setAutoSwitchStatsToday(todayCounts)
    store.setAutoSwitchStatsTotal(totalCounts)
    objectWillChange.send()
  }
}

extension PreferenceStore: AutoSwitchStatsStore {
  func autoSwitchStatsTotal() -> [String: Int] {
    defaults.dictionary(forKey: autoSwitchStatsTotalKey) as? [String: Int] ?? [:]
  }

  func setAutoSwitchStatsTotal(_ counts: [String: Int]) {
    defaults.set(counts, forKey: autoSwitchStatsTotalKey)
  }

  func autoSwitchStatsToday() -> [String: Int] {
    defaults.dictionary(forKey: autoSwitchStatsTodayKey) as? [String: Int] ?? [:]
  }

  func setAutoSwitchStatsToday(_ counts: [String: Int]) {
    defaults.set(counts, forKey: autoSwitchStatsTodayKey)
  }

  func autoSwitchStatsDay() -> Date? {
    defaults.object(forKey: autoSwitchStatsDayKey) as? Date
  }

  func setAutoSwitchStatsDay(_ day: Date?) {
    if let day {
      defaults.set(day, forKey: autoSwitchStatsDayKey)
    } else {
      defaults.removeObject(forKey: autoSwitchStatsDayKey)
    }
  }
}

/// Shared by AppDelegate, MenuView and SettingsView.
let autoSwitchStats = AutoSwitchStats(store: preferenceStore, now: { Date() })
