import Foundation

// Selection tests (run via tests/selection_test.sh).
//
// With no recorded word, the action key converts the selection. Babbler reads it from
// Accessibility when the app exposes it, otherwise copies it with Cmd+C. Pasting the
// user's own clipboard instead of a selection must never happen: a copy that never
// arrived (nothing selected, slow app) or an old clipboard written back by anyone
// (an earlier restore, a clipboard manager) leaves the saved clipboard text in place.

var failures = 0
func check(_ name: String, _ got: String?, _ want: String?) {
  if got != want {
    failures += 1
    print("FAIL \(name): got \(got.map { "'\($0)'" } ?? "nil"), want \(want.map { "'\($0)'" } ?? "nil")")
  }
}

// Accessibility returned a selection: use it, no clipboard involved.
check("ax selection", SelectionGuard.text(axSelection: "ghbdtn", copied: nil, saved: "x",
                                          changeCountAfterClear: 1, changeCountNow: 1), "ghbdtn")
// Some apps (Electron, web views) report an empty selection that is not: fall back to Cmd+C.
check("ax empty, echo of clipboard", SelectionGuard.text(axSelection: "", copied: "And I changed",
                                                         saved: "And I changed",
                                                         changeCountAfterClear: 1, changeCountNow: 2), nil)
check("ax empty, real copy", SelectionGuard.text(axSelection: "", copied: "ghbdtn", saved: "And I changed",
                                                 changeCountAfterClear: 1, changeCountNow: 2), "ghbdtn")

// Clipboard fallback.
check("copied selection", SelectionGuard.text(axSelection: nil, copied: "ghbdtn", saved: "And I changed",
                                              changeCountAfterClear: 1, changeCountNow: 2), "ghbdtn")
check("nothing copied", SelectionGuard.text(axSelection: nil, copied: nil, saved: "And I changed",
                                            changeCountAfterClear: 1, changeCountNow: 1), nil)
check("old clipboard written back", SelectionGuard.text(axSelection: nil, copied: "And I changed success",
                                                        saved: "And I changed success",
                                                        changeCountAfterClear: 1, changeCountNow: 2), nil)
check("no write since clear", SelectionGuard.text(axSelection: nil, copied: "stale", saved: "other",
                                                  changeCountAfterClear: 3, changeCountNow: 3), nil)
check("multi-line copy kept", SelectionGuard.text(axSelection: nil, copied: "line one\nline two", saved: "",
                                                      changeCountAfterClear: 1, changeCountNow: 2), "line one\nline two")
check("empty copy", SelectionGuard.text(axSelection: nil, copied: "", saved: "",
                                        changeCountAfterClear: 1, changeCountNow: 2), nil)

if failures == 0 { print("selection tests: all passed") } else { print("selection tests: \(failures) failed"); exit(1) }
