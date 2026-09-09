#!/usr/bin/env python3
"""Verify Gonggi redesign V1 screenshot artifacts are present and not blank."""
from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Pillow is required: pip install Pillow")
    sys.exit(1)

REQUIRED = [
    "00_welcome_after.png",
    "01_home_after.png",
    "01_record_mode_after.png",
    "02_library_spaces_after.png",
    "02_library_spaces_loading.png",
    "02_library_spaces_empty.png",
    "02_library_spaces_error.png",
    "03_library_assets_thumb.png",
    "03_library_assets_no_thumb.png",
    "03_library_assets_generating.png",
    "04_space_detail_after.png",
    "05_asset_detail_need_prepare.png",
    "05_asset_detail_ready.png",
    "05_asset_detail_failed.png",
    "06_space_picker_after.png",
    "06_asset_picker_after.png",
    "07_profile_after.png",
    "08_vr_edit_menu_after.png",
    "09_ar_camera_denied.png",
    "10_app_icon_preview.png",
]

MIN_MEAN_LUMINANCE = 8.0
screenshots_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "screenshots")

failed = False
for name in REQUIRED:
    path = screenshots_dir / name
    if not path.is_file():
        print(f"FAIL missing: {name}")
        failed = True
        continue
    size = path.stat().st_size
    if size == 0:
        print(f"FAIL empty file: {name}")
        failed = True
        continue
    with Image.open(path) as img:
        gray = img.convert("L")
        pixels = list(gray.getdata())
        mean = sum(pixels) / len(pixels)
        if mean < MIN_MEAN_LUMINANCE:
            print(f"FAIL too dark (likely blank): {name} mean_luma={mean:.1f}")
            failed = True
        else:
            print(f"OK {name} ({size} bytes, mean_luma={mean:.1f}, {img.size[0]}x{img.size[1]})")

if failed:
    sys.exit(1)
print(f"Verified {len(REQUIRED)} required screenshots")
