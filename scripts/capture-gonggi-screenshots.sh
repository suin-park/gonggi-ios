#!/usr/bin/env bash
# Capture Gonggi Brand Redesign V1 screenshots (+ welcome video) on a booted iOS Simulator.
set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.whik.gonggi}"
DERIVED_DATA="${DERIVED_DATA:-DerivedData}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-screenshots}"
VIDEO_DIR="${VIDEO_DIR:-videos}"
SETTLE_SEC="${SETTLE_SEC:-4}"
WELCOME_VIDEO_SEC="${WELCOME_VIDEO_SEC:-12}"

if [[ -z "${UDID:-}" ]]; then
  echo "UDID environment variable is required"
  exit 1
fi

APP_PATH="${APP_PATH:-${DERIVED_DATA}/Build/Products/Debug-iphonesimulator/Gonggi.app}"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "Gonggi.app not found at ${APP_PATH}"
  exit 1
fi

mkdir -p "${SCREENSHOT_DIR}" "${VIDEO_DIR}"

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
  "welcome:00_welcome_after.png"
  "welcomeReduceMotion:00_welcome_reduce_motion.png"
  "welcomeDynamicType:00_welcome_dynamic_type.png"
  "loginEmail:00_login_email_after.png"
  "home:01_home_after.png"
  "recordMode:01_record_mode_after.png"
  "librarySpaces:02_library_spaces_after.png"
  "librarySpacesLoading:02_library_spaces_loading.png"
  "librarySpacesEmpty:02_library_spaces_empty.png"
  "librarySpacesError:02_library_spaces_error.png"
  "libraryAssetsThumb:03_library_assets_thumb.png"
  "libraryAssetsNoThumb:03_library_assets_no_thumb.png"
  "libraryAssetsGenerating:03_library_assets_generating.png"
  "spaceDetail:04_space_detail_after.png"
  "assetDetailNeedPrepare:05_asset_detail_need_prepare.png"
  "assetDetailProcessing:05_asset_detail_processing.png"
  "assetDetailReady:05_asset_detail_ready.png"
  "assetDetailFailed:05_asset_detail_failed.png"
  "spacePicker:06_space_picker_after.png"
  "assetPicker:06_asset_picker_after.png"
  "profile:07_profile_after.png"
  "vrEditMenu:08_vr_edit_menu_after.png"
  "arCameraDenied:09_ar_camera_denied.png"
  "processing:09_processing_after.png"
  "appIconPreview:10_app_icon_preview.png"
  "capture30:02_capture_30.png"
  "capture68:03_capture_68.png"
  "capture90:04_capture_90.png"
  "captureSummary:08_capture_summary.png"
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

# Welcome animation video (~12s)
VIDEO_OUT="${VIDEO_DIR}/00_welcome_after.mp4"
echo "--- Recording welcome video ${VIDEO_OUT} ---"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
sleep 1
xcrun simctl launch "${UDID}" "${BUNDLE_ID}" -mock "-screenshot-screen" "welcome"
sleep 2
# recordVideo blocks until stopped; run in background then kill after duration
xcrun simctl io "${UDID}" recordVideo --codec=h264 --force "${VIDEO_OUT}" &
REC_PID=$!
sleep "${WELCOME_VIDEO_SEC}"
kill -INT "${REC_PID}" 2>/dev/null || true
wait "${REC_PID}" 2>/dev/null || true
if [[ ! -s "${VIDEO_OUT}" ]]; then
  echo "Welcome video missing or empty: ${VIDEO_OUT}"
  exit 1
fi
echo "OK ${VIDEO_OUT} ($(wc -c < "${VIDEO_OUT}") bytes)"

xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
echo "All screenshots captured in ${SCREENSHOT_DIR}; video in ${VIDEO_DIR}"
