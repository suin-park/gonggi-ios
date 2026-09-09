#!/usr/bin/env bash
# Capture Gonggi 2.0 (3) release visual proof (production Welcome = Space Light).
set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.whik.gonggi}"
DERIVED_DATA="${DERIVED_DATA:-DerivedData}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-docs/gonggi-2.0-3}"
SETTLE_SEC="${SETTLE_SEC:-4}"
SPACE_LIGHT_VIDEO_SEC="${SPACE_LIGHT_VIDEO_SEC:-16}"

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
  --time "9:41" \
  --batteryState charged \
  --batteryLevel 100 \
  --cellularMode active \
  --cellularBars 4 \
  --wifiBars 3 2>/dev/null || true

capture_one() {
  local screen="$1"
  local filename="$2"
  local out="${SCREENSHOT_DIR}/${filename}"
  echo "--- Capturing ${filename} (${screen}) ---"
  xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "${UDID}" "${BUNDLE_ID}" -mock "-screenshot-screen" "${screen}"
  sleep "${SETTLE_SEC}"
  if [[ "${screen}" == "loginEmailKeyboard" ]]; then
    sleep 2
  fi
  xcrun simctl io "${UDID}" screenshot "${out}"
  if [[ ! -s "${out}" ]]; then
    echo "Screenshot empty: ${out}"
    exit 1
  fi
  echo "OK ${out}"
}

# Production Welcome is Space Light — use welcome* screens (not DEBUG-only aliases only).
declare -a SCREENS=(
  "loginEmail:login_email.png"
  "welcome:welcome.png"
  "welcomeDynamicType:welcome_dynamic_type.png"
  "welcomeReduceMotion:welcome_reduce_motion.png"
  "welcomeCompact:welcome_compact.png"
)

for entry in "${SCREENS[@]}"; do
  capture_one "${entry%%:*}" "${entry##*:}"
done

if [[ -n "${UDID_COMPACT:-}" ]]; then
  echo "Installing on compact simulator ${UDID_COMPACT}"
  xcrun simctl boot "${UDID_COMPACT}" 2>/dev/null || true
  xcrun simctl bootstatus "${UDID_COMPACT}" -b
  sleep 5
  xcrun simctl install "${UDID_COMPACT}" "${APP_PATH}"
  xcrun simctl status_bar "${UDID_COMPACT}" override --time "9:41" --batteryState charged --batteryLevel 100 2>/dev/null || true
  out="${SCREENSHOT_DIR}/welcome_compact.png"
  xcrun simctl terminate "${UDID_COMPACT}" "${BUNDLE_ID}" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "${UDID_COMPACT}" "${BUNDLE_ID}" -mock "-screenshot-screen" "welcomeCompact"
  sleep 12
  xcrun simctl io "${UDID_COMPACT}" screenshot "${out}"
  echo "OK ${out} (compact device)"
fi

VIDEO_OUT="${SCREENSHOT_DIR}/welcome_space_light.mp4"
echo "--- Recording ${VIDEO_OUT} ---"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
sleep 1
xcrun simctl launch "${UDID}" "${BUNDLE_ID}" -mock "-screenshot-screen" "welcome"
sleep 2
xcrun simctl io "${UDID}" recordVideo --codec=h264 --force "${VIDEO_OUT}" &
REC_PID=$!
sleep "${SPACE_LIGHT_VIDEO_SEC}"
kill -INT "${REC_PID}" 2>/dev/null || true
wait "${REC_PID}" 2>/dev/null || true
if [[ ! -s "${VIDEO_OUT}" ]]; then
  echo "Video missing: ${VIDEO_OUT}"
  exit 1
fi
echo "OK ${VIDEO_OUT}"

echo "--- Capturing SpringBoard app icon ---"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
sleep 2
xcrun simctl io "${UDID}" screenshot "${SCREENSHOT_DIR}/app_icon_springboard.png" || true
if [[ -s "${SCREENSHOT_DIR}/app_icon_springboard.png" ]]; then
  echo "OK ${SCREENSHOT_DIR}/app_icon_springboard.png"
fi

# Copy static AppIcon masters for the report pack
if [[ -f Gonggi/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png ]]; then
  cp Gonggi/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png "${SCREENSHOT_DIR}/app_icon_1024.png"
fi

xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
echo "2.0 (3) captures in ${SCREENSHOT_DIR}"
