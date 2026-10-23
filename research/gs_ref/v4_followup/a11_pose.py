"""POSE-REFINE ONLY part of a2_bm.py (same LM, 320x240, 8 iters, fixed saved map). test_10 PC Bm (same chain as e2e_device baseline = what the app ports): pose refine all frames, depth from saved map, edge layer, K=5 blend, SS3, smooth_sil.
Tests: (A) leave-out at real photo poses (exclude self, or self +-G neighbours) vs the real photo; (B) panel edge-on novel views at in-band / out-of-band elevation; (C) panel thickness in the map."""
import os, sys, json, time
os.environ.setdefault('DATA', '10')
sys.path.insert(0, r'C:\projects\gonggi-ios-gs3\research\gs_ref')
import numpy as np, cv2
from scipy import ndimage
import gsref, bmcore
from bm_edge import matte
P = bmcore.P; g = bmcore.g; EW, EH = bmcore.EW, bmcore.EH
OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True); CDIR = os.path.join(OUT, 'cache'); os.makedirs(CDIR, exist_ok=True)
M = g.load_map(); RW, RH = 320, 240
views = [i for i in range(P.n) if P.mask[i].sum() > 50 and P.fr[i]['trusted']]
md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}


def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12:
        return np.eye(3)
    k = r / th
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K


cam0 = P.cam
POSE = {}


def cam(i, w=EW, h=EH):
    c = dict(cam0(i, w, h))
    if i in POSE:
        p = POSE[i]; c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]
    return c


def R_(c):
    return gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], c, **g.DISPLAY)


def small(i):
    return cv2.resize(P.gt[i], (RW, RH), interpolation=cv2.INTER_AREA), cv2.resize(P.mask[i].astype(np.uint8), (RW, RH), interpolation=cv2.INTER_NEAREST) > 0


def residual(i, p, gts, ms):
    c = dict(cam0(i, RW, RH)); c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]
    return ((R_(c)[0] - gts) * ms[..., None]).ravel()


def refine_pose(i, iters=8):
    gts, ms = small(i); p = np.zeros(6); lam = 1e-2; r = residual(i, p, gts, ms); f0 = f = float(r @ r); steps = np.array([0.002] * 6)
    for _ in range(iters):
        J = np.stack([(residual(i, p + np.eye(6)[k] * steps[k], gts, ms) - r) / steps[k] for k in range(6)], 1); A = J.T @ J; b = J.T @ r; moved = False
        for _ in range(4):
            dd = -np.linalg.solve(A + lam * np.diag(np.diag(A) + 1e-9), b); r2 = residual(i, p + dd, gts, ms); f2 = float(r2 @ r2)
            if f2 < f:
                p = p + dd; r = r2; f = f2; lam = max(lam / 3, 1e-6); moved = True; break
            lam *= 4
        if not moved:
            break
    return p, f0, f


pf = os.path.join(CDIR, 'poses.json'); t0 = time.time()
if os.path.exists(pf):
    d = json.load(open(pf)); POSE.update({int(k): np.array(v[0]) for k, v in d.items()}); PC = {int(k): v[1:] for k, v in d.items()}
else:
    PC = {}
    for i in views:
        p, f0, f1 = refine_pose(i); POSE[i] = p; PC[i] = [f0, f1]
    json.dump({str(k): [POSE[k].tolist()] + PC[k] for k in POSE}, open(pf, 'w'))
print('pose refine s', round(time.time() - t0, 1), flush=True)
dp = np.array([np.linalg.norm(POSE[i][3:]) for i in views]) * 1000; da = np.array([np.degrees(np.linalg.norm(POSE[i][:3])) for i in views]); red = np.array([PC[i][1] / max(PC[i][0], 1e-9) for i in views])
print('pose delta mm p50/p90', np.percentile(dp, [50, 90]).round(1), 'deg', np.percentile(da, [50, 90]).round(2), 'cost after/before p50', np.median(red).round(3), flush=True)
