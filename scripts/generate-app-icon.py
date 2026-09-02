#!/usr/bin/env python3
"""Generate Gonggi temporary App Store-valid AppIcon PNGs."""
from __future__ import annotations

import json
import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICON_DIR = ROOT / "Gonggi" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

# iPhone-only catalog entries (points -> pixels)
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


def _clamp(v: float) -> int:
    return max(0, min(255, int(round(v))))


def _lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def pixel_color(x: int, y: int, size: int) -> tuple[int, int, int, int]:
    """Deep navy base with subtle teal glow - Gonggi brand tone."""
    nx = (x + 0.5) / size
    ny = (y + 0.5) / size
    cx, cy = 0.5, 0.42
    dist = math.hypot(nx - cx, ny - cy)

    # Background gradient
    r = _lerp(0.03, 0.08, ny)
    g = _lerp(0.05, 0.12, ny)
    b = _lerp(0.10, 0.20, ny)

    # Soft radial glow
    glow = max(0.0, 1.0 - dist / 0.55)
    glow *= glow
    r += 0.12 * glow
    g += 0.28 * glow
    b += 0.30 * glow

    # Simple wind arc motif
    angle = math.atan2(ny - cy, nx - cx)
    arc = math.sin(angle * 2.2 + dist * 9.0) * 0.08
    if 0.18 < dist < 0.38:
        t = 1.0 - abs(dist - 0.28) / 0.10
        t = max(0.0, min(1.0, t))
        r += 0.10 * t
        g += 0.35 * t
        b += 0.32 * t
        r += arc * t
        g += arc * t

    return (_clamp(r * 255), _clamp(g * 255), _clamp(b * 255), 255)


def write_png(path: Path, size: int) -> None:
  rows = []
  for y in range(size):
    row = bytearray([0])  # filter type 0
    for x in range(size):
      row.extend(pixel_color(x, y, size))
    rows.append(bytes(row))

  compressed = zlib.compress(b"".join(rows), 9)

  def chunk(tag: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

  ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
  png = b"\x89PNG\r\n\x1a\n"
  png += chunk(b"IHDR", ihdr)
  png += chunk(b"IDAT", compressed)
  png += chunk(b"IEND", b"")
  path.write_bytes(png)


def main() -> None:
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    images = []
    for idiom, size_label, scale, pixels in SIZES:
        filename = f"icon-{pixels}.png"
        write_png(ICON_DIR / filename, pixels)
        images.append(
            {
                "filename": filename,
                "idiom": idiom,
                "scale": scale,
                "size": size_label,
            }
        )
        print(f"Wrote {filename} ({pixels}x{pixels})")

    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (ICON_DIR / "Contents.json").write_text(
        json.dumps(contents, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Wrote {ICON_DIR / 'Contents.json'}")


if __name__ == "__main__":
    main()
