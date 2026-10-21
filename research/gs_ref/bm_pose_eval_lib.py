import numpy as np, cv2
from bmcore import P, EW, EH
import gtlib as g, gsref
cam0 = P.cam
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
def small(i): return cv2.resize(P.gt[i], (320, 240), interpolation=cv2.INTER_AREA), cv2.resize(P.mask[i].astype(np.uint8), (320, 240), interpolation=cv2.INTER_NEAREST) > 0
def residual(i, p, gts, ms, M):
    c = dict(cam0(i, 320, 240)); c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]; img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], c, **g.DISPLAY); return ((img - gts) * ms[..., None]).ravel()
def tt_pose(i, M, iters=8):
    gts, ms = small(i); p = np.zeros(6); lam = 1e-2; r = residual(i, p, gts, ms, M); f = float(r @ r); steps = np.array([0.002] * 6)
    for _ in range(iters):
        J = np.stack([(residual(i, p + np.eye(6)[k] * steps[k], gts, ms, M) - r) / steps[k] for k in range(6)], 1); A = J.T @ J; b = J.T @ r; moved = False
        for _ in range(4):
            d = -np.linalg.solve(A + lam * np.diag(np.diag(A) + 1e-9), b); r2 = residual(i, p + d, gts, ms, M); f2 = float(r2 @ r2)
            if f2 < f: p = p + d; r = r2; f = f2; lam = max(lam / 3, 1e-6); moved = True; break
            lam *= 4
        if not moved: break
    return p
