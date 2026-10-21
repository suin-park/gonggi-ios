"""Same-layout images for the sequential (empty-map, past-only) comparison: photo | base | full640 tau1 | win tau1 | full640 tau3 | win tau3 for views 2 (earlier), 45 (strict held-out), 47 (newest). Local only."""
import os, sys, numpy as np, cv2
sys.path.insert(0, '.')
import gtlib as g
OUT = 'out_seq'; P = g.Photos(); tags = ['base_t0', 'full640_t1', 'win_t1', 'full640_t3', 'win_t3']
rd = lambda t, v: cv2.cvtColor(cv2.imdecode(np.fromfile(os.path.join(OUT, f'render_{t}_view{v}.png'), np.uint8), 1), cv2.COLOR_BGR2RGB).astype(np.float32) / 255
def put(img, text): im = (np.clip(img, 0, 1) * 255).astype(np.uint8).copy(); cv2.putText(im, text, (3, 13), cv2.FONT_HERSHEY_SIMPLEX, 0.42, (255, 255, 0), 1); return im
def boxes(i):
    gt, m = P.gt[i], P.mask[i]; eye = g.find_eyes(gt, m); out = {}
    if eye is not None: out['eyes/nose'] = eye['box']
    hf = np.abs(g.lum(gt) - cv2.GaussianBlur(g.lum(gt), (0, 0), 3.0)); k = 96; mi = cv2.integral(m.astype(np.float32)); hi_ = cv2.integral(hf.astype(np.float32)); ed = cv2.Canny((gt * 255).astype(np.uint8), 60, 140).astype(np.float32); ei = cv2.integral(ed); best = None; bc = None
    for y in range(0, g.EH - k, 8):
        for x in range(0, g.EW - k, 8):
            cov = (mi[y + k, x + k] - mi[y, x + k] - mi[y + k, x] + mi[y, x]) / (k * k); h = (hi_[y + k, x + k] - hi_[y, x + k] - hi_[y + k, x] + hi_[y, x]) / (k * k)
            if cov > 0.97 and (best is None or h < best[0]): best = (h, x, y)
            if 0.3 < cov < 0.7:
                e = (ei[y + k, x + k] - ei[y, x + k] - ei[y + k, x] + ei[y, x]); bc = (e, x, y) if (bc is None or e > bc[0]) else bc
    if best: out['smooth surface'] = (best[1], best[2], best[1] + k, best[2] + k)
    if bc: out['contour'] = (bc[1], bc[2], bc[1] + k, bc[2] + k)
    return out
for v, lab in ((2, 'earlier view (used by every arm)'), (45, 'strict held-out (never used by the map nor by the depth)'), (47, 'newest keyframe at the end')):
    rows = []
    for nm, b in boxes(v).items():
        x0, y0, x1, y1 = b; tiles = [put(P.gt[v][y0:y1, x0:x1], f'photo {nm}')] + [put(rd(t, v)[y0:y1, x0:x1], t) for t in tags]
        rows.append(np.concatenate([cv2.resize(t, None, fx=3, fy=3, interpolation=cv2.INTER_CUBIC) for t in tiles], 1))
    w = max(r.shape[1] for r in rows); rows = [np.pad(r, ((0, 0), (0, w - r.shape[1]), (0, 0))) for r in rows]; im = np.concatenate(rows, 0); cv2.putText(im, f'view {v}: {lab}', (4, im.shape[0] - 5), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
    cv2.imencode('.png', cv2.cvtColor(im, cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, f'cmp_seq_crops_view{v}.png'))
    ys, xs = np.nonzero(P.mask[v]); x0, y0, x1, y1 = max(0, xs.min() - 15), max(0, ys.min() - 15), min(g.EW, xs.max() + 15), min(g.EH, ys.max() + 15)
    tiles = [put(P.gt[v][y0:y1, x0:x1], f'photo v{v}')] + [put(rd(t, v)[y0:y1, x0:x1], t) for t in tags]; cv2.imencode('.png', cv2.cvtColor(np.concatenate(tiles, 1), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, f'cmp_seq_product_view{v}.png'))
print('ok')
