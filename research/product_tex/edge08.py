"""Outline experiment v2 (synthetic GT, TRUE depth): what makes the silhouette rough? cell granularity (cells kept only if >=50 % product), nearest-upsampled binary texel alpha,
alpha test + no AA, 0.75 render scale + upscale. Measured against the exact silhouette (3x supersampled GT coverage).
 edge_loss : 1 - alpha averaged over the GT-inside band (<=6 px from the GT silhouette) -> how much of the true object edge is cut away
 band_err  : |alpha - GT coverage| in the +-3 px edge band (cut + stairs + fuzz)
 jag       : contour length ratio (>1 = staircase/serrated contour)
 leak      : alpha mass outside the GT silhouette (+3 px) per boundary px -> over-expansion
"""
import sys, os, time, pickle
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, cv2
import syn_env as E, h07, cams07, fix06 as F, texsplat as TS, synth07 as S, fix06_final as FF

syn = E.Syn()
W, H = 480, 360


def build(alpha_mode, min_prod, ext='0'):
    os.environ['ALPHA_SOFT'] = alpha_mode; os.environ['MIN_PROD'] = str(min_prod); os.environ['EDGE_EXT'] = ext
    return syn.build(Zuse=syn.Zgt)


def render_view(L, Sm, cam, W, H, thr, aa):
    rgb = np.zeros((len(L), H, W, 3), np.float32); z = np.full((len(L), H, W), np.inf, np.float32); al = np.zeros((len(L), H, W), np.float32)
    for i in range(len(L)):
        s = L[i].get('_S') or F.surf(L[i]); L[i]['_S'] = s
        im, zb, ap = TS.render_layer_zba(s, cam, W, H, 0.04, 1, thr)
        zz = zb.copy(); zz[zz > 1e8] = np.inf; rgb[i] = im; z[i] = zz; al[i] = ap
    sel, w, _ = F.coarse_select(L, Sm, cam, W, H, kmax=8, seed=5); sel = np.array(sel)
    im, A, cnt = FF.compose_new(rgb[sel], z[sel], w)
    zb = F.LAST_ZB; fin = np.isfinite(z[sel]); zbs = np.where(np.isfinite(zb), zb, 0)
    tight = fin & (np.abs(np.where(fin, z[sel], 0) - zbs[None]) < 0.06 * np.maximum(zbs, 0.3)[None])
    ww = tight * w[:, None, None]
    cov = (al[sel] * ww).sum(0) / np.maximum(ww.sum(0), 1e-9)
    alpha = (A > 0.5).astype(np.float32) * (np.clip(cov, 0, 1) if aa else 1.0)
    return im, alpha


def finish(im, alpha, scale, up):
    if scale == 1.0: return im, alpha
    pm = np.dstack([im * alpha[..., None], alpha])
    big = cv2.resize(pm, (W, H), interpolation=cv2.INTER_NEAREST if up == 'nearest' else cv2.INTER_LINEAR)
    a = big[..., 3]; return big[..., :3] / np.maximum(a, 1e-4)[..., None], a


_GT = {}
def gt_cov(cam, W, H, ss=3):
    key = (round(float(cam.C[0]), 4), round(float(cam.C[1]), 4), round(float(cam.C[2]), 4), W)
    if key not in _GT:
        c = F.Cam(cam.R, cam.C, cam.fx * ss, cam.fy * ss, (cam.cx + .5) * ss - .5, (cam.cy + .5) * ss - .5)
        rgb, z, hit = S.render(c.R, c.C, c.fx, c.fy, c.cx, c.cy, W * ss, H * ss)
        cov_ = cv2.resize(hit.astype(np.float32), (W, H), interpolation=cv2.INTER_AREA); rgbp = cv2.resize(rgb * hit[..., None], (W, H), interpolation=cv2.INTER_AREA)
        _GT[key] = (cov_, rgbp)
    return _GT[key]


def metrics(alpha, cov):
    inside = (cov > 0.98).astype(np.uint8)
    dist_in = cv2.distanceTransform(inside, cv2.DIST_L2, 3)
    inner_band = (inside > 0) & (dist_in <= 6)
    edge_loss = float((1 - alpha)[inner_band].mean())
    band = cv2.dilate(((cov > 0.02) & (cov < 0.98)).astype(np.uint8), np.ones((7, 7), np.uint8)) > 0
    band_err = float(np.abs(alpha - cov)[band].mean())
    def perim(m):
        cs, _ = cv2.findContours(m.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        return sum(cv2.arcLength(c, True) for c in cs) if cs else 0
    jag = perim(alpha > 0.5) / max(perim(cv2.GaussianBlur(cov, (0, 0), 1.2) > 0.5), 1)
    outside = (cov < 0.02) & (cv2.dilate((cov > 0.5).astype(np.uint8), np.ones((9, 9), np.uint8)) > 0)
    leak = float(alpha[outside].sum() / max(perim(cov > 0.5), 1))
    return dict(edge_loss=edge_loss, band_err=band_err, jag=jag, leak=leak)


variants = [('A current  .75 nearest', '0', 0.5, 0.5, False, 0.75, 'nearest'),
            ('A1 current @1.0', '0', 0.5, 0.5, False, 1.0, 'nearest'),
            ('B soft a, cells>=.25, AA @1.0', '1', 0.25, 0.25, True, 1.0, 'linear'),
            ('C soft a, cells>=.10, AA @1.0', '1', 0.10, 0.25, True, 1.0, 'linear'),
            ('D soft a, cells>=.25, AA .75 bilin', '1', 0.25, 0.25, True, 0.75, 'linear'),
            ('E soft a, cells>=.25, AA .75 nearest', '1', 0.25, 0.25, True, 0.75, 'nearest'),
            ('F soft a, cells>=.5, AA @1.0', '1', 0.5, 0.25, True, 1.0, 'linear'),
            ('G binary a, cells>=.25, no AA @1.0', '0', 0.25, 0.5, False, 1.0, 'nearest')]
Lcache = {}
c = syn.origin; Cs = np.array([f['C'] for f in syn.real]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor)); fx = syn.real[0]['fx'] * W / 960
for name, am, mp, thr, aa, scale, up in variants:
    key = (am, mp)
    if key not in Lcache: Lcache[key] = build(am, mp)
    L = Lcache[key]; Sm = [F.layer_samples(l) for l in L]; rows = []
    for pitch in (54, 30):
        for a in range(-150, 180, 60):
            cam = cams07.orbit(c, R, [a], pitch, fx, W, H)[0]
            cov = gt_cov(cam, W, H)
            ws, hs = int(round(W * scale)), int(round(H * scale)); cs = F.Cam(cam.R, cam.C, cam.fx * scale, cam.fy * scale, (cam.cx + .5) * scale - .5, (cam.cy + .5) * scale - .5)
            im, al = render_view(L, Sm, cs, ws, hs, thr, aa); im, al = finish(im, al, scale, up)
            rows.append(metrics(al, cov))
    m = {k: float(np.mean([r[k] for r in rows])) for k in rows[0]}
    print(f'{name:38s}', ' '.join(f'{k} {v:.3f}' for k, v in m.items()), flush=True)
