#!/bin/bash
set -euo pipefail

# Builds a Release DMG for Babbler
# Usage: ./scripts/make_dmg.sh [VERSION] [--no-build]
# VERSION: semantic version string (default: 1.7); can also be set via $VERSION env var
# --no-build: skip xcodebuild, reuse existing build/Build/Products/Release/Babbler.app

# Parse arguments (support any order)
VERSION="${VERSION:-1.7}"
NO_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --no-build)
      NO_BUILD=1
      ;;
    *)
      # Treat as version if it doesn't start with --
      if [[ ! "$arg" =~ ^-- ]]; then
        VERSION="$arg"
      fi
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_OUTPUT_DIR="$PROJECT_ROOT/build/Build/Products/Release"
APP_PATH="$BUILD_OUTPUT_DIR/Babbler.app"
DMG_OUTPUT_DIR="$PROJECT_ROOT/dist"
DMG_PATH="$DMG_OUTPUT_DIR/Babbler-${VERSION}.dmg"
STAGING_DIR="$PROJECT_ROOT/build/dmg-staging"
README_PATH="$STAGING_DIR/README.txt"

mkdir -p "$DMG_OUTPUT_DIR"

# Step 1: Build (unless --no-build is set)
if [[ $NO_BUILD -eq 0 ]]; then
  echo "Building Release configuration..."
  xcodebuild \
    -project "$PROJECT_ROOT/Babbler.xcodeproj" \
    -scheme Babbler \
    -configuration Release \
    -derivedDataPath "$PROJECT_ROOT/build" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | grep -E "^(BUILD|error:)" || true
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: app not found at $APP_PATH" >&2
  exit 1
fi

# Step 2: Stage and ad-hoc sign the staged copy (never the build copy, so it can't be
# confused with the installed app by LaunchServices / TCC)
echo "Staging DMG contents..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/Babbler.app"
echo "Ad-hoc signing the app..."
codesign --force --deep --sign - "$STAGING_DIR/Babbler.app"
ln -s /Applications "$STAGING_DIR/Applications"

# Write README.txt
cat > "$README_PATH" << 'EOF'
Installation on another Mac

To install Babbler from this DMG:

1. Drag Babbler.app into Applications folder.

2. First launch: app is not notarized → Gatekeeper may block it.
   Fix: right-click Babbler.app → Open → Open
   OR: xattr -dr com.apple.quarantine /Applications/Babbler.app
   macOS 15+: System Settings → Privacy & Security → "Open Anyway"

3. Grant permissions: quit Babbler, then open System Settings →
   Privacy & Security → Accessibility AND Input Monitoring →
   enable Babbler. Relaunch Babbler.

4. After updating to a new build, permissions must be re-granted
   (remove old Babbler entry with "–" and add again), because the
   ad-hoc signature changes.

5. Optional: enable Launch at Login in Babbler settings.

---

Установка на другом Mac

Для установки Babbler из этого DMG:

1. Перетащите Babbler.app в папку Applications.

2. При первом запуске: приложение не нотаризировано → Gatekeeper может
   заблокировать. Решение: правый клик по Babbler.app → Open → Open
   ИЛИ: xattr -dr com.apple.quarantine /Applications/Babbler.app
   macOS 15+: System Settings → Privacy & Security → "Open Anyway"

3. Выдайте разрешения: закройте Babbler, затем откройте System Settings →
   Privacy & Security → Accessibility И Input Monitoring →
   включите Babbler. Перезапустите Babbler.

4. При обновлении на новую сборку разрешения нужно выдать заново
   (удалите старую запись Babbler и добавьте её снова), так как
   ad-hoc подпись изменяется.

5. Опционально: включите Launch at Login в настройках Babbler.
EOF

# Step 4: Create DMG
echo "Creating DMG..."
hdiutil create \
  -volname "Babbler $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

# Step 5: Cleanup staging
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$STAGING_DIR/Babbler.app" 2>/dev/null || true
rm -rf "$STAGING_DIR"

# Step 6: Report results
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo ""
echo "DMG created successfully:"
echo "  Path:   $DMG_PATH"
echo "  Size:   $DMG_SIZE"
echo "  SHA256: $DMG_SHA256"
