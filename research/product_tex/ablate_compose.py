"""Ablation of the corroboration rule on LOO-near views, for saved device layers (A-type) and regenerated layers (C-type)."""
import sys, os, time, pickle
os.environ['KNEE'] = '1'
import numpy as np, cv2
sys.path.insert(0, r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs')
import tex_data, fix06 as F, regen
from skimage.metrics import structural_similarity

D = np.load('cache/t06_320.npz'); fr = regen.frames(); n = len(fr)
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
sets = {'saved(A-type)': F.load_kmots(KM), 'regen(C-type)': regen.build_layers(D, gains=G3, masks=M2, trust=trust2)}
frames = sorted(set([i for i in range(2, 70, 4) if trust2[i]] + [11, 24, 41, 44, 70]))


def cam_of(f):
    s = W / f['img'].shape[1]
    return F.Cam(f['R'], f['C'], f['fx']*s, f['fy']*s, (f['cx']+.5)*s-.5, (f['cy']+.5)*s-.5)


def corroborate(img, cnt, need, fr, tol_cnt=None):
    keep = cnt >= need
    ring = np.zeros_like(keep)
    for dy, dx in [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]:
        for r in range(fr, fr + 1):
            sh = np.roll(np.roll(keep, dy * r, 0), dx * r, 1)
            if dy * r > 0: sh[:dy * r] = False
            elif dy * r < 0: sh[dy * r:] = False
            if dx * r > 0: sh[:, :dx * r] = False
            elif dx * r < 0: sh[:, dx * r:] = False
            ring |= sh
    alive = (cnt >= 1) & (keep | ring)
    return img * alive[..., None], alive


variants = [('no corroboration', None), ('need2 fringe3 (current)', (2, 3, 0.06)), ('need2 fringe3 tolcnt0.12', (2, 3, 0.12)), ('need2 fringe8 tolcnt0.12', (2, 8, 0.12)),
            ('need2 fringe12 tolcnt0.12', (2, 12, 0.12)), ('need2 fringe8 tolcnt0.20', (2, 8, 0.20))]
for sname, L in sets.items():
    S = [F.layer_samples(l) for l in L]; res = {v[0]: [] for v in variants}
    for i in frames:
        f = fr[i]; cam = cam_of(f)
        gt = np.clip(cv2.resize(f['img'], (W, H), interpolation=cv2.INTER_AREA).astype(np.float32) / 255, 0, 1)
        lab = cv2.resize(D['MASK'][i], (W, H), interpolation=cv2.INTER_NEAREST); R1 = lab == 1; region = cv2.dilate((lab == 1).astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
        keep = [j for j, l in enumerate(L) if l['id'] != f['id']]
        sub = [L[j] for j in keep]; Ssub = [S[j] for j in keep]
        ids, rgb, z = F.render_all(L, cam, W, H, only=keep, cull=1)
        sel, w, _ = F.coarse_select(sub, Ssub, cam, W, H, kmax=8); sel = np.array(sel)
        wf = w[:, None, None] * np.ones((1, H, W), np.float32)
        im, A, _ = F.blend_consensus(rgb[sel], z[sel], wf, tol=0.06, mode='hyb')
        zz = z[sel]; zb = np.where(np.isfinite(zz), zz, np.inf)
        # consensus surface depth used for loose counting: recompute from the strict consensus support
        cnt_strict = F.LAST_CNT.copy()
        # loose count around the strict surface: reuse depth of the highest-weight consistent layer
        best = np.where(np.isfinite(zz) & (np.abs(zz - np.min(np.where(np.isfinite(zz), zz, np.inf), 0)[None]) < 1e9), zz, np.inf)
        for name, cfg in variants:
            if cfg is None: out, alive = im, A > 0
            else:
                need, fringe, tol_cnt = cfg
                if tol_cnt == 0.06: cnt = cnt_strict
                else:
                    # count layers within tol_cnt of the depth chosen by the strict consensus
                    F.blend_consensus(rgb[sel], z[sel], wf, tol=tol_cnt, mode='hyb'); cnt = F.LAST_CNT.copy()
                out, alive = corroborate(im, cnt, need if len(sel) >= 3 else 1, fringe)
            psnr = F.psnr_masked(out, gt, R1)
            ssim = float(structural_similarity(out, gt, channel_axis=2, data_range=1.0, win_size=7, full=True)[1].mean(-1)[R1].mean())
            res[name].append((psnr, ssim, float((~alive[R1]).mean()), float((alive & ~cv2.dilate(region.astype(np.uint8), np.ones((5, 5), np.uint8)).astype(bool)).sum() / max(region.sum(), 1)),
                              float((alive & region).sum() / max((alive | region).sum(), 1))))
    print(sname, flush=True)
    for name, _ in variants:
        r = np.array(res[name]).mean(0)
        print(f'  {name:32s} psnr {r[0]:.2f} ssim {r[1]:.3f} hole {r[2]:.4f} leak {r[3]:.4f} iou {r[4]:.3f}', flush=True)
