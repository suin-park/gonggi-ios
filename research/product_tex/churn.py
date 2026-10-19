import sys, os, numpy as np
import fix06 as F
from scipy.spatial.transform import Rotation as Rot, Slerp
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
L = F.load_kmots(KM); S = [F.layer_samples(l) for l in L]; W, H = 320, 240
def cam_between(a, b, t):
    rs = Slerp([0, 1], Rot.from_matrix([a['R'], b['R']]))(t).as_matrix(); C = (1 - t) * a['C'] + t * b['C']; s = W / a['w']
    return F.Cam(rs, C, a['fx'] * s, a['fy'] * s, (a['cx'] + .5) * s - .5, (a['cy'] + .5) * s - .5)
res = {}
for name, kw in [('nearest5', None), ('cov8 (hyst bonus)', dict(seed=0)), ('near5+cov3 (no seed hyst)', dict(seed=5, nohyst=True)), ('near5+cov3 (seed hyst 0.03)', dict(seed=5))]:
    prev = None; ch = []
    for i in range(8, 60):
        for t in (0, 1/3, 2/3):
            cam = cam_between(L[i], L[i + 1], t)
            if kw is None:
                sel = set(np.argsort([F.score_of(l, cam) for l in L])[:5].tolist())
            else:
                kk = dict(kw); nohyst = kk.pop('nohyst', False)
                if nohyst:
                    import numpy as _n
                    sel, _, _ = F.coarse_select(L, S, cam, W, H, kmax=8, prev=None, **kk)
                    # emulate bonus only (greedy) without seed hysteresis: pass prev but seed uses plain score -> temporarily disable via prev=None for seed ordering
                    sel, _, _ = F.coarse_select(L, S, cam, W, H, kmax=8, prev=prev, **{**kk, 'seed': 0}) if False else (sel, 0, 0)
                else:
                    sel, _, _ = F.coarse_select(L, S, cam, W, H, kmax=8, prev=prev, **kk)
                sel = set(sel)
            if prev is not None: ch.append(1 - len(sel & prev) / len(sel | prev))
            prev = sel
    res[name] = np.mean(ch); print(name, round(float(np.mean(ch)), 3), flush=True)
