#!/usr/bin/env bash
# Build a minimal opencv2.xcframework for Gonggi Phase 2.
# Requires: macOS, Xcode, CMake, Python 3, curl.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="${ROOT}/Vendor/OpenCV"
VERSION_FILE="${VENDOR}/VERSION"
VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
BUILD_ROOT="${ROOT}/.opencv-build"
SRC_DIR="${BUILD_ROOT}/opencv-${VERSION}"
OUT_DIR="${BUILD_ROOT}/out"
XCFRAMEWORK_DST="${VENDOR}/opencv2.xcframework"

IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

echo "==> Gonggi OpenCV ${VERSION} minimal xcframework"
echo "    vendor: ${VENDOR}"
echo "    jobs:   ${JOBS}"

mkdir -p "${BUILD_ROOT}" "${VENDOR}"

if [[ ! -d "${SRC_DIR}" ]]; then
  ARCHIVE="${BUILD_ROOT}/opencv-${VERSION}.tar.gz"
  URL="https://github.com/opencv/opencv/archive/refs/tags/${VERSION}.tar.gz"
  echo "==> Downloading ${URL}"
  curl -L --fail --retry 3 -o "${ARCHIVE}" "${URL}"
  tar -xzf "${ARCHIVE}" -C "${BUILD_ROOT}"
fi

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

# Exclude heavy / unused modules. Keep stitching + features2d + calib3d stack.
WITHOUT_ARGS=(
  --without=dnn
  --without=video
  --without=videoio
  --without=highgui
  --without=ml
  --without=gapi
  --without=objc
  --without=java
  --without=python
  --without=js
  --without=ts
  --without=world
  --without=photo
  --without=objdetect
)

echo "==> Building xcframework (iphoneos arm64 + iphonesimulator arm64)"
python3 "${SRC_DIR}/platforms/apple/build_xcframework.py" \
  --out "${OUT_DIR}" \
  --iphoneos_archs=arm64 \
  --iphonesimulator_archs=arm64 \
  --iphoneos_deployment_target="${IPHONEOS_DEPLOYMENT_TARGET}" \
  --disable-bitcode \
  --build_only_specified_archs \
  "${WITHOUT_ARGS[@]}"

BUILT="$(find "${OUT_DIR}" -type d -name 'opencv2.xcframework' | head -n 1)"
if [[ -z "${BUILT}" ]]; then
  echo "ERROR: opencv2.xcframework not found under ${OUT_DIR}" >&2
  ls -laR "${OUT_DIR}" || true
  exit 1
fi

rm -rf "${XCFRAMEWORK_DST}"
cp -R "${BUILT}" "${XCFRAMEWORK_DST}"

# Record provenance next to the binary (not committed with binary).
cat > "${VENDOR}/BUILD_INFO.txt" <<EOF
version=${VERSION}
builtAt=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
iphoneos=arm64
iphonesimulator=arm64
deploymentTarget=${IPHONEOS_DEPLOYMENT_TARGET}
modules=core,imgproc,imgcodecs,flann,features2d,calib3d,stitching
EOF

echo "==> Installed ${XCFRAMEWORK_DST}"
du -sh "${XCFRAMEWORK_DST}" || true
