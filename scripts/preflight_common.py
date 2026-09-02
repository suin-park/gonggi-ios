"""Shared helpers for Gonggi IPA/app preflight validation."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

BUNDLE_ID = "com.whik.gonggi"


def collect_car_icon_assets(car_path: Path) -> set[int]:
    found: set[int] = set()

    try:
        out = subprocess.check_output(
            ["xcrun", "assetutil", "--info", str(car_path)],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        data = json.loads(out)
        items = data if isinstance(data, list) else [data]
        for item in items:
            if not isinstance(item, dict):
                continue
            name = str(item.get("Name", ""))
            if "AppIcon" not in name and name not in ("", "App Icon"):
                continue
            w = item.get("PixelWidth") or item.get("pixelWidth") or item.get("width")
            h = item.get("PixelHeight") or item.get("pixelHeight") or item.get("height")
            if w is None or h is None:
                continue
            w_i, h_i = int(w), int(h)
            if w_i == h_i:
                found.add(w_i)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, ValueError):
        pass

    if found:
        return found

    try:
        data = car_path.read_bytes()
    except OSError:
        return set()

    needle = b"\x89PNG\r\n\x1a\n"
    offset = 0
    while True:
        idx = data.find(needle, offset)
        if idx == -1:
            break
        ihdr_offset = idx + len(needle) + 4
        if ihdr_offset + 8 < len(data):
            w = int.from_bytes(data[ihdr_offset : ihdr_offset + 4], "big")
            h = int.from_bytes(data[ihdr_offset + 4 : ihdr_offset + 8], "big")
            if w == h and 20 <= w <= 1024:
                found.add(w)
        offset = idx + 1
    return found
