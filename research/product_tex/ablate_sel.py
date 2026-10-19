"""Selection ablation (LOO near/far, sanitised eval region) with the final compose, on regenerated layers and saved device layers."""
import sys, os, time
os.environ['KNEE'] = '1'
import numpy as np, cv2
sys.path.insert(0, r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs')
import tex_data, fix06 as F, fix06_final as FF, regen
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
sets = {'regen(C-type)': regen.build_layers(D, gains=G3, masks=M2, trust=trust2), 'saved(A-type)': F.load_kmots(KM)}
frames = sorted(set([i for i in range(2, 70, 4) if trust2[i]] + [11, 24, 41, 44, 70]))


def cam_of(f):
    s = W / f['img'].shape[1]
    return F.Cam(f['R'], f['C'], f['fx']*s, f['fy']*s, (f['cx']+.5)*s-.5, (f['cy']+.5)*s-.5)


variants = [('nearest5 + new compose', dict(kind='near', k=5)), ('nearest8 + new compose', dict(kind='near', k=8)), ('cov k8 qf0.4', dict(kind='cov', k=8, qf=0.4)),
            ('cov k8 qf0.1', dict(kind='cov', k=8, qf=0.1)), ('cov k6 qf0.1', dict(kind='cov', k=6, qf=0.1)), ('cov k6 qf0.4', dict(kind='cov', k=6, qf=0.4)),
            ('cov k8 qf0.1 decay9', dict(kind='cov', k=8, qf=0.1, decay=9.0))]
for sname, L in sets.items():
    S = [F.layer_samples(l) for l in L]
    for tag, excl in (('near', 0), ('far', 2)):
        res = {v[0]: [] for v in variants}
        for i in frames:
            f = fr[i]; cam = cam_of(f)
            gt = np.clip(cv2.resize(f['img'], (W, H), interpolation=cv2.INTER_AREA).astype(np.float32) / 255, 0, 1)
            lab = cv2.resize(MS[i], (W, H), interpolation=cv2.INTER_NEAREST); R1 = lab == 1; region = cv2.dilate((lab == 1).astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
            keep = [j for j, l in enumerate(L) if abs(l['id'] - f['id']) > excl]
            sub = [L[j] for j in keep]; Ssub = [S[j] for j in keep]
            ids, rgb, z = F.render_all(L, cam, W, H, only=keep, cull=1)
            sc = np.array([F.score_of(l, cam) for l in sub], np.float32); order = np.argsort(sc)
            for name, cfg in variants:
                dec = cfg.get('decay', 6.0)
                if cfg['kind'] == 'near':
                    sel = order[:cfg['k']]; w = np.exp(-dec * sc[sel]).astype(np.float32)
                else:
                    sel, w, _ = F.coarse_select(sub, Ssub, cam, W, H, kmax=cfg['k'], qf=cfg['qf'], decay=dec); sel = np.array(sel)
                im, A, _ = FF.compose_new(rgb[sel], z[sel], w)
                alive = A > 0.5
                psnr = F.psnr_masked(im, gt, R1)
                ssim = float(structural_similarity(im, gt, channel_axis=2, data_range=1.0, win_size=7, full=True)[1].mean(-1)[R1].mean())
                res[name].append((psnr, ssim, float((~alive[R1]).mean()), float((alive & ~cv2.dilate(region.astype(np.uint8), np.ones((5, 5), np.uint8)).astype(bool)).sum() / max(region.sum(), 1)),
                                  float((alive & region).sum() / max((alive | region).sum(), 1))))
        print(sname, tag, flush=True)
        for name, _ in variants:
            r = np.array(res[name]).mean(0)
            print(f'  {name:28s} psnr {r[0]:.2f} ssim {r[1]:.3f} hole {r[2]:.4f} leak {r[3]:.4f} iou {r[4]:.3f}', flush=True)
