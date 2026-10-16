import Foundation

// Decides which text the action key converts when no word was recorded, so that the
// user's own clipboard is never typed in place of a selection.
enum SelectionGuard {
  /// - axSelection: the focused element's selected text, or nil when the app does not expose it.
  ///   Empty is not trusted: Electron and web views report "" over a real selection.
  /// - copied: the clipboard string after Cmd+C, or nil when nothing arrived.
  /// - saved: the clipboard string saved before Cmd+C.
  /// - changeCountAfterClear / changeCountNow: pasteboard change counts after clearing it and
  ///   when `copied` was read.
  static func text(axSelection: String?, copied: String?, saved: String,
                   changeCountAfterClear: Int, changeCountNow: Int) -> String? {
    if let axSelection, !axSelection.isEmpty { return axSelection }
    guard let copied, !copied.isEmpty, changeCountNow > changeCountAfterClear else { return nil }
    // Identical to the old clipboard: an echo of it (an earlier restore, a clipboard manager),
    // not a copy of the selection.
    if copied == saved { return nil }
    return copied
  }
}
