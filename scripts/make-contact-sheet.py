#!/usr/bin/env python3
"""Build a grid contact sheet from Gonggi redesign V1 screenshots."""
from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Pillow is required: pip install Pillow")
    sys.exit(1)

# Prefer redesign V1 names; fall back gracefully if a subset is present.
PREFERRED = [
    "00_welcome_after.png",
    "00_welcome_reduce_motion.png",
    "00_login_email_after.png",
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
    "05_asset_detail_processing.png",
    "05_asset_detail_ready.png",
    "05_asset_detail_failed.png",
    "06_space_picker_after.png",
    "06_asset_picker_after.png",
    "07_profile_after.png",
    "08_vr_edit_menu_after.png",
    "09_ar_camera_denied.png",
    "09_processing_after.png",
    "10_app_icon_preview.png",
]

COLS = 4
THUMB_WIDTH = 280
PADDING = 14
LABEL_HEIGHT = 36
BG = (14, 35, 62)  # brand navy


def main() -> None:
    screenshots_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "screenshots")
    out_path = Path(sys.argv[2] if len(sys.argv) > 2 else "screenshots/contact_sheet.png")

    names = [n for n in PREFERRED if (screenshots_dir / n).is_file()]
    if not names:
        # Legacy fallback
        names = sorted(p.name for p in screenshots_dir.glob("*.png") if p.name != "contact_sheet.png" and p.name != "contact-sheet.png")
    if not names:
        raise SystemExit(f"No screenshots found in {screenshots_dir}")

    images: list[tuple[str, Image.Image]] = []
    for name in names:
        path = screenshots_dir / name
        img = Image.open(path).convert("RGB")
        ratio = THUMB_WIDTH / img.width
        thumb_h = int(img.height * ratio)
        label = name.replace(".png", "")
        images.append((label, img.resize((THUMB_WIDTH, thumb_h), Image.Resampling.LANCZOS)))

    rows = (len(images) + COLS - 1) // COLS
    cell_h = max(im.height for _, im in images) + LABEL_HEIGHT
    sheet_w = COLS * THUMB_WIDTH + (COLS + 1) * PADDING
    sheet_h = rows * cell_h + (rows + 1) * PADDING

    sheet = Image.new("RGB", (sheet_w, sheet_h), BG)
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 12)
    except OSError:
        try:
            font = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 12)
        except OSError:
            font = ImageFont.load_default()

    for idx, (label, thumb) in enumerate(images):
        row, col = divmod(idx, COLS)
        x = PADDING + col * (THUMB_WIDTH + PADDING)
        y = PADDING + row * (cell_h + PADDING)
        sheet.paste(thumb, (x, y))
        draw.text((x, y + thumb.height + 4), label[:42], fill=(63, 207, 228), font=font)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out_path, format="PNG", optimize=True)
    print(f"Wrote {out_path} ({sheet_w}x{sheet_h}) from {len(images)} images")


if __name__ == "__main__":
    main()
