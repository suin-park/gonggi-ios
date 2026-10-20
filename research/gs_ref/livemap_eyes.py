"""Real-engine evidence from the LIVE capture of test_09 (device build 3.0(28), the saved .kmogs = the on-device Gaussian map, 6,890 Gaussians, bornKF/state per Gaussian).
Rendered here with the PC reference rasteriser (display rules); the PC raster matched the Swift render of 37 Gaussians (49.6 dB on lit pixels) but that is not a proof for the whole map.
Question: where do the eyes/nose (visible from the very first frames idx 0-14 and again from idx 37) first fail to be represented in the real map, and which keyframes' Gaussians cover them?
NOTE: the live app trains on every processed keyframe (no held-out views), so no view here is 'unused for optimisation'."""
import os, sys, json
os.environ['DATA'] = '09'; os.environ['REF'] = '41'; os.environ['NB'] = '42'
import numpy as np, cv2
import colorexplain as ce
from colorexplain import ctx, EW, EH, region, lum, imwrite
import gsref, pc_abc
KM = r'C:/Users/emili/Downloads/테스트_09/product-gs-20261021-074241-product-gs.kmogs'
OUT = os.environ.get('OUTDIR', 'out_livemap'); os.makedirs(OUT, exist_ok=True)
import struct
B = open(KM, 'rb').read(); i_ = B.rindex(b'gaussians.bin'); o_, l_ = struct.unpack('<QQ', B[i_ + 13:i_ + 29]); b = B[o_:o_ + l_]; n = int(np.frombuffer(b, np.uint32, 1, 8)[0]); f = np.frombuffer(b, np.float32, n * 14, 12).reshape(n, 14); off = 12 + n * 56
def arr(dt, cnt):
    global off; a = np.frombuffer(b, dt, cnt, off); off += a.nbytes; return a
ids = arr(np.uint32, n); born = arr(np.int32, n); last = arr(np.int32, n); rev = arr(np.uint32, n); parent = arr(np.uint32, n); nobs = arr(np.uint16, n); state = arr(np.uint8, n); flags = arr(np.uint8, n); indep = arr(np.uint8, n)
mu, logs, quat, col, opa = f[:, 0:3].copy(), f[:, 3:6].copy(), f[:, 6:10].copy(), f[:, 10:13].copy(), f[:, 13].copy()
print('Gaussians', n, '| bornKF (replay frame id) min/max', born.min(), born.max(), '| states', np.bincount(state), '| split children (parent!=self?)', int((parent != ids).sum()))
class G:
    def __init__(s, m): s.m = m; s.n = int(m.sum())
    def view(s): m = s.m; return mu[m], logs[m], quat[m], col[m], opa[m]
def render(m, v):
    cam = ctx.cam_scaled(v, EW, EH); img, dep, Tf, st = gsref.render(mu[m], logs[m], quat[m], col[m], opa[m], cam, **pc_abc.DISPLAY); return img, 1 - Tf
# bornKF is the replay frame ID (1-based): idx = id - 1
bidx = born - 1
rows = {}; views = list(range(2, 15)) + [37, 39, 41, 42, 45, 47]
allm = np.ones(n, bool)
groups = {'born idx<=3 (first 2 valid keyframes)': bidx <= 3, 'born idx 4..14': (bidx >= 4) & (bidx <= 14), 'born idx 15..36': (bidx >= 15) & (bidx <= 36), 'born idx>=37': bidx >= 37}
print({k: int(v.sum()) for k, v in groups.items()})
for v in views:
    rg = region(v); gt = ctx.hi_eval[v]; img, al = render(allm, v); m = rg['mask']
    mt = dict(product_psnr=float(-10 * np.log10(max(((img - gt) ** 2)[m].mean(), 1e-12))), product_alpha=float(al[m].mean()), eyes_visible=rg['n'] == 3)
    if rg['n'] == 3:
        gl, il = lum(gt), lum(img); bl, ring = rg['blob'], rg['ring']
        mt.update(eye_contrast_gt=float(gl[ring].mean() - gl[bl].mean()), eye_contrast_render=float(il[ring].mean() - il[bl].mean())); mt['eye_contrast_recovery'] = mt['eye_contrast_render'] / max(mt['eye_contrast_gt'], 1e-6)
        mt['eye_psnr'] = float(-10 * np.log10(max(((img - gt) ** 2)[cv2.dilate(bl.astype(np.uint8), np.ones((9, 9), np.uint8)).astype(bool) & m].mean(), 1e-12)))
        # which Gaussians cover the eyes: share of crop alpha carried by each born-group (rendered alone)
        sh = {}
        for k, gm in groups.items():
            if gm.sum() == 0: continue
            im2, a2 = render(gm, v); sh[k] = float(a2[rg['face']].mean())
        mt['face_alpha_by_group'] = sh; mt['face_alpha_all'] = float(al[rg['face']].mean())
        ys, xs = np.nonzero(rg['face']); y0, y1, x0, x1 = max(0, ys.min() - 20), min(EH, ys.max() + 20), max(0, xs.min() - 20), min(EW, xs.max() + 20)
        tiles = [gt[y0:y1, x0:x1], img[y0:y1, x0:x1]] + [render(gm, v)[0][y0:y1, x0:x1] for gm in groups.values()]
        imwrite(os.path.join(OUT, f'face_view{v}.png'), np.concatenate([cv2.resize((t * 255).astype(np.uint8), None, fx=3, fy=3, interpolation=cv2.INTER_NEAREST) for t in tiles], 1).astype(np.float32) / 255)
    rows[v] = mt
    print(v, {k: (round(x, 3) if isinstance(x, float) else x) for k, x in mt.items() if k != 'face_alpha_by_group'}, {k[:14]: round(x, 3) for k, x in mt.get('face_alpha_by_group', {}).items()})
json.dump(dict(views=views, rows=rows, groups={k: int(v.sum()) for k, v in groups.items()}), open(os.path.join(OUT, 'livemap_eyes.json'), 'w'), indent=1, default=float)
