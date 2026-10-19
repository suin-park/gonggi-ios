"""Before/after on test_06 (PC reference): A = saved 3.0(24) layers + old renderer; B = same saved layers + new renderer; C = regenerated from the replay with the new pipeline + new renderer;
D = regenerated + old renderer. LOO near (own layer excluded) and far (own +-2 neighbours excluded). Same eval region / GT for every method."""
import sys, os, json, time, pickle
os.environ['KNEE'] = '1'
import numpy as np, cv2
sys.path.insert(0, r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs')
import tex_data, fix06 as F, fix06_final as FF, regen, study

D = np.load('cache/t06_320.npz'); fr = regen.frames(); n = len(fr)
KM = r'C:\Users\emili\Downloads\테스트_06\product-tex-20261020-013225-product-gs.kmots'
EW, EH = study.EW, study.EH
MS = np.load('cache/masks_sanitised.npy')
small = D['imgs'].astype(np.float32) / 255; Ks = D['K']; Rr = D['R']; Cc = D['C']; Z = D['Z']
ys_, xs_ = np.mgrid[0:240, 0:320]


def relabel(lab, band):
    region = cv2.dilate((lab == 1).astype(np.uint8), np.ones((9, 9), np.uint8)) > 0      # recorded masks use band 4
    k = 2 * band + 1
    inner = cv2.erode(region.astype(np.uint8), np.ones((k, k), np.uint8), borderType=cv2.BORDER_REPLICATE) > 0
    outer = cv2.dilate(region.astype(np.uint8), np.ones((k, k), np.uint8)) > 0
    out = np.zeros(lab.shape, np.uint8); out[inner] = 1; out[~outer] = 2
    return out


M2 = [relabel(MS[i], 2) if D['TRUST'][i] and (MS[i] == 1).sum() > 100 else MS[i] for i in range(n)]


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
    if not D['TRUST'][i] or (M2[i] == 1).sum() < 100: continue
    if last is not None:
        r = warp_ratio(i, last)
        G[i] = np.clip(G[last] * r, 0.8, 1.25) if r is not None else G[last]
    last = i
G3 = np.clip(G, 0.88, 1.15)
np.save('cache/G3_final.npy', G3)
print('gain range', G3.min(0), G3.max(0), flush=True)
trust2 = [bool(D['TRUST'][i]) and (M2[i] == 1).sum() > 100 for i in range(n)]
LC = regen.build_layers(D, gains=G3, masks=M2, trust=trust2)
LA = F.load_kmots(KM)
os.environ['KNEE'] = '0'
LE = regen.build_layers(D, gains=np.load('cache/G1.npy'))     # OLD pipeline settings on the same PC depth: product-mean gain, original masks, no highlight knee
os.environ['KNEE'] = '1'
SE = [F.layer_samples(l) for l in LE]
print('regenerated layers', len(LC), 'saved layers', len(LA), flush=True)
SA = [F.layer_samples(l) for l in LA]; SC = [F.layer_samples(l) for l in LC]


def cam_of(f, w=EW, h=EH):
    s = w / f['img'].shape[1]
    return F.Cam(f['R'], f['C'], f['fx']*s, f['fy']*s, (f['cx']+.5)*s-.5, (f['cy']+.5)*s-.5)


def render_set(L, S, keep, cam, W, H, mode):
    sub = [L[j] for j in keep]; Ssub = [S[j] for j in keep]
    if mode == 'old':
        ids, rgb, z = F.render_all(L, cam, W, H, only=keep, cull=0)
        sc = {j: F.score_of(sub[j], cam) for j in range(len(sub))}
        return F.blend_current(list(range(len(sub))), rgb, z, sc)
    ids, rgb, z = F.render_all(L, cam, W, H, only=keep, cull=1)
    sel, w, _ = F.coarse_select(sub, Ssub, cam, W, H, kmax=8); sel = np.array(sel)
    im, A, cnt = FF.compose_new(rgb[sel], z[sel], w)
    return im, A


def eval_set(frames, excl):
    rows = {k: [] for k in ('A', 'B', 'C', 'D', 'E')}; imgs = {}
    for i in frames:
        f = fr[i]; cam = cam_of(f); gt, lab = study.gt_and_labels(f, MS[i])        # eval region = SANITISED product mask (cloth excluded) for every method
        labo = cv2.resize(D['MASK'][i], (EW, EH), interpolation=cv2.INTER_NEAREST)
        hsv = cv2.cvtColor((gt * 255).astype(np.uint8), cv2.COLOR_RGB2HSV); cloth = (hsv[..., 0] > 95) & (hsv[..., 0] < 135) & (hsv[..., 1] > 90) & (labo == 1) & (lab != 1)
        for name, L, S, mode in (('A', LA, SA, 'old'), ('B', LA, SA, 'new'), ('C', LC, SC, 'new'), ('D', LC, SC, 'old'), ('E', LE, SE, 'old')):
            fid = f['id']
            keep = [j for j, l in enumerate(L) if abs(l['id'] - fid) > excl]
            im, A = render_set(L, S, keep, cam, EW, EH, mode)
            s = study.score(np.clip(im, 0, 1), A, gt, lab)
            if s is None: continue
            R1 = lab == 1
            s['sat'] = float((im.max(-1)[R1] > 0.97).mean()); s['gt_sat'] = float((gt.max(-1)[R1] > 0.97).mean())
            s['cloth'] = float((A[cloth] > 0.5).mean()) if cloth.sum() > 100 else float('nan')
            rows[name].append((i, s)); imgs[(i, name)] = (np.float16(im), np.float16(A))
    return rows, imgs


t0 = time.time()
frames = sorted(set([i for i in range(2, 70, 4) if trust2[i]] + [11, 24, 41, 44, 70]))
res = {}
for tag, excl in (('near', 0), ('far', 2)):
    rows, imgs = eval_set(frames, excl); res[tag] = rows
    pickle.dump(imgs, open(f'results/final_{tag}.pkl', 'wb'))
    keys = ['psnr', 'psnr_gc', 'ssim', 'lpips', 'hf_corr', 'psnr_edge', 'hole', 'leak', 'sil_iou', 'sat', 'gt_sat', 'cloth']
    print(tag, 'frames', len(frames), round(time.time() - t0), flush=True)
    for name in 'ABCDE':
        print(f'  {name}: ' + ' '.join(f"{k} {np.nanmean([s[k] for _, s in rows[name]]):.4f}" for k in keys), flush=True)
json.dump({t: {k: [(i, s) for i, s in v] for k, v in r.items()} for t, r in res.items()}, open('results/final_metrics.json', 'w'))
