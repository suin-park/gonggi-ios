#!/usr/bin/env python3
"""Build a grid contact sheet from Gonggi UI screenshots (post-processing only)."""
from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Pillow is required: pip install Pillow")
    sys.exit(1)

NAMES = [
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

COLS = 4
THUMB_WIDTH = 320
PADDING = 16
LABEL_HEIGHT = 28
BG = (12, 18, 32)


def main() -> None:
    screenshots_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "screenshots")
    out_path = Path(sys.argv[2] if len(sys.argv) > 2 else "screenshots/contact-sheet.png")

    images: list[tuple[str, Image.Image]] = []
    for name in NAMES:
        path = screenshots_dir / name
        if not path.is_file():
            raise SystemExit(f"Missing screenshot: {path}")
        img = Image.open(path).convert("RGB")
        ratio = THUMB_WIDTH / img.width
        thumb_h = int(img.height * ratio)
        images.append((name.replace(".png", ""), img.resize((THUMB_WIDTH, thumb_h), Image.Resampling.LANCZOS)))

    rows = (len(images) + COLS - 1) // COLS
    cell_h = max(h for _, im in images) + LABEL_HEIGHT
    sheet_w = COLS * THUMB_WIDTH + (COLS + 1) * PADDING
    sheet_h = rows * cell_h + (rows + 1) * PADDING

    sheet = Image.new("RGB", (sheet_w, sheet_h), BG)
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 14)
    except OSError:
        font = ImageFont.load_default()

    for idx, (label, thumb) in enumerate(images):
        row, col = divmod(idx, COLS)
        x = PADDING + col * (THUMB_WIDTH + PADDING)
        y = PADDING + row * (cell_h + PADDING)
        sheet.paste(thumb, (x, y))
        draw.text((x, y + thumb.height + 4), label, fill=(220, 225, 235), font=font)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out_path, format="PNG", optimize=True)
    print(f"Wrote {out_path} ({sheet_w}x{sheet_h})")


if __name__ == "__main__":
    main()
