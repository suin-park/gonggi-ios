#!/usr/bin/env python3
"""Preflight validation for Gonggi .app bundle (CI Release build)."""
from __future__ import annotations

import plistlib
import sys
from pathlib import Path

BUNDLE_ID = "com.whik.gonggi"
REQUIRED_ICON_PIXELS = {120, 180, 1024}


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    sys.exit(1)


def ok(message: str) -> None:
    print(f"OK: {message}")


def collect_car_icon_assets(car_path: Path) -> set[int]:
    try:
        data = car_path.read_bytes()
    except OSError:
        return set()

    found: set[int] = set()
    needle = b"\x89PNG\r\n\x1a\n"
    offset = 0
    while True:
        idx = data.find(needle, offset)
        if idx == -1:
            break
        ihdr_offset = idx + len(needle) + 4
        if ihdr_offset + 8 < len(data):
            w = int.from_bytes(data[ihdr_offset : ihdr_offset + 4], "big")
            h = int.from_bytes(data[ihdr_offset + 4 : ihdr_offset + 8], "big")
            if w == h and 20 <= w <= 1024:
                found.add(w)
        offset = idx + 1
    return found


def main() -> None:
    if len(sys.argv) != 2:
        fail("Usage: validate-app-bundle-preflight.py <path-to.app>")

    app_path = Path(sys.argv[1])
    if not app_path.is_dir() or app_path.suffix != ".app":
        fail(f"App bundle not found: {app_path}")

    info_path = app_path / "Info.plist"
    if not info_path.is_file():
        fail(f"Info.plist missing in {app_path}")

    with info_path.open("rb") as fp:
        info = plistlib.load(fp)

    bundle_id = info.get("CFBundleIdentifier")
    if bundle_id != BUNDLE_ID:
        fail(f"CFBundleIdentifier is '{bundle_id}', expected '{BUNDLE_ID}'")
    ok(f"CFBundleIdentifier == {BUNDLE_ID}")

    icon_name = info.get("CFBundleIconName")
    if not icon_name:
        fail("CFBundleIconName missing from Info.plist")
    ok(f"CFBundleIconName == {icon_name}")

    pixel_sizes: set[int] = set()
    for png in app_path.rglob("*.png"):
        if "AppIcon" not in png.name and "AppIcon" not in str(png.parent):
            continue
        header = png.read_bytes()[:24]
        if len(header) >= 24 and header.startswith(b"\x89PNG\r\n\x1a\n"):
            w = int.from_bytes(header[16:20], "big")
            h = int.from_bytes(header[20:24], "big")
            if w == h:
                pixel_sizes.add(w)

    car_path = app_path / "Assets.car"
    if car_path.is_file():
        pixel_sizes |= collect_car_icon_assets(car_path)
        ok("Assets.car present (compiled asset catalog)")

    if not pixel_sizes:
        fail("No AppIcon PNG sizes detected in app bundle")

    ok(f"Detected icon pixel sizes: {sorted(pixel_sizes)}")

    missing = REQUIRED_ICON_PIXELS - pixel_sizes
    if missing:
        fail(f"Missing required icon sizes: {sorted(missing)}")

    ok(f"Required icon sizes present: {sorted(REQUIRED_ICON_PIXELS)}")
    print("App bundle preflight validation passed.")


if __name__ == "__main__":
    main()
