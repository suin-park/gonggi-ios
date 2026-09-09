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

# Compact device screens (optional UDID_COMPACT)
if [[ -n "${UDID_COMPACT:-}" ]]; then
  echo "Installing on compact simulator ${UDID_COMPACT}"
  xcrun simctl boot "${UDID_COMPACT}" 2>/dev/null || true
  xcrun simctl bootstatus "${UDID_COMPACT}" -b
  xcrun simctl install "${UDID_COMPACT}" "${APP_PATH}"
  xcrun simctl status_bar "${UDID_COMPACT}" override --time "9:41" --batteryState charged --batteryLevel 100 2>/dev/null || true
  for pair in "welcomeCompact:welcome_compact.png" "welcomeSpaceLightCompact:welcome_space_light_compact.png"; do
    screen="${pair%%:*}"; filename="${pair##*:}"
    out="${SCREENSHOT_DIR}/${filename}"
    echo "--- Compact ${filename} ---"
    xcrun simctl terminate "${UDID_COMPACT}" "${BUNDLE_ID}" 2>/dev/null || true
    sleep 1
    xcrun simctl launch "${UDID_COMPACT}" "${BUNDLE_ID}" -mock "-screenshot-screen" "${screen}"
    # SE / mini needs longer settle; verify process is up
    sleep 8
    if ! xcrun simctl spawn "${UDID_COMPACT}" launchctl print system 2>/dev/null | grep -q "${BUNDLE_ID}"; then
      echo "WARN: ${BUNDLE_ID} may not be running on compact; relaunching"
      xcrun simctl launch "${UDID_COMPACT}" "${BUNDLE_ID}" -mock "-screenshot-screen" "${screen}" || true
      sleep 6
    fi
    xcrun simctl io "${UDID_COMPACT}" screenshot "${out}"
    # Reject near-blank white captures
    python3 - <<PY
from PIL import Image
from pathlib import Path
p = Path(${out@Q} if False else r"""${out}""")
im = Image.open(p).convert("L")
mean = sum(im.getdata()) / (im.width * im.height)
print(f"compact mean_luma={mean:.1f} size={im.size}")
if mean > 240:
    raise SystemExit(f"compact screenshot looks blank white: {p}")
PY
    echo "OK ${out}"
  done
  xcrun simctl terminate "${UDID_COMPACT}" "${BUNDLE_ID}" 2>/dev/null || true
else
  echo "UDID_COMPACT not set — capturing compact screens on primary simulator"
  capture_one "welcomeCompact" "welcome_compact.png"
  capture_one "welcomeSpaceLightCompact" "welcome_space_light_compact.png"
fi

# Space-light welcome video (~16s = two 8s loops)
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

xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
echo "Refinement-01 captures in ${SCREENSHOT_DIR}"
