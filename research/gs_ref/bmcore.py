"""Shared Bm renderer pieces (PC research; same logic as bm_smooth.py / bm_final.py but with explicit source lists and pluggable depth, so held-out protocols can be run)."""
import os, sys, json
import numpy as np, cv2
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gtlib as g
EW, EH = g.EW, g.EH; SS = 2; HW, HH = EW * SS, EH * SS; yy, xx = np.mgrid[:EH, :EW]
P = g.Photos(); ANCH = {k: np.array(v) for k, v in json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out_best_anchors.json'))).items()}
u8 = lambda x: (np.clip(x, 0, 1) * 255).astype(np.uint8)
def ranked(ct, srcs):
    out = []
    for s in srcs:
        cs = P.cam(s); d = float(np.linalg.norm(cs['C'] - ct['C'])); a = float(np.degrees(np.arccos(np.clip(cs['Rcw'][2] @ ct['Rcw'][2], -1, 1)))); out.append((d + 0.004 * a, s, a))
    out.sort(); return out
def warp_ss(s, ct, z):
    cs = P.cam(s); m = z > 0; zz = z[m]; x = (xx[m] - cs['cx']) / cs['fx'] * zz; y = (yy[m] - cs['cy']) / cs['fy'] * zz; Xw = np.stack([x, y, zz], 1) @ cs['Rcw'] + cs['C']; pt = (Xw - ct['C']) @ ct['Rcw'].T; ok = pt[:, 2] > 0.1; pt = pt[ok]; col = P.gt[s][m][ok]; zs = zz[ok]
    u = (ct['fx'] * pt[:, 0] / pt[:, 2] + ct['cx'] + 0.5) * SS - 0.5; w = (ct['fy'] * pt[:, 1] / pt[:, 2] + ct['cy'] + 0.5) * SS - 0.5
    rho = (ct['fx'] / pt[:, 2]) / (cs['fx'] / zs); fp = np.clip(np.ceil(rho * SS), 2, 6).astype(int); o = np.argsort(-pt[:, 2]); u, w, col, fp, zt = u[o], w[o], col[o], fp[o], pt[o, 2]
    img = np.zeros((HH, HW, 3), np.float32); zb = np.full((HH, HW), np.inf, np.float32)
    for f in range(2, 7):
        sel = fp == f
        if not sel.any(): continue
        for du in range(f):
            for dw in range(f):
                ui = np.floor(u[sel] - (f - 1) / 2).astype(int) + du; wi = np.floor(w[sel] - (f - 1) / 2).astype(int) + dw; k = (ui >= 0) & (ui < HW) & (wi >= 0) & (wi < HH); ui, wi, cc, zv = ui[k], wi[k], col[sel][k], zt[sel][k]
                win = zv < zb[wi, ui]; img[wi[win], ui[win]] = cc[win]; zb[wi[win], ui[win]] = zv[win]
    return img, zb
def blend(ct, srcs, zfun, K=5, p0=3.0, p1=None, sigma=60.0, want_parts=False):
    """continuous multi-photo blend (Bm-smooth); p1 given -> face-weighted exponent near the eye/nose anchor (Bm-final)."""
    r = ranked(ct, srcs); K = min(K, len(r) - 1); dK = r[K][0]; parts = []
    for d, s, a in r[:K]: im, zb = warp_ss(s, ct, zfun(s)); parts.append((max(0.0, 1 - d / dK), s, im, zb))
    zmin = np.min(np.stack([p[3] for p in parts]), 0)
    if p1 is not None:
        pt = (ANCH['face'] - ct['C']) @ ct['Rcw'].T; u = (ct['fx'] * pt[0] / pt[2] + ct['cx']) * SS; v = (ct['fy'] * pt[1] / pt[2] + ct['cy']) * SS; gy, gx = np.mgrid[:HH, :HW]; pe = p0 + (p1 - p0) * np.exp(-(((gx - u) ** 2 + (gy - v) ** 2) / (2 * (sigma * SS) ** 2))).astype(np.float32)
    else: pe = np.full((HH, HW), p0, np.float32)
    num = np.zeros((HH, HW, 3), np.float32); den = np.zeros((HH, HW), np.float32); keeps = []
    for base, s, im, zb in parts:
        keep = np.isfinite(zb) & (zb <= zmin * 1.04 + 0.01); w = (np.exp(np.log(max(base, 1e-12)) * pe) * keep * (base > 0)).astype(np.float32); num += im * w[..., None]; den += w; keeps.append(keep)
    cov = den > 0; col = np.where(cov[..., None], num / np.maximum(den, 1e-9)[..., None], 0); lo = (col * cov[..., None]).reshape(EH, SS, EW, SS, 3).mean((1, 3)); al = cov.reshape(EH, SS, EW, SS).mean((1, 3)).astype(np.float32)
    if want_parts: return lo.astype(np.float32), al, parts, keeps
    return lo.astype(np.float32), al
def hard(ct, srcs, zfun, K=4):
    """existing Bm: nearest-first fill, 1x splat, no blending."""
    out = np.zeros((EH, EW, 3), np.float32); fill = np.zeros((EH, EW), bool)
    for _, s, a in ranked(ct, srcs)[:K]:
        cs = P.cam(s); z = zfun(s); m = z > 0; x = (xx[m] - cs['cx']) / cs['fx'] * z[m]; y = (yy[m] - cs['cy']) / cs['fy'] * z[m]; Xw = np.stack([x, y, z[m]], 1) @ cs['Rcw'] + cs['C']; pt = (Xw - ct['C']) @ ct['Rcw'].T; ok = pt[:, 2] > 0.1; pt = pt[ok]; col = P.gt[s][m][ok]
        u = ct['fx'] * pt[:, 0] / pt[:, 2] + ct['cx']; w = ct['fy'] * pt[:, 1] / pt[:, 2] + ct['cy']; o = np.argsort(-pt[:, 2]); u, w, col = u[o], w[o], col[o]; im = np.zeros((EH, EW, 3), np.float32); f = np.zeros((EH, EW), bool)
        for du in (0, 1):
            for dw in (0, 1):
                ui = np.floor(u).astype(int) + du; wi = np.floor(w).astype(int) + dw; k = (ui >= 0) & (ui < EW) & (wi >= 0) & (wi < EH); im[wi[k], ui[k]] = col[k]; f[wi[k], ui[k]] = True
        add = f & ~fill; out[add] = im[add]; fill |= f
    return out, fill.astype(np.float32)
def refine_mask(i, r=8, eps=1e-3):
    hi = P.hi[i]; H, W = hi.shape[:2]; m = cv2.resize((P.fr[i]['mask'] == 1).astype(np.float32), (W, H), interpolation=cv2.INTER_LINEAR)
    guide = cv2.cvtColor(hi, cv2.COLOR_RGB2GRAY).astype(np.float32) / 255; bx = lambda x: cv2.boxFilter(x, -1, (2 * r + 1, 2 * r + 1)); mi, mp = bx(guide), bx(m); cov = bx(guide * m) - mi * mp; var = bx(guide * guide) - mi * mi
    a = cov / (var + eps); b = mp - a * mi; q = np.clip(bx(a) * guide + bx(b), 0, 1); hd = (m > 0.5).astype(np.uint8); k = np.ones((13, 13), np.uint8); q[cv2.erode(hd, k) > 0] = 1; q[cv2.dilate(hd, k) == 0] = 0
    return cv2.resize(q, (EW, EH), interpolation=cv2.INTER_AREA) > 0.5
