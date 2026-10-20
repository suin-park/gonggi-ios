"""Test_07 evaluation harness (PC reference, local data only; PC depth != app Core ML depth).
 prepare(): data D, sanitised masks (band 2), exposure chain gains (held frames excluded) and an `Env` with layer building / evaluation helpers.
 build(Zuse): layers from the replay with a given depth set; held frames never become layers.
 heldout(L): held-out photo evaluation (render-stage uses ONLY layers built without the held frames) — real held-out for the regenerated sets.
 ghost(L, cams): contributor disagreement at arbitrary virtual cameras (no ground truth).
"""
import os, sys
os.environ['KNEE'] = '1'
os.environ.setdefault('REGEN_RP', r'C:\Users\emili\Downloads\테스트_07\product-tex-20261020-070707-product-gs.kmoreplay')
sys.path.insert(0, r'C:\projects\gonggi-ios-ondevice-gs\research\ondevice_gs')
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, cv2
import tex_data, fix06 as F, fix06_final as FF, regen, study, masksan

NPZ = os.environ.get('NPZ07') or os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cache', 't07_320.npz')


def relabel(lab, band, src_band=4):
    region = cv2.dilate((lab == 1).astype(np.uint8), np.ones((2 * src_band + 1, 2 * src_band + 1), np.uint8)) > 0
    k = 2 * band + 1
    inner = cv2.erode(region.astype(np.uint8), np.ones((k, k), np.uint8), borderType=cv2.BORDER_REPLICATE) > 0
    outer = cv2.dilate(region.astype(np.uint8), np.ones((k, k), np.uint8)) > 0
    out = np.zeros(lab.shape, np.uint8); out[inner] = 1; out[~outer] = 2
    return out


class Env:
    def __init__(self, held_mode='near'):
        os.environ['HELD_MODE'] = held_mode
        self.D = np.load(NPZ); D = self.D; self.fr = regen.frames(); self.n = len(self.fr)
        self.held = {i for i in range(self.n) if ((i % 10 in (4, 5, 6)) if held_mode == 'far' else (i % 10 == 5))}
        self.small = D['imgs'].astype(np.float32) / 255; self.Ks = D['K']; self.Rr = D['R']; self.Cc = D['C']
        masks, _ = masksan.sanitise(D, self.small, range(self.n))
        self.MS = np.stack([masks[i] for i in range(self.n)])
        # saved masks of the app were band 2 already (test_07 recorded with band 2): use as-is for trusted frames
        self.M = [self.MS[i] for i in range(self.n)]
        self.trust = [bool(D['TRUST'][i]) and (self.M[i] == 1).sum() > 100 for i in range(self.n)]
        self.gains = self._gains()

    def _gains(self):
        D, small, M, n = self.D, self.small, self.M, self.n
        ys_, xs_ = np.mgrid[0:240, 0:320]; Z = D['Z']; Ks, Rr, Cc = self.Ks, self.Rr, self.Cc

        def ratio(i, j):
            m = (M[i] == 1) & (Z[i] > 0.3)
            if m.sum() < 300: return None
            z = Z[i][m]; fx, fy, cx, cy = Ks[i]
            X = np.stack([(xs_[m] - cx) / fx * z, (ys_[m] - cy) / fy * z, z], 1) @ Rr[i].T + Cc[i]
            Xc = (X - Cc[j]) @ Rr[j]; fxj, fyj, cxj, cyj = Ks[j]
            u = fxj * Xc[:, 0] / Xc[:, 2] + cxj; v = fyj * Xc[:, 1] / Xc[:, 2] + cyj
            ok = (Xc[:, 2] > 0.3) & (u >= 1) & (v >= 1) & (u < 318) & (v < 238) & (M[j][np.clip(v.round().astype(int), 0, 239), np.clip(u.round().astype(int), 0, 319)] == 1)
            if ok.sum() < 100: return None
            a = small[i][ys_[m][ok], xs_[m][ok]]
            b = cv2.remap(small[j], u[ok].reshape(-1, 1).astype(np.float32), v[ok].reshape(-1, 1).astype(np.float32), cv2.INTER_LINEAR)[:, 0]
            good = (a.min(1) > .05) & (a.max(1) < .95) & (b.min(1) > .05) & (b.max(1) < .95)
            if good.sum() < 100: return None
            return np.median(b[good] / a[good], axis=0)
        G = np.ones((n, 3), np.float32); last = None
        for i in range(n):
            if not self.trust[i] or i in self.held: continue
            if last is not None:
                r = ratio(i, last); G[i] = np.clip(G[last] * r, 0.8, 1.25) if r is not None else G[last]
            last = i
        return np.clip(G, 0.88, 1.15)

    def build(self, Zuse=None, with_held=False):
        trust = [t and (with_held or i not in self.held) for i, t in enumerate(self.trust)]
        return regen.build_layers(self.D, gains=self.gains, Zuse=Zuse, masks=self.M, trust=trust)

    def cam_of(self, f, w=study.EW, h=study.EH):
        s = w / f['img'].shape[1]
        return F.Cam(f['R'], f['C'], f['fx'] * s, f['fy'] * s, (f['cx'] + .5) * s - .5, (f['cy'] + .5) * s - .5)


def render(L, S, cam, W, H, kmax=8, seed=5):
    ids, rgb, z = F.render_all(L, cam, W, H, cull=1)
    sel, w, _ = F.coarse_select(L, S, cam, W, H, kmax=kmax, seed=seed); sel = np.array(sel)
    im, A, cnt = FF.compose_new(rgb[sel], z[sel], w)
    return im, A, rgb[sel], z[sel], w, sel


def heldout(env, L, label='', verbose=False, eval_M=None):
    S = [F.layer_samples(l) for l in L]; rows = []
    for i in sorted(env.held):
        if not env.D['TRUST'][i] or (env.D['MASK'][i] == 1).sum() < 100: continue
        f = env.fr[i]; cam = env.cam_of(f); gt, lab = study.gt_and_labels(f, (env.M if eval_M is None else eval_M)[i])
        im, A, *_ = render(L, S, cam, study.EW, study.EH)
        s = study.score(np.clip(im, 0, 1), A, gt, lab)
        if s is None: continue
        s['sat'] = float((im.max(-1)[lab == 1] > 0.97).mean()); rows.append(s)
    keys = ['psnr', 'psnr_gc', 'ssim', 'lpips', 'hf_corr', 'psnr_edge', 'hole', 'leak', 'sil_iou', 'sat']
    out = {k: float(np.nanmean([r[k] for r in rows])) for k in keys}; out['n'] = len(rows)
    if verbose: print(label, ' '.join(f'{k} {v:.3f}' for k, v in out.items()), flush=True)
    return out


def ghost_at(L, S, cam, W, H):
    """Contributor disagreement at a virtual camera, measured against the surface the composer picked (zb):
       spread_cm = median over pixels with >=2 contributors within 16% of zb of (max z - min z) (stacked / mis-registered copies of the same surface),
       stack = fraction of such pixels whose spread > 3 cm, dcol = luma std of contributors within 6% of zb (appearance ghost)."""
    im, A, rgb, z, w, sel = render(L, S, cam, W, H)
    zb = F.LAST_ZB.copy(); fin = np.isfinite(z)
    zbs = np.where(np.isfinite(zb), zb, 0)
    near = fin & (np.abs(np.where(fin, z, 0) - zbs[None]) < 0.16 * np.maximum(zbs, 0.3)[None])
    n = near.sum(0); m2 = (n >= 2) & (A > 0.5)
    if m2.sum() < 200: return None
    zn = np.where(near, z, np.nan)
    spread = np.nanmax(zn, 0) - np.nanmin(zn, 0)
    luma = rgb @ np.array([0.299, 0.587, 0.114], np.float32)
    tight = fin & (np.abs(np.where(fin, z, 0) - zbs[None]) < 0.06 * np.maximum(zbs, 0.3)[None]); nt = tight.sum(0); mm = (nt >= 2) & (A > 0.5)
    lm = np.where(tight, luma, 0).sum(0) / np.maximum(nt, 1)
    var = np.where(tight, (luma - lm[None]) ** 2, 0).sum(0) / np.maximum(nt, 1)
    return dict(stack=float((spread[m2] > 0.03).mean()), dz_cm=float(np.median(spread[m2]) * 100), dcol=float(np.sqrt(var[mm]).mean()) if mm.sum() > 100 else float('nan'), cover=float((A > 0.5).sum()), A=A, im=im)


def pair_stats(L, step=3, gaps=(1, 2, 4)):
    """layer j rendered into layer i's own camera vs i's own depth (|dz| inside the overlap) — near-surface registration of neighbouring layers."""
    W, H = 320, 240; rows = []
    for a in range(0, len(L), step):
        la = L[a]; cam = F.Cam(la['R'], la['C'], la['fx'] * W / la['w'], la['fy'] * W / la['w'], (la['cx'] + .5) * W / la['w'] - .5, (la['cy'] + .5) * W / la['w'] - .5)
        others = [b for b in range(len(L)) if b != a and abs(b - a) <= max(gaps)]
        ids, rgb, z = F.render_all(L, cam, W, H, cull=1, only=[a] + others); za = z[0]
        for k, b in enumerate(others):
            zb = z[k + 1]; m = np.isfinite(za) & np.isfinite(zb)
            if m.sum() < 300: continue
            dz = np.abs(zb[m] - za[m]); rows.append((abs(b - a), float(np.median(dz)), float(np.percentile(dz, 75)), float(np.mean(dz > 0.03))))
    rows = np.array(rows); out = {}
    for g in gaps:
        r = rows[rows[:, 0] == g]
        if len(r): out[g] = (float(np.median(r[:, 1]) * 100), float(np.median(r[:, 2]) * 100), float(np.median(r[:, 3])))
    return out
