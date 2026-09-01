#!/usr/bin/env bash
# Capture Gonggi UI screenshots on a booted iOS Simulator (unsigned Debug build).
set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.whik.gonggi}"
DERIVED_DATA="${DERIVED_DATA:-DerivedData}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-screenshots}"
SETTLE_SEC="${SETTLE_SEC:-4}"

if [[ -z "${UDID:-}" ]]; then
  echo "UDID environment variable is required"
  exit 1
fi

APP_PATH="${APP_PATH:-${DERIVED_DATA}/Build/Products/Debug-iphonesimulator/Gonggi.app}"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "Gonggi.app not found at ${APP_PATH}"
  exit 1
fi

mkdir -p "${SCREENSHOT_DIR}"

echo "Installing ${APP_PATH} on ${UDID}"
xcrun simctl install "${UDID}" "${APP_PATH}"

echo "Configuring status bar for deterministic screenshots"
xcrun simctl status_bar "${UDID}" override \
  --time "9:41" \
  --batteryState charged \
  --batteryLevel 100 \
  --cellularMode active \
  --cellularBars 4 \
  --wifiBars 3 2>/dev/null || echo "status_bar override not supported on this runtime (continuing)"

declare -a SCREENS=(
  "home:01_home.png"
  "capture30:02_capture_30.png"
  "capture68:03_capture_68.png"
  "capture90:04_capture_90.png"
  "fastMovement:05_capture_fast_movement.png"
  "trackingLimited:06_capture_tracking_limited.png"
  "lowTexture:07_capture_low_texture.png"
  "captureSummary:08_capture_summary.png"
  "processing:09_processing.png"
  "library:10_library.png"
  "spaceDetail:11_space_detail.png"
  "profile:12_profile.png"
)

capture_one() {
  local screen="$1"
  local filename="$2"
  local out="${SCREENSHOT_DIR}/${filename}"

  echo "--- Capturing ${filename} (${screen}) ---"
  xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "${UDID}" "${BUNDLE_ID}" -mock "-screenshot-screen" "${screen}"
  sleep "${SETTLE_SEC}"
  xcrun simctl io "${UDID}" screenshot "${out}"

  if [[ ! -s "${out}" ]]; then
    echo "Screenshot empty or missing: ${out}"
    exit 1
  fi
  echo "OK ${out} ($(wc -c < "${out}") bytes)"
}

for entry in "${SCREENS[@]}"; do
  screen="${entry%%:*}"
  filename="${entry##*:}"
  capture_one "${screen}" "${filename}"
done

xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
echo "All screenshots captured in ${SCREENSHOT_DIR}"
