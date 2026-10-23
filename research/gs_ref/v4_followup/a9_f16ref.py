"""Reference outline for ONE photo (test_10 index 16, f000017.jpg), evaluation only (never used to build shapes or tune settings).
GrabCut on the 960x720 raw photo, initialised: definite background = outside the union of all candidate outlines dilated 40 px; probable foreground = inside the union; then visually checked.
Compares auto mask / V0 / V4 / V4-all against it per region (panel = upper part, neck, base) in pixels and px of over/under width."""
import os, sys, json
import numpy as np, cv2
O = r'C:\Users\emili\Downloads\best_3d_quality_before_friday\bm_v4_followup\test10_f16'
raw = cv2.imdecode(np.fromfile(os.path.join(O, 'f16_raw.png'), np.uint8), 1)
raw = cv2.rotate(raw, cv2.ROTATE_90_COUNTERCLOCKWISE)        # back to sensor orientation (960x720)
S = {k: np.load(os.path.join(O, f'sil_{k}.npy')) for k in ('auto', 'V0', 'V4', 'V4all')}
uni = np.zeros(raw.shape[:2], bool)
for m in S.values():
    uni |= m
mask = np.full(raw.shape[:2], cv2.GC_BGD, np.uint8)
mask[cv2.dilate(uni.astype(np.uint8), np.ones((81, 81), np.uint8)) > 0] = cv2.GC_PR_BGD
mask[uni] = cv2.GC_PR_FGD
mask[cv2.erode((S['auto'] & S['V0'] & S['V4']).astype(np.uint8), np.ones((15, 15), np.uint8)) > 0] = cv2.GC_FGD
bg = np.zeros((1, 65), np.float64); fg = np.zeros((1, 65), np.float64)
cv2.grabCut(raw, mask, None, bg, fg, 8, cv2.GC_INIT_WITH_MASK)
ref = (mask == cv2.GC_FGD) | (mask == cv2.GC_PR_FGD)
ref = cv2.morphologyEx(ref.astype(np.uint8), cv2.MORPH_OPEN, np.ones((5, 5), np.uint8)) > 0
n, lab = cv2.connectedComponents(ref.astype(np.uint8))
if n > 2:
    sz = [(lab == k).sum() for k in range(1, n)]; ref = lab == (1 + int(np.argmax(sz)))
from scipy import ndimage
ref = ndimage.binary_fill_holes(ref)
np.save(os.path.join(O, 'ref_outline_f16.npy'), ref)
# regions along the product's long axis (sensor image: product lies horizontally; panel on the left = small x)
xs = np.where(ref.any(0))[0]; x0, x1 = xs.min(), xs.max(); L = x1 - x0
reg = {'panel': (x0, x0 + int(0.45 * L)), 'neck': (x0 + int(0.45 * L), x0 + int(0.6 * L)), 'base': (x0 + int(0.6 * L), x1 + 1)}
out = {}
for k, m in S.items():
    r = {}
    for nm, (a, b) in reg.items():
        R = ref[:, a:b]; Mk = m[:, a:b]
        over = int((Mk & ~R).sum()); under = int((R & ~Mk).sum()); cols = max(1, (R.any(0)).sum())
        r[nm] = dict(iou=round(float((Mk & R).sum() / max(1, (Mk | R).sum())), 3), over_px=over, under_px=under, over_width_px=round(over / cols, 1), under_width_px=round(under / cols, 1))
    r['all'] = dict(iou=round(float((m & ref).sum() / max(1, (m | ref).sum())), 3))
    out[k] = r
json.dump(dict(note='reference = GrabCut on this single raw photo, visually checked; evaluation only. Widths are per image column (sensor image, 960x720).', regions=reg and {k: [int(a), int(b)] for k, (a, b) in reg.items()}, result=out), open(os.path.join(O, 'f16_vs_reference.json'), 'w'), indent=1)
print(json.dumps(out, indent=0))
def contour(img, m, col, th=2):
    cs, _ = cv2.findContours(m.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE); cv2.drawContours(img, cs, -1, col, th); return img
ys, xs2 = np.where(cv2.dilate(uni.astype(np.uint8), np.ones((61, 61), np.uint8)) > 0); y0, y1, xa, xb = ys.min(), ys.max(), xs2.min(), xs2.max()
tiles = []
for k, col, t in (('ref', (255, 255, 255), 'reference (GrabCut, checked)'), ('auto', (0, 220, 255), 'auto mask'), ('V0', (255, 230, 0), 'V0 Bm'), ('V4', (255, 0, 255), 'V4 leave-out'), ('V4all', (0, 255, 0), 'V4 all-view')):
    im = raw.copy(); m = ref if k == 'ref' else S[k]
    if k != 'ref':
        im = contour(im, ref, (255, 255, 255), 1)
    im = contour(im, m, col, 2)
    im = cv2.rotate(im[y0:y1, xa:xb], cv2.ROTATE_90_CLOCKWISE); im = cv2.resize(im, None, fx=1.6, fy=1.6, interpolation=cv2.INTER_CUBIC)
    cv2.putText(im, t, (8, 26), 0, 0.7, (255, 255, 255), 3); cv2.putText(im, t, (8, 26), 0, 0.7, (0, 0, 0), 1); tiles.append(im)
cv2.imwrite(os.path.join(O, 'f16_vs_reference_sheet.png'), np.concatenate(tiles, 1))
