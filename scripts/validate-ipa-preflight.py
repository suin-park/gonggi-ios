#!/usr/bin/env python3
"""Preflight validation for Gonggi IPA before App Store Connect upload."""
from __future__ import annotations

import plistlib
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from preflight_common import BUNDLE_ID, collect_car_icon_assets

REQUIRED_ICON_PIXELS = {120, 180, 1024}


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    sys.exit(1)


def ok(message: str) -> None:
    print(f"OK: {message}")


def find_app_bundle(zf: zipfile.ZipFile) -> str:
    apps = [n for n in zf.namelist() if n.endswith(".app/Info.plist")]
    if not apps:
        fail("No .app/Info.plist found in IPA")
    if len(apps) > 1:
        fail(f"Multiple app bundles found in IPA: {apps}")
    return apps[0].rsplit("/", 1)[0] + "/"


def read_info_plist(zf: zipfile.ZipFile, app_prefix: str) -> dict:
    with zf.open(app_prefix + "Info.plist") as fp:
        return plistlib.load(fp)


def main() -> None:
    if len(sys.argv) != 2:
        fail("Usage: validate-ipa-preflight.py <path-to.ipa>")

    ipa_path = Path(sys.argv[1])
    if not ipa_path.is_file():
        fail(f"IPA not found: {ipa_path}")

    with zipfile.ZipFile(ipa_path, "r") as zf:
        app_prefix = find_app_bundle(zf)
        info = read_info_plist(zf, app_prefix)

        bundle_id = info.get("CFBundleIdentifier")
        if bundle_id != BUNDLE_ID:
            fail(f"CFBundleIdentifier is '{bundle_id}', expected '{BUNDLE_ID}'")
        ok(f"CFBundleIdentifier == {BUNDLE_ID}")

        icon_name = info.get("CFBundleIconName")
        if not icon_name:
            fail("CFBundleIconName missing from Info.plist")
        ok(f"CFBundleIconName == {icon_name}")

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

        if not car_files:
            fail("Assets.car missing from IPA — AppIcon asset catalog did not compile")

        car_tmp = Path(ipa_path).parent / "_preflight_Assets.car"
        with zf.open(car_files[0]) as src, car_tmp.open("wb") as dst:
            dst.write(src.read())
        pixel_sizes |= collect_car_icon_assets(car_tmp)
        car_tmp.unlink(missing_ok=True)
        ok("Assets.car present (compiled asset catalog)")

        if not pixel_sizes:
            fail("No AppIcon sizes detected in IPA")

        ok(f"Detected icon pixel sizes: {sorted(pixel_sizes)}")

        missing = REQUIRED_ICON_PIXELS - pixel_sizes
        if missing:
            fail(f"Missing required icon sizes: {sorted(missing)}")

        ok(f"Required icon sizes present: {sorted(REQUIRED_ICON_PIXELS)}")

    print("Preflight validation passed.")


if __name__ == "__main__":
    main()
