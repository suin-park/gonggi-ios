"""Novel orbit views (no ground truth): how much of the corroborated surface (>=2 of ALL layers agree within 6%) stays visible for each selection + the final compose."""
import sys, os, json, time
os.environ['KNEE'] = '1'
import numpy as np, cv2
sys.path.insert(0, r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs')
import fix06 as F, fix06_final as FF, regen

D = np.load('cache/t06_320.npz'); n = len(D['Z'])
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
MS = np.load('cache/masks_sanitised.npy'); G3 = np.load('cache/G3_final.npy')
W, H = 320, 240


def relabel(lab, band):
    region = cv2.dilate((lab == 1).astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
    k = 2 * band + 1
    inner = cv2.erode(region.astype(np.uint8), np.ones((k, k), np.uint8), borderType=cv2.BORDER_REPLICATE) > 0
    outer = cv2.dilate(region.astype(np.uint8), np.ones((k, k), np.uint8)) > 0
    out = np.zeros(lab.shape, np.uint8); out[inner] = 1; out[~outer] = 2
    return out


M2 = [relabel(MS[i], 2) if D['TRUST'][i] and (MS[i] == 1).sum() > 100 else MS[i] for i in range(n)]
trust2 = [bool(D['TRUST'][i]) and (M2[i] == 1).sum() > 100 for i in range(n)]
sets = {'regen(C-type)': regen.build_layers(D, gains=G3, masks=M2, trust=trust2), 'saved(A-type)': F.load_kmots(KM)}


def lookat(Cp, tgt):
    f = tgt - Cp; f /= np.linalg.norm(f); up = np.array([0, 1., 0]); r = np.cross(f, up); r /= np.linalg.norm(r); d = np.cross(f, r)
    return np.stack([r, d, f], 1)


for sname, L in sets.items():
    S = [F.layer_samples(l) for l in L]
    pts = np.concatenate([l['corners'].mean(1) for l in L]); c = np.median(pts, 0)
    C0 = np.array([l['C'] for l in L]); rel = C0 - c
    rad = np.linalg.norm(rel[:, [0, 2]], axis=1); h = rel[:, 1]
    l0 = L[0]; fx = l0['fx'] * W / l0['w']
    views = []
    for rscale in (0.8, 1.0, 1.25):
        for dh in (-0.2, 0.0, 0.25):
            for a in np.arange(-180, 175, 15):
                r = np.median(rad) * rscale; hh = np.median(h) + dh
                Cp = c + np.array([r * np.sin(np.radians(a)), hh, r * np.cos(np.radians(a))])
                views.append(F.Cam(lookat(Cp, c), Cp, fx, fx, (W - 1) / 2, (H - 1) / 2))
    variants = [('nearest5 (old selection)', dict(kind='near', k=5)), ('nearest8', dict(kind='near', k=8)), ('near5+cov3', dict(kind='cov', seed=5)), ('cov8', dict(kind='cov', seed=0))]
    agg = {v[0]: [] for v in variants}; t0 = time.time()
    for vi, cam in enumerate(views[::3]):
        ids, rgb, z = F.render_all(L, cam, W, H, cull=1)
        fin = np.isfinite(z)
        cnt = np.zeros((H, W), np.int32)
        for k in range(len(ids)):
            agree = fin & fin[k][None] & (np.abs(z - z[k][None]) < 0.06 * np.maximum(z[k][None], 0.3))
            cnt = np.maximum(cnt, agree.sum(0) * fin[k])
        corr = cnt >= 2
        if corr.sum() < 300: continue
        sc = np.array([F.score_of(l, cam) for l in L], np.float32); order = np.argsort(sc)
        for name, cfg in variants:
            if cfg['kind'] == 'near': sel = order[:cfg['k']]; w = np.exp(-6 * sc[sel]).astype(np.float32)
            else:
                sel, w, _ = F.coarse_select(L, S, cam, W, H, kmax=8, seed=cfg['seed']); sel = np.array(sel)
            im, A, _ = FF.compose_new(rgb[sel], z[sel], w)
            agg[name].append(float((A > 0.5)[corr].mean()))
    print(sname, 'views', len(agg['nearest8']), round(time.time() - t0), flush=True)
    for name, _ in variants: print(f'  {name:26s} retained corroborated surface: mean {np.mean(agg[name]):.3f} p10 {np.percentile(agg[name], 10):.3f}', flush=True)
