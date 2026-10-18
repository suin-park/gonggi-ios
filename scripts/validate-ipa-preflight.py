#!/usr/bin/env python3
"""Preflight validation for Gonggi IPA before App Store Connect upload."""
from __future__ import annotations

import argparse
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


def truthy(value: object) -> bool:
    """Info.plist values come from build settings: a bool, or a string such as "YES" after $(VAR) expansion."""
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    return isinstance(value, str) and value.strip().lower() in {"1", "yes", "true", "on"}


def check_depth_model(zf: zipfile.ZipFile, app_prefix: str) -> None:
    names = zf.namelist()
    compiled = [n for n in names if n.startswith(app_prefix) and "DepthAnythingV2SmallF16.mlmodelc/" in n]
    package = [n for n in names if n.startswith(app_prefix) and "DepthAnythingV2SmallF16.mlpackage/" in n]
    if compiled:
        ok(f"Depth model compiled into the app (.mlmodelc, {len(compiled)} files)")
    elif package:
        ok(f"Depth model present as .mlpackage ({len(package)} files); the app compiles it on first use")
    else:
        fail("Depth Anything V2 Small model is not inside the IPA")


def check_release_inputs(info: dict, args: argparse.Namespace) -> None:
    """Optional checks of the real IPA Info.plist against the workflow inputs (only the ones given)."""
    if args.marketing_version is not None:
        got = info.get("CFBundleShortVersionString")
        if got != args.marketing_version:
            fail(f"CFBundleShortVersionString is {got!r}, workflow input is {args.marketing_version!r}")
        ok(f"CFBundleShortVersionString == {got}")
    if args.build_number is not None:
        got = info.get("CFBundleVersion")
        if got != args.build_number:
            fail(f"CFBundleVersion is {got!r}, workflow input is {args.build_number!r}")
        ok(f"CFBundleVersion == {got}")
    if args.api_base_url is not None:
        got = info.get("GonggiAPIBaseURL")
        expected = args.api_base_url.rstrip("/")
        if got != expected:
            fail(f"GonggiAPIBaseURL is {got!r}, workflow input is {expected!r}")
        ok(f"GonggiAPIBaseURL == {got}")
    if args.store_api_base_url is not None:
        got = info.get("GonggiStoreAPIBaseURL")
        expected = args.store_api_base_url.rstrip("/")
        if (got or "") != expected:
            fail(f"GonggiStoreAPIBaseURL is {got!r}, workflow input is {expected!r}")
        ok(f"GonggiStoreAPIBaseURL == {got!r}")
    if args.build_sha is not None:
        got = str(info.get("GonggiBuildSHA") or "")
        if not got or got in {"local", "unknown"} or not args.build_sha.startswith(got):
            fail(f"GonggiBuildSHA is {got!r}, checked-out commit is {args.build_sha!r}")
        ok(f"GonggiBuildSHA {got} matches commit {args.build_sha[:12]}")
    if args.require_pending_angular_rescue:
        if info.get("GonggiPendingAngularRescueDefault") is not True:
            fail(f"GonggiPendingAngularRescueDefault is {info.get('GonggiPendingAngularRescueDefault')!r}, expected True")
        ok("GonggiPendingAngularRescueDefault == true")
    if args.require_sensor_experiments:
        raw = info.get("GonggiSensorExperimentsEnabled")
        if not truthy(raw):
            fail(f"GonggiSensorExperimentsEnabled is {raw!r}, expected an enabled value (YES/true)")
        ok(f"GonggiSensorExperimentsEnabled == {raw!r} (enabled)")
        motion = info.get("NSMotionUsageDescription")
        if not isinstance(motion, str) or not motion.strip():
            fail("NSMotionUsageDescription missing or empty")
        ok("NSMotionUsageDescription present")


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Preflight validation for a Gonggi IPA before App Store Connect upload.")
    ap.add_argument("ipa", help="path to the .ipa")
    ap.add_argument("--marketing-version")
    ap.add_argument("--build-number")
    ap.add_argument("--api-base-url")
    ap.add_argument("--store-api-base-url", help="empty string = expect no separate store server")
    ap.add_argument("--build-sha", help="full commit SHA of the checked-out source")
    ap.add_argument("--require-pending-angular-rescue", action="store_true")
    ap.add_argument("--require-sensor-experiments", action="store_true")
    ap.add_argument("--require-depth-model", action="store_true", help="IPA must contain the Core ML depth prior (compiled .mlmodelc or .mlpackage)")
    return ap.parse_args()


def main() -> None:
    args = parse_args()
    ipa_path = Path(args.ipa)
    if not ipa_path.is_file():
        fail(f"IPA not found: {ipa_path}")

    with zipfile.ZipFile(ipa_path, "r") as zf:
        app_prefix = find_app_bundle(zf)
        info = read_info_plist(zf, app_prefix)

        bundle_id = info.get("CFBundleIdentifier")
        if bundle_id != BUNDLE_ID:
            fail(f"CFBundleIdentifier is '{bundle_id}', expected '{BUNDLE_ID}'")
        ok(f"CFBundleIdentifier == {BUNDLE_ID}")

        check_release_inputs(info, args)
        if args.require_depth_model:
            check_depth_model(zf, app_prefix)

        icon_name = info.get("CFBundleIconName")
        if not icon_name:
            fail("CFBundleIconName missing from Info.plist")
        if info.get("CFBundleDisplayName") != "커모":
            fail(f"CFBundleDisplayName is {info.get('CFBundleDisplayName')!r}, expected '커모'")
        ok(f"Installed app display name: {info.get('CFBundleDisplayName')} (CFBundleName={info.get('CFBundleName')})")
        names = [n for n in zf.namelist() if n.startswith(app_prefix) and n.endswith("InfoPlist.strings")]
        ok(f"InfoPlist.strings in IPA: {sorted(names)}")
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
