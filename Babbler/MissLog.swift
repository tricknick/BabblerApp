import Foundation

/// One line of `misses.jsonl`: a word auto-switch left alone that the user
/// then had to fix by hand (`kind == "miss"`), or a correction the user undid
/// (`kind == "undo"`). Encoded with `JSONEncoder`, which omits nil optionals,
/// so `tier`, `app` and `prev` are absent from the line when unknown.
struct MissLogEntry: Codable, Equatable {
  var ts: String
  var kind: String
  var typed: String
  var layout: String
  var converted: String
  var tier: String?
  var app: String?
  var prev: [String]?
}

/// Append-only local log of real auto-switch misses, kept so detection can be
/// reviewed and improved later. Never sent anywhere; lives next to the crash
/// log under `~/Library/Application Support/Babbler` (see CrashLogger.swift).
///
/// Every write happens on a private serial queue, so a slow disk never blocks
/// typing — `logMiss`/`logUndo` only ever block the caller long enough to
/// check the enabled/secure-input predicates and encode the entry.
///
/// `isEnabled` and `isSecureInput` are injectable so tests can drive both
/// without touching real preferences or `SecurityInputUtils`. AppDelegate
/// wires `isSecureInput` to its own `isSecurityInput` state.
final class MissLog {
  /// Upper bound on stored lines; oldest are trimmed first.
  static let maxLines = 2000
  /// How many writes to batch between trim checks — trimming reads and
  /// rewrites the whole file, so it is not worth doing on every write.
  static let defaultTrimCheckInterval = 100

  static let directory: URL = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("Babbler", isDirectory: true)
  }()

  static let defaultFileURL = directory.appendingPathComponent("misses.jsonl")

  /// Shared instance the app logs through. Wire `isSecureInput` once at
  /// startup (see AppDelegate.finishApplicationSetup).
  static let shared = MissLog(fileURL: defaultFileURL)

  let fileURL: URL
  var isEnabled: () -> Bool
  var isSecureInput: () -> Bool

  private let queue = DispatchQueue(label: "com.babbler.misslog", qos: .utility)
  private let trimCheckInterval: Int
  private var writesSinceTrimCheck = 0

  init(
    fileURL: URL,
    isEnabled: @escaping () -> Bool = MissLog.defaultIsEnabled,
    isSecureInput: @escaping () -> Bool = { false },
    trimCheckInterval: Int = MissLog.defaultTrimCheckInterval
  ) {
    self.fileURL = fileURL
    self.isEnabled = isEnabled
    self.isSecureInput = isSecureInput
    self.trimCheckInterval = trimCheckInterval
  }

  /// Reads `missLogEnabledKey` (PreferenceStore.swift); absent means on.
  static func defaultIsEnabled() -> Bool {
    if UserDefaults.standard.object(forKey: missLogEnabledKey) == nil { return true }
    return UserDefaults.standard.bool(forKey: missLogEnabledKey)
  }

  /// A manual swap of a word auto-switch had the chance to catch and left alone.
  func logMiss(
    typed: String, layout: String, converted: String,
    app: String?, prev: [String]? = nil, at date: Date = Date()
  ) {
    log(kind: "miss", typed: typed, layout: layout, converted: converted, tier: nil, app: app, prev: prev, at: date)
  }

  /// The user undid an automatic correction, so the word they typed was right as it stood.
  func logUndo(
    typed: String, layout: String, converted: String, tier: String?,
    app: String?, prev: [String]? = nil, at date: Date = Date()
  ) {
    log(kind: "undo", typed: typed, layout: layout, converted: converted, tier: tier, app: app, prev: prev, at: date)
  }

  /// Deletes the log file. Runs on the write queue so it cannot race a pending append.
  func clear() {
    queue.async { [weak self] in
      guard let self else { return }
      try? FileManager.default.removeItem(at: self.fileURL)
    }
  }

  /// Blocks until every write queued so far has completed. Test-only: lets a
  /// synchronous assertion follow an async `logMiss`/`logUndo`/`clear` call.
  func waitUntilFinished() {
    queue.sync {}
  }

  private func log(
    kind: String, typed: String, layout: String, converted: String,
    tier: String?, app: String?, prev: [String]?, at date: Date
  ) {
    guard isEnabled(), !isSecureInput() else { return }
    let entry = MissLogEntry(
      ts: ISO8601DateFormatter().string(from: date),
      kind: kind,
      typed: typed,
      layout: layout,
      converted: converted,
      tier: tier,
      app: app,
      prev: (prev?.isEmpty == false) ? prev : nil
    )
    queue.async { [weak self] in
      self?.append(entry)
    }
  }

  private func append(_ entry: MissLogEntry) {
    guard let data = try? JSONEncoder().encode(entry),
          let line = String(data: data, encoding: .utf8) else { return }
    let fullLine = (line + "\n").data(using: .utf8)!

    try? FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    if let handle = try? FileHandle(forWritingTo: fileURL) {
      handle.seekToEndOfFile()
      handle.write(fullLine)
      try? handle.close()
    } else {
      try? fullLine.write(to: fileURL, options: .atomic)
    }

    writesSinceTrimCheck += 1
    if writesSinceTrimCheck >= trimCheckInterval {
      writesSinceTrimCheck = 0
      trimIfNeeded()
    }
  }

  private func trimIfNeeded() {
    guard let data = try? Data(contentsOf: fileURL),
          let content = String(data: data, encoding: .utf8) else { return }
    var lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    guard lines.count > Self.maxLines else { return }
    lines.removeFirst(lines.count - Self.maxLines)
    let trimmed = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
    try? trimmed.write(to: fileURL, options: .atomic)
  }
}

/// Shared by AppDelegate and SettingsView.
let missLog = MissLog.shared
