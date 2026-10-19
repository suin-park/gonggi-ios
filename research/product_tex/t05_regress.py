"""Regression check on test_05 (same chair family, earlier recording): old pipeline settings + old renderer vs new pipeline + new renderer, on the held-out frames (index % 10 == 5, layers built without them)."""
import sys, os, time
os.environ['REGEN_RP'] = r'C:\Users\emili\Downloads\테스트_05\product-gs-20261019-204158-product-gs.kmoreplay'
import numpy as np, cv2
sys.path.insert(0, r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs')
import tex_data, fix06 as F, fix06_final as FF, regen, study, masksan

D = np.load('cache/t05_320.npz'); fr = regen.frames(); n = len(fr)
held = {i for i in range(n) if i % 10 == 5}
small = D['imgs'].astype(np.float32) / 255; Ks = D['K']; Rr = D['R']; Cc = D['C']; Z = D['Z']
ys_, xs_ = np.mgrid[0:240, 0:320]
masks, stats = masksan.sanitise(D, small, range(n))
MS = np.stack([masks[i] for i in range(n)])
removed = sum(int(((D['MASK'][i] == 1) & (MS[i] != 1)).sum()) for i in range(n)); total = sum(int((D['MASK'][i] == 1).sum()) for i in range(n))
print('mask guard on test_05 removed', removed, 'of', total, 'product pixels =', round(100 * removed / total, 2), '%', 'frames dropped', sum(1 for v in stats.values() if v and v.get('dropped_frame')), flush=True)


def relabel(lab, band, src_band=4):
    region = cv2.dilate((lab == 1).astype(np.uint8), np.ones((2 * src_band + 1, 2 * src_band + 1), np.uint8)) > 0
    k = 2 * band + 1
    inner = cv2.erode(region.astype(np.uint8), np.ones((k, k), np.uint8), borderType=cv2.BORDER_REPLICATE) > 0
    outer = cv2.dilate(region.astype(np.uint8), np.ones((k, k), np.uint8)) > 0
    out = np.zeros(lab.shape, np.uint8); out[inner] = 1; out[~outer] = 2
    return out


# test_05 was recorded with band 4 too (3.0(23) used 4)
M2 = [relabel(MS[i], 2) if D['TRUST'][i] and (MS[i] == 1).sum() > 100 else MS[i] for i in range(n)]
trust_new = [bool(D['TRUST'][i]) and i not in held and (M2[i] == 1).sum() > 100 for i in range(n)]
trust_old = [bool(D['TRUST'][i]) and i not in held for i in range(n)]


def warp_ratio(i, j):
    m = (M2[i] == 1) & (Z[i] > 0.3)
    if m.sum() < 300: return None
    z = Z[i][m]; fx, fy, cx, cy = Ks[i]
    X = np.stack([(xs_[m]-cx)/fx*z, (ys_[m]-cy)/fy*z, z], 1) @ Rr[i].T + Cc[i]
    Xc = (X - Cc[j]) @ Rr[j]; fxj, fyj, cxj, cyj = Ks[j]
    u = fxj*Xc[:,0]/Xc[:,2]+cxj; v = fyj*Xc[:,1]/Xc[:,2]+cyj
    ok = (Xc[:,2]>0.3)&(u>=1)&(v>=1)&(u<318)&(v<238)&(M2[j][np.clip(v.round().astype(int),0,239), np.clip(u.round().astype(int),0,319)]==1)
    if ok.sum() < 100: return None
    a = small[i][ys_[m][ok], xs_[m][ok]]; b = cv2.remap(small[j], u[ok].reshape(-1,1).astype(np.float32), v[ok].reshape(-1,1).astype(np.float32), cv2.INTER_LINEAR)[:,0]
    good = (a.min(1) > .05) & (a.max(1) < .95) & (b.min(1) > .05) & (b.max(1) < .95)
    if good.sum() < 100: return None
    return np.median(b[good] / a[good], axis=0)


G = np.ones((n, 3), np.float32); last = None
for i in range(n):
    if not trust_new[i]: continue
    if last is not None:
        r = warp_ratio(i, last)
        G[i] = np.clip(G[last] * r, 0.8, 1.25) if r is not None else G[last]
    last = i
G3 = np.clip(G, 0.88, 1.15)
means = np.array([small[i][D['MASK'][i] == 1].mean(0) if (D['MASK'][i] == 1).sum() > 50 else np.full(3, np.nan) for i in range(n)])
ref = np.nanmedian(np.array([means[i] for i in range(n) if i not in held][:5]), axis=0)
G1 = np.clip(ref[None] / np.where(np.isnan(means), ref[None], means), 0.7, 1.4)
os.environ['KNEE'] = '0'; LE = regen.build_layers(D, gains=G1, trust=trust_old)
os.environ['KNEE'] = '1'; LC = regen.build_layers(D, gains=G3, masks=M2, trust=trust_new)
print('layers old', len(LE), 'new', len(LC), 'gain range new', G3.min(0), G3.max(0), flush=True)
SE = [F.layer_samples(l) for l in LE]; SC = [F.layer_samples(l) for l in LC]
EW, EH = study.EW, study.EH


def cam_of(f, w=EW, h=EH):
    s = w / f['img'].shape[1]
    return F.Cam(f['R'], f['C'], f['fx']*s, f['fy']*s, (f['cx']+.5)*s-.5, (f['cy']+.5)*s-.5)


def render(L, S, cam, mode):
    if mode == 'old':
        ids, rgb, z = F.render_all(L, cam, EW, EH, cull=0); sc = {j: F.score_of(L[j], cam) for j in range(len(L))}
        return F.blend_current(list(range(len(L))), rgb, z, sc)
    ids, rgb, z = F.render_all(L, cam, EW, EH, cull=1)
    sel, w, _ = F.coarse_select(L, S, cam, EW, EH, kmax=8, seed=5); sel = np.array(sel)
    im, A, _ = FF.compose_new(rgb[sel], z[sel], w)
    return im, A


rows = {'old': [], 'new': []}
for i in sorted(held):
    if not D['TRUST'][i] or (D['MASK'][i] == 1).sum() < 100: continue
    f = fr[i]; cam = cam_of(f); gt, lab = study.gt_and_labels(f, D['MASK'][i])
    for name, L, S, mode in (('old', LE, SE, 'old'), ('new', LC, SC, 'new')):
        im, A = render(L, S, cam, mode)
        s = study.score(np.clip(im, 0, 1), A, gt, lab)
        if s is None: continue
        s['sat'] = float((im.max(-1)[lab == 1] > 0.97).mean()); rows[name].append(s)
keys = ['psnr', 'psnr_gc', 'ssim', 'lpips', 'hf_corr', 'psnr_edge', 'hole', 'leak', 'sil_iou', 'sat']
print('test_05 held-out frames', len(rows['old']))
for name in ('old', 'new'):
    print(f'  {name}: ' + ' '.join(f'{k} {np.nanmean([s[k] for s in rows[name]]):.4f}' for k in keys), flush=True)
