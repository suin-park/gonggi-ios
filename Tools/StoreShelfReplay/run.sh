#!/usr/bin/env bash
# usage (repo root):
#   docker run --rm -v "$PWD":/repo:ro -v "$BUNDLE_DIR":/data swift:5.9-jammy bash /repo/Tools/StoreShelfReplay/run.sh /data/session.json [options]
# options: --json OUT.json  --same 0.20  --group-same 0.20  --group-similar 0.35  --depth 0.6  --radius-floor 0.05
#          --radius-factor 0.5  --no-merge
set -euo pipefail
W=/tmp/replaypkg
rm -rf "$W" && mkdir -p "$W/Sources/replay"
cp /repo/Tools/StoreShelfReplay/Package.swift "$W/"
cp /repo/Gonggi/Features/StoreShelf/Core/*.swift "$W/Sources/replay/"
cp /repo/Tools/StoreShelfReplay/Sources/replay/main.swift "$W/Sources/replay/main.swift"
cd "$W"
swift build -c release 2>&1 | grep -E "error|warning: unre" || true
.build/release/replay "$@"
