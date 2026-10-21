"""Depth refinement v2 (strict P2). Lesson from v1: depth COMPLETION by nearest-valid-depth (Bm-final's edge fix) cost ~5 dB on far held-out views (25.4 -> 20.7) -> not used here.
R0 raw prior (map depth alpha>0.5 inside the dilated mask, as the original Bm) | R1 = R0 + photo-consistency refinement of the existing depth | R2 = R1 + depth for missing pixels INSIDE the refined photo mask found by a wide plane sweep (+-20% around nearest valid depth), kept only if photo-consistent (cost < CONF); the rest stay holes."""
import numpy as np, cv2, json, time
from depth_refine import *
md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}
def raw(i):
    img, dep, Tf, st = gsref.render(MAP['mu'], MAP['logs'], MAP['quat'], MAP['col'], MAP['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf; return np.where((al > 0.5) & md[i], dep / np.maximum(al, 1e-3), 0).astype(np.float32)
zr = {i: raw(i) for i in train}; CONF = 0.08
def up640(z2):
    full = cv2.resize(z2, (EW, EH), interpolation=cv2.INTER_NEAREST); lin = cv2.resize(z2, (EW, EH), interpolation=cv2.INTER_LINEAR); mk = cv2.resize((z2 > 0).astype(np.float32), (EW, EH), interpolation=cv2.INTER_LINEAR); return np.where(full > 0, lin / np.maximum(mk, 1e-3), 0).astype(np.float32)
def refine_v2(i, pool, fill):
    nb = [s for d, s, a in ranked(P.cam(i), [s for s in pool if s != i])[:6] if a < 45]; z0 = cv2.resize(zr[i], (W2, H2), interpolation=cv2.INTER_NEAREST); have = z0 > 0
    z1, _, _ = sweep(i, z0, nb, 0.12, 25, CONF); z2, _, _ = sweep(i, z1, nb, 0.03, 13, CONF); z2 = np.where(have, cv2.medianBlur(z2, 3), 0).astype(np.float32); out = z2.copy(); nfill = 0
    if fill:
        m320 = cv2.resize(mref[i].astype(np.uint8), (W2, H2), interpolation=cv2.INTER_NEAREST) > 0; miss = m320 & ~have
        if miss.any() and have.any():
            d, (iy, ix) = ndimage.distance_transform_edt(~have, return_indices=True); zi = np.where(miss & (d <= 25), z2[iy, ix], 0).astype(np.float32); zf, _, c0 = sweep(i, zi, nb, 0.20, 41, CONF)
            good = (zi > 0) & (c0 < CONF * 0.75); out = np.where(good, zf, out); nfill = int(good.sum())
    return up640(out), nfill
t0 = time.time(); z1 = {}; z2 = {}; nf = []
for n, i in enumerate(train):
    z1[i], _ = refine_v2(i, train, False); z2[i], k = refine_v2(i, train, True); nf.append(k)
    if n % 20 == 0: print('refine', n, len(train), f'{time.time() - t0:.0f}s', flush=True)
print('refine seconds', int(time.time() - t0), 'mean filled px/frame (320x240)', np.mean(nf), flush=True)
np.savez_compressed('out_best/depth_R1_P2.npz', **{str(k): v for k, v in z1.items()}); np.savez_compressed('out_best/depth_R2_P2.npz', **{str(k): v for k, v in z2.items()})
lum = lambda x: 0.299 * x[..., 0] + 0.587 * x[..., 1] + 0.114 * x[..., 2]
def ghost(ct, parts, keeps):
    fl = np.stack([lum(p[2]) for p in parts]); fm = np.stack(keeps); cnt = fm.sum(0); mean = (fl * fm).sum(0) / np.maximum(cnt, 1); sd = np.sqrt((((fl - mean) ** 2) * fm).sum(0) / np.maximum(cnt, 1)); ok = cnt >= 2; o = {}
    for name, anc in ANCH.items():
        pt = (anc - ct['C']) @ ct['Rcw'].T; u = int((ct['fx'] * pt[0] / pt[2] + ct['cx']) * SS); v = int((ct['fy'] * pt[1] / pt[2] + ct['cy']) * SS); sl = (slice(max(0, v - 60), v + 60), slice(max(0, u - 80), u + 80)); oo = ok[sl]; o[name] = float(sd[sl][oo].mean()) if oo.sum() > 200 else float('nan')
    return o
R = {}
for nm, zd in (('R0_raw', zr), ('R1_refined', z1), ('R2_refined_filled', z2)):
    out = dict(hard=[], smooth=[], interior=[], holes=[], ghost=[], contour=[])
    for f in held:
        ct = P.cam(f); gt = P.gt[f]; m = P.mask[f]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; ps = lambda im, mm: float(-10 * np.log10(max(((im - gt) ** 2)[mm].mean(), 1e-12)))
        ih, fh = hard(ct, train, lambda s: zd[s]); isml, al, parts, keeps = blend(ct, train, lambda s: zd[s], want_parts=True)
        out['hard'].append(ps(ih, m)); out['smooth'].append(ps(isml, m)); out['interior'].append(ps(isml, me)); out['holes'].append(float(1 - (al[me] > 0.95).mean())); out['ghost'].append(ghost(ct, parts, keeps))
        if f in (40, 60, 80): g.imwrite(f'out_best/dr2_P2_f{f}_{nm}.png', isml)
    R[nm] = dict(psnr_hard=float(np.mean(out['hard'])), psnr_smooth=float(np.mean(out['smooth'])), interior_smooth=float(np.mean(out['interior'])), holes=float(np.mean(out['holes'])), ghost={a: float(np.nanmean([x[a] for x in out['ghost']])) for a in ANCH}); print(nm, json.dumps(R[nm]), flush=True)
img3 = [float(-10 * np.log10(((g.render(MAP, P.cam(f))[0] - P.gt[f]) ** 2)[P.mask[f]].mean())) for f in held]; R['3dgs'] = float(np.mean(img3)); print('3dgs', R['3dgs'])
json.dump(R, open('out_best/dr2_P2.json', 'w'), indent=1)
