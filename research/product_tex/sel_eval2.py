import sys, numpy as np, cv2, json, time
import fix06 as F
exec(open('orbit_views.py').read()) if False else None
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
W, H = 320, 240
L = F.load_kmots(KM); samples = [F.layer_samples(l) for l in L]
pts = np.concatenate([l['corners'].mean(1) for l in L]); c = np.median(pts, 0)
C0 = np.array([l['C'] for l in L]); rel = C0 - c
az = np.degrees(np.arctan2(rel[:, 0], rel[:, 2])); rad = np.linalg.norm(rel[:, [0, 2]], axis=1); h = rel[:, 1]
def lookat(Cp, tgt):
    f = tgt - Cp; f /= np.linalg.norm(f); up = np.array([0, 1., 0]); r = np.cross(f, up); r /= np.linalg.norm(r); d = np.cross(f, r)
    return np.stack([r, d, f], 1)
l0 = L[0]; fx = l0['fx'] * W / l0['w']
views = []
for rscale in (0.8, 1.0, 1.25):
    for dh in (-0.2, 0.0, 0.25):
        for a in np.arange(-180, 175, 12):
            r = np.median(rad) * rscale; hh = np.median(h) + dh
            Cp = c + np.array([r * np.sin(np.radians(a)), hh, r * np.cos(np.radians(a))])
            views.append(F.Cam(lookat(Cp, c), Cp, fx, fx, (W - 1) / 2, (H - 1) / 2))
agg = {}; t0 = time.time(); sub = views[::4]
for vi, cam in enumerate(sub):
    ids, rgb, z = F.render_all(L, cam, W, H, cull=1)
    fin = np.isfinite(z); zf = np.where(fin, z, 0)
    # corroborated region: >=2 layers agree within 6% of the nearest agreeing depth (independent evidence)
    cnt = np.zeros((H, W), np.int32)
    for k in range(len(ids)):
        agree = fin & fin[k][None] & (np.abs(z - z[k][None]) < 0.06 * np.maximum(z[k][None], 0.3))
        cnt = np.maximum(cnt, agree.sum(0) * fin[k])
    corr = cnt >= 2
    if corr.sum() < 300: continue
    sc = np.array([F.score_of(L[j], cam) for j in ids], np.float32); order = np.argsort(sc)
    out = {}
    def cover(sel, w):
        im, A, _ = F.blend_consensus(rgb[sel], z[sel], w[:, None, None] * np.ones((1, H, W), np.float32))
        return float(A[corr].mean())
    for name, kk in [('nearest5', 5), ('nearest8', 8)]:
        sel = order[:kk]; out[name] = cover(sel, np.exp(-6 * sc[sel]))
    sel, w, cc = F.coarse_select(L, samples, cam, W, H, kmax=8); out['coarse8'] = cover(np.array(sel), w); out['coarse8_n'] = len(sel); out['coarse8_est'] = cc
    sel, w, cc = F.coarse_select(L, samples, cam, W, H, kmax=8, cand=24); out['coarse8_cand24'] = cover(np.array(sel), w)
    sel, w, cc = F.coarse_select(L, samples, cam, W, H, kmax=8, cand=16); out['coarse8_cand16'] = cover(np.array(sel), w)
    for k_, v in out.items(): agg.setdefault(k_, []).append(v)
    if vi % 10 == 0: print(vi, {k_: round(v, 3) for k_, v in out.items()}, round(time.time() - t0), flush=True)
print('MEAN', {k_: round(float(np.mean(v)), 4) for k_, v in agg.items()}, 'MIN', {k_: round(float(np.min(v)), 3) for k_, v in agg.items()})
