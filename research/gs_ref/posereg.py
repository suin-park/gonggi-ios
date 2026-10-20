"""Causal local pose refinement by direct photometric alignment (PC study). ARKit pose is the initial value; a small 6-DoF correction is estimated for frame i only from PAST refined,
non-held reference frames, using the frame's own depth map (320x240) and gray images. Robust (Huber) residual, coarse-to-fine, correction bounded (<= 1.5 deg, <= 3 cm).
A correction is ACCEPTED only if it lowers the residual clearly and consistently; otherwise the ARKit pose is kept (counts reported).
Held-out evaluation frames are never refined from their own photo: their pose = ARKit pose composed with the interpolated correction of the neighbouring training frames."""
import numpy as np, cv2
from scipy.optimize import least_squares


def so3(w):
    return cv2.Rodrigues(np.asarray(w, np.float64))[0]


def bil(img, u, v):
    return cv2.remap(img, u.astype(np.float32).reshape(-1, 1), v.astype(np.float32).reshape(-1, 1), cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=-1)[:, 0]


def residual_fn(i, refs, R_all, C_all, K, gray, Z, pts, w_obs):
    H, W = Z[i].shape; ys, xs = pts; z = Z[i][ys, xs]; fx, fy, cx, cy = K[i]
    Xc = np.stack([(xs - cx) / fx * z, (ys - cy) / fy * z, z], 1)                         # camera-i points
    gi = gray[i][ys, xs]
    def f(p):
        dR = so3(p[:3]); R = R_all[i] @ dR; C = C_all[i] + p[3:]
        Xw = C + Xc @ R.T; out = []
        for j in refs:
            pc = (Xw - C_all[j]) @ R_all[j]; fxj, fyj, cxj, cyj = K[j]
            zj = np.maximum(pc[:, 2], 1e-3); u = fxj * pc[:, 0] / zj + cxj; v = fyj * pc[:, 1] / zj + cyj
            ok = (pc[:, 2] > 0.2) & (u > 1) & (v > 1) & (u < W - 2) & (v < H - 2)
            gj = bil(gray[j], u, v); good = ok & (gj >= 0)
            # occlusion-robust: depth of the reference at the projected pixel must agree within 12 %
            zr = bil(Z[j], u, v); good &= (zr > 0.2) & (np.abs(zr - pc[:, 2]) < 0.12 * pc[:, 2])
            r = np.where(good, gi - gj, 0.0); out.append(r)
        return np.concatenate(out)
    return f


def refine_frame(i, refs, R_all, C_all, K, gray, Z, rng, npts=3000, max_deg=1.5, max_m=0.03):
    H, W = Z[i].shape
    ys, xs = np.nonzero(Z[i] > 0.25)
    if len(ys) < 500 or len(refs) < 2: return None
    sel = rng.choice(len(ys), min(npts, len(ys)), replace=False); pts = (ys[sel], xs[sel])
    f = residual_fn(i, refs, R_all, C_all, K, gray, Z, pts, None)
    p0 = np.zeros(6); r0 = f(p0)
    n0 = np.count_nonzero(r0); cost0 = float(np.sum(r0 ** 2)) / max(n0, 1)
    if n0 < 600: return None
    sc = np.array([np.radians(0.3)] * 3 + [0.004] * 3)
    sol = least_squares(lambda q: f(q * sc), np.zeros(6), loss='huber', f_scale=0.05, max_nfev=60, diff_step=0.3)
    p = sol.x * sc; r1 = f(p); n1 = np.count_nonzero(r1); cost1 = float(np.sum(r1 ** 2)) / max(n1, 1)
    ang = np.degrees(np.linalg.norm(p[:3])); tr = np.linalg.norm(p[3:])
    ok = cost1 < 0.9 * cost0 and ang <= max_deg and tr <= max_m and n1 >= 0.6 * n0
    return dict(p=p, cost0=cost0, cost1=cost1, deg=ang, mm=tr * 1000, accepted=bool(ok), n0=n0, n1=n1)


def refine_all(R, C, K, gray, Z, held, pick_refs, seed=0):
    n = len(R); Rr = R.copy(); Cr = C.copy(); rng = np.random.RandomState(seed); info = [None] * n
    ok = lambda j: (not held(j)) and Z[j].max() > 0
    for i in range(n):
        if held(i) or Z[i].max() <= 0: continue
        refs = pick_refs(i, ok)
        r = refine_frame(i, refs, Rr, Cr, K, gray, Z, rng)
        info[i] = r
        if r and r['accepted']:
            Rr[i] = Rr[i] @ so3(r['p'][:3]); Cr[i] = Cr[i] + r['p'][3:]
    # held-out frames: ARKit pose composed with the correction interpolated from the nearest refined neighbours (no use of the held-out photo)
    for i in range(n):
        if not held(i): continue
        nb = [j for j in range(n) if not held(j) and info[j] and info[j]['accepted']]
        if not nb: continue
        lo = [j for j in nb if j < i]; hi = [j for j in nb if j > i]
        use = ([lo[-1]] if lo else []) + ([hi[0]] if hi else [])
        dR = [R[j].T @ Rr[j] for j in use]; dC = [Cr[j] - C[j] for j in use]
        Rr[i] = R[i] @ so3(np.mean([cv2.Rodrigues(d)[0].ravel() for d in dR], 0)); Cr[i] = C[i] + np.mean(dC, 0)
    return Rr, Cr, info
