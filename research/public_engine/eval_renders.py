"""Same metric code for every engine: held-out (6) and rotation-path (40) renders vs exact GT. Regions from the object-id map / GT depth discontinuities (as in gs_ref/expB.py).
Usage: python eval_renders.py DATASET_DIR OUT_JSON LABEL=RENDER_DIR [LABEL=RENDER_DIR ...]   (also writes montage PNG + rotation MP4 next to OUT_JSON)"""
import os, sys, json, glob
import numpy as np, cv2
from skimage.metrics import structural_similarity

ds, out_json = sys.argv[1], sys.argv[2]; engines = [a.split('=', 1) for a in sys.argv[3:]]
EW, EH = 640, 480
def load(p): return cv2.cvtColor(cv2.imread(p), cv2.COLOR_BGR2RGB).astype(np.float32) / 255
def psnr(a, b, m): return float(-10 * np.log10(max(((a - b) ** 2)[m].mean(), 1e-12))) if m.sum() > 20 else float('nan')
def metrics(img, name):
    gt = load(os.path.join(ds, 'images', name)); ids = np.load(os.path.join(ds, name.replace('.png', '_ids.npy'))); z = np.load(os.path.join(ds, name.replace('.png', '_depth.npy')))
    jump = np.zeros(z.shape, bool)
    for sh in ((0, 2), (2, 0), (0, -2), (-2, 0)): jump |= (np.abs(np.roll(z, sh, (0, 1)) - z) > 0.12)
    jump = cv2.dilate(jump.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0
    rod = cv2.dilate((ids == 3).astype(np.uint8), np.ones((5, 5), np.uint8)) > 0
    gx = np.abs(cv2.Sobel(cv2.cvtColor((gt * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY), cv2.CV_32F, 1, 0, ksize=3)) / 255; edge = gx > 0.25
    full = np.ones(ids.shape, bool)
    return dict(psnr=psnr(img, gt, full), ssim=float(structural_similarity(img, gt, channel_axis=2, data_range=1.0, win_size=7)), plate=psnr(img, gt, ids == 1), text_edges=psnr(img, gt, (ids == 1) & edge),
                slope=psnr(img, gt, ids == 2), rod=psnr(img, gt, rod), sphere=psnr(img, gt, ids == 4), occl_boundary=psnr(img, gt, jump))
res = {}
for label, d in engines:
    res[label] = {}
    for kind, pat in (('held', 't_h*.png'), ('path', 't_p*.png')):
        names = sorted(os.path.basename(p) for p in glob.glob(os.path.join(ds, 'images', pat)))
        rows = [metrics(load(os.path.join(d, n)), n) for n in names if os.path.exists(os.path.join(d, n))]
        res[label][kind] = {k: float(np.nanmean([r[k] for r in rows])) for k in rows[0]} | {'views': len(rows)} if rows else None
json.dump(res, open(out_json, 'w'), indent=1)
for label in res:
    for kind in ('held', 'path'):
        v = res[label][kind]
        if v: print(f'{label:34s} {kind:5s} views {v["views"]:2d} psnr {v["psnr"]:.2f} ssim {v["ssim"]:.3f} plate {v["plate"]:.2f} textedge {v["text_edges"]:.2f} slope {v["slope"]:.2f} rod {v["rod"]:.2f} sphere {v["sphere"]:.2f} occl {v["occl_boundary"]:.2f}')
# montage: GT | engines on the first held view, then a 3x zoom of the plate print; rotation video GT | engines over the path
base = os.path.splitext(out_json)[0]; nm = sorted(os.path.basename(p) for p in glob.glob(os.path.join(ds, 'images', 't_h*.png')))[0]
gt = load(os.path.join(ds, 'images', nm)); tiles = [gt] + [load(os.path.join(d, nm)) for _, d in engines if os.path.exists(os.path.join(d, nm))]
lab = ['GT'] + [l for l, d in engines if os.path.exists(os.path.join(d, nm))]
def cap(im, t): im = (np.clip(im, 0, 1) * 255).astype(np.uint8).copy(); cv2.putText(im, t, (6, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 3, cv2.LINE_AA); cv2.putText(im, t, (6, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 0), 1, cv2.LINE_AA); return im
row1 = np.concatenate([cap(t, l) for t, l in zip(tiles, lab)], 1)
ids = np.load(os.path.join(ds, nm.replace('.png', '_ids.npy'))); ys, xs = np.nonzero(ids == 1); y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
crop = lambda t: cv2.resize((np.clip(t[y0:y1, x0:x1], 0, 1) * 255).astype(np.uint8), None, fx=3, fy=3, interpolation=cv2.INTER_NEAREST)
row2 = np.concatenate([crop(t) for t in tiles], 1); w = row1.shape[1]; row2 = cv2.resize(row2, (w, int(row2.shape[0] * w / row2.shape[1])), interpolation=cv2.INTER_AREA)
cv2.imwrite(base + '_montage.png', cv2.cvtColor(np.concatenate([row1, row2], 0), cv2.COLOR_RGB2BGR))
names = sorted(os.path.basename(p) for p in glob.glob(os.path.join(ds, 'images', 't_p*.png'))); vw = None
for n in names:
    fr = [load(os.path.join(ds, 'images', n))] + [load(os.path.join(d, n)) for _, d in engines if os.path.exists(os.path.join(d, n))]
    if len(fr) < 2: continue
    img = cv2.cvtColor(np.concatenate([cap(t, l) for t, l in zip(fr, ['GT'] + [l for l, d in engines if os.path.exists(os.path.join(d, n))])], 1), cv2.COLOR_RGB2BGR)
    if vw is None: vw = cv2.VideoWriter(base + '_rotation.mp4', cv2.VideoWriter_fourcc(*'mp4v'), 8, (img.shape[1], img.shape[0]))
    vw.write(img)
if vw: vw.release()
