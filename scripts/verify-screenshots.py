#!/usr/bin/env python3
"""Verify Gonggi UI screenshot artifacts are present and not blank."""
from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Pillow is required: pip install Pillow")
    sys.exit(1)

EXPECTED = [
    "01_home.png",
    "02_capture_30.png",
    "03_capture_68.png",
    "04_capture_90.png",
    "05_capture_fast_movement.png",
    "06_capture_tracking_limited.png",
    "07_capture_low_texture.png",
    "08_capture_summary.png",
    "09_processing.png",
    "10_library.png",
    "11_space_detail.png",
    "12_profile.png",
]

MIN_MEAN_LUMINANCE = 8.0
screenshots_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "screenshots")

failed = False
for name in EXPECTED:
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
print(f"Verified {len(EXPECTED)} screenshots")
