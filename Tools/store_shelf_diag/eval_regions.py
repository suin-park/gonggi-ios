#!/usr/bin/env python3
"""Scores what the app DECIDED about every detected region against a person's labels of the same regions.

    python eval_regions.py BUNDLE.zip-or-folder LABELS.json

LABELS.json (written after looking at frames_overlay/ and the sheets from render.py):
    {"frames": {"12": {"0": "product", "1": "structure", "2": "part", "3": "product"}},
     "missedProducts": {"12": 1}}                      # real products in frame 12 that no region covers (optional)

Region labels: "product" (one whole product), "structure" (shelf, door frame, light, wall...), "part" (label / piece of a
product), "other". The table separates the detector's job (did it propose real products?) from the filter's job (did it
keep the products and drop the rest?), so a model change and a filter change are not mixed up.
"""
import json
import os
import sys
import zipfile
from collections import Counter


def load_session(path):
    if os.path.isdir(path):
        return json.load(open(os.path.join(path, "session.json"), encoding="utf-8"))
    with zipfile.ZipFile(path) as z:
        return json.loads(z.read("session.json").decode("utf-8"))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    s = load_session(sys.argv[1])
    labels = json.load(open(sys.argv[2], encoding="utf-8"))
    lab = labels.get("frames", {})
    missed = labels.get("missedProducts", {})
    kept_label = Counter()
    dropped_label = Counter()
    by_reason = Counter()
    n = 0
    for fr in s["frames"]:
        fl = lab.get(str(fr["index"]))
        if not fl:
            continue
        for r in fr["regions"]:
            truth = fl.get(str(r["index"]))
            if truth is None:
                continue
            n += 1
            kept = r["arbiter"] == "kept"
            (kept_label if kept else dropped_label)[truth] += 1
            if not kept:
                by_reason[(truth, r.get("verdict") if r["arbiter"] == "notProduct" else r["arbiter"])] += 1
    products = kept_label["product"] + dropped_label["product"]
    kept_total = sum(kept_label.values())
    print("labelled regions:", n, "in", len(lab), "frames")
    print("detector proposed real products: %d (of %d regions)" % (products, n))
    if kept_total:
        print("precision of KEPT regions (product / kept): %.2f   (%d of %d)" % (kept_label["product"] / kept_total, kept_label["product"], kept_total))
    if products:
        print("real products DROPPED by the filter: %d of %d (%.0f%%)" % (dropped_label["product"], products, 100 * dropped_label["product"] / products))
    print("structure kept: %d, parts kept: %d, other kept: %d" % (kept_label["structure"], kept_label["part"], kept_label["other"]))
    print("structure/part/other dropped: %d / %d / %d" % (dropped_label["structure"], dropped_label["part"], dropped_label["other"]))
    if by_reason:
        print("drops by (label, reason):")
        for (t, why), c in by_reason.most_common():
            print("  %-10s %-22s %d" % (t, why, c))
    if missed:
        m = sum(missed.values())
        print("real products with NO proposed region (detector misses): %d vs %d proposed" % (m, products))
    return 0


if __name__ == "__main__":
    sys.exit(main())
