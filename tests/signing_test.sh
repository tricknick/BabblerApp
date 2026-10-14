#!/bin/bash
#
# Part A: stable code signing regression checks.
#
# Contracts under test (implemented by others):
#   scripts/setup_signing.sh            idempotent; creates the "Babbler Local Signing"
#                                       code-signing identity in the login keychain.
#   scripts/sign_app.sh <app>           signs <app> with "Babbler Local Signing" (exit 0).
#                                       If the identity is missing it falls back to ad-hoc
#                                       with a warning on stderr (exit 0).
#   scripts/dmg_install.command --dry-run-tcc <installed_app_or_missing_path> <new_app>
#                                       prints exactly TCC_RESET=yes or TCC_RESET=no to
#                                       stdout and never touches TCC or /Applications.
#
# Expected DR: identifier "eugene.Babbler" and certificate leaf = H"<sha1>", no cdhash.
#
#   ./tests/signing_test.sh            exit 0 = all PASS, exit 1 = at least one FAIL

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

IDENTITY_NAME="Babbler Local Signing"
BUNDLE_ID="eugene.Babbler"
WORK_DIR="$ROOT_DIR/build/signing-test"
DERIVED_DATA="$WORK_DIR/derived"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/Babbler.app"
APP_A="$WORK_DIR/copy-a/Babbler.app"
APP_B="$WORK_DIR/copy-b/Babbler.app"
APP_ADHOC="$WORK_DIR/adhoc/Babbler.app"
MISSING_APP="$WORK_DIR/does-not-exist/Babbler.app"
SETUP="$ROOT_DIR/scripts/setup_signing.sh"
SIGN_APP="$ROOT_DIR/scripts/sign_app.sh"
DMG_INSTALL="$ROOT_DIR/scripts/dmg_install.command"
INSTALL_SH="$ROOT_DIR/scripts/install.sh"
MAKE_DMG="$ROOT_DIR/scripts/make_dmg.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1${2:+ — $2}"; }

# check <name> <command...>: PASS when command exits 0
check() {
  local name="$1"; shift
  local out
  if out=$("$@" 2>&1); then
    pass "$name"
  else
    fail "$name" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi
}

# Designated requirement of an app bundle (codesign prints it on stderr)
designated_requirement() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'
}

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

echo "== 1. Signing identity setup =="

check "scripts/setup_signing.sh exists" test -f "$SETUP"
check "scripts/sign_app.sh exists" test -f "$SIGN_APP"

if [[ -f "$SETUP" ]]; then
  check "setup_signing.sh first run exits 0" bash "$SETUP"
  check "setup_signing.sh second run exits 0 (idempotent)" bash "$SETUP"

  identity_lines=$(security find-identity -p codesigning 2>/dev/null | grep -c "\"$IDENTITY_NAME\"" || true)
  if [[ "$identity_lines" -ge 1 ]]; then
    pass "codesigning identity \"$IDENTITY_NAME\" is listed by security find-identity"
  else
    fail "codesigning identity \"$IDENTITY_NAME\" is listed by security find-identity" "not found"
  fi

  if [[ "$identity_lines" -eq 1 ]]; then
    pass "identity exists exactly once after two setup runs"
  else
    fail "identity exists exactly once after two setup runs" "found $identity_lines entries"
  fi
else
  fail "setup_signing.sh first run exits 0" "script missing"
  fail "setup_signing.sh second run exits 0 (idempotent)" "script missing"
  fail "codesigning identity \"$IDENTITY_NAME\" is listed by security find-identity" "script missing"
  fail "identity exists exactly once after two setup runs" "script missing"
fi

echo "== 2. Build and sign =="

BUILD_OK=0
if xcodebuild \
  -project "$ROOT_DIR/Babbler.xcodeproj" \
  -scheme Babbler \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build > "$WORK_DIR/build.log" 2>&1 && [[ -d "$BUILT_APP" ]]; then
  BUILD_OK=1
  pass "xcodebuild Release build produces Babbler.app"
else
  fail "xcodebuild Release build produces Babbler.app" "see $WORK_DIR/build.log"
fi

SIGN_OK=0
if [[ $BUILD_OK -eq 1 && -f "$SIGN_APP" ]]; then
  mkdir -p "$WORK_DIR/copy-a" "$WORK_DIR/copy-b" "$WORK_DIR/adhoc"
  ditto "$BUILT_APP" "$APP_A"
  ditto "$BUILT_APP" "$APP_B"
  ditto "$BUILT_APP" "$APP_ADHOC"

  # Signing A, then re-signing A after an unrelated change, then signing B (different
  # content → different cdhash) must all yield the same designated requirement.
  if bash "$SIGN_APP" "$APP_A" >/dev/null 2>&1; then
    pass "sign_app.sh signs copy A (exit 0)"
    SIGN_OK=1
  else
    fail "sign_app.sh signs copy A (exit 0)"
  fi

  if [[ $SIGN_OK -eq 1 ]]; then
    echo "signing-test marker" > "$APP_B/Contents/Resources/signing-test-marker.txt"
    if bash "$SIGN_APP" "$APP_B" >/dev/null 2>&1; then
      pass "sign_app.sh signs copy B with extra resource (exit 0)"
    else
      fail "sign_app.sh signs copy B with extra resource (exit 0)"
      SIGN_OK=0
    fi
  fi

  if [[ $SIGN_OK -eq 1 ]]; then
    echo "resign" >> "$APP_A/Contents/Resources/signing-test-marker.txt"
    if bash "$SIGN_APP" "$APP_A" >/dev/null 2>&1; then
      pass "sign_app.sh re-signs copy A after a change (exit 0)"
    else
      fail "sign_app.sh re-signs copy A after a change (exit 0)"
      SIGN_OK=0
    fi
  fi
else
  fail "sign_app.sh signs copy A (exit 0)" "build or sign_app.sh missing"
fi

echo "== 3. Designated requirement stability =="

if [[ $SIGN_OK -eq 1 ]]; then
  DR_A=$(designated_requirement "$APP_A")
  DR_B=$(designated_requirement "$APP_B")
  echo "    DR A: $DR_A"
  echo "    DR B: $DR_B"

  if [[ -n "$DR_A" && "$DR_A" == "$DR_B" ]]; then
    pass "designated requirement identical across different builds/copies"
  else
    fail "designated requirement identical across different builds/copies" "A='$DR_A' B='$DR_B'"
  fi

  for dr_name in "A" "B"; do
    dr_var="DR_$dr_name"
    dr_val="${!dr_var}"

    if [[ "$dr_val" == *"identifier \"$BUNDLE_ID\""* ]]; then
      pass "DR $dr_name contains identifier \"$BUNDLE_ID\""
    else
      fail "DR $dr_name contains identifier \"$BUNDLE_ID\"" "$dr_val"
    fi

    if [[ "$dr_val" == *"certificate leaf"* ]]; then
      pass "DR $dr_name uses certificate leaf"
    else
      fail "DR $dr_name uses certificate leaf" "$dr_val"
    fi

    if [[ "$dr_val" != *"cdhash"* ]]; then
      pass "DR $dr_name has no cdhash"
    else
      fail "DR $dr_name has no cdhash" "$dr_val"
    fi
  done

  check "codesign --verify --deep --strict passes on signed app" \
    codesign --verify --deep --strict "$APP_A"
  check "codesign --verify --deep --strict passes on second signed app" \
    codesign --verify --deep --strict "$APP_B"
else
  for name in \
    "designated requirement identical across different builds/copies" \
    "DR contains identifier \"$BUNDLE_ID\"" \
    "DR uses certificate leaf" \
    "DR has no cdhash" \
    "codesign --verify --deep --strict passes on signed app"; do
    fail "$name" "signing step did not complete"
  done
fi

echo "== 4. dmg_install.command TCC reset decision =="

if [[ -f "$DMG_INSTALL" ]]; then
  # Stub tccutil on PATH: the dry run must never invoke it.
  TCC_STUB_DIR="$WORK_DIR/tcc-stub"
  TCC_MARKER="$WORK_DIR/tccutil-was-called"
  mkdir -p "$TCC_STUB_DIR"
  printf '#!/bin/sh\necho called >> "%s"\n' "$TCC_MARKER" > "$TCC_STUB_DIR/tccutil"
  chmod +x "$TCC_STUB_DIR/tccutil"

  tcc_decision() {
    PATH="$TCC_STUB_DIR:$PATH" bash "$DMG_INSTALL" --dry-run-tcc "$1" "$2" 2>/dev/null
  }

  expect_decision() {
    local name="$1" installed="$2" new="$3" expected="$4" got
    got=$(tcc_decision "$installed" "$new")
    if [[ "$got" == "$expected" ]]; then
      pass "$name → $expected"
    else
      fail "$name" "expected '$expected', got '$got'"
    fi
  }

  if [[ $SIGN_OK -eq 1 ]]; then
    expect_decision "same identity, different content → no reset" "$APP_A" "$APP_B" "TCC_RESET=no"
    expect_decision "same identity, same app → no reset" "$APP_A" "$APP_A" "TCC_RESET=no"

    if [[ ! -d "$APP_ADHOC" ]]; then
      mkdir -p "$(dirname "$APP_ADHOC")"
      ditto "$BUILT_APP" "$APP_ADHOC"
    fi
    if codesign --force --deep --sign - "$APP_ADHOC" >/dev/null 2>&1; then
      expect_decision "installed ad-hoc vs new cert-signed → reset" "$APP_ADHOC" "$APP_A" "TCC_RESET=yes"
    else
      fail "installed ad-hoc vs new cert-signed → reset" "could not ad-hoc sign fixture"
    fi
  else
    fail "same identity, different content → no reset" "signing step did not complete"
    fail "same identity, same app → no reset" "signing step did not complete"
    fail "installed ad-hoc vs new cert-signed → reset" "signing step did not complete"
  fi

  expect_decision "missing installed app → no reset" "$MISSING_APP" "${APP_A}" "TCC_RESET=no"

  if [[ -f "$TCC_MARKER" ]]; then
    fail "dry run never invokes tccutil" "tccutil stub was called"
  else
    pass "dry run never invokes tccutil"
  fi
else
  fail "dmg_install.command exists" "$DMG_INSTALL missing"
fi

echo "== 5. Callers use sign_app.sh =="

if [[ -f "$MAKE_DMG" ]] && grep -q "sign_app.sh" "$MAKE_DMG"; then
  pass "make_dmg.sh calls scripts/sign_app.sh"
else
  fail "make_dmg.sh calls scripts/sign_app.sh"
fi

if [[ -f "$INSTALL_SH" ]] && grep -q "sign_app.sh" "$INSTALL_SH"; then
  pass "install.sh calls scripts/sign_app.sh"
else
  fail "install.sh calls scripts/sign_app.sh"
fi

echo
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ $FAIL_COUNT -eq 0 ]]; then
  echo "ALL SIGNING CHECKS PASS"
  exit 0
fi
echo "SIGNING CHECKS FAILED"
exit 1
