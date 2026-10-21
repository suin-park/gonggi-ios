"""Hybrid 3DGS + photo-detail validation, STRICT held-out P2 (map, depth, source photos exclude the five held 7-frame blocks 17-23, 37-43, 57-63, 77-83, 97-103). PC research, photos local.
G  : 3DGS render (out_ub/map_gsmax_P2.npz, built from the training frames only)
B  : Bm-smooth with the map's raw depth (alpha>0.5 inside the dilated mask) = the original Bm geometry, continuous 5-photo blend
agreement a(x) : per-pixel luminance spread among the photos that pass the occlusion rule (low = photos agree = trustworthy); gate g = exp(-(a/TAU)^2), forced to 0 where B has no coverage. TAU=0.04, SIGMA=2 px: fixed a priori, not tuned.
H1 : g*B + (1-g)*G                       (premultiplied over black)
H2 : LF(G) + g*HF(B) + (1-g)*HF(G)       (3DGS keeps colour/shape; photo detail is added only where photos agree; LF = gaussian blur SIGMA)
Metrics on the held-out frames: product-mask PSNR, interior PSNR (mask eroded 9 px), edge-band PSNR (photo gradient > 0.25), Laplacian energy / photo (sharpness; 1.0 = like the photo), eye/nose contrast recovery, silhouette IoU."""
import json, time
import numpy as np, cv2
from bmcore import *
import gsref
BLOCKS = [(17, 23), (37, 43), (57, 63), (77, 83), (97, 103)]; HELD = set(i for a, b in BLOCKS for i in range(a, b + 1)); TAU = 0.04; SIGMA = 2.0
views = [i for i in range(P.n) if P.mask[i].sum() > 50]; train = [i for i in views if i not in HELD]; held = [i for i in views if i in HELD]
z_ = np.load('out_ub/map_gsmax_P2.npz'); MAP = {k: z_[k] for k in z_.files}; md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}
zc = {}
def zraw(i):
    if i not in zc:
        img, dep, Tf, st = gsref.render(MAP['mu'], MAP['logs'], MAP['quat'], MAP['col'], MAP['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf; zc[i] = np.where((al > 0.5) & md[i], dep / np.maximum(al, 1e-3), 0).astype(np.float32)
    return zc[i]
lum = lambda x: 0.299 * x[..., 0] + 0.587 * x[..., 1] + 0.114 * x[..., 2]
def agreement(parts, keeps):
    fl = np.stack([lum(p[2]) for p in parts]); fm = np.stack(keeps); cnt = fm.sum(0); mean = (fl * fm).sum(0) / np.maximum(cnt, 1); sd = np.sqrt((((fl - mean) ** 2) * fm).sum(0) / np.maximum(cnt, 1)); sd = np.where(cnt >= 2, sd, 0.0)       # single-photo pixels: no disagreement observable -> treated as consistent
    return sd.reshape(EH, SS, EW, SS).mean((1, 3))
blur = lambda x: cv2.GaussianBlur(x, (0, 0), SIGMA)
def metrics(im, gt, m, me, eye, em, G_al=None):
    ps = lambda mm: float(-10 * np.log10(max(((im - gt) ** 2)[mm].mean(), 1e-12))); lap = lambda x, mm: float(np.abs(cv2.Laplacian(cv2.cvtColor(u8(x), cv2.COLOR_RGB2GRAY), cv2.CV_32F))[mm].mean())
    o = dict(psnr=ps(m), interior=ps(me), edge=ps(em), sharp=lap(im, me) / max(lap(gt, me), 1e-9))
    if eye is not None: o['recovery'] = g.metrics(im, np.ones((EH, EW), np.float32), gt, m, eye).get('recovery', float('nan'))
    return o
rows = []; t0 = time.time()
for f in held:
    ct = P.cam(f); gt = P.gt[f]; m = P.mask[f]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; eye = g.find_eyes(gt, m)
    gray = cv2.cvtColor(u8(gt), cv2.COLOR_RGB2GRAY); em = (np.hypot(cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3), cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)) / 255 > 0.25) & (cv2.dilate(m.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0)
    Gi, Ga, _ = g.render(MAP, ct); Bi, Ba, parts, keeps = blend(ct, train, zraw, p0=3.0, p1=10.0, want_parts=True); a = agreement(parts, keeps); gate = np.exp(-(a / TAU) ** 2) * (Ba > 0.5)
    H1 = gate[..., None] * Bi + (1 - gate[..., None]) * Gi; H2 = blur(Gi) + gate[..., None] * (Bi - blur(Bi)) + (1 - gate[..., None]) * (Gi - blur(Gi))
    B0, B0a = blend(ct, train, zraw, p0=3.0); H3 = B0 + (1 - B0a[..., None]) * Gi
    row = dict(frame=f, gate_mean=float(gate[m].mean()))
    for nm, im in (('G', Gi), ('B', Bi), ('B0', B0), ('H1', H1), ('H2', H2), ('H3', H3)): row[nm] = metrics(np.clip(im, 0, 1), gt, m, me, eye, em)
    rows.append(row)
    if f in (22, 40, 60, 80, 99): g.imwrite(f'out_best/hyb2_f{f}.png', np.concatenate([gt, Gi, B0, np.clip(H3, 0, 1), np.clip(H1, 0, 1), np.clip(H2, 0, 1)], 1))
    print(f, {k: round(row[k]['psnr'], 1) for k in ('G', 'B0', 'H3')}, 'gate %.2f' % row['gate_mean'], flush=True)
summ = {nm: {k: float(np.nanmean([r[nm][k] for r in rows if k in r[nm]])) for k in rows[0][nm]} for nm in ('G', 'B', 'B0', 'H1', 'H2', 'H3')}; summ['gate_mean'] = float(np.mean([r['gate_mean'] for r in rows]))
print(json.dumps(summ, indent=1)); json.dump(dict(summary=summ, frames=rows, tau=TAU, sigma=SIGMA, seconds=time.time() - t0), open('out_best/hyb_P2_v2.json', 'w'), indent=1)
