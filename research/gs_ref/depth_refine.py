"""Photo-consistency depth refinement for Bm (PC research; photos local only).
For every SOURCE photo i the prior depth (rendered from a 3DGS map) is refined by a plane sweep against its nearest neighbour photos (poses fixed = ARKit as recorded): candidate depths z0*(1+delta), cost = patch colour difference after re-projection into each neighbour (5x5 box aggregation, mean of the 3 best neighbours = robust to occlusion), + small prior term; round 1 +-12% (25 steps), round 2 +-3% (13 steps), sub-step parabola. Pixels whose best cost is above CONF keep the prior depth. 3x3 median. 320x240.
Protocol P2 (strict held-out): map (depth prior), source photos and neighbours exclude the five held 7-frame blocks. Evaluation cameras are the recorded poses of the held frames; they are never moved.
usage: python depth_refine.py"""
import os, sys, json, time
import numpy as np, cv2
from scipy import ndimage
from bmcore import *
import gsref
BLOCKS = [(17, 23), (37, 43), (57, 63), (77, 83), (97, 103)]; HELD = set(i for a, b in BLOCKS for i in range(a, b + 1)); W2, H2 = 320, 240
views = [i for i in range(P.n) if P.mask[i].sum() > 50]; train = [i for i in views if i not in HELD]; held = [i for i in views if i in HELD]
z_ = np.load('out_ub/map_gsmax_P2.npz'); MAP = {k: z_[k] for k in z_.files}
mref = {i: refine_mask(i) for i in views}; mer = {i: cv2.erode(mref[i].astype(np.uint8), np.ones((3, 3), np.uint8)) > 0 for i in views}
img320 = {i: cv2.resize(P.gt[i], (W2, H2), interpolation=cv2.INTER_AREA) for i in views}
def prior640(i):
    img, dep, Tf, st = gsref.render(MAP['mu'], MAP['logs'], MAP['quat'], MAP['col'], MAP['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf; z = np.where((al > 0.5) & mref[i], dep / np.maximum(al, 1e-3), 0)
    inv = z <= 0; d, (iy, ix) = ndimage.distance_transform_edt(inv, return_indices=True); zf = z[iy, ix]; return np.where(mer[i] & (d <= 25) & (zf > 0), zf, 0).astype(np.float32)       # = Bm-final's completed depth
zprior = {i: prior640(i) for i in train}
def to320(z): return cv2.resize(z, (W2, H2), interpolation=cv2.INTER_NEAREST)
def sweep(i, z0, nbrs, rng, steps, conf):
    ci = P.cam(i, W2, H2); u, v = np.meshgrid(np.arange(W2, dtype=np.float32), np.arange(H2, dtype=np.float32)); m = z0 > 0; dirs = np.stack([(u - ci['cx']) / ci['fx'], (v - ci['cy']) / ci['fy'], np.ones_like(u)], -1); base = img320[i]
    ds = np.linspace(-rng, rng, steps); cost = np.zeros((steps, H2, W2), np.float32)
    for k, dl in enumerate(ds):
        z = z0 * (1 + dl); Xw = (dirs * z[..., None]).reshape(-1, 3) @ ci['Rcw'] + ci['C']; cs = []
        for j in nbrs:
            cj = P.cam(j, W2, H2); pt = (Xw - cj['C']) @ cj['Rcw'].T; pz = np.maximum(pt[:, 2], 1e-3); mx = (cj['fx'] * pt[:, 0] / pz + cj['cx']).reshape(H2, W2).astype(np.float32); my = (cj['fy'] * pt[:, 1] / pz + cj['cy']).reshape(H2, W2).astype(np.float32)
            wj = cv2.remap(img320[j], mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=(9, 9, 9)); c = np.abs(wj - base).mean(-1); c[(wj[..., 0] > 5)] = 0.6; cs.append(cv2.boxFilter(c, -1, (5, 5)))
        cs = np.sort(np.stack(cs), 0)[:min(3, len(nbrs))].mean(0); cost[k] = cs + 1.0 * dl * dl
    k0 = cost.argmin(0); kk = np.clip(k0, 1, steps - 2); c0 = np.take_along_axis(cost, k0[None], 0)[0]; cm1 = np.take_along_axis(cost, (kk - 1)[None], 0)[0]; cp1 = np.take_along_axis(cost, (kk + 1)[None], 0)[0]; cc = np.take_along_axis(cost, kk[None], 0)[0]
    den = cm1 - 2 * cc + cp1; off = np.where(den > 1e-9, 0.5 * (cm1 - cp1) / np.maximum(den, 1e-9), 0); off = np.clip(off, -1, 1) * ((k0 > 0) & (k0 < steps - 1)); dl = ds[k0] + off * (ds[1] - ds[0])
    ok = m & (c0 < conf); out = np.where(ok, z0 * (1 + dl), z0); return out.astype(np.float32), float(ok[m].mean()) if m.any() else 0.0, c0
def refine(i, pool, conf=0.08):
    z0 = to320(zprior[i]); cs = ranked(P.cam(i), [s for s in pool if s != i]); nbrs = [s for d, s, a in cs[:6] if a < 45]
    z1, f1, c1 = sweep(i, z0, nbrs, 0.12, 25, conf); z2, f2, c2 = sweep(i, z1, nbrs, 0.03, 13, conf); z2 = np.where(z0 > 0, cv2.medianBlur(z2, 3), 0).astype(np.float32); z2 = np.where(z0 > 0, z2, 0)
    full = cv2.resize(z2, (EW, EH), interpolation=cv2.INTER_NEAREST); lin = cv2.resize(z2, (EW, EH), interpolation=cv2.INTER_LINEAR); mk = cv2.resize((z2 > 0).astype(np.float32), (EW, EH), interpolation=cv2.INTER_LINEAR)
    z640 = np.where(full > 0, lin / np.maximum(mk, 1e-3), 0).astype(np.float32); z640 = np.where(zprior[i] > 0, z640, 0); return z640, dict(refined_fraction=f2, rel_change=float(np.median(np.abs(z640[zprior[i] > 0] / zprior[i][zprior[i] > 0] - 1))))
if __name__ == '__main__':
    t0 = time.time(); zref = {}; info = {}
    for n, i in enumerate(train):
        zref[i], info[i] = refine(i, train)
        if n % 10 == 0: print('refine', n, len(train), info[i], f'{time.time() - t0:.0f}s', flush=True)
    t_ref = time.time() - t0; print('refinement seconds', int(t_ref), 'mean refined fraction %.3f median |dz/z| %.4f' % (np.mean([v['refined_fraction'] for v in info.values()]), np.mean([v['rel_change'] for v in info.values()])), flush=True)
    np.savez_compressed('out_best/depth_refined_P2.npz', **{str(k): v for k, v in zref.items()})
    lum = lambda x: 0.299 * x[..., 0] + 0.587 * x[..., 1] + 0.114 * x[..., 2]
    zf = {'prior': lambda s: zprior[s], 'refined': lambda s: zref[s]}; rows = []
    def ghost(ct, parts, keeps):
        fl = np.stack([lum(p[2]) for p in parts]); fm = np.stack(keeps); cnt = fm.sum(0); mean = (fl * fm).sum(0) / np.maximum(cnt, 1); sd = np.sqrt((((fl - mean) ** 2) * fm).sum(0) / np.maximum(cnt, 1)); ok = cnt >= 2; o = {}
        for name, anc in ANCH.items():
            pt = (anc - ct['C']) @ ct['Rcw'].T; u = int((ct['fx'] * pt[0] / pt[2] + ct['cx']) * SS); v = int((ct['fy'] * pt[1] / pt[2] + ct['cy']) * SS); sl = (slice(max(0, v - 60), v + 60), slice(max(0, u - 80), u + 80)); oo = ok[sl]
            o[name] = float(sd[sl][oo].mean()) if oo.sum() > 200 else float('nan')
        return o
    for f in held:
        ct = P.cam(f); gt = P.gt[f]; m = P.mask[f]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; ps = lambda im, mm: float(-10 * np.log10(max(((im - gt) ** 2)[mm].mean(), 1e-12))); row = dict(frame=f)
        img3, al3, _ = g.render(MAP, ct); row['3dgs'] = dict(psnr=ps(img3, m), interior=ps(img3, me))
        for nm, zfn in zf.items():
            ih, fh = hard(ct, train, zfn); row['hard_' + nm] = dict(psnr=ps(ih, m), interior=ps(ih, me))
            isml, al, parts, keeps = blend(ct, train, zfn, want_parts=True); row['smooth_' + nm] = dict(psnr=ps(isml, m), interior=ps(isml, me), holes=float(1 - (al[me] > 0.95).mean()), ghost=ghost(ct, parts, keeps))
            if f in (40, 60, 80): g.imwrite(f'out_best/refine_P2_f{f}_smooth_{nm}.png', isml)
        rows.append(row); print(f, {k: round(v['psnr'], 1) for k, v in row.items() if isinstance(v, dict) and 'psnr' in v}, flush=True)
    def mean(k, f='psnr'): return float(np.nanmean([r[k][f] for r in rows]))
    summ = {k: dict(psnr=mean(k), interior=mean(k, 'interior')) for k in rows[0] if k != 'frame'}
    for nm in zf: summ['smooth_' + nm]['ghost'] = {a: float(np.nanmean([r['smooth_' + nm]['ghost'][a] for r in rows])) for a in ANCH}; summ['smooth_' + nm]['holes'] = mean('smooth_' + nm, 'holes')
    print(json.dumps(summ, indent=1)); json.dump(dict(summary=summ, frames=rows, refine_seconds=t_ref, info={str(k): v for k, v in info.items()}), open('out_best/depth_refine_P2.json', 'w'), indent=1)
