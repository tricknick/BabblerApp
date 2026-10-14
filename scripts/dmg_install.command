#!/bin/bash
# Installs (or updates) Babbler from the mounted DMG into /Applications.
# Shipped inside the DMG as "Install Babbler.command".
set -euo pipefail

BUNDLE_ID="eugene.Babbler"
SRC="$(cd "$(dirname "$0")" && pwd)/Babbler.app"
DEST="/Applications/Babbler.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

designated_requirement() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p' || true
}

# Prints yes if an app is already installed and its designated requirement differs from
# the new app's (so old TCC grants would no longer match); otherwise prints no.
tcc_reset_decision() {
  local installed="$1" new="$2"
  if [[ ! -d "$installed" ]]; then
    echo no
  elif [[ "$(designated_requirement "$installed")" != "$(designated_requirement "$new")" ]]; then
    echo yes
  else
    echo no
  fi
}

if [[ "${1:-}" == "--dry-run-tcc" ]]; then
  echo "TCC_RESET=$(tcc_reset_decision "${2:-}" "${3:-}")"
  exit 0
fi

if [[ ! -d "$SRC" ]]; then
  echo "Babbler.app not found next to this script ($SRC)" >&2
  exit 1
fi

echo "==> Stopping running Babbler..."
osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
  pgrep -f "Babbler.app/Contents/MacOS/Babbler" >/dev/null || break
  sleep 1
done
for pid in $(pgrep -f "Babbler.app/Contents/MacOS/Babbler" || true); do
  kill "$pid" 2>/dev/null || true
done

RESET_TCC="$(tcc_reset_decision "$DEST" "$SRC")"

echo "==> Installing to $DEST..."
rm -rf "$DEST"
ditto "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Only the /Applications copy may be launched by name or at login
"$LSREGISTER" -u "$SRC" 2>/dev/null || true
"$LSREGISTER" -f "$DEST" 2>/dev/null || true

# Grants are keyed to the designated requirement. Reset them only when it changed
# (e.g. first move from ad-hoc to the stable signing identity); otherwise they persist.
if [[ "$RESET_TCC" == "yes" ]]; then
  echo "==> Signature changed; resetting Accessibility / Input Monitoring grants for Babbler..."
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  tccutil reset ListenEvent "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

echo "==> Launching Babbler..."
open "$DEST"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true

cat <<'EOF'

Готово. Включите Babbler в:
  Конфиденциальность и безопасность → Универсальный доступ (Accessibility)
  Конфиденциальность и безопасность → Мониторинг ввода (Input Monitoring)
Затем перезапустите Babbler (меню Babbler → Quit, и снова открыть из Программ).

Done. Enable Babbler in Accessibility and Input Monitoring, then relaunch it.
EOF
