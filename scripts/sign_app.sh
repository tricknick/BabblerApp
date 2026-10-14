#!/bin/bash
# Signs an app bundle with the "Babbler Local Signing" identity (see setup_signing.sh).
# Falls back to ad-hoc signing with a warning if the identity is missing.
set -euo pipefail

IDENTITY_NAME="Babbler Local Signing"
BUNDLE_ID="eugene.Babbler"
APP="${1:-}"

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "usage: $0 <path-to-app>" >&2
  exit 1
fi

HASH="$(security find-identity -p codesigning 2>/dev/null \
  | awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }')"

if [[ -n "$HASH" ]]; then
  codesign --force --deep -s "$HASH" --identifier "$BUNDLE_ID" "$APP"
  echo "==> Signed $APP with \"$IDENTITY_NAME\" ($HASH)"
else
  echo "WARNING: signing identity \"$IDENTITY_NAME\" not found; falling back to ad-hoc signing." >&2
  echo "WARNING: run scripts/setup_signing.sh once to keep Accessibility/Input Monitoring grants across updates." >&2
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
fi
