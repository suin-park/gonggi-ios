#!/usr/bin/env bash
# Depth Anything V2 Small (Core ML, F16)를 받아 Gonggi/Experiments/RealtimeGS/Model/에 둔다. 앱 번들에 포함되어 단안 깊이 사전값에 쓰인다.
# 출처: https://huggingface.co/apple/coreml-depth-anything-v2-small (라이선스: Apache-2.0)
# 각 파일의 SHA-256을 고정해 두었고 맞지 않으면 실패한다. 큰 바이너리는 저장소에 커밋하지 않는다.
# macOS 기본 bash(3.2)에서도 돌도록 연관 배열을 쓰지 않는다.
set -euo pipefail

# Gonggi 소스 디렉터리 안에 두면 project.yml을 건드리지 않고 앱 타깃에 포함된다. 받지 않은 빌드에는 모델이 없고 앱은 스테레오 전용으로 동작한다.
DEST="Gonggi/Experiments/RealtimeGS/Model/DepthAnythingV2SmallF16.mlpackage"
BASE="https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/DepthAnythingV2SmallF16.mlpackage"

FILES="
Manifest.json|2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7
Data/com.apple.CoreML/model.mlmodel|44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042
Data/com.apple.CoreML/weights/weight.bin|fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed
"

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

while IFS='|' read -r rel want; do
  [ -z "${rel}" ] && continue
  out="${DEST}/${rel}"
  mkdir -p "$(dirname "${out}")"
  if [ -f "${out}" ] && [ "$(sha "${out}")" = "${want}" ]; then
    echo "ok (cached): ${rel}"
    continue
  fi
  echo "downloading: ${rel}"
  curl -fsSL --retry 3 --retry-delay 2 -o "${out}" "${BASE}/${rel}"
  got="$(sha "${out}")"
  if [ "${got}" != "${want}" ]; then
    echo "::error::checksum mismatch for ${rel}: ${got}"
    rm -f "${out}"
    exit 1
  fi
  echo "ok: ${rel}"
done <<< "${FILES}"
echo "Depth Anything V2 Small F16 ready at ${DEST}"
