#!/usr/bin/env python3
"""Generate Gonggi AppIcon from official logo (cyan full-bleed, navy mark).

Original SVG/PNG sources under docs/gonggi-redesign-v1/brand/logos/ are preserved.
This writes derived AppIcon catalog PNGs + refinement-01 review images.
"""
from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
ICON_DIR = ROOT / "Gonggi" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
PREVIEW_DIR = ROOT / "Gonggi" / "Resources" / "Assets.xcassets" / "GonggiAppIconPreview.imageset"
LOGO_CROPPED = ROOT / "docs" / "gonggi-redesign-v1" / "brand" / "logos" / "cropped" / "gonggi_app_logo_white@3x.png"
OUT_DOCS = ROOT / "docs" / "gonggi-redesign-v1" / "refinement-01"

CYAN = (63, 207, 228, 255)  # #3FCFE4
NAVY = (14, 35, 62, 255)  # #0E233E

# Apple HIG: keep artwork inside ~80–90% of the square; avoid nested rounded plate.
CONTENT_SCALE = 0.72  # logo bbox relative to canvas (internal margin)

SIZES: list[tuple[str, str, str, int]] = [
    ("iphone", "20x20", "2x", 40),
    ("iphone", "20x20", "3x", 60),
    ("iphone", "29x29", "2x", 58),
    ("iphone", "29x29", "3x", 87),
    ("iphone", "40x40", "2x", 80),
    ("iphone", "40x40", "3x", 120),
    ("iphone", "60x60", "2x", 120),
    ("iphone", "60x60", "3x", 180),
    ("ios-marketing", "1024x1024", "1x", 1024),
]


def recolor_to_navy(src: Image.Image) -> Image.Image:
    src = src.convert("RGBA")
    pix = src.load()
    out = Image.new("RGBA", src.size, (0, 0, 0, 0))
    op = out.load()
    for y in range(src.height):
        for x in range(src.width):
            r, g, b, a = pix[x, y]
            if a <= 8:
                continue
            # Preserve anti-alias by multiplying navy with source alpha / luminance.
            lum = max(r, g, b) / 255.0
            aa = int(a * lum) if lum < 0.98 else a
            op[x, y] = (NAVY[0], NAVY[1], NAVY[2], aa)
    return out


def trim_transparent(im: Image.Image, pad: int = 0) -> Image.Image:
    bbox = im.getbbox()
    if not bbox:
        return im
    cropped = im.crop(bbox)
    if pad <= 0:
        return cropped
    canvas = Image.new("RGBA", (cropped.width + pad * 2, cropped.height + pad * 2), (0, 0, 0, 0))
    canvas.paste(cropped, (pad, pad), cropped)
    return canvas


def wordmark_only(logo: Image.Image) -> Image.Image:
    """Drop slogan band under the clear horizontal gap (derived crop only)."""
    pix = logo.load()
    dens = []
    for y in range(logo.height):
        dens.append(sum(1 for x in range(logo.width) if pix[x, y][3] > 20))
    # Gap in lower-mid area
    gap_start = None
    for y in range(int(logo.height * 0.40), int(logo.height * 0.85)):
        if dens[y] < max(1, int(max(dens) * 0.02)):
            gap_start = y
            break
    if gap_start is None:
        return logo
    return trim_transparent(logo.crop((0, 0, logo.width, gap_start)))


def compose_icon(logo: Image.Image, size: int = 1024) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), CYAN)
    # Fit logo into CONTENT_SCALE box, centered
    max_w = int(size * CONTENT_SCALE)
    max_h = int(size * CONTENT_SCALE)
    lw, lh = logo.size
    scale = min(max_w / lw, max_h / lh)
    nw, nh = max(1, int(lw * scale)), max(1, int(lh * scale))
    resized = logo.resize((nw, nh), Image.Resampling.LANCZOS)
    x = (size - nw) // 2
    y = (size - nh) // 2
    canvas.alpha_composite(resized, (x, y))
    return canvas.convert("RGB")


def ios_home_preview(icon_rgb: Image.Image, display: int = 180, corner_ratio: float = 0.2237) -> Image.Image:
    """Approximate home-screen masked icon (system applies real mask)."""
    icon = icon_rgb.resize((display, display), Image.Resampling.LANCZOS).convert("RGBA")
    radius = int(display * corner_ratio)
    mask = Image.new("L", (display, display), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, display - 1, display - 1), radius=radius, fill=255)
    out = Image.new("RGBA", (display, display), (0, 0, 0, 0))
    out.paste(icon, (0, 0), mask)
    # Place on light springboard-ish backdrop for review
    board = Image.new("RGB", (display + 40, display + 40), (28, 28, 30))
    board.paste(out.convert("RGB"), (20, 20), out)
    return board


def write_catalog(master: Image.Image) -> None:
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    images = []
    for idiom, size_label, scale, pixels in SIZES:
        filename = f"icon-{pixels}.png"
        master.resize((pixels, pixels), Image.Resampling.LANCZOS).save(
            ICON_DIR / filename, format="PNG", optimize=True
        )
        images.append(
            {
                "filename": filename,
                "idiom": idiom,
                "scale": scale,
                "size": size_label,
            }
        )
        print(f"Wrote {ICON_DIR / filename}")
    (ICON_DIR / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    if not LOGO_CROPPED.is_file():
        raise SystemExit(f"Missing cropped white logo: {LOGO_CROPPED}")

    white = Image.open(LOGO_CROPPED).convert("RGBA")
    navy_full = recolor_to_navy(white)
    navy_mark = trim_transparent(navy_full)
    navy_no_slogan = wordmark_only(navy_mark)

    master = compose_icon(navy_mark, 1024)
    master_no_slogan = compose_icon(navy_no_slogan, 1024)

    write_catalog(master)

    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    preview = master.resize((512, 512), Image.Resampling.LANCZOS)
    preview.save(PREVIEW_DIR / "preview.png", format="PNG", optimize=True)
    (PREVIEW_DIR / "Contents.json").write_text(
        json.dumps(
            {
                "images": [{"filename": "preview.png", "idiom": "universal", "scale": "1x"}],
                "info": {"author": "xcode", "version": 1},
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {PREVIEW_DIR / 'preview.png'}")

    OUT_DOCS.mkdir(parents=True, exist_ok=True)
    master.save(OUT_DOCS / "app_icon_1024.png", format="PNG", optimize=True)
    master_no_slogan.save(OUT_DOCS / "app_icon_1024_no_slogan_COMPARE.png", format="PNG", optimize=True)
    ios_home_preview(master, 180).save(OUT_DOCS / "app_icon_home_preview.png", format="PNG", optimize=True)
    ios_home_preview(master_no_slogan, 180).save(
        OUT_DOCS / "app_icon_home_preview_no_slogan_COMPARE.png", format="PNG", optimize=True
    )
    # Also keep brand logos folder master updated (derived)
    brand = ROOT / "docs" / "gonggi-redesign-v1" / "brand" / "logos"
    master.save(brand / "app_icon_master_1024.png", format="PNG", optimize=True)
    master.resize((180, 180), Image.Resampling.LANCZOS).save(brand / "app_icon_180.png", format="PNG", optimize=True)
    print(f"Wrote review assets under {OUT_DOCS}")


if __name__ == "__main__":
    main()
