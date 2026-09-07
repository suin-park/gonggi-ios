#!/usr/bin/env bash
# Pre-archive checks for Unified Auth (Build 58+). Fails CI if Google/Apple config missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

check() {
  local msg="$1"
  shift
  if "$@"; then
    echo "PASS: ${msg}"
  else
    echo "::error::FAIL: ${msg}"
    fail=1
  fi
}

AUTH_XC="${ROOT}/Config/Auth.xcconfig"
ENT="${ROOT}/Gonggi/Resources/Gonggi.entitlements"
PYML="${ROOT}/project.yml"
INFO="${ROOT}/Gonggi/Resources/Info.plist"

check "Auth.xcconfig exists" test -f "${AUTH_XC}"
check "GOOGLE_IOS_CLIENT_ID set in Auth.xcconfig" grep -qE '^GOOGLE_IOS_CLIENT_ID = .+\.apps\.googleusercontent\.com$' "${AUTH_XC}"
check "GOOGLE_REVERSED_CLIENT_ID set in Auth.xcconfig" grep -qE '^GOOGLE_REVERSED_CLIENT_ID = com\.googleusercontent\.apps\.' "${AUTH_XC}"
check "Info.plist references GoogleClientID build setting" grep -q 'GoogleClientID' "${INFO}"
check "Info.plist URL scheme uses GOOGLE_REVERSED_CLIENT_ID" grep -q 'GOOGLE_REVERSED_CLIENT_ID' "${INFO}"
check "Sign in with Apple entitlement" grep -q 'com.apple.developer.applesignin' "${ENT}"
check "Bundle ID com.whik.gonggi in project.yml" grep -q 'PRODUCT_BUNDLE_IDENTIFIER: com.whik.gonggi' "${PYML}"
if grep -RIn --include='*.swift' 'mock@3d-locker.com' "${ROOT}/Gonggi" >/dev/null 2>&1; then
  echo "::error::FAIL: mock@3d-locker.com found in sources"
  fail=1
else
  echo "PASS: No mock@3d-locker.com in sources"
fi

if grep -RInE --include='*.swift' '[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com' "${ROOT}/Gonggi" >/dev/null 2>&1; then
  echo "::error::FAIL: Hardcoded Google client id found in Swift"
  fail=1
else
  echo "PASS: No hardcoded Google client id in Swift"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "::error::Pre-archive auth config checks failed"
  exit 1
fi
echo "All pre-archive auth config checks passed."
