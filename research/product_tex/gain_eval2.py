import sys, numpy as np, cv2, time
import tex_data, fix06 as F, regen
from skimage.metrics import structural_similarity
D = np.load('cache/t06_320.npz'); fr = regen.frames()
W, H = 320, 240
G1 = np.load('cache/G1.npy'); G2 = np.load('cache/G2.npy')
opts = {'G0_none': None, 'G1_current': G1, 'G2_overlap': G2}
evalset = [i for i in range(2, 70, 4) if D['TRUST'][i]] + [11, 24, 44, 70]
def cam_of(f):
    s = W / f['img'].shape[1]
    return F.Cam(f['R'], f['C'], f['fx']*s, f['fy']*s, (f['cx']+.5)*s-.5, (f['cy']+.5)*s-.5)
for name, g in opts.items():
    t0 = time.time(); L = regen.build_layers(D, gains=g); S = [F.layer_samples(l) for l in L]
    byidx = {l['idx']: k for k, l in enumerate(L)}
    ps, ss, spread, satr, satg = [], [], [], [], []
    for i in sorted(set(evalset)):
        if i not in byidx: continue
        k = byidx[i]; f = fr[i]; cam = cam_of(f)
        keep = [j for j in range(len(L)) if j != k]; Lk = [L[j] for j in keep]; Sk = [S[j] for j in keep]
        ids, rgb, z = F.render_all(L, cam, W, H, only=keep, cull=1)
        sel, w, _ = F.coarse_select(Lk, Sk, cam, W, H, kmax=8); sel = np.array(sel)
        im, A, _ = F.blend_consensus(rgb[sel], z[sel], w[:, None, None] * np.ones((1, H, W), np.float32))
        gt = cv2.resize(f['img'], (W, H), interpolation=cv2.INTER_AREA).astype(np.float32) / 255
        m = cv2.resize(f['mask'], (W, H), interpolation=cv2.INTER_NEAREST) == 1
        ps.append(F.psnr_masked(im, gt, m))
        ss.append(float(structural_similarity(im, gt, channel_axis=2, data_range=1.0, win_size=7, full=True)[1].mean(-1)[m].mean()))
        # colour spread among the selected consistent layers (seam indicator)
        zz = z[sel]; fin = np.isfinite(zz); zb = np.where(fin, zz, np.inf).min(0)
        cons = fin & (np.abs(zz - zb[None]) < 0.06 * np.maximum(zb, .3)[None]); ww = cons * w[:, None, None]
        mu = (rgb[sel] * ww[..., None]).sum(0) / np.maximum(ww.sum(0), 1e-9)[..., None]
        var = (((rgb[sel] - mu[None]) ** 2).sum(-1) * ww).sum(0) / np.maximum(ww.sum(0), 1e-9)
        mm = m & (cons.sum(0) >= 2); spread.append(float(np.sqrt(var[mm]).mean()) if mm.sum() > 100 else np.nan)
        satr.append(float((im.max(-1)[m] > 0.97).mean())); satg.append(float((gt.max(-1)[m] > 0.97).mean()))
    print(name, f'layers {len(L)} LOO psnr vs raw GT {np.mean(ps):.2f} ssim {np.mean(ss):.3f} | seam colour spread {np.nanmean(spread):.4f} | saturated frac render {np.mean(satr):.3f} vs GT {np.mean(satg):.3f} | {time.time()-t0:.0f}s', flush=True)
