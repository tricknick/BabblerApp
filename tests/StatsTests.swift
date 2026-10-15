import Foundation

// Local stats tests. Compiled with the engine sources plus Babbler/AutoSwitchStats*.swift.
// Run with ./tests/stats_test.sh.
//
// API contract the implementation must match:
//   Babbler/AutoSwitchStats.swift
//     extension AutoSwitchStats {
//       enum Tier: String, CaseIterable, Hashable { case exact, typo, ngram, phrase }
//         // Reuses AutoSwitchEngine.Tier for exact/typo. The engine's .languageModel is the
//         // ngram tier. phrase is the AppDelegate sweep of short words before an exact anchor;
//         // the engine has no case for it.
//     }
//     extension AutoSwitchStats.Tier {
//       init(engine: AutoSwitchEngine.Tier)                 // .exact→.exact, .typo→.typo, .languageModel→.ngram
//     }
//     protocol AutoSwitchStatsStore: AnyObject {
//       func autoSwitchStatsTotal() -> [String: Int]         // opaque keys; tests only round-trip them
//       func setAutoSwitchStatsTotal(_ counts: [String: Int])
//       func autoSwitchStatsToday() -> [String: Int]
//       func setAutoSwitchStatsToday(_ counts: [String: Int])
//       func autoSwitchStatsDay() -> Date?                   // start of the local day "today" belongs to
//       func setAutoSwitchStatsDay(_ day: Date?)
//     }
//     struct StatsSnapshot {
//       var switches: Int
//       var undos: Int
//       var manualSwaps: Int
//       var switchesByTier: [AutoSwitchStats.Tier: Int]      // tests read with `?? 0`
//       var precision: Double?                               // (switches - undos) / switches; nil when switches == 0
//     }
//     final class AutoSwitchStats {
//       init(store: AutoSwitchStatsStore, now: @escaping () -> Date)
//       func recordSwitch(tier: AutoSwitchStats.Tier)
//       func recordUndo()                 // undos += 1 only
//       func recordManualSwap()           // manualSwaps += 1 only
//       var today: StatsSnapshot { get }  // since start of the calendar day of now(); rolls over on read
//       var total: StatsSnapshot { get }  // all time since install or last reset()
//       func reset()                      // clears today and total, persisted through the store
//     }
//   PreferenceStore conformance to AutoSwitchStatsStore lives in AutoSwitchStats.swift, not tested here.

var failures = 0
func check(_ passed: Bool, _ message: String) {
  if !passed {
    failures += 1
    print("  FAIL  \(message)")
  }
}

func approx(_ value: Double?, _ expected: Double) -> Bool {
  guard let value else { return false }
  return abs(value - expected) < 1e-9
}

final class Clock {
  var date: Date
  init(_ date: Date) { self.date = date }
}

/// Local-calendar date, so the tests do not depend on the machine's time zone.
func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0, _ s: Int = 0) -> Date {
  Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

/// In-memory store standing in for PreferenceStore.
final class FakeAutoSwitchStatsStore: AutoSwitchStatsStore {
  var total: [String: Int] = [:]
  var today: [String: Int] = [:]
  var day: Date? = nil
  func autoSwitchStatsTotal() -> [String: Int] { total }
  func setAutoSwitchStatsTotal(_ counts: [String: Int]) { total = counts }
  func autoSwitchStatsToday() -> [String: Int] { today }
  func setAutoSwitchStatsToday(_ counts: [String: Int]) { today = counts }
  func autoSwitchStatsDay() -> Date? { day }
  func setAutoSwitchStatsDay(_ value: Date?) { day = value }
}

func makeStats(_ store: AutoSwitchStatsStore, _ clock: Clock) -> AutoSwitchStats {
  AutoSwitchStats(store: store, now: { clock.date })
}

func recordSwitches(_ stats: AutoSwitchStats, _ tier: AutoSwitchStats.Tier, _ n: Int) {
  for _ in 0..<n { stats.recordSwitch(tier: tier) }
}

// MARK: - Tier mapping

print("=== tier mapping from engine tiers")
check(AutoSwitchStats.Tier(engine: .exact) == .exact, "engine .exact must map to .exact")
check(AutoSwitchStats.Tier(engine: .typo) == .typo, "engine .typo must map to .typo")
check(AutoSwitchStats.Tier(engine: .languageModel) == .ngram, "engine .languageModel must map to .ngram")
check(AutoSwitchStats.Tier.allCases.count == 4, "Tier must have exactly 4 cases")

// MARK: - Counting and precision

print("=== counters and precision")
let freshStats = makeStats(FakeAutoSwitchStatsStore(), Clock(localDate(2026, 10, 14, 9)))
check(freshStats.today.switches == 0 && freshStats.total.switches == 0, "fresh stats must have zero switches")
check(freshStats.today.precision == nil, "fresh today precision must be nil")
check(freshStats.total.precision == nil, "fresh total precision must be nil")
check(freshStats.total.switchesByTier.values.allSatisfy { $0 == 0 }, "fresh byTier counts must all be zero")

let (storeC, clockC) = (FakeAutoSwitchStatsStore(), Clock(localDate(2026, 10, 14, 9)))
let statsC = makeStats(storeC, clockC)
recordSwitches(statsC, .exact, 3)
recordSwitches(statsC, .typo, 1)
recordSwitches(statsC, .ngram, 2)
recordSwitches(statsC, .phrase, 1)
let byTierC = statsC.total.switchesByTier
check(statsC.total.switches == 7, "7 switches recorded, got \(statsC.total.switches)")
check(byTierC[.exact] ?? 0 == 3, "exact tier must count 3, got \(byTierC[.exact] ?? 0)")
check(byTierC[.typo] ?? 0 == 1, "typo tier must count 1, got \(byTierC[.typo] ?? 0)")
check(byTierC[.ngram] ?? 0 == 2, "ngram tier must count 2, got \(byTierC[.ngram] ?? 0)")
check(byTierC[.phrase] ?? 0 == 1, "phrase tier must count 1, got \(byTierC[.phrase] ?? 0)")
check(byTierC.values.reduce(0, +) == statsC.total.switches, "byTier must sum to switches")
check(statsC.today.switches == 7, "today must match total on the same day")
check(approx(statsC.total.precision, 1.0), "no undos yet: precision must be 1.0")

statsC.recordUndo()
statsC.recordUndo()
check(statsC.total.undos == 2 && statsC.today.undos == 2, "2 undos must be counted in total and today")
check(statsC.total.switches == 7, "undos must not change the switch count")
check(approx(statsC.total.precision, 5.0 / 7.0), "precision must be (7-2)/7, got \(String(describing: statsC.total.precision))")

statsC.recordManualSwap()
statsC.recordManualSwap()
statsC.recordManualSwap()
statsC.recordManualSwap()
check(statsC.total.manualSwaps == 4 && statsC.today.manualSwaps == 4, "4 manual swaps must be counted")
check(statsC.total.switches == 7 && statsC.total.undos == 2, "manual swaps must not change switches or undos")
check(approx(statsC.total.precision, 5.0 / 7.0), "manual swaps must not change precision")

let (storeU, clockU) = (FakeAutoSwitchStatsStore(), Clock(localDate(2026, 10, 14, 9)))
let statsU = makeStats(storeU, clockU)
statsU.recordUndo()
check(statsU.total.undos == 1, "undo-only stats must count the undo")
check(statsU.total.precision == nil, "precision must be nil when there are no switches, even with undos")
check(statsU.today.precision == nil, "today precision must be nil when there are no switches")

let (storeP, clockP) = (FakeAutoSwitchStatsStore(), Clock(localDate(2026, 10, 14, 9)))
let statsP = makeStats(storeP, clockP)
recordSwitches(statsP, .exact, 2)
check(approx(statsP.total.precision, 1.0), "2 switches and 0 undos must give precision 1.0")
statsP.recordUndo()
statsP.recordUndo()
check(approx(statsP.total.precision, 0.0), "2 switches and 2 undos must give precision 0.0")

// MARK: - Today versus total, calendar-day rollover

print("=== today rolls over at the calendar day")
let (storeR, clockR) = (FakeAutoSwitchStatsStore(), Clock(localDate(2026, 10, 14, 9)))
let statsR = makeStats(storeR, clockR)
recordSwitches(statsR, .exact, 2)
statsR.recordUndo()

clockR.date = localDate(2026, 10, 14, 23, 59, 59)
check(statsR.today.switches == 2 && statsR.today.undos == 1, "late the same day, today must still hold the counts")

clockR.date = localDate(2026, 10, 15, 0, 0, 1)
check(statsR.today.switches == 0, "after midnight today.switches must reset to 0, got \(statsR.today.switches)")
check(statsR.today.undos == 0 && statsR.today.manualSwaps == 0, "after midnight today undos and manual swaps must reset")
check(statsR.today.precision == nil, "after midnight today precision must be nil")
check(statsR.total.switches == 2 && statsR.total.undos == 1, "total must keep counts across the day change")

recordSwitches(statsR, .ngram, 1)
statsR.recordManualSwap()
check(statsR.today.switches == 1 && statsR.today.switchesByTier[.ngram] ?? 0 == 1, "new day: today must count only new switches")
check(statsR.total.switches == 3 && statsR.total.manualSwaps == 1, "total must accumulate across days")

let (storeY, clockY) = (FakeAutoSwitchStatsStore(), Clock(localDate(2026, 12, 31, 23, 59, 30)))
let statsY = makeStats(storeY, clockY)
statsY.recordSwitch(tier: .exact)
clockY.date = localDate(2027, 1, 1, 0, 0, 5)
check(statsY.today.switches == 0, "year boundary must also roll today over")
check(statsY.total.switches == 1, "year boundary must keep total")

// MARK: - Persistence

print("=== persistence through the store")
let (storeS, clockS) = (FakeAutoSwitchStatsStore(), Clock(localDate(2026, 10, 14, 10)))
let statsS = makeStats(storeS, clockS)
recordSwitches(statsS, .exact, 2)
recordSwitches(statsS, .ngram, 1)
statsS.recordUndo()
statsS.recordManualSwap()

let reloadedSameDay = makeStats(storeS, clockS)
check(reloadedSameDay.today.switches == 3, "reload on the same day: today.switches must be 3, got \(reloadedSameDay.today.switches)")
check(reloadedSameDay.today.undos == 1 && reloadedSameDay.today.manualSwaps == 1, "reload on the same day: undos and manual swaps must persist")
check(reloadedSameDay.today.switchesByTier[.ngram] ?? 0 == 1, "reload: byTier must persist")
check(reloadedSameDay.total.switches == 3 && reloadedSameDay.total.undos == 1, "reload: total must persist")
check(approx(reloadedSameDay.total.precision, 2.0 / 3.0), "reload: precision must be recomputed from persisted counts")

reloadedSameDay.recordSwitch(tier: .typo)
check(reloadedSameDay.today.switches == 4 && reloadedSameDay.total.switches == 4, "writing after reload must add to the persisted counts, not reset them")

clockS.date = localDate(2026, 10, 15, 8)
let reloadedNextDay = makeStats(storeS, clockS)
check(reloadedNextDay.today.switches == 0, "reload on a later day: today must be empty")
check(reloadedNextDay.total.switches == 4, "reload on a later day: total must still be 4, got \(reloadedNextDay.total.switches)")
reloadedNextDay.recordSwitch(tier: .exact)
check(reloadedNextDay.today.switches == 1 && reloadedNextDay.total.switches == 5, "first write on a later day: today 1, total 5")

let emptyStore = FakeAutoSwitchStatsStore()
let fromEmpty = makeStats(emptyStore, Clock(localDate(2026, 10, 14, 10)))
check(fromEmpty.total.switches == 0 && fromEmpty.today.switches == 0, "an empty store must read as zero counts")

// MARK: - Reset

print("=== reset")
let (storeX, clockX) = (FakeAutoSwitchStatsStore(), Clock(localDate(2026, 10, 14, 10)))
let statsX = makeStats(storeX, clockX)
recordSwitches(statsX, .exact, 2)
statsX.recordUndo()
statsX.recordManualSwap()
statsX.reset()
check(statsX.today.switches == 0 && statsX.today.undos == 0 && statsX.today.manualSwaps == 0, "reset must clear today")
check(statsX.total.switches == 0 && statsX.total.undos == 0 && statsX.total.manualSwaps == 0, "reset must clear total")
check(statsX.total.precision == nil && statsX.today.precision == nil, "reset must leave precision nil")
check(statsX.total.switchesByTier.values.allSatisfy { $0 == 0 }, "reset must clear byTier")

let reloadedAfterReset = makeStats(storeX, clockX)
check(reloadedAfterReset.total.switches == 0 && reloadedAfterReset.total.undos == 0, "reset must persist: reload reads zeros")

statsX.recordSwitch(tier: .phrase)
check(statsX.total.switches == 1 && statsX.today.switches == 1, "recording after reset must count from zero")

// MARK: - Summary

// A manual swap is a missed auto-switch only when auto-switch had its chance:
// it is active, the word was finished (space/Enter) and auto-switch kept it.
check(AutoSwitchStats.isMissedAutoSwitch(autoSwitchActive: true, wordInProgress: false, keptWordPending: true),
      "finished kept word swapped by hand is a miss")
check(!AutoSwitchStats.isMissedAutoSwitch(autoSwitchActive: true, wordInProgress: true, keptWordPending: true),
      "swap before the word was finished is not a miss")
check(!AutoSwitchStats.isMissedAutoSwitch(autoSwitchActive: true, wordInProgress: false, keptWordPending: false),
      "swap with no kept word (nothing typed, or undo of a correction) is not a miss")
check(!AutoSwitchStats.isMissedAutoSwitch(autoSwitchActive: false, wordInProgress: false, keptWordPending: true),
      "swap while auto-switch is off or excluded in the app is not a miss")

// The action key undoes a correction only when nothing was typed after it.
check(AutoSwitchStats.isUndoOfCorrection(typedSinceCorrection: false), "Alt straight after a correction is an undo")
check(!AutoSwitchStats.isUndoOfCorrection(typedSinceCorrection: true), "Alt after typing more is not an undo")

if failures == 0 {
  print("ALL STATS CHECKS PASS")
} else {
  print("\(failures) stats check(s) FAILED")
  exit(1)
}
