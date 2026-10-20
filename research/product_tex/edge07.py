"""Outline experiment on the synthetic GT scene with TRUE depth (so only mask / alpha / AA / render-scale effects remain).
 A  current:    nearest-upsampled binary texel alpha, alpha test .5, hard alive mask, render scale .75 + nearest upscale (app browse)
 A1 current at scale 1.0
 B  soft texel alpha (bilinear-upsampled mask)  hard alive, scale .75 nearest
 C  soft alpha + coverage AA (alpha output = weighted contributor alpha, test .25), scale .75 bilinear upscale
 D  soft alpha + coverage AA, scale 1.0
 E  soft alpha (sharpened x2) + coverage AA, scale 1.0
"""
import sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, cv2
import syn_env as E, h07, cams07, fix06 as F, texsplat as TS, synth07 as S

syn = E.Syn()
W, H = 480, 360


def build(alpha_mode):
    os.environ['ALPHA_SOFT'] = alpha_mode
    return syn.build(Zuse=syn.Zgt)


def render_view(L, Sm, cam, W, H, thr, aa):
    ids = list(range(len(L))); rgb = np.zeros((len(L), H, W, 3), np.float32); z = np.full((len(L), H, W), np.inf, np.float32); al = np.zeros((len(L), H, W), np.float32)
    for i in ids:
        s = L[i].get('_S') or F.surf(L[i]); L[i]['_S'] = s
        im, zb, ap = TS.render_layer_zba(s, cam, W, H, 0.04, 1, thr)
        zz = zb.copy(); zz[zz > 1e8] = np.inf; rgb[i] = im; z[i] = zz; al[i] = ap
    sel, w, _ = F.coarse_select(L, Sm, cam, W, H, kmax=8, seed=5); sel = np.array(sel)
    import fix06_final as FF
    im, A, cnt = FF.compose_new(rgb[sel], z[sel], w)
    zb = F.LAST_ZB; fin = np.isfinite(z[sel]); zbs = np.where(np.isfinite(zb), zb, 0)
    tight = fin & (np.abs(np.where(fin, z[sel], 0) - zbs[None]) < 0.06 * np.maximum(zbs, 0.3)[None])
    ww = tight * w[:, None, None]
    cov = (al[sel] * ww).sum(0) / np.maximum(ww.sum(0), 1e-9)
    alpha = (A > 0.5).astype(np.float32) * (np.clip(cov, 0, 1) if aa else 1.0)
    return im, alpha


def finish(im, alpha, scale, up):
    """upscale a render made at `scale` to W x H the way the display would (colour premultiplied by alpha)."""
    if scale == 1.0: return im, alpha
    pm = np.dstack([im * alpha[..., None], alpha])
    flag = cv2.INTER_NEAREST if up == 'nearest' else cv2.INTER_LINEAR
    big = cv2.resize(pm, (W, H), interpolation=flag)
    a = big[..., 3]; rgb = big[..., :3] / np.maximum(a, 1e-4)[..., None]
    return rgb, a


import pickle
_GT = {}
def gt_cov(cam, W, H, ss=3):
    key = (round(float(cam.C[0]), 4), round(float(cam.C[1]), 4), round(float(cam.C[2]), 4), W)
    if key in _GT: return _GT[key]
    r = _gt_cov(cam, W, H, ss); _GT[key] = r; return r


def _gt_cov(cam, W, H, ss=3):
    c = F.Cam(cam.R, cam.C, cam.fx * ss, cam.fy * ss, (cam.cx + .5) * ss - .5, (cam.cy + .5) * ss - .5)
    rgb, z, hit = S.render(c.R, c.C, c.fx, c.fy, c.cx, c.cy, W * ss, H * ss)
    return cv2.resize(hit.astype(np.float32), (W, H), interpolation=cv2.INTER_AREA), cv2.resize(rgb, (W, H), interpolation=cv2.INTER_AREA)


def metrics(alpha, cov):
    band = cv2.dilate(((cov > 0.02) & (cov < 0.98)).astype(np.uint8), np.ones((5, 5), np.uint8)) > 0
    err = float(np.abs(alpha - cov)[band].mean())
    iou = float(((alpha > 0.5) & (cov > 0.5)).sum() / max(((alpha > 0.5) | (cov > 0.5)).sum(), 1))
    def perim(m):
        cs, _ = cv2.findContours(m.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        return sum(cv2.arcLength(c, True) for c in cs) if cs else 0
    jag = perim(alpha > 0.5) / max(perim(cv2.GaussianBlur(cov, (0, 0), 1.2) > 0.5), 1)
    hole = float(((alpha < 0.5) & (cov > 0.98) & ~band).sum() / max((cov > 0.98).sum(), 1))
    # edge width: number of pixels in the transition (0.1<alpha<0.9) per boundary pixel (soft edges are ~1-2 px, hard ones 0)
    trans = float(((alpha > 0.1) & (alpha < 0.9)).sum() / max(perim(alpha > 0.5), 1))
    return dict(band_err=err, iou=iou, jag=jag, hole=hole, trans=trans)


variants = [('A current (.75 nearest)', '0', 0.5, False, 0.75, 'nearest'), ('A1 current @1.0', '0', 0.5, False, 1.0, 'nearest'),
            ('B soft alpha .75 nearest', '1', 0.5, False, 0.75, 'nearest'), ('C soft+AA .75 bilinear', '1', 0.25, True, 0.75, 'linear'),
            ('D soft+AA @1.0', '1', 0.25, True, 1.0, 'linear'), ('E sharp soft+AA @1.0', '2', 0.25, True, 1.0, 'linear'),
            ('F soft+AA .75 nearest', '1', 0.25, True, 0.75, 'nearest')]
Lcache = {}
c = syn.origin; Cs = np.array([f['C'] for f in syn.real]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor)); fx = syn.real[0]['fx'] * W / 960
res = {}
for name, am, thr, aa, scale, up in variants:
    if am not in Lcache: Lcache[am] = build(am)
    L = Lcache[am]; Sm = [F.layer_samples(l) for l in L]; rows = []
    for pitch in (54, 30):
        for a in range(-150, 180, 60):
            cam = cams07.orbit(c, R, [a], pitch, fx, W, H)[0]
            cov, grgb = gt_cov(cam, W, H)
            ws, hs = int(round(W * scale)), int(round(H * scale)); cs = F.Cam(cam.R, cam.C, cam.fx * scale, cam.fy * scale, (cam.cx + .5) * scale - .5, (cam.cy + .5) * scale - .5)
            im, al = render_view(L, Sm, cs, ws, hs, thr, aa)
            im, al = finish(im, al, scale, up)
            rows.append(metrics(al, cov))
    res[name] = {k: float(np.mean([r[k] for r in rows])) for k in rows[0]}
    print(f'{name:26s}', ' '.join(f'{k} {v:.3f}' for k, v in res[name].items()), flush=True)
