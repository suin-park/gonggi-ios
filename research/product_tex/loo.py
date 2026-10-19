import sys, numpy as np, cv2, json, time
import tex_data, fix06 as F
from skimage.metrics import structural_similarity
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
RP = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmoreplay'
W, H = 320, 240
L = F.load_kmots(KM); fr = tex_data.load(RP)
byid = {l['id']: k for k, l in enumerate(L)}
def cam_of(f):
    s = W / f['img'].shape[1]
    return F.Cam(f['R'], f['C'], f['fx']*s, f['fy']*s, (f['cx']+.5)*s-.5, (f['cy']+.5)*s-.5)
strategies = ['cur5', 'cons5', 'rep5', 'cov_cons', 'cur_all', 'cons_all']
agg = {s: [] for s in strategies}
frames = [i for i in range(0, 71, 2)] + [11, 24, 41, 44, 70]
t0 = time.time()
for i in sorted(set(frames)):
    f = fr[i]; lid = f['id']
    if lid not in byid or not f['trusted']: continue
    k = byid[lid]; cam = cam_of(f)
    only = [j for j in range(len(L)) if j != k]
    ids, rgb, z = F.render_all(L, cam, W, H, only=only)
    gt = cv2.resize(f['img'], (W, H), interpolation=cv2.INTER_AREA).astype(np.float32)/255
    gtg = np.clip(gt * L[k]['gain'], 0, 1)
    m = cv2.resize(f['mask'], (W, H), interpolation=cv2.INTER_NEAREST) == 1
    sc = np.array([F.score_of(L[j], cam) for j in ids], np.float32)
    order = np.argsort(sc)
    res = {}
    # current
    scd = {j: sc[n] for n, j in enumerate(ids)}
    img, A = F.blend_current(ids, rgb, z, scd)
    res['cur5'] = (img, A)
    for name, kk, mode in [('cons5', 5, 'avg'), ('rep5', 5, 'rep'), ('cons_all', len(ids), 'avg')]:
        sel = order[:kk]; w = np.exp(-6 * sc[sel])
        im, A2, _ = F.blend_consensus(rgb[sel], z[sel], w[:, None, None] * np.ones((1, H, W), np.float32), mode=mode)
        res[name] = (im, A2)
    sel, w = F.pick_cov(ids, z, L, cam, region=m)
    im, A2, _ = F.blend_consensus(rgb[sel], z[sel], w[:, None, None] * np.ones((1, H, W), np.float32))
    res['cov_cons'] = (im, A2)
    scd2 = {j: sc[n] for n, j in enumerate(ids)}
    res['cur_all'] = F.blend_current(ids, rgb, z, scd2, k=len(ids))
    line = f'i{i} id{lid}: '
    for s in strategies:
        im, A2 = res[s]
        p = F.psnr_masked(im, gtg, m); hole = float((A2[m] < .5).mean())
        ss = float(structural_similarity(im, gtg, channel_axis=2, data_range=1.0, win_size=7, full=True)[1].mean(-1)[m].mean())
        agg[s].append((p, ss, hole)); line += f'{s} {p:.1f}/{ss:.2f}/{hole:.3f}  '
    print(line, round(time.time()-t0), flush=True)
print('MEAN psnr/ssim/hole')
for s in strategies:
    a = np.array(agg[s]); print(s, a.mean(0).round(4))
