import numpy as np, cv2, json
from depth_refine import *
md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}
def raw(i):
    img, dep, Tf, st = gsref.render(MAP['mu'], MAP['logs'], MAP['quat'], MAP['col'], MAP['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf; return np.where((al > 0.5) & md[i], dep / np.maximum(al, 1e-3), 0).astype(np.float32)
zr = {i: raw(i) for i in train}; zref = {int(k): v for k, v in np.load('out_best/depth_refined_P2.npz').items()}
lum = lambda x: 0.299 * x[..., 0] + 0.587 * x[..., 1] + 0.114 * x[..., 2]
def ghost(ct, parts, keeps):
    fl = np.stack([lum(p[2]) for p in parts]); fm = np.stack(keeps); cnt = fm.sum(0); mean = (fl * fm).sum(0) / np.maximum(cnt, 1); sd = np.sqrt((((fl - mean) ** 2) * fm).sum(0) / np.maximum(cnt, 1)); ok = cnt >= 2; o = {}
    for name, anc in ANCH.items():
        pt = (anc - ct['C']) @ ct['Rcw'].T; u = int((ct['fx'] * pt[0] / pt[2] + ct['cx']) * SS); v = int((ct['fy'] * pt[1] / pt[2] + ct['cy']) * SS); sl = (slice(max(0, v - 60), v + 60), slice(max(0, u - 80), u + 80)); oo = ok[sl]; o[name] = float(sd[sl][oo].mean()) if oo.sum() > 200 else float('nan')
    return o
R = {}
for nm, zfn in (('raw', lambda s: zr[s]), ('completed', lambda s: zprior[s])):
    P_, S_, G_ = [], [], []
    for f in held:
        ct = P.cam(f); gt = P.gt[f]; m = P.mask[f]; ps = lambda im: float(-10 * np.log10(max(((im - gt) ** 2)[m].mean(), 1e-12)))
        ih, fh = hard(ct, train, zfn); isml, al, parts, keeps = blend(ct, train, zfn, want_parts=True); P_.append(ps(ih)); S_.append(ps(isml)); G_.append(ghost(ct, parts, keeps))
    R[nm] = dict(hard=float(np.mean(P_)), smooth=float(np.mean(S_)), ghost={a: float(np.nanmean([x[a] for x in G_])) for a in ANCH}); print(nm, R[nm], flush=True)
