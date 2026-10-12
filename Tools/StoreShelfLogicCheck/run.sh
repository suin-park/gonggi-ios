#!/usr/bin/env bash
# usage (repo root): docker run --rm -v "$PWD":/repo:ro swift:5.9-jammy bash /repo/Tools/StoreShelfLogicCheck/run.sh
set -euo pipefail
W=/tmp/pkg
rm -rf "$W" && mkdir -p "$W/Sources/Gonggi" "$W/Tests/GonggiTests"
cp /repo/Tools/StoreShelfLogicCheck/Package.swift "$W/"
cp /repo/Gonggi/Features/StoreShelf/Core/*.swift "$W/Sources/Gonggi/"
cp /repo/GonggiTests/StoreShelfCoreTests.swift "$W/Tests/GonggiTests/"
cd "$W"
swift test 2>&1
