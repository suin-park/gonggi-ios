import sys, numpy as np, cv2, json, time
import tex_data, fix06 as F
from skimage.metrics import structural_similarity
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
RP = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmoreplay'
W, H = 320, 240
L = F.load_kmots(KM); fr = tex_data.load(RP); S_all = [F.layer_samples(l) for l in L]
byid = {l['id']: k for k, l in enumerate(L)}
def cam_of(f):
    s = W / f['img'].shape[1]
    return F.Cam(f['R'], f['C'], f['fx']*s, f['fy']*s, (f['cx']+.5)*s-.5, (f['cy']+.5)*s-.5)
names = ['cur5_nocull', 'cons5', 'cons5_cull', 'hyb5_cull', 'coarse8_cons', 'coarse8_hyb', 'coarse8_rep']
agg = {s: [] for s in names}; t0 = time.time()
frames = sorted(set(list(range(0, 71, 2)) + [11, 24, 41, 44, 70]))
for i in frames:
    f = fr[i]; lid = f['id']
    if lid not in byid or not f['trusted']: continue
    k = byid[lid]; cam = cam_of(f)
    keep = [j for j in range(len(L)) if j != k]; Lk = [L[j] for j in keep]; Sk = [S_all[j] for j in keep]
    gt = cv2.resize(f['img'], (W, H), interpolation=cv2.INTER_AREA).astype(np.float32)/255
    gtg = np.clip(gt * L[k]['gain'], 0, 1); m = cv2.resize(f['mask'], (W, H), interpolation=cv2.INTER_NEAREST) == 1
    ids0, rgb0, z0 = F.render_all(L, cam, W, H, only=keep, cull=0)
    ids1, rgb1, z1 = F.render_all(L, cam, W, H, only=keep, cull=1)
    sc = np.array([F.score_of(l, cam) for l in Lk], np.float32); order = np.argsort(sc); res = {}
    res['cur5_nocull'] = F.blend_current(list(range(len(Lk))), rgb0, z0, {j: sc[j] for j in range(len(Lk))})
    wf = lambda sel, w: w[:, None, None] * np.ones((1, H, W), np.float32)
    sel = order[:5]; w = np.exp(-6 * sc[sel])
    res['cons5'] = F.blend_consensus(rgb0[sel], z0[sel], wf(sel, w))[:2]
    res['cons5_cull'] = F.blend_consensus(rgb1[sel], z1[sel], wf(sel, w))[:2]
    res['hyb5_cull'] = F.blend_consensus(rgb1[sel], z1[sel], wf(sel, w), mode='hyb')[:2]
    sel, w, _ = F.coarse_select(Lk, Sk, cam, W, H, kmax=8); sel = np.array(sel)
    for nm, md in (('coarse8_cons', 'avg'), ('coarse8_hyb', 'hyb'), ('coarse8_rep', 'rep')):
        res[nm] = F.blend_consensus(rgb1[sel], z1[sel], wf(sel, w), mode=md)[:2]
    line = f'i{i}: '
    for nm in names:
        im, A2 = res[nm]; p = F.psnr_masked(im, gtg, m); hole = float((A2[m] < .5).mean())
        ss = float(structural_similarity(im, gtg, channel_axis=2, data_range=1.0, win_size=7, full=True)[1].mean(-1)[m].mean())
        agg[nm].append((p, ss, hole)); line += f'{nm} {p:.1f}/{ss:.2f} '
    print(line, round(time.time()-t0), flush=True)
print('MEAN psnr/ssim/hole')
for nm in names: print(nm, np.array(agg[nm]).mean(0).round(4))
bad = [n for n, a in enumerate(agg['cur5_nocull'])]
