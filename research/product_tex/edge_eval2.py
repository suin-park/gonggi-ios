import sys, numpy as np, cv2, time, os
os.environ['KNEE'] = '1'
import tex_data, fix06 as F, regen, texsplat as TS
D = np.load('cache/t06_320.npz'); fr = regen.frames(); W, H = 320, 240
G3 = np.clip(np.load('cache/G2.npy'), 0.88, 1.15); MS = np.load('cache/masks_sanitised.npy')
def relabel(lab, band):
    region = cv2.dilate((lab == 1).astype(np.uint8), np.ones((7, 7), np.uint8)) > 0       # original region ~ dilate(product, 3)
    reg = region
    k = 2 * band + 1
    inner = cv2.erode(reg.astype(np.uint8), np.ones((k, k), np.uint8), borderType=cv2.BORDER_REPLICATE) > 0
    outer = cv2.dilate(reg.astype(np.uint8), np.ones((k, k), np.uint8)) > 0
    out = np.zeros(lab.shape, np.uint8); out[inner] = 1; out[~outer] = 2
    return out
evalset = sorted(set([i for i in range(2, 70, 4) if D['TRUST'][i]] + [11, 24, 44, 70]))
def cam_of(f, w=W, h=H):
    s = w / f['img'].shape[1]
    return F.Cam(f['R'], f['C'], f['fx']*s, f['fy']*s, (f['cx']+.5)*s-.5, (f['cy']+.5)*s-.5)
def run(name, band, minprod=0.5, atest=0.5, scale=1.0, min_agree=1):
    masks = [relabel(MS[i], band) if D['TRUST'][i] and (MS[i]==1).sum()>100 else MS[i] for i in range(len(MS))]
    import texsplat
    old = TS.build_from_frame
    L = regen.build_layers(D, gains=G3, masks=masks)
    S = [F.layer_samples(l) for l in L]; byidx = {l['idx']: k for k, l in enumerate(L)}
    res = []
    for i in evalset:
        if i not in byidx: continue
        k = byidx[i]; f = fr[i]; keep = [j for j in range(len(L)) if j != k]; Lk = [L[j] for j in keep]; Sk = [S[j] for j in keep]
        rw, rh = int(W * scale), int(H * scale); cam = cam_of(f, rw, rh)
        ids, rgb, z = F.render_all(L, cam, rw, rh, only=keep, cull=1)
        sel, w, _ = F.coarse_select(Lk, Sk, cam, rw, rh, kmax=8); sel = np.array(sel)
        im, A, _ = F.blend_consensus(rgb[sel], z[sel], w[:, None, None] * np.ones((1, rh, rw), np.float32), mode='hyb')
        A = A * (F.LAST_CNT >= min_agree)
        if scale != 1.0: im = cv2.resize(im, (W, H), interpolation=cv2.INTER_LINEAR); A = cv2.resize(A, (W, H), interpolation=cv2.INTER_LINEAR)
        gt = np.clip(cv2.resize(f['img'], (W, H), interpolation=cv2.INTER_AREA).astype(np.float32) / 255, 0, 1)
        lab0 = MS[i]; region = cv2.dilate((lab0 == 1).astype(np.uint8), np.ones((7, 7), np.uint8)) > 0
        core = lab0 == 1; rim = region & ~cv2.erode(core.astype(np.uint8), np.ones((7, 7), np.uint8)).astype(bool)   # band region just around the certain core
        pred = A > 0.5
        iou = float((pred & region).sum() / max((pred | region).sum(), 1))
        leak = float((pred & ~cv2.dilate(region.astype(np.uint8), np.ones((5, 5), np.uint8)).astype(bool)).sum() / max(region.sum(), 1))
        cover_rim = float(pred[region & ~core].mean()) if (region & ~core).sum() > 50 else np.nan
        psnr_core = F.psnr_masked(im, gt, core)
        res.append((iou, leak, cover_rim, psnr_core))
    r = np.nanmean(np.array(res), 0)
    print(f'{name}: layers {len(L)} sil IoU {r[0]:.3f} | outside-region leak {r[1]:.4f} | band-ring coverage {r[2]:.3f} | core PSNR {r[3]:.2f}', flush=True)
for nm, kw in [('band2 agree>=1', dict(band=2)), ('band2 agree>=2', dict(band=2, min_agree=2)), ('band2 agree>=3', dict(band=2, min_agree=3))]:
    run(nm, **kw)
