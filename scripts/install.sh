#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Babbler.xcodeproj"
SCHEME="Babbler"
CONFIGURATION="Release"
DERIVED_DATA_PATH="$ROOT_DIR/build"
APP_NAME="Babbler"
INSTALL_DIR="/Applications"

echo "==> Building $APP_NAME (Release, signed)..."

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | grep -E "^(Build |Compil|\*\*)" | tail -5

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: Build product not found at $APP_PATH" >&2
  exit 1
fi

echo "==> Stopping running $APP_NAME..."
pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true

echo "==> Installing to $INSTALL_DIR/$APP_NAME.app..."
rm -rf "$INSTALL_DIR/$APP_NAME.app"
ditto "$APP_PATH" "$INSTALL_DIR/$APP_NAME.app"
# Seal the bundle so TCC (Accessibility / Input Monitoring) keys on a stable bundle signature
"$ROOT_DIR/scripts/sign_app.sh" "$INSTALL_DIR/$APP_NAME.app"

# Keep LaunchServices from launching the build copy (different signature → permissions look missing)
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$APP_PATH" 2>/dev/null || true
"$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true

echo "==> Launching $APP_NAME..."
open "$INSTALL_DIR/$APP_NAME.app"

echo "==> Done! $APP_NAME is running."
