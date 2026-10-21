"""Bm edge study (PC research, photos local): soft alpha matte + foreground colour decontamination + higher internal resolution, geometry (depth) unchanged.
Strict P1 on the JOINT arm of posejoint.py (map out_pj/map_joint.npz + refined poses of the 98 training frames; the 12 held-out frames i%10==5 are used by nothing; held-out cameras = test-time aligned against the map, camera only).
Configs (Bm = continuous 5-photo blend, same weights / occlusion rule / depth as bmcore.blend):
  old        : bmcore.blend (binary coverage, SS=2)
  A_ss2      : alpha matte carried through the warp (guided-filter matte of the 960x720 photo), fg colour decontamination, SS=2
  A_ss3      : same, SS=3
  A_ss3_ext3 : + depth extended by <=3 px (nearest valid depth) only for matte-band pixels that have no map depth (silhouette completeness; NOT the 25 px completion that hurt far views)
Metric on held-out: edge-band PSNR against GT*matte_GT (premultiplied over black; band = matte in (0.02,0.98) dilated 3 px), alpha MAE in the band, interior PSNR (mask eroded 9 px), full mask PSNR.
usage: python bm_edge.py [video]"""
import os, sys, json, time
import numpy as np, cv2
from scipy import ndimage
from bmcore import P, ranked, ANCH, EW, EH, u8, blend, xx, yy
import bmcore, gsref, gtlib as g
views = [i for i in range(P.n) if P.mask[i].sum() > 50]; held = [i for i in views if i % 10 == 5]; train = [i for i in views if i % 10 != 5]; cam0 = P.cam
md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
def set_poses(d):
    def cam(i, w=EW, h=EH):
        c = dict(cam0(i, w, h))
        if i in d: p = d[i]; c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]
        return c
    P.cam = cam
_mat, _fg = {}, {}
def matte(i, r=4, eps=1e-4):
    if i not in _mat:
        hi = P.hi[i]; H, W = hi.shape[:2]; m = cv2.resize((P.fr[i]['mask'] == 1).astype(np.float32), (W, H), interpolation=cv2.INTER_LINEAR); guide = cv2.cvtColor(hi, cv2.COLOR_RGB2GRAY).astype(np.float32) / 255
        bx = lambda x: cv2.boxFilter(x, -1, (2 * r + 1, 2 * r + 1)); mi, mp = bx(guide), bx(m); cov = bx(guide * m) - mi * mp; var = bx(guide * guide) - mi * mi; a = cov / (var + eps); b = mp - a * mi; q = np.clip(bx(a) * guide + bx(b), 0, 1)
        hd = (m > 0.5).astype(np.uint8); hd = ndimage.binary_fill_holes(hd).astype(np.uint8); k = np.ones((7, 7), np.uint8); t = np.clip((q - 0.3) / 0.4, 0, 1); q = t * t * (3 - 2 * t); q[cv2.erode(hd, k) > 0] = 1; q[cv2.dilate(hd, k) == 0] = 0; _mat[i] = cv2.resize(q, (EW, EH), interpolation=cv2.INTER_AREA).astype(np.float32)
    return _mat[i]
def fgcolor(i):
    if i not in _fg:
        a = matte(i); inner = cv2.erode((a > 0.98).astype(np.uint8), np.ones((3, 3), np.uint8)) > 0; d, (iy, ix) = ndimage.distance_transform_edt(~inner, return_indices=True); _fg[i] = np.where((a < 0.98)[..., None], P.gt[i][iy, ix], P.gt[i]).astype(np.float32)
    return _fg[i]
def warp_a(s, ct, z, SSn, ext):
    cs = P.cam(s); a = matte(s); zz = z.copy()
    if ext > 0:
        have = zz > 0; d, (iy, ix) = ndimage.distance_transform_edt(~have, return_indices=True); zz = np.where((~have) & (a > 0.02) & (d <= ext), zz[iy, ix], zz)
    m = (zz > 0) & (a > 0.02); zv = zz[m]; x = (xx[m] - cs['cx']) / cs['fx'] * zv; y = (yy[m] - cs['cy']) / cs['fy'] * zv; Xw = np.stack([x, y, zv], 1) @ cs['Rcw'] + cs['C']; pt = (Xw - ct['C']) @ ct['Rcw'].T; ok = pt[:, 2] > 0.1; pt = pt[ok]
    col = fgcolor(s)[m][ok]; al = a[m][ok]; zs = zv[ok]; HW, HH = EW * SSn, EH * SSn
    u = (ct['fx'] * pt[:, 0] / pt[:, 2] + ct['cx'] + 0.5) * SSn - 0.5; w = (ct['fy'] * pt[:, 1] / pt[:, 2] + ct['cy'] + 0.5) * SSn - 0.5; rho = (ct['fx'] / pt[:, 2]) / (cs['fx'] / zs); fp = np.clip(np.ceil(rho * SSn), 2, 7).astype(int)
    o = np.argsort(-pt[:, 2]); u, w, col, al, fp, zt = u[o], w[o], col[o], al[o], fp[o], pt[o, 2]; img = np.zeros((HH, HW, 3), np.float32); alp = np.zeros((HH, HW), np.float32); zb = np.full((HH, HW), np.inf, np.float32)
    for f in range(2, 8):
        sel = fp == f
        if not sel.any(): continue
        for du in range(f):
            for dw in range(f):
                ui = np.floor(u[sel] - (f - 1) / 2).astype(int) + du; wi = np.floor(w[sel] - (f - 1) / 2).astype(int) + dw; k = (ui >= 0) & (ui < HW) & (wi >= 0) & (wi < HH); ui, wi, cc, aa, zv2 = ui[k], wi[k], col[sel][k], al[sel][k], zt[sel][k]
                win = zv2 < zb[wi, ui]; img[wi[win], ui[win]] = cc[win]; alp[wi[win], ui[win]] = aa[win]; zb[wi[win], ui[win]] = zv2[win]
    return img, alp, zb
def blend_a(ct, srcs, zfun, SSn=2, ext=0, K=5, power=3.0, crisp=None, close=0, prim_edge=False):
    r = ranked(ct, srcs); K = min(K, len(r) - 1); dK = r[K][0]; parts = []
    for d, s, a in r[:K]: im, alp, zb = warp_a(s, ct, zfun(s), SSn, ext); parts.append((max(0.0, 1 - d / dK) ** power, im, alp, zb))
    zmin = np.min(np.stack([np.where(p[2] > 0.5, p[3], np.inf) for p in parts]), 0); HH, HW = EH * SSn, EW * SSn; num = np.zeros((HH, HW, 3), np.float32); nal = np.zeros((HH, HW), np.float32); den = np.zeros((HH, HW), np.float32); wa = np.zeros((HH, HW), np.float32)
    for w_, im, alp, zb in parts:
        keep = np.isfinite(zb) & (zb <= zmin * 1.04 + 0.01); w = (w_ * keep).astype(np.float32); num += im * (w * alp)[..., None]; wa += w * alp; nal += w * alp; den += w
    col = np.where((wa > 0)[..., None], num / np.maximum(wa, 1e-9)[..., None], 0); alpha = np.where(den > 0, nal / np.maximum(den, 1e-9), 0)
    if prim_edge:          # silhouette band comes from ONE photo (the highest-weight one): per-photo mattes are misaligned by depth/pose errors, averaging them makes a mottled rim
        pw, pim, palp, pzb = max(parts, key=lambda p: p[0]); band = np.isfinite(pzb) & (palp < 0.98) & (palp > 0.02); col = np.where(band[..., None], pim, col); alpha = np.where(band, palp, alpha)
    if close > 0:          # thin gaps inside the silhouette (coverage holes between layers) are filled from the nearest covered pixel; the outer boundary is not grown (closing then masked by a slightly eroded closing of the alpha>0.5 region)
        cov = (alpha > 0.5).astype(np.uint8); closed = cv2.morphologyEx(cov, cv2.MORPH_CLOSE, np.ones((close, close), np.uint8)) > 0; gap = closed & (alpha <= 0.5)
        if gap.any(): d, (iy, ix) = ndimage.distance_transform_edt(alpha <= 0.5, return_indices=True); col = np.where(gap[..., None], col[iy, ix], col); alpha = np.where(gap, alpha[iy, ix], alpha)
    pm = (col * alpha[..., None]).reshape(EH, SSn, EW, SSn, 3).mean((1, 3)); al_lo = alpha.reshape(EH, SSn, EW, SSn).mean((1, 3))
    if crisp is not None:       # remove the translucent speckle ring: un-premultiply, then re-apply a steeper alpha (smoothstep between crisp[0] and crisp[1])
        c = pm / np.maximum(al_lo, 1e-3)[..., None]; t = np.clip((al_lo - crisp[0]) / (crisp[1] - crisp[0]), 0, 1); a2 = t * t * (3 - 2 * t); return (c * a2[..., None]).astype(np.float32), a2.astype(np.float32)
    return pm.astype(np.float32), al_lo.astype(np.float32)
if __name__ == '__main__':
    MJ = {k: v for k, v in np.load('out_pj/map_joint.npz').items()}; pose = {int(k): np.array(v) for k, v in json.load(open('out_pj/poses_refined.json')).items()}
    # test-time alignment of the held-out cameras (camera only) -- same code as bm_pose_eval.py
    set_poses({}); import bm_pose_eval_lib as L
    tt = {i: L.tt_pose(i, MJ) for i in held}; set_poses({**pose, **tt}); zc = {}
    def zf(i):
        if i not in zc:
            img, dep, Tf, st = gsref.render(MJ['mu'], MJ['logs'], MJ['quat'], MJ['col'], MJ['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf; zc[i] = np.where((al > 0.5) & md[i], dep / np.maximum(al, 1e-3), 0).astype(np.float32)
        return zc[i]
    cfgs = {'old': None, 'A_ss2': dict(SSn=2, ext=0), 'A_ss3': dict(SSn=3, ext=0), 'A_ss3_ext3': dict(SSn=3, ext=3)}; R = {k: [] for k in cfgs}; t0 = time.time()
    for f in held:
        ct = P.cam(f); gt = P.gt[f]; m = P.mask[f]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; aG = matte(f); gpm = gt * aG[..., None]; band = cv2.dilate(((aG > 0.02) & (aG < 0.98)).astype(np.uint8), np.ones((7, 7), np.uint8)) > 0
        for nm, kw in cfgs.items():
            if kw is None: im, al = blend(ct, train, zf); alp = (al > 0.5).astype(np.float32) * 0 + al
            else: im, alp = blend_a(ct, train, zf, **kw)
            ps = lambda mm, ref: float(-10 * np.log10(max(((im - ref) ** 2)[mm].mean(), 1e-12)))
            R[nm].append(dict(frame=f, full=ps(m, gt), interior=ps(me, gt), band=ps(band, gpm), alpha_mae=float(np.abs(alp - aG)[band].mean())))
            if f in (45, 75): g.imwrite(f'out_pj/edge_{nm}_held{f}.png', im)
        print(f, {k: round(R[k][-1]['band'], 1) for k in cfgs}, f'{time.time() - t0:.0f}s', flush=True)
    summ = {k: {a: float(np.mean([x[a] for x in v])) for a in ('full', 'interior', 'band', 'alpha_mae')} for k, v in R.items()}; print(json.dumps(summ, indent=1)); json.dump(dict(summary=summ, frames=R), open('out_pj/bm_edge.json', 'w'), indent=1)
