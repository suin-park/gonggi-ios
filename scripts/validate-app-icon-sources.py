#!/usr/bin/env python3
"""Validate AppIcon source assets before archive/upload."""
from __future__ import annotations

import json
import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICON_DIR = ROOT / "Gonggi" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
INFO_PLIST = ROOT / "Gonggi" / "Resources" / "Info.plist"
REQUIRED_PIXELS = {120, 180, 1024}


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    sys.exit(1)


def ok(message: str) -> None:
    print(f"OK: {message}")


def main() -> None:
    if not ICON_DIR.is_dir():
        fail(f"AppIcon.appiconset missing: {ICON_DIR}")

    contents_path = ICON_DIR / "Contents.json"
    if not contents_path.is_file():
        fail("AppIcon.appiconset/Contents.json missing")

    contents = json.loads(contents_path.read_text(encoding="utf-8"))
    filenames = {img.get("filename") for img in contents.get("images", []) if img.get("filename")}
    if not filenames:
        fail("No icon filenames listed in Contents.json")

    for name in sorted(filenames):
        png = ICON_DIR / name
        if not png.is_file():
            fail(f"Missing PNG referenced by Contents.json: {name}")
        header = png.read_bytes()[:24]
        if not header.startswith(b"\x89PNG\r\n\x1a\n"):
            fail(f"Not a PNG: {name}")
    ok(f"AppIcon.appiconset contains {len(filenames)} PNG(s)")

    pixels: set[int] = set()
    for name in filenames:
        png = ICON_DIR / name
        header = png.read_bytes()[:24]
        w = int.from_bytes(header[16:20], "big")
        h = int.from_bytes(header[20:24], "big")
        if w == h:
            pixels.add(w)

    missing = REQUIRED_PIXELS - pixels
    if missing:
        fail(f"Source catalog missing required pixel sizes: {sorted(missing)}")
    ok(f"Required source icon sizes present: {sorted(REQUIRED_PIXELS)}")

    if not INFO_PLIST.is_file():
        fail(f"Info.plist missing: {INFO_PLIST}")

    with INFO_PLIST.open("rb") as fp:
        info = plistlib.load(fp)
    icon_name = info.get("CFBundleIconName")
    if icon_name != "AppIcon":
        fail(f"CFBundleIconName must be 'AppIcon', got '{icon_name}'")
    ok("CFBundleIconName == AppIcon")

    print("App icon source validation passed.")


if __name__ == "__main__":
    main()
