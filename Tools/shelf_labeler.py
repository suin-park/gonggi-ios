#!/usr/bin/env python3
"""Label real shelf photos for the detection / recognition measurement (GonggiTests/Fixtures/ShelfPhotos).

  python tools/shelf_labeler.py --in PHOTOS_DIR --out OUT_DIR --role register --split tune
  python tools/shelf_labeler.py --in PHOTOS_DIR --out OUT_DIR --role search   --split eval

For every photo: the EXIF orientation is applied and the picture is saved UPRIGHT with no orientation tag (the app's
test harness reads raw pixels), then you draw one box per PRODUCT and type its product id.
  - draw a box: drag, then press ENTER/SPACE;  finish the photo: press ESC
  - product id: the stable id you give a product ("cola500", "cola-zero500", ...). Leave empty or "-" for a product that is
    NOT registered in the store (it must come out as unregistered / uncertain, never confirmed).
  - price tags, shelf frames and printed patterns get NO box.
Use the SAME ids in the register and the search shootings. Different shootings, not crops of the same frames.
Requires: pip install opencv-python pillow
"""
import argparse
import json
import os
import sys

import cv2
from PIL import Image, ImageOps


def normalise(src, dst):
    img = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
    img.save(dst, "JPEG", quality=92)
    return img.size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", dest="out", required=True)
    ap.add_argument("--role", choices=["register", "search"], required=True)
    ap.add_argument("--split", choices=["tune", "eval"], required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    names = sorted(f for f in os.listdir(a.src) if f.lower().endswith((".jpg", ".jpeg", ".png", ".heic")))
    if not names:
        print("no photos found")
        return 1
    for n, f in enumerate(names, 1):
        stem = f"{a.role}_{a.split}_{n:02d}"
        jpg = os.path.join(a.out, stem + ".jpg")
        w, h = normalise(os.path.join(a.src, f), jpg)
        img = cv2.imread(jpg)
        boxes = []
        print(f"\n[{n}/{len(names)}] {f}  ({w}x{h})  ->  {stem}")
        while True:
            r = cv2.selectROI(stem, img, showCrosshair=False, fromCenter=False)
            x, y, bw, bh = [int(v) for v in r]
            if bw == 0 or bh == 0:
                break
            pid = input("  product id (empty or - = not registered): ").strip()
            boxes.append({"rect": [x, y, x + bw, y + bh], "productId": None if pid in ("", "-") else pid})
            cv2.rectangle(img, (x, y), (x + bw, y + bh), (0, 200, 0) if pid not in ("", "-") else (0, 0, 220), 2)
        cv2.destroyAllWindows()
        with open(os.path.join(a.out, stem + ".json"), "w", encoding="utf-8") as fh:
            json.dump({"role": a.role, "split": a.split, "boxes": boxes}, fh, ensure_ascii=False, indent=1)
        print(f"  saved {len(boxes)} boxes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
