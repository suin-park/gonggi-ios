#!/usr/bin/env python3
"""Contact sheet for Gonggi redesign refinement-01 auth / space-light captures."""
from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Pillow is required: pip install Pillow")
    sys.exit(1)

PREFERRED = [
    ("login_email.png", "login email"),
    ("login_email_keyboard.png", "login + keyboard"),
    ("welcome_logo_refined.png", "welcome logo"),
    ("welcome_dynamic_type.png", "welcome Dynamic Type"),
    ("welcome_compact.png", "welcome compact"),
    ("welcome_reduce_motion.png", "welcome Reduce Motion"),
    ("space_light_storyboard.png", "space-light storyboard (DEBUG)"),
    ("welcome_space_light.png", "welcome + space-light (DEBUG)"),
    ("welcome_space_light_dynamic_type.png", "space-light Dynamic Type (DEBUG)"),
    ("welcome_space_light_compact.png", "space-light compact (DEBUG)"),
    ("welcome_space_light_reduce_motion.png", "space-light Reduce Motion (DEBUG)"),
]

COLS = 3
THUMB_WIDTH = 300
PADDING = 14
LABEL_HEIGHT = 40
BG = (14, 35, 62)


def main() -> None:
    screenshots_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "docs/gonggi-redesign-v1/refinement-01")
    out_path = Path(sys.argv[2] if len(sys.argv) > 2 else screenshots_dir / "contact_sheet.png")

    images: list[tuple[str, Image.Image]] = []
    for name, label in PREFERRED:
        path = screenshots_dir / name
        if not path.is_file():
            print(f"WARN missing: {path}")
            continue
        img = Image.open(path).convert("RGB")
        ratio = THUMB_WIDTH / img.width
        thumb_h = int(img.height * ratio)
        images.append((label, img.resize((THUMB_WIDTH, thumb_h), Image.Resampling.LANCZOS)))

    if not images:
        raise SystemExit(f"No screenshots in {screenshots_dir}")

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
        draw.text((x, y + thumb.height + 4), label[:48], fill=(63, 207, 228), font=font)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out_path, format="PNG", optimize=True)
    print(f"Wrote {out_path} from {len(images)} images")


if __name__ == "__main__":
    main()
