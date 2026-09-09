#!/usr/bin/env bash
# Capture Space Detail layout fix proof (wide latlong + tab bar fixture).
set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.whik.gonggi}"
DERIVED_DATA="${DERIVED_DATA:-DerivedData}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-docs/gonggi-space-detail-layout-fix}"
SETTLE_SEC="${SETTLE_SEC:-5}"
SCROLL_VIDEO_SEC="${SCROLL_VIDEO_SEC:-8}"

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
xcrun simctl status_bar "${UDID}" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 2>/dev/null || true

capture_one() {
  local screen="$1"
  local filename="$2"
  local settle="${3:-$SETTLE_SEC}"
  local out="${SCREENSHOT_DIR}/${filename}"
  echo "--- Capturing ${filename} (${screen}) ---"
  xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "${UDID}" "${BUNDLE_ID}" -mock "-screenshot-screen" "${screen}"
  sleep "${settle}"
  xcrun simctl io "${UDID}" screenshot "${out}"
  [[ -s "${out}" ]] || { echo "empty ${out}"; exit 1; }
  echo "OK ${out}"
}

# Before (pre-fix redesign capture — placeholder, no wide image)
if [[ -f docs/gonggi-redesign-v1/screenshots/04_space_detail_after.png ]]; then
  cp docs/gonggi-redesign-v1/screenshots/04_space_detail_after.png \
    "${SCREENSHOT_DIR}/before_space_detail_top.png"
  echo "OK before_space_detail_top.png (from redesign capture)"
fi

capture_one "spaceDetail" "after_space_detail_top.png" 6
capture_one "spaceDetailScrolled" "after_space_detail_bottom.png" 7
capture_one "spaceDetailDynamicType" "after_space_detail_dynamic_type.png" 6

if [[ -n "${UDID_COMPACT:-}" ]]; then
  xcrun simctl boot "${UDID_COMPACT}" 2>/dev/null || true
  xcrun simctl bootstatus "${UDID_COMPACT}" -b
  sleep 3
  xcrun simctl install "${UDID_COMPACT}" "${APP_PATH}"
  xcrun simctl status_bar "${UDID_COMPACT}" override --time "9:41" --batteryState charged --batteryLevel 100 2>/dev/null || true
  xcrun simctl terminate "${UDID_COMPACT}" "${BUNDLE_ID}" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "${UDID_COMPACT}" "${BUNDLE_ID}" -mock "-screenshot-screen" "spaceDetailCompact"
  sleep 8
  xcrun simctl io "${UDID_COMPACT}" screenshot "${SCREENSHOT_DIR}/after_space_detail_compact.png"
  echo "OK after_space_detail_compact.png"
else
  capture_one "spaceDetailCompact" "after_space_detail_compact.png" 6
fi

# Mid section: reuse top after settle (hero+meta visible)
cp "${SCREENSHOT_DIR}/after_space_detail_top.png" "${SCREENSHOT_DIR}/after_space_detail_mid.png"

VIDEO_OUT="${SCREENSHOT_DIR}/space_detail_scroll.mp4"
echo "--- Recording ${VIDEO_OUT} ---"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
sleep 1
xcrun simctl launch "${UDID}" "${BUNDLE_ID}" -mock "-screenshot-screen" "spaceDetail"
sleep 2
xcrun simctl io "${UDID}" recordVideo --codec=h264 --force "${VIDEO_OUT}" &
REC_PID=$!
sleep 2
# Jump to scrolled state mid-recording by relaunching scrolled screen
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
xcrun simctl launch "${UDID}" "${BUNDLE_ID}" -mock "-screenshot-screen" "spaceDetailScrolled"
sleep $((SCROLL_VIDEO_SEC - 2))
kill -INT "${REC_PID}" 2>/dev/null || true
wait "${REC_PID}" 2>/dev/null || true
[[ -s "${VIDEO_OUT}" ]] || { echo "video missing"; exit 1; }
echo "OK ${VIDEO_OUT}"

echo "CAPTURE_SHA=$(git rev-parse HEAD)" > "${SCREENSHOT_DIR}/CAPTURE_META.txt"
echo "DEBUG_FIXTURE=yes (wide latlong + TabView host)" >> "${SCREENSHOT_DIR}/CAPTURE_META.txt"
echo "REAL_DEVICE=NOT RUN" >> "${SCREENSHOT_DIR}/CAPTURE_META.txt"
echo "Space Detail layout captures in ${SCREENSHOT_DIR}"
