import Foundation

/// Per-app defaults for whether auto-switch may rewrite a word in that app.
///
/// Terminals, IDEs and password managers are where an automatic rewrite is
/// most likely to be wrong, and most expensive when it is: a shell command, a
/// variable name, a master password. See docs/AUTO_SWITCH_PLAN.md.
enum AutoSwitchAppProfiles {
  /// Thin wrapper around PreferenceStore's `autoSwitchDefaultExcludedApps`:
  /// same list, single source of truth, kept there so PreferenceStore.swift
  /// still compiles without this file (see its doc comment).
  static let defaultExcludedBundleIds: Set<String> = Set(autoSwitchDefaultExcludedApps)

  /// JetBrains ships one bundle id per IDE (GoLand, PyCharm, WebStorm, ...),
  /// so a prefix covers the family instead of listing each one by hand.
  static let defaultExcludedBundlePrefixes: [String] = ["com.jetbrains."]

  /// Whether a word typed in `bundleId` may be auto-switched. A user override
  /// for that exact bundle id always wins over the defaults; a nil bundle id
  /// (no frontmost app could be identified) is never allowed.
  static func isAutoSwitchAllowed(bundleId: String?, userOverrides: [String: Bool]) -> Bool {
    guard let bundleId else { return false }
    if let override = userOverrides[bundleId] { return override }
    if defaultExcludedBundleIds.contains(bundleId) { return false }
    if defaultExcludedBundlePrefixes.contains(where: bundleId.hasPrefix) { return false }
    return true
  }
}
