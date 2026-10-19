import sys, numpy as np, cv2, time, os
os.environ['KNEE'] = '1'
import tex_data, fix06 as F, regen, tscale
from skimage.metrics import structural_similarity
D = np.load('cache/t06_320.npz'); fr = regen.frames(); Ds = np.load('cache/t06_small.npz')
W, H = 320, 240; G3 = np.clip(np.load('cache/G2.npy'), 0.88, 1.15)
rng = np.random.default_rng(1); Zp = D['Z'] * np.exp(rng.normal(0, 0.08, len(D['Z'])))[:, None, None].astype(np.float32)
Zp_fix, _ = tscale.temporal_scale_fix(Zp, D['MASK'], D['K'], D['R'], D['C'], D['TRUST'])
Zs_fix, _ = tscale.temporal_scale_fix(Ds['Z'], D['MASK'], D['K'], D['R'], D['C'], D['TRUST'])
variants = {'PC960': D['Z'], 'PC960+scale-perturb8%': Zp, 'PC960+perturb+fix': Zp_fix, 'small320': Ds['Z'], 'small320+fix': Zs_fix}
evalset = sorted(set([i for i in range(2, 70, 4) if D['TRUST'][i]] + [11, 24, 44, 70]))
def cam_of(f):
    s = W / f['img'].shape[1]
    return F.Cam(f['R'], f['C'], f['fx']*s, f['fy']*s, (f['cx']+.5)*s-.5, (f['cy']+.5)*s-.5)
for name, Z in variants.items():
    t0 = time.time(); L = regen.build_layers(D, gains=G3, Zuse=Z); S = [F.layer_samples(l) for l in L]; byidx = {l['idx']: k for k, l in enumerate(L)}
    ps, ss, cur_ps = [], [], []
    for i in evalset:
        if i not in byidx: continue
        k = byidx[i]; f = fr[i]; cam = cam_of(f); keep = [j for j in range(len(L)) if j != k]; Lk = [L[j] for j in keep]; Sk = [S[j] for j in keep]
        ids, rgb, z = F.render_all(L, cam, W, H, only=keep, cull=1)
        sel, w, _ = F.coarse_select(Lk, Sk, cam, W, H, kmax=8); sel = np.array(sel)
        im, A, _ = F.blend_consensus(rgb[sel], z[sel], w[:, None, None] * np.ones((1, H, W), np.float32), mode='hyb')
        sc = np.array([F.score_of(l, cam) for l in Lk], np.float32)
        ids0, rgb0, z0 = F.render_all(L, cam, W, H, only=keep, cull=0)
        im0, _ = F.blend_current(list(range(len(Lk))), rgb0, z0, {j: sc[j] for j in range(len(Lk))})
        gt = np.clip(cv2.resize(f['img'], (W, H), interpolation=cv2.INTER_AREA).astype(np.float32) / 255, 0, 1); m = cv2.resize(f['mask'], (W, H), interpolation=cv2.INTER_NEAREST) == 1
        ps.append(F.psnr_masked(im, gt, m)); cur_ps.append(F.psnr_masked(im0, gt, m))
        ss.append(float(structural_similarity(im, gt, channel_axis=2, data_range=1.0, win_size=7, full=True)[1].mean(-1)[m].mean()))
    print(f'{name}: new-render LOO psnr {np.mean(ps):.2f} ssim {np.mean(ss):.3f} | current-render(cur5) psnr {np.mean(cur_ps):.2f} | {time.time()-t0:.0f}s', flush=True)
