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

capture_one "recordHome" "record_01_home.png"
capture_one "recordProduct" "record_02_product.png"
capture_one "recordPhotoSource" "record_03_photo_source.png"
capture_one "recordSpace" "record_04_space.png"
capture_one "recordHomeDynamicType" "record_01_home_dynamic_type.png"
capture_one "recordProductDynamicType" "record_02_product_dynamic_type.png"
capture_one "recordSpaceDynamicType" "record_04_space_dynamic_type.png"

echo "CAPTURE_SHA=$(git rev-parse HEAD)" > "${SCREENSHOT_DIR}/CAPTURE_META.txt"
echo "DEBUG_FIXTURE=yes (-mock -screenshot-screen, Debug simulator build)" >> "${SCREENSHOT_DIR}/CAPTURE_META.txt"
echo "REAL_DEVICE=NOT RUN" >> "${SCREENSHOT_DIR}/CAPTURE_META.txt"
