#!/usr/bin/env python3
"""Preflight validation for Gonggi IPA before App Store Connect upload."""
from __future__ import annotations

import plistlib
import sys
import zipfile
from pathlib import Path

BUNDLE_ID = "com.whik.gonggi"
REQUIRED_ICON_PIXELS = {120, 180, 1024}


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    sys.exit(1)


def ok(message: str) -> None:
    print(f"OK: {message}")


def find_app_bundle(ipa_path: Path) -> str:
    with zipfile.ZipFile(ipa_path, "r") as zf:
        apps = [n for n in zf.namelist() if n.endswith(".app/Info.plist")]
        if not apps:
            fail(f"No .app/Info.plist found in {ipa_path}")
        if len(apps) > 1:
            fail(f"Multiple app bundles found in IPA: {apps}")
        return apps[0].rsplit("/", 1)[0] + "/"


def read_info_plist(zf: zipfile.ZipFile, app_prefix: str) -> dict:
    with zf.open(app_prefix + "Info.plist") as fp:
        return plistlib.load(fp)


def collect_car_icon_assets(car_path: Path) -> set[int]:
    """Best-effort parse of Assets.car for compiled icon dimensions."""
    try:
        from pathlib import Path as P

        data = car_path.read_bytes()
    except OSError:
        return set()

    found: set[int] = set()
    # Heuristic: PNG IHDR width/height appear as big-endian uint32 pairs in car.
    needle = b"\x89PNG\r\n\x1a\n"
    offset = 0
    while True:
        idx = data.find(needle, offset)
        if idx == -1:
            break
        ihdr_offset = idx + len(needle) + 4  # skip chunk length
        if ihdr_offset + 8 < len(data):
            w = int.from_bytes(data[ihdr_offset : ihdr_offset + 4], "big")
            h = int.from_bytes(data[ihdr_offset + 4 : ihdr_offset + 8], "big")
            if w == h and 20 <= w <= 1024:
                found.add(w)
        offset = idx + 1
    return found


def main() -> None:
    if len(sys.argv) != 2:
        fail("Usage: validate-ipa-preflight.py <path-to.ipa>")

    ipa_path = Path(sys.argv[1])
    if not ipa_path.is_file():
        fail(f"IPA not found: {ipa_path}")

    with zipfile.ZipFile(ipa_path, "r") as zf:
        app_prefix = find_app_bundle(ipa_path)
        info = read_info_plist(zf, app_prefix)

        bundle_id = info.get("CFBundleIdentifier")
        if bundle_id != BUNDLE_ID:
            fail(f"CFBundleIdentifier is '{bundle_id}', expected '{BUNDLE_ID}'")
        ok(f"CFBundleIdentifier == {BUNDLE_ID}")

        icon_name = info.get("CFBundleIconName")
        if not icon_name:
            fail("CFBundleIconName missing from Info.plist")
        ok(f"CFBundleIconName == {icon_name}")

        # Collect icon files inside app bundle
        icon_files = [
            n
            for n in zf.namelist()
            if n.startswith(app_prefix) and "AppIcon" in n and n.endswith(".png")
        ]
        car_files = [n for n in zf.namelist() if n.startswith(app_prefix) and n.endswith("Assets.car")]

        pixel_sizes: set[int] = set()
        for name in icon_files:
            with zf.open(name) as fp:
                header = fp.read(24)
            if len(header) >= 24 and header.startswith(b"\x89PNG\r\n\x1a\n"):
                w = int.from_bytes(header[16:20], "big")
                h = int.from_bytes(header[20:24], "big")
                if w == h:
                    pixel_sizes.add(w)

        if car_files:
            car_tmp = Path(ipa_path).parent / "_preflight_Assets.car"
            with zf.open(car_files[0]) as src, car_tmp.open("wb") as dst:
                dst.write(src.read())
            pixel_sizes |= collect_car_icon_assets(car_tmp)
            car_tmp.unlink(missing_ok=True)

        if not pixel_sizes:
            fail("No AppIcon PNG sizes detected in IPA (nor Assets.car heuristics)")

        ok(f"Detected icon pixel sizes: {sorted(pixel_sizes)}")

        missing = REQUIRED_ICON_PIXELS - pixel_sizes
        if missing:
            fail(f"Missing required icon sizes: {sorted(missing)}")

        ok(f"Required icon sizes present: {sorted(REQUIRED_ICON_PIXELS)}")

    print("Preflight validation passed.")


if __name__ == "__main__":
    main()
