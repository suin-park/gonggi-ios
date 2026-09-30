#!/usr/bin/env bash
# Capture the 기록 tab (기록 → 제품 / 공간) in mock mode, default and accessibility XXL text.
set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.whik.gonggi}"
DERIVED_DATA="${DERIVED_DATA:-DerivedData}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-docs/gonggi-record-tab}"
SETTLE_SEC="${SETTLE_SEC:-6}"

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

# Prefer an iPhone 14 Plus simulator (the review device); create one on the booted device's runtime if the
# device type exists. Falls back to the resolved simulator.
DEVICE_LABEL="${DEVICE_NAME:-resolved simulator} (${RUNTIME:-unknown runtime})"
if [[ -n "${RUNTIME:-}" ]] && xcrun simctl list devicetypes | grep -q "com.apple.CoreSimulator.SimDeviceType.iPhone-14-Plus"; then
  if NEW_UDID="$(xcrun simctl create "Record iPhone 14 Plus" com.apple.CoreSimulator.SimDeviceType.iPhone-14-Plus "${RUNTIME}" 2>/dev/null)"; then
    xcrun simctl boot "${NEW_UDID}" 2>/dev/null || true
    xcrun simctl bootstatus "${NEW_UDID}" -b
    UDID="${NEW_UDID}"
    DEVICE_LABEL="iPhone 14 Plus (${RUNTIME})"
  fi
fi
echo "Capturing on ${DEVICE_LABEL}"

xcrun simctl install "${UDID}" "${APP_PATH}"
xcrun simctl status_bar "${UDID}" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 2>/dev/null || true

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
  [[ -s "${out}" ]] || { echo "empty ${out}"; exit 1; }
  echo "OK ${out}"
}

capture_one "recordHome" "record_home_regular.png"
capture_one "recordHomeDynamicType" "record_home_xxl_top.png"
capture_one "recordHomeDynamicTypeBottom" "record_home_xxl_bottom.png"
capture_one "recordPhotoSource" "photo_source_regular.png"
capture_one "recordPhotoSourceDynamicType" "photo_source_xxl.png"

echo "CAPTURE_SHA=$(git rev-parse HEAD)" > "${SCREENSHOT_DIR}/CAPTURE_META.txt"
echo "SIMULATOR=yes (not a real iPhone)" >> "${SCREENSHOT_DIR}/CAPTURE_META.txt"
echo "DEVICE=${DEVICE_LABEL}" >> "${SCREENSHOT_DIR}/CAPTURE_META.txt"
echo "MOCK_DATA=yes (-mock -screenshot-screen, Debug build)" >> "${SCREENSHOT_DIR}/CAPTURE_META.txt"
echo "REAL_DEVICE=NOT RUN" >> "${SCREENSHOT_DIR}/CAPTURE_META.txt"
