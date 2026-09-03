#!/usr/bin/env bash
# Ensure Vendor/OpenCV/opencv2.xcframework exists.
# Prefer: (1) existing local tree (2) GitHub Actions cache restore (3) build from source.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="${ROOT}/Vendor/OpenCV"
XCFRAMEWORK="${VENDOR}/opencv2.xcframework"
VERSION="$(tr -d '[:space:]' < "${VENDOR}/VERSION")"

if [[ -d "${XCFRAMEWORK}" ]]; then
  echo "OpenCV xcframework already present at ${XCFRAMEWORK}"
  exit 0
fi

# Optional: download a prebuilt artifact published by Gonggi (same pin).
# Set GONGGI_OPENCV_XCFRAMEWORK_URL to a zip that extracts to opencv2.xcframework/.
if [[ -n "${GONGGI_OPENCV_XCFRAMEWORK_URL:-}" ]]; then
  echo "==> Downloading prebuilt OpenCV ${VERSION} from GONGGI_OPENCV_XCFRAMEWORK_URL"
  TMP="$(mktemp -d)"
  ZIP="${TMP}/opencv2.xcframework.zip"
  curl -L --fail --retry 3 -o "${ZIP}" "${GONGGI_OPENCV_XCFRAMEWORK_URL}"
  unzip -q "${ZIP}" -d "${TMP}"
  FOUND="$(find "${TMP}" -type d -name 'opencv2.xcframework' | head -n 1)"
  if [[ -z "${FOUND}" ]]; then
    echo "ERROR: zip did not contain opencv2.xcframework" >&2
    exit 1
  fi
  mkdir -p "${VENDOR}"
  rm -rf "${XCFRAMEWORK}"
  cp -R "${FOUND}" "${XCFRAMEWORK}"
  echo "Installed prebuilt ${XCFRAMEWORK}"
  exit 0
fi

echo "==> Building OpenCV ${VERSION} from source (may take 30–60+ minutes)"
bash "${ROOT}/scripts/build_opencv_xcframework.sh"
