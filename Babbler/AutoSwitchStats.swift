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

    /// Short Russian label for the settings breakdown.
    var title: String {
      switch self {
      case .exact: return "по словарю"
      case .typo: return "опечатка"
      case .ngram: return "по частотам"
      case .phrase: return "фраза"
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
  /// Compact Russian summary, e.g. "12 исправлений · 1 отмена · точность 92%".
  var summaryLine: String {
    var parts = [
      "\(switches) \(russianPlural(switches, "исправление", "исправления", "исправлений"))",
      "\(undos) \(russianPlural(undos, "отмена", "отмены", "отмен"))",
    ]
    if let precision = precision {
      parts.append("точность \(Int((min(max(precision, 0), 1) * 100).rounded()))%")
    }
    return parts.joined(separator: " · ")
  }
}

private func russianPlural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
  if (11...14).contains(n % 100) { return many }
  switch n % 10 {
  case 1: return one
  case 2...4: return few
  default: return many
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
