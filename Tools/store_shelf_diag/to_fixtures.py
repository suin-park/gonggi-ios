#!/usr/bin/env python3
"""Turns exported camera frames into labelled-photo fixtures for ShelfRecognitionFixtureTests (macOS CI), so a detector
or a filter change can be measured on the SAME real frames again and again.

    python to_fixtures.py BUNDLE.zip-or-folder BOXES.json OUT_DIR [--role register|search] [--split tune|eval]

BOXES.json: {"frames": {"12": [{"rect": [minU, minV, maxU, maxV], "productId": "cola500" | null}, ...]}}
  rect: FULL sensor pixels as in session.json regions (u right, v down, origin top-left, landscape sensor image).

The exported frame is the landscape sensor image; fixtures are UPRIGHT (the app holds the phone in portrait), so the
image is rotated 90 degrees clockwise and the boxes are mapped with  x = H - v,  y = u  (H = sensor height).
"""
import argparse
import io
import json
import os
import sys
import zipfile

from PIL import Image


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle")
    ap.add_argument("boxes")
    ap.add_argument("out")
    ap.add_argument("--role", default="search")
    ap.add_argument("--split", default="eval")
    a = ap.parse_args()

    if os.path.isdir(a.bundle):
        read = lambda n: open(os.path.join(a.bundle, n), "rb").read()  # noqa: E731
    else:
        z = zipfile.ZipFile(a.bundle)
        read = lambda n: z.read(n)  # noqa: E731
    s = json.loads(read("session.json").decode("utf-8"))
    boxes = json.load(open(a.boxes, encoding="utf-8"))["frames"]
    os.makedirs(a.out, exist_ok=True)
    frames = {str(f["index"]): f for f in s["frames"]}
    written = 0
    for idx, items in boxes.items():
        fr = frames.get(idx)
        if not fr or not fr.get("imageFile"):
            print("frame %s has no saved image, skipped" % idx)
            continue
        im = Image.open(io.BytesIO(read(fr["imageFile"]))).convert("RGB")
        sc = fr["imageScale"]
        H = fr["sensorHeight"]
        up = im.transpose(Image.ROTATE_270)  # 90 degrees clockwise
        out_boxes = []
        for it in items:
            u0, v0, u1, v1 = [c * sc for c in it["rect"]]
            h = H * sc
            out_boxes.append({"rect": [h - v1, u0, h - v0, u1], "productId": it.get("productId")})
        name = "%s_f%04d" % (s["kind"], int(idx))
        up.save(os.path.join(a.out, name + ".jpg"), quality=92)
        json.dump({"role": a.role, "split": a.split, "boxes": out_boxes}, open(os.path.join(a.out, name + ".json"), "w", encoding="utf-8"))
        written += 1
    print("wrote %d fixtures to %s" % (written, a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
