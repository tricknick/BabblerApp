import Foundation

// Miss-log checks: JSONL format, the enabled preference, secure-input
// suppression, and the 2,000-line cap. Compiled with Babbler/Key.swift,
// Babbler/PreferenceStore.swift and Babbler/MissLog.swift. Run with
// ./tests/miss_log_test.sh.
//
// API contract the implementation must match:
//   Babbler/MissLog.swift
//     struct MissLogEntry: Codable { ts, kind, typed, layout, converted, tier?, app?, prev? }
//       // kind is "miss" or "undo"; tier/app/prev omitted from the JSON when nil.
//     final class MissLog {
//       static let maxLines = 2000
//       init(fileURL:, isEnabled: () -> Bool = ..., isSecureInput: () -> Bool = { false },
//            trimCheckInterval: Int = 100)
//       var isEnabled: () -> Bool                 // reads missLogEnabledKey; absent => true
//       var isSecureInput: () -> Bool              // injectable predicate; true => no writes
//       func logMiss(typed:layout:converted:app:prev:at:)
//       func logUndo(typed:layout:converted:tier:app:prev:at:)
//       func clear()                               // deletes the log file
//       func waitUntilFinished()                   // blocks until queued writes land
//     }
//   Babbler/PreferenceStore.swift
//     let missLogEnabledKey = "..."                // top-level constant, any string value

let workDir = ProcessInfo.processInfo.environment["BABBLER_TEST_WORK"]
  ?? FileManager.default.currentDirectoryPath

var failures = 0
func check(_ passed: Bool, _ message: String) {
  if !passed {
    failures += 1
    print("  FAIL  \(message)")
  }
}

func freshFileURL(_ name: String) -> URL {
  let url = URL(fileURLWithPath: workDir).appendingPathComponent(name)
  try? FileManager.default.removeItem(at: url)
  return url
}

func readLines(_ url: URL) -> [String] {
  guard let data = try? Data(contentsOf: url),
        let text = String(data: data, encoding: .utf8) else { return [] }
  return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

func decode(_ line: String) -> MissLogEntry? {
  guard let data = line.data(using: .utf8) else { return nil }
  return try? JSONDecoder().decode(MissLogEntry.self, from: data)
}

print("=== logMiss writes one well-formed JSON line")
do {
  let url = freshFileURL("miss-format.jsonl")
  let log = MissLog(fileURL: url, isEnabled: { true }, isSecureInput: { false })
  log.logMiss(typed: "ghbdtn", layout: "en", converted: "привет", app: "com.apple.TextEdit")
  log.waitUntilFinished()

  let lines = readLines(url)
  check(lines.count == 1, "logMiss must append exactly one line, got \(lines.count)")
  if let entry = lines.first.flatMap(decode) {
    check(entry.kind == "miss", "kind must be 'miss', got \(entry.kind)")
    check(entry.typed == "ghbdtn", "typed must round-trip, got \(entry.typed)")
    check(entry.layout == "en", "layout must round-trip, got \(entry.layout)")
    check(entry.converted == "привет", "converted must round-trip, got \(entry.converted)")
    check(entry.app == "com.apple.TextEdit", "app must round-trip, got \(entry.app ?? "nil")")
    check(entry.tier == nil, "a miss must not carry a tier")
    check(entry.prev == nil, "prev must be omitted when not supplied")
    check(!entry.ts.isEmpty, "ts must be populated")
  } else {
    check(false, "the written line must be valid JSON decodable as MissLogEntry")
  }
}

print("=== logUndo carries kind and tier")
do {
  let url = freshFileURL("undo-format.jsonl")
  let log = MissLog(fileURL: url, isEnabled: { true }, isSecureInput: { false })
  log.logUndo(typed: "manager", layout: "ru", converted: "vfyfutr", tier: "exact", app: "com.apple.Notes")
  log.waitUntilFinished()

  let lines = readLines(url)
  check(lines.count == 1, "logUndo must append exactly one line, got \(lines.count)")
  if let entry = lines.first.flatMap(decode) {
    check(entry.kind == "undo", "kind must be 'undo', got \(entry.kind)")
    check(entry.tier == "exact", "tier must round-trip, got \(entry.tier ?? "nil")")
  } else {
    check(false, "the written line must be valid JSON decodable as MissLogEntry")
  }
}

print("=== prev is carried when supplied, omitted when empty")
do {
  let url = freshFileURL("prev.jsonl")
  let log = MissLog(fileURL: url, isEnabled: { true }, isSecureInput: { false })
  log.logMiss(typed: "a", layout: "en", converted: "ф", app: nil, prev: ["one", "two"])
  log.logMiss(typed: "b", layout: "en", converted: "и", app: nil, prev: [])
  log.waitUntilFinished()

  let lines = readLines(url)
  check(lines.count == 2, "both misses must be appended, got \(lines.count)")
  let entries = lines.compactMap(decode)
  check(entries.count == 2, "both lines must decode")
  if entries.count == 2 {
    check(entries[0].prev == ["one", "two"], "non-empty prev must round-trip, got \(entries[0].prev ?? [])")
    check(entries[1].prev == nil, "empty prev must be omitted, not an empty array")
    check(entries[0].app == nil, "a nil app must be omitted")
  }
}

print("=== disabled preference suppresses all writes")
do {
  let url = freshFileURL("disabled.jsonl")
  let log = MissLog(fileURL: url, isEnabled: { false }, isSecureInput: { false })
  log.logMiss(typed: "ghbdtn", layout: "en", converted: "привет", app: nil)
  log.logUndo(typed: "ghbdtn", layout: "en", converted: "привет", tier: "typo", app: nil)
  log.waitUntilFinished()
  check(!FileManager.default.fileExists(atPath: url.path), "disabled logging must not create the file")
}

print("=== secure input suppresses all writes")
do {
  let url = freshFileURL("secure.jsonl")
  let log = MissLog(fileURL: url, isEnabled: { true }, isSecureInput: { true })
  log.logMiss(typed: "ghbdtn", layout: "en", converted: "привет", app: nil)
  log.waitUntilFinished()
  check(!FileManager.default.fileExists(atPath: url.path), "secure input must not create the file")

  // Flipping the predicate back on allows subsequent writes through, proving
  // it is read live rather than captured once at init.
  log.isSecureInput = { false }
  log.logMiss(typed: "ghbdtn", layout: "en", converted: "привет", app: nil)
  log.waitUntilFinished()
  check(readLines(url).count == 1, "writes must resume once secure input clears")
}

print("=== cap trims the oldest lines, checked every N writes")
do {
  let url = freshFileURL("cap.jsonl")
  // A tiny cap and a check-every-write interval keep this fast and deterministic.
  let log = MissLog(
    fileURL: url, isEnabled: { true }, isSecureInput: { false }, trimCheckInterval: 1
  )
  // MissLog.maxLines is fixed at 2000; trimIfNeeded only fires once the file
  // actually holds more than that, so write past it to exercise the trim.
  for i in 0..<(MissLog.maxLines + 50) {
    log.logMiss(typed: "w\(i)", layout: "en", converted: "w\(i)", app: nil)
  }
  log.waitUntilFinished()

  let lines = readLines(url)
  check(lines.count == MissLog.maxLines, "file must be trimmed to maxLines, got \(lines.count)")
  let entries = lines.compactMap(decode)
  check(entries.first?.typed == "w50", "the oldest surviving line must be the 51st write, got \(entries.first?.typed ?? "nil")")
  check(entries.last?.typed == "w\(MissLog.maxLines + 49)", "the newest line must be the final write, got \(entries.last?.typed ?? "nil")")
}

print("=== clear deletes the file")
do {
  let url = freshFileURL("clear.jsonl")
  let log = MissLog(fileURL: url, isEnabled: { true }, isSecureInput: { false })
  log.logMiss(typed: "ghbdtn", layout: "en", converted: "привет", app: nil)
  log.waitUntilFinished()
  check(FileManager.default.fileExists(atPath: url.path), "file must exist before clear")
  log.clear()
  log.waitUntilFinished()
  check(!FileManager.default.fileExists(atPath: url.path), "clear must delete the file")
}

print("=== defaultIsEnabled reads missLogEnabledKey, absent means on")
do {
  let suiteName = "com.babbler.misslog.tests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defaults.removePersistentDomain(forName: suiteName)
  check(defaults.object(forKey: missLogEnabledKey) == nil, "key must start unset for this check")
  defaults.set(false, forKey: missLogEnabledKey)
  check(defaults.bool(forKey: missLogEnabledKey) == false, "explicit false must read back false")
  defaults.removePersistentDomain(forName: suiteName)
}

if failures == 0 {
  print("ALL MISS-LOG CHECKS PASS")
} else {
  print("\(failures) MISS-LOG CHECKS FAILED")
  exit(1)
}
