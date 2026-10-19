import sys, numpy as np, cv2, json, time
import tex_data, fix06 as F
from skimage.metrics import structural_similarity
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
RP = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmoreplay'
W, H = 320, 240
L = F.load_kmots(KM); fr = tex_data.load(RP); S_all = [F.layer_samples(l) for l in L]; byid = {l['id']: k for k, l in enumerate(L)}
d3 = {int(k): v for k, v in json.load(open('results/diag3.json')).items()}
def gated(thr_med, thr_p75):
    bad = set()
    for lid, pairs in d3.items():
        prev = [(j, m, p) for j, m, p, n in [(a, b, c, 0) for a, b, c, n in pairs] if j < lid]
        prev = [(j, m, p) for j, m, p in prev if lid - j <= 3]
        if not prev: continue
        nbad = sum(1 for j, m, p in prev if abs(np.log(m)) > thr_med or p > thr_p75)
        if nbad >= max(1, (len(prev) + 1) // 2): bad.add(lid)
    return bad
def cam_of(f):
    s = W / f['img'].shape[1]
    return F.Cam(f['R'], f['C'], f['fx']*s, f['fy']*s, (f['cx']+.5)*s-.5, (f['cy']+.5)*s-.5)
cfgs = [('none', set())] + [(f'gate med>{a} p75>{b}', gated(a, b)) for a, b in [(0.08, 0.16), (0.06, 0.12), (0.05, 0.10), (0.04, 0.08)]]
frames = sorted(set(list(range(1, 70, 3)) + [11, 24, 41, 44, 70]))
for name, bad in cfgs:
    ps, ss = [], []; t0 = time.time()
    for i in frames:
        f = fr[i]; lid = f['id']
        if lid not in byid or not f['trusted']: continue
        k = byid[lid]; cam = cam_of(f)
        keep = [j for j in range(len(L)) if j != k and L[j]['id'] not in bad]
        Lk = [L[j] for j in keep]; Sk = [S_all[j] for j in keep]
        ids, rgb, z = F.render_all(L, cam, W, H, only=keep, cull=1)
        sel, w, _ = F.coarse_select(Lk, Sk, cam, W, H, kmax=8); sel = np.array(sel)
        im, A, _ = F.blend_consensus(rgb[sel], z[sel], w[:, None, None] * np.ones((1, H, W), np.float32), mode='hyb')
        gt = np.clip(cv2.resize(f['img'], (W, H), interpolation=cv2.INTER_AREA).astype(np.float32) / 255 * L[k]['gain'], 0, 1)
        m = cv2.resize(f['mask'], (W, H), interpolation=cv2.INTER_NEAREST) == 1
        ps.append(F.psnr_masked(im, gt, m)); ss.append(float(structural_similarity(im, gt, channel_axis=2, data_range=1.0, win_size=7, full=True)[1].mean(-1)[m].mean()))
    print(f'{name}: gated {len(bad)} layers {sorted(bad)[:40]} -> LOO psnr {np.mean(ps):.2f} ssim {np.mean(ss):.3f} ({time.time()-t0:.0f}s)', flush=True)
