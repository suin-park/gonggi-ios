#!/usr/bin/env bash
# Capture Gonggi Brand Redesign refinement-01 (auth logo + space-light motion).
set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.whik.gonggi}"
DERIVED_DATA="${DERIVED_DATA:-DerivedData}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-docs/gonggi-redesign-v1/refinement-01}"
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

declare -a SCREENS=(
  "loginEmail:login_email.png"
  "loginEmailKeyboard:login_email_keyboard.png"
  "welcome:welcome_logo_refined.png"
  "welcomeDynamicType:welcome_dynamic_type.png"
  "welcomeReduceMotion:welcome_reduce_motion.png"
  "welcomeSpaceLight:welcome_space_light.png"
  "welcomeSpaceLightDynamicType:welcome_space_light_dynamic_type.png"
  "welcomeSpaceLightReduceMotion:welcome_space_light_reduce_motion.png"
  "spaceLightStoryboard:space_light_storyboard.png"
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
  # Keyboard screen needs a bit longer for focus
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

for entry in "${SCREENS[@]}"; do
  capture_one "${entry%%:*}" "${entry##*:}"
done

# Space-light welcome video BEFORE compact (avoid losing video if compact flakes)
VIDEO_OUT="${SCREENSHOT_DIR}/welcome_space_light.mp4"
echo "--- Recording ${VIDEO_OUT} ---"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
sleep 1
xcrun simctl launch "${UDID}" "${BUNDLE_ID}" -mock "-screenshot-screen" "welcomeSpaceLight"
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

# SpringBoard BEFORE compact — compact SE flakiness must not block icon review
if [[ "${CAPTURE_SPRINGBOARD_ICON:-1}" == "1" ]]; then
  echo "--- Capturing SpringBoard app icon ---"
  xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
  sleep 2
  xcrun simctl io "${UDID}" screenshot "${SCREENSHOT_DIR}/app_icon_springboard.png" || true
  if [[ -s "${SCREENSHOT_DIR}/app_icon_springboard.png" ]]; then
    echo "OK ${SCREENSHOT_DIR}/app_icon_springboard.png"
  else
    echo "WARN missing SpringBoard screenshot"
  fi
fi

mean_luma_ok() {
  local path="$1"
  SCREENSHOT_PATH="${path}" python3 - <<'PY'
from PIL import Image
import os, sys
p = os.environ["SCREENSHOT_PATH"]
im = Image.open(p).convert("L")
pixels = list(im.getdata())
mean = sum(pixels) / (im.width * im.height)
print(f"mean_luma={mean:.1f} size={im.size} path={p}")
sys.exit(0 if mean <= 240 else 1)
PY
}

capture_compact_one() {
  local udid="$1"
  local screen="$2"
  local filename="$3"
  local out="${SCREENSHOT_DIR}/${filename}"
  local attempt
  for attempt in 1 2 3; do
    echo "--- Compact ${filename} (attempt ${attempt}/3 on ${udid}) ---"
    xcrun simctl terminate "${udid}" "${BUNDLE_ID}" 2>/dev/null || true
    sleep 1
    if [[ "${attempt}" -ge 2 ]]; then
      echo "Reinstalling app on compact simulator before retry"
      xcrun simctl uninstall "${udid}" "${BUNDLE_ID}" 2>/dev/null || true
      xcrun simctl install "${udid}" "${APP_PATH}"
      sleep 2
    fi
    if ! xcrun simctl launch "${udid}" "${BUNDLE_ID}" -mock "-screenshot-screen" "${screen}"; then
      echo "Launch failed on attempt ${attempt}"
      sleep 3
      continue
    fi
    # Second launch / Canvas-heavy screens need longer settle on SE-class sims
    sleep $((8 + attempt * 4))
    xcrun simctl io "${udid}" screenshot "${out}"
    if [[ ! -s "${out}" ]]; then
      echo "Empty screenshot on attempt ${attempt}"
      continue
    fi
    if mean_luma_ok "${out}"; then
      echo "OK ${out}"
      return 0
    fi
    echo "Blank/white compact screenshot on attempt ${attempt}; retrying"
  done
  return 1
}

# Compact device screens (optional UDID_COMPACT)
if [[ -n "${UDID_COMPACT:-}" ]]; then
  echo "Installing on compact simulator ${UDID_COMPACT}"
  xcrun simctl boot "${UDID_COMPACT}" 2>/dev/null || true
  xcrun simctl bootstatus "${UDID_COMPACT}" -b
  # Extra settle after first boot / data migration (CI SE often needs this)
  sleep 5
  xcrun simctl install "${UDID_COMPACT}" "${APP_PATH}"
  xcrun simctl status_bar "${UDID_COMPACT}" override --time "9:41" --batteryState charged --batteryLevel 100 2>/dev/null || true
  if ! capture_compact_one "${UDID_COMPACT}" "welcomeCompact" "welcome_compact.png"; then
    echo "WARN: compact welcome failed; falling back to primary ${UDID}"
    capture_one "welcomeCompact" "welcome_compact.png"
    if ! mean_luma_ok "${SCREENSHOT_DIR}/welcome_compact.png"; then
      echo "Primary fallback also blank for welcome_compact.png"
      exit 1
    fi
  fi
  # Space Light on SE is flaky (blank white); soft-fail after primary fallback
  if ! capture_compact_one "${UDID_COMPACT}" "welcomeSpaceLightCompact" "welcome_space_light_compact.png"; then
    echo "WARN: compact Space Light failed; falling back to primary ${UDID}"
    capture_one "welcomeSpaceLightCompact" "welcome_space_light_compact.png"
    if ! mean_luma_ok "${SCREENSHOT_DIR}/welcome_space_light_compact.png"; then
      echo "WARN: Space Light compact blank after fallback — continuing (non-blocking)"
    fi
  fi
  xcrun simctl terminate "${UDID_COMPACT}" "${BUNDLE_ID}" 2>/dev/null || true
else
  echo "UDID_COMPACT not set — capturing compact screens on primary simulator"
  capture_one "welcomeCompact" "welcome_compact.png"
  capture_one "welcomeSpaceLightCompact" "welcome_space_light_compact.png"
fi

xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
echo "Refinement-01 captures in ${SCREENSHOT_DIR}"
