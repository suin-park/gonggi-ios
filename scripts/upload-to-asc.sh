#!/usr/bin/env bash
# Upload IPA to App Store Connect and fail on validation/upload errors.
set -euo pipefail

IPA_PATH="${1:?IPA path required}"
ASC_KEY_ID="${ASC_KEY_ID:?ASC_KEY_ID required}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:?ASC_ISSUER_ID required}"
LOG_FILE="${RUNNER_TEMP:-/tmp}/altool-upload.log"

: > "${LOG_FILE}"

echo "Uploading ${IPA_PATH} to App Store Connect..."

set +e
xcrun altool --upload-app \
  --type ios \
  --file "${IPA_PATH}" \
  --apiKey "${ASC_KEY_ID}" \
  --apiIssuer "${ASC_ISSUER_ID}" \
  --output-format json \
  2>&1 | tee "${LOG_FILE}"
ALTOOL_EXIT=${PIPESTATUS[0]}
set -e

if grep -qiE 'UPLOAD FAILED|Validation failed|STATE_ERROR|ERROR ITMS-|error uploading' "${LOG_FILE}"; then
  echo "::error::App Store Connect upload failed (see log above)"
  exit 1
fi

if grep -qiE 'No errors uploading|UPLOAD SUCCEEDED|successfully uploaded' "${LOG_FILE}"; then
  echo "Upload accepted by App Store Connect."
  exit 0
fi

# JSON output fallback — check success before generic error tokens
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' "${LOG_FILE}" "${ALTOOL_EXIT}"
import json, re, sys
log_path, exit_code = sys.argv[1], int(sys.argv[2])
text = open(log_path, encoding="utf-8", errors="replace").read()
lower = text.lower()

success_markers = (
    "no errors uploading",
    "upload succeeded",
    "successfully uploaded",
    "package summary:",
)
if any(marker in lower for marker in success_markers):
    print("Upload accepted by App Store Connect.")
    sys.exit(0)

failure_markers = (
    "upload failed",
    "validation failed",
    "state_error",
    "error itms-",
    "error uploading",
)
if any(marker in lower for marker in failure_markers):
    print("::error::App Store Connect upload failed (response markers)")
    sys.exit(1)

for chunk in re.findall(r"\{.*\}|\[.*\]", text, flags=re.S):
    try:
        data = json.loads(chunk)
    except json.JSONDecodeError:
        continue
    blob = json.dumps(data).lower()
    if any(x in blob for x in ("validation_error", "upload failed", "state_error")):
        print("::error::App Store Connect upload failed (JSON response)")
        sys.exit(1)
    if any(x in blob for x in ("no errors uploading", "successfully uploaded")):
        print("Upload accepted by App Store Connect.")
        sys.exit(0)

if exit_code != 0:
    print(f"::error::altool exited with code {exit_code}")
    sys.exit(1)

print("::error::Could not confirm App Store Connect upload success from altool output")
sys.exit(1)
PY
fi

if [[ ${ALTOOL_EXIT} -ne 0 ]]; then
  echo "::error::altool exited with code ${ALTOOL_EXIT}"
  exit 1
fi

echo "::error::Could not confirm App Store Connect upload success"
exit 1
