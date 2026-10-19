import sys, numpy as np, cv2, json, time
import fix06 as F
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
W, H = 320, 240
L = F.load_kmots(KM)
meta = json.load(open(r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.meta.json', encoding='utf-8'))
# robust product centre from the layers' surface points (median of cell centres), not the possibly contaminated bounds box
pts = np.concatenate([l['corners'].mean(1) for l in L]); c = np.median(pts, 0)
print('median surface centre', c, 'meta centre', meta['productCenter'])
C0 = np.array([l['C'] for l in L]); rel = C0 - c
az = np.degrees(np.arctan2(rel[:, 0], rel[:, 2])); rad = np.linalg.norm(rel[:, [0, 2]], axis=1); h = rel[:, 1]
print('az range', az.min(), az.max(), 'radius med', np.median(rad), 'height med', np.median(h))
def lookat(Cp, tgt):
    f = tgt - Cp; f /= np.linalg.norm(f); up = np.array([0, 1., 0]); r = np.cross(f, up)
    if np.linalg.norm(r) < 1e-6: r = np.array([1., 0, 0])
    r /= np.linalg.norm(r); d = np.cross(f, r)       # camera: x right, y down, z forward (OpenCV)
    return np.stack([r, d, f], 1)
l0 = L[0]; s = W / l0['w']; fx = l0['fx'] * s
views = []
for rscale in (0.8, 1.0, 1.25):
    for dh in (-0.2, 0.0, 0.25):
        for a in np.arange(az.min() - 10, az.max() + 10, 12):
            r = np.median(rad) * rscale; hh = np.median(h) + dh
            Cp = c + np.array([r * np.sin(np.radians(a)), hh, r * np.cos(np.radians(a))])
            views.append(F.Cam(lookat(Cp, c), Cp, fx, fx, (W - 1) / 2, (H - 1) / 2))
print(len(views), 'novel views')
agg = {}
t0 = time.time()
for vi, cam in enumerate(views):
    ids, rgb, z = F.render_all(L, cam, W, H)
    union = np.isfinite(z).any(0)
    if union.sum() < 500: continue
    sc = np.array([F.score_of(L[j], cam) for j in ids], np.float32); order = np.argsort(sc)
    out = {}
    for name, kk in [('nearest5', 5), ('nearest8', 8), ('nearest12', 12), ('all', len(ids))]:
        sel = order[:kk]; out[name] = float(np.isfinite(z[sel]).any(0)[union].mean())
    sel, w = F.pick_cov(ids, z, L, cam, k0=5, kmax=10, region=union); out['cov10'] = float(np.isfinite(z[sel]).any(0)[union].mean()); out['cov10_n'] = len(sel)
    for k_, v in out.items(): agg.setdefault(k_, []).append(v)
    if vi % 6 == 0: print(vi, {k_: round(v, 3) for k_, v in out.items()}, round(time.time()-t0), flush=True)
print('MEAN coverage of observed-union region', {k_: round(float(np.mean(v)), 4) for k_, v in agg.items()}, 'MIN', {k_: round(float(np.min(v)), 3) for k_, v in agg.items()})
