#!/usr/bin/env python3
"""Renders a store-shelf diagnostics bundle (ZIP or folder exported from the app) into images and a report.

    python render.py BUNDLE.zip OUT_DIR [--replay REPORT.json]

Output
  frames_overlay/fNNNN.jpg   camera frames with every detected region, coloured by what happened to it
  products_sheet.jpg         one row per final product: the crops that were merged into it (duplicates show as rows
                             that look alike)
  nonproduct_sheet.jpg       crops (cut from the frames) of regions that were rejected as structure / container / part
  report.md                  counters, region verdicts, tracking decisions, OCR lines vs final names, search timeline
"""
import argparse
import json
import os
import sys
import zipfile
from collections import Counter

from PIL import Image, ImageDraw, ImageFont

COLORS = {
    "kept": (60, 200, 90),
    "notProduct": (230, 60, 60),
    "container": (240, 150, 30),
    "part": (170, 80, 220),
    "unplaced": (140, 140, 140),
    "notFeatured": (140, 140, 140),
}


def load(path):
    if os.path.isdir(path):
        base = path

        def read(name):
            with open(os.path.join(base, name), "rb") as f:
                return f.read()

        def exists(name):
            return os.path.exists(os.path.join(base, name))

        return read, exists
    z = zipfile.ZipFile(path)
    names = set(z.namelist())
    return (lambda n: z.read(n)), (lambda n: n in names)


def font(size=14):
    for name in ("arial.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def open_image(read, name):
    import io

    return Image.open(io.BytesIO(read(name))).convert("RGB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle")
    ap.add_argument("out")
    ap.add_argument("--replay")
    a = ap.parse_args()
    read, exists = load(a.bundle)
    s = json.loads(read("session.json"))
    os.makedirs(a.out, exist_ok=True)
    os.makedirs(os.path.join(a.out, "frames_overlay"), exist_ok=True)
    f14, f11 = font(14), font(11)

    # ---- frame overlays
    non_product = []  # (label, image)
    for fr in s.get("frames", []):
        name = fr.get("imageFile")
        if not name or not exists(name):
            continue
        im = open_image(read, name)
        sc = fr.get("imageScale", 1.0)
        d = ImageDraw.Draw(im)
        for r in fr.get("regions", []):
            col = COLORS.get(r.get("arbiter"), (200, 200, 0))
            box = [r["minU"] * sc, r["minV"] * sc, r["maxU"] * sc, r["maxV"] * sc]
            d.rectangle(box, outline=col, width=3)
            tag = "%d %s" % (r["index"], r.get("verdict") if r.get("arbiter") == "notProduct" else r.get("arbiter"))
            d.rectangle([box[0], box[1], box[0] + 7 * len(tag) + 4, box[1] + 15], fill=col)
            d.text((box[0] + 2, box[1] + 1), tag, fill=(0, 0, 0), font=f11)
            if r.get("arbiter") in ("notProduct", "container", "part") and len(non_product) < 80:
                x0, y0, x1, y1 = [int(v) for v in box]
                if x1 - x0 > 8 and y1 - y0 > 8:
                    crop = im.crop((max(0, x0), max(0, y0), min(im.width, x1), min(im.height, y1)))
                    non_product.append(("f%d r%d %s" % (fr["index"], r["index"], tag.split(" ", 1)[1]), crop.copy()))
        im.save(os.path.join(a.out, "frames_overlay", "f%04d.jpg" % fr["index"]), quality=85)

    # ---- sheets
    def sheet(rows, path, cell=120, label_h=34):
        if not rows:
            return
        maxn = max(len(r[1]) for r in rows) or 1
        w = 260 + maxn * (cell + 6)
        h = len(rows) * (cell + label_h + 6)
        img = Image.new("RGB", (w, h), (24, 24, 28))
        dr = ImageDraw.Draw(img)
        y = 0
        for title, crops in rows:
            dr.text((6, y + 6), title, fill=(255, 255, 255), font=f14)
            x = 260
            for label, c in crops:
                c = c.copy()
                c.thumbnail((cell, cell))
                img.paste(c, (x, y + 2))
                dr.text((x, y + cell + 4), label, fill=(190, 190, 190), font=f11)
                x += cell + 6
            y += cell + label_h + 6
        img.save(path, quality=88)

    obs_by_ref = {o["ref"]: o for o in s.get("observations", [])}
    rows = []
    for p in s.get("products", []):
        crops = []
        for ci in p.get("candidateIndices", []):
            cand = s["candidates"][ci]
            for ref in cand.get("observationRefs", [])[:4]:
                o = obs_by_ref.get(ref)
                if o and o.get("cropFile") and exists(o["cropFile"]):
                    crops.append(("c%d f%d" % (ci, o["frameIndex"]), open_image(read, o["cropFile"])))
        title = "%s  [%s]  cand %s" % (p["name"], p.get("nameSource") or "-", p.get("candidateIndices"))
        rows.append((title, crops[:10]))
    sheet(rows, os.path.join(a.out, "products_sheet.jpg"))

    nrows, chunk = [], 10
    for i in range(0, len(non_product), chunk):
        nrows.append(("non-product regions %d-%d" % (i, i + chunk - 1), non_product[i : i + chunk]))
    sheet(nrows, os.path.join(a.out, "nonproduct_sheet.jpg"))

    # ---- report
    out = []
    out.append("# Diagnostics report (%s, app %s (%s), %s, iOS %s)" % (s["kind"], s["appVersion"], s["appBuild"], s["device"], s["osVersion"]))
    out.append("")
    out.append("OCR: `%s`" % s.get("ocrSummary", ""))
    c = s.get("counters")
    if c:
        out.append("")
        out.append("## Counters")
        for k, v in c.items():
            out.append("- %s: %s" % (k, v))
    arb = Counter()
    ver = Counter()
    for fr in s.get("frames", []):
        for r in fr.get("regions", []):
            arb[r.get("arbiter")] += 1
            if r.get("verdict"):
                ver[r["verdict"]] += 1
    out.append("")
    out.append("## Regions (all frames, incl. frames without a saved image)")
    out.append("- by outcome: " + ", ".join("%s %d" % kv for kv in arb.most_common()))
    out.append("- structural verdicts: " + ", ".join("%s %d" % kv for kv in ver.most_common()))
    asc = s.get("associations", [])
    if asc:
        created = [t for t in asc if t.get("created")]
        reasons = Counter()
        depth_joins = 0
        for t in created:
            near = [x for x in t["considered"] if x.get("separation") is not None]
            near.sort(key=lambda x: x["separation"])
            reasons[near[0]["result"] if near else "no_other_cluster"] += 1
        for t in asc:
            for x in t["considered"]:
                if x["result"] == "joined" and (x.get("impliedDepth") or 0) > 0.3:
                    depth_joins += 1
        out.append("")
        out.append("## Tracking")
        out.append("- observations %d, new clusters %d, merges at the end %d" % (len(asc), len(created), len(s.get("merges", []))))
        out.append("- why new clusters started (verdict for the nearest existing cluster): " + ", ".join("%s %d" % kv for kv in reasons.most_common()))
        out.append("- joins that needed an implied depth > 0.3 m: %d (check these for wrongly merged neighbours)" % depth_joins)
    if s.get("candidates"):
        out.append("")
        out.append("## Candidates -> products")
        out.append("| cand | u | v | obs | depth | read name | product |")
        out.append("|---|---|---|---|---|---|---|")
        for cd in s["candidates"]:
            nm = cd.get("name") or {}
            out.append("| %d | %.2f | %.2f | %d | %s | %s | %s |" % (
                cd["index"], cd["u"], cd["v"], len(cd.get("observationRefs", [])),
                "-" if cd.get("depthBehindPlaneM") is None else "%.2f" % cd["depthBehindPlaneM"],
                nm.get("displayName", "-"), cd.get("productId") or "-"))
        out.append("")
        out.append("## Final products")
        for p in s.get("products", []):
            out.append("- **%s** (%s) cand %s reasons %s" % (p["name"], p.get("nameSource") or "-", p.get("candidateIndices"), p.get("reviewReasons")))
    # OCR lines by observation (raw text) for names
    ocr_rows = [o for o in s.get("observations", []) if o.get("texts")]
    if ocr_rows:
        out.append("")
        out.append("## OCR lines read (first 30 observations that had text)")
        for o in ocr_rows[:30]:
            lines = "; ".join("%s (%.2f)" % (t["text"], t["confidence"]) for t in o["texts"])
            out.append("- f%d %s: %s" % (o["frameIndex"], o["ref"][:8], lines))
    if s.get("searchFrames"):
        out.append("")
        out.append("## Search timeline")
        for e in s.get("searchEvents", []):
            out.append("- %.2fs %s %s %s" % (e["t"], e["kind"], e.get("productId") or "", e.get("detail") or ""))
        ev = {e["kind"]: e["t"] for e in s.get("searchEvents", [])}
        if "firstProduct" in ev and "locked" in ev:
            out.append("- first product seen -> locked: %.2f s" % (ev["locked"] - ev["firstProduct"]))
        if "locked" in ev and "guidance" in ev:
            out.append("- locked -> guidance started: %.2f s (includes waiting for space restore)" % (ev["guidance"] - ev["locked"]))
        if "aligned" in ev:
            out.append("- space restored at: %.2f s" % ev["aligned"])
        sf = s["searchFrames"]
        times = sorted(x["analysisSeconds"] for x in sf)
        if times:
            out.append("- analysis time per frame: median %.3f s, max %.3f s over %d frames" % (times[len(times) // 2], times[-1], len(times)))
        oc = Counter(x["outcome"].split(":")[0] for x in sf)
        out.append("- per-frame outcomes: " + ", ".join("%s %d" % kv for kv in oc.most_common()))
        wrong = Counter(x["outcome"] for x in sf if x["outcome"].startswith("matched:"))
        if wrong:
            out.append("- products matched in single frames: " + ", ".join("%s %d" % kv for kv in wrong.most_common()))
    if a.replay and os.path.exists(a.replay):
        r = json.load(open(a.replay, encoding="utf-8"))
        out.append("")
        out.append("## Replay with the current code")
        out.append("- recorded: %s" % r["recorded"])
        out.append("- replayed: %s" % r["replayed"])
        out.append("- pairs that ended as different products but are close:")
        for p in r.get("pairs", [])[:30]:
            out.append("  - #%d vs #%d: centre %.3f m, closest views %.3f m, implied depth %.2f m, appearance %s, shared frames %d -> **%s**" % (
                p["a"], p["b"], p["centreSeparationM"], p["minSeparationM"], p["impliedDepthM"],
                "-" if p.get("minAppearance") is None else "%.3f" % p["minAppearance"], p["sharedFrames"], p["stage"]))
    with open(os.path.join(a.out, "report.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    print("wrote", a.out)


if __name__ == "__main__":
    sys.exit(main())
