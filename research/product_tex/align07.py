"""Layer registration prototypes (PC). Operates on layer dicts (corners (N,4,3), tex (N,8,8,4), cells, R, C, fx.., w, h) = exactly what a .kmots holds.
A cell is only moved ALONG ITS OWN CAMERA RAY (homothetic scaling of the quad about the layer's camera centre): the layer still reproduces its own photo exactly,
only where the surface sits in 3D changes. Textures are never touched.
 photo_cost : ZNCC of the cell window (own photo) against the neighbour photos at hypothesised depth scales s
 consensus  : neighbours' depth at the same ray (rendered z in own camera)
"""
import numpy as np, cv2
import fix06 as F, texsplat as TS

CELL = 8


def own_photo(l, scale=1):
    """Layer rendered in its own camera = its photo on the cells' texels. Returns gray (h,w) float, valid (h,w) bool, z (h,w) of the nearest surface."""
    W, H = l['w'] // scale, l['h'] // scale
    cam = F.Cam(l['R'], l['C'], l['fx'] / scale, l['fy'] / scale, (l['cx'] + .5) / scale - .5, (l['cy'] + .5) / scale - .5)
    S = TS.Surfels.__new__(TS.Surfels); S.P = l['corners'].mean(1).astype(np.float32); S.corners = l['corners']; S.tex = l['tex']
    im, zb = TS.render_layer_zb(S, cam, W, H, 0.0, 0)
    valid = zb < 1e8
    g = cv2.cvtColor((np.clip(im, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY).astype(np.float32) / 255
    z = zb.copy(); z[~valid] = np.inf
    return g, valid, z, im


def cell_xy(l):
    cols = l['w'] // CELL
    return (l['cells'] % cols) * CELL, (l['cells'] // cols) * CELL


def cell_geom(l):
    c = l['corners']; ctr = c.mean(1)
    n = np.cross(c[:, 1] - c[:, 0], c[:, 2] - c[:, 0]); n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-9)
    return ctr, n


def neighbours(L, i, kmax=6, dmin=0.03, dmax=0.35, ang=35):
    li = L[i]; out = []
    for j, lj in enumerate(L):
        if j == i: continue
        d = np.linalg.norm(lj['C'] - li['C']); a = np.degrees(np.arccos(np.clip(li['R'][:, 2] @ lj['R'][:, 2], -1, 1)))
        if dmin <= d <= dmax and a < ang: out.append((d + 0.004 * a, j))
    out.sort()
    return [j for _, j in out[:kmax]]


def bilinear(img, u, v):
    h, w = img.shape
    u0 = np.floor(u).astype(int); v0 = np.floor(v).astype(int); fu = u - u0; fv = v - v0
    u0c = np.clip(u0, 0, w - 2); v0c = np.clip(v0, 0, h - 2)
    a = img[v0c, u0c]; b = img[v0c, u0c + 1]; c = img[v0c + 1, u0c]; d = img[v0c + 1, u0c + 1]
    return (a * (1 - fu) + b * fu) * (1 - fv) + (c * (1 - fu) + d * fu) * fv


def photo_costs(L, i, photos, scales, nb, win=16, ns=6):
    """cost[N, S]: robust mean over neighbours of (1-ZNCC) of the cell window; conf[N]: window contrast (texture-poor cells carry no photometric information)."""
    li = L[i]; gi = photos[i][0]; vi = photos[i][1]
    ctr, n = cell_geom(li); x0, y0 = cell_xy(li); N = len(ctr); S = len(scales)
    # window sample pixel coordinates (pixel centres in the layer's own image)
    off = (np.arange(ns) + 0.5) * (win / ns) - win / 2 + CELL / 2
    ou, ov = np.meshgrid(off, off); ou = ou.ravel(); ov = ov.ravel(); M = len(ou)
    u = x0[:, None] + ou[None]; v = y0[:, None] + ov[None]                       # (N,M)
    ok_i = (u >= 0) & (u < li['w'] - 1) & (v >= 0) & (v < li['h'] - 1)
    a = np.where(ok_i, bilinear(gi, np.clip(u, 0, li['w'] - 2), np.clip(v, 0, li['h'] - 2)), 0)
    vi_s = np.where(ok_i, bilinear(vi.astype(np.float32), np.clip(u, 0, li['w'] - 2), np.clip(v, 0, li['h'] - 2)) > 0.99, False)
    ray = np.stack([(u - li['cx']) / li['fx'], (v - li['cy']) / li['fy'], np.ones_like(u)], -1) @ li['R'].T          # world directions (N,M,3)
    am = (a * vi_s).sum(1) / np.maximum(vi_s.sum(1), 1); av = np.where(vi_s, (a - am[:, None]) ** 2, 0).sum(1) / np.maximum(vi_s.sum(1), 1)
    conf = np.sqrt(av)
    costs = np.full((N, S, len(nb)), 2.0, np.float32)
    nd = (n[:, None, :] * ray).sum(-1)                                              # n . d
    for si, s in enumerate(scales):
        ctr_s = li['C'] + s * (ctr - li['C'])
        t = ((n * (ctr_s - li['C'])).sum(1))[:, None] / np.where(np.abs(nd) < 1e-6, 1e-6, nd)
        X = li['C'] + t[..., None] * ray                                              # (N,M,3)
        for jj, j in enumerate(nb):
            lj = L[j]; gj, vj = photos[j][0], photos[j][1]
            pc = (X - lj['C']) @ lj['R']; z = pc[..., 2]
            uj = lj['fx'] * pc[..., 0] / np.maximum(z, 1e-3) + lj['cx']; vj_ = lj['fy'] * pc[..., 1] / np.maximum(z, 1e-3) + lj['cy']
            inside = (z > 0.1) & (uj >= 1) & (uj < lj['w'] - 2) & (vj_ >= 1) & (vj_ < lj['h'] - 2) & vi_s
            ucl = np.clip(uj, 0, lj['w'] - 2); vcl = np.clip(vj_, 0, lj['h'] - 2)
            okv = inside & (bilinear(vj.astype(np.float32), ucl, vcl) > 0.99)
            b = bilinear(gj, ucl, vcl)
            cnt = okv.sum(1)
            bm = (b * okv).sum(1) / np.maximum(cnt, 1); am2 = (a * okv).sum(1) / np.maximum(cnt, 1)
            cov = ((a - am2[:, None]) * (b - bm[:, None]) * okv).sum(1); va = (((a - am2[:, None]) ** 2) * okv).sum(1); vb = (((b - bm[:, None]) ** 2) * okv).sum(1)
            ncc = cov / np.sqrt(va * vb + 1e-6)
            costs[:, si, jj] = np.where(cnt >= 0.6 * M, 1 - ncc, 2.0)
    cs = np.sort(costs, axis=2)[:, :, :2].mean(2) if len(nb) >= 2 else costs[:, :, 0]
    return cs, conf


def consensus_depth(L, i, zmaps, nb, tau_rel=0.12):
    """Per cell: neighbours' depth along the cell-centre ray (inf where none)."""
    li = L[i]; ctr, n = cell_geom(li); x0, y0 = cell_xy(li)
    pc = (ctr - li['C']) @ li['R']; d = pc[:, 2]
    out = []
    for j in nb:
        lj = L[j]; pj = (ctr - lj['C']) @ lj['R']; zj = pj[:, 2]
        uj = lj['fx'] * pj[:, 0] / np.maximum(zj, 1e-3) + lj['cx']; vj = lj['fy'] * pj[:, 1] / np.maximum(zj, 1e-3) + lj['cy']
        ok = (zj > 0.1) & (uj >= 0) & (uj < lj['w']) & (vj >= 0) & (vj < lj['h'])
        zmap = zmaps[j]; zq = np.full(len(ctr), np.inf, np.float32)
        ui = np.clip(uj[ok].astype(int), 0, lj['w'] - 1); vi = np.clip(vj[ok].astype(int), 0, lj['h'] - 1)
        zq[ok] = zmap[vi // zmaps[j].shape[0] * 0 + vi, ui] if False else zmap[vi, ui]
        # j's own surface depth z_j along ITS ray through the point; to compare with i's depth, convert to i-ray depth: point on j's ray at zj_surf
        ray = np.stack([(uj - lj['cx']) / lj['fx'], (vj - lj['cy']) / lj['fy'], np.ones_like(uj)], -1) @ lj['R'].T
        Xs = lj['C'] + ray * np.where(np.isfinite(zq), zq, 0)[:, None]
        zi_of = ((Xs - li['C']) @ li['R'])[:, 2]
        out.append(np.where(np.isfinite(zq), zi_of, np.inf))
    return d, np.stack(out, 1)


def align(L, scales=np.linspace(0.88, 1.12, 13), mode='photo+cons', kmax=6, iters=1, lam=1.0, sig=0.03, min_conf=0.02, smooth=True, verbose=False, scale_div=1):
    """returns new layers (corners scaled per cell along own rays) + stats."""
    photos = [own_photo(l) for l in L]
    zmaps = [p[2] for p in photos]
    newL = [{k: v for k, v in l.items() if k != '_S'} for l in L]
    stats = []
    for it in range(iters):
        out = []
        for i in range(len(newL)):
            nb = neighbours(newL, i, kmax)
            li = newL[i]
            if len(nb) < 2: out.append(li); continue
            ctr, n = cell_geom(li); d0 = ((ctr - li['C']) @ li['R'])[:, 2]
            sc = np.ones(len(ctr), np.float32)
            d, zc = consensus_depth(newL, i, zmaps, nb)
            # consensus term: neighbours' depth in i-ray terms, supported when within 15 % of own depth
            rel = zc / d[:, None]
            supp = np.isfinite(zc) & (np.abs(rel - 1) < 0.15)
            if 'cons' in mode:
                # robust centre of {own} U {supporting neighbours}: median
                vals = np.where(supp, rel, np.nan)
                allv = np.concatenate([np.ones((len(d), 1)), vals], 1)
                med = np.nanmedian(allv, axis=1)
                cons_s = np.where(supp.sum(1) >= 1, med, 1.0)
            else:
                cons_s = np.ones(len(d))
            if 'photo' in mode:
                cs, conf = photo_costs(newL, i, photos, scales, nb)
                # penalty towards consensus point (keeps texture-poor cells near the geometric consensus)
                pen = lam * ((scales[None, :] - cons_s[:, None]) / sig) ** 2 * 0.02
                tot = cs + pen
                best = np.argmin(tot, 1); s_best = scales[best]
                # sub-sample by parabola
                bi = np.clip(best, 1, len(scales) - 2); ya = tot[np.arange(len(tot)), bi - 1]; yb = tot[np.arange(len(tot)), bi]; yc = tot[np.arange(len(tot)), bi + 1]
                den = ya - 2 * yb + yc; dl = np.where(np.abs(den) > 1e-6, 0.5 * (ya - yc) / den, 0)
                s_sub = np.where((best > 0) & (best < len(scales) - 1), scales[bi] + np.clip(dl, -1, 1) * (scales[1] - scales[0]), s_best)
                informative = (conf > min_conf) & (np.take_along_axis(cs, best[:, None], 1)[:, 0] < 0.5)
                sc = np.where(informative, s_sub, cons_s)
            else:
                sc = cons_s
            if smooth:
                sc = smooth_cells(li, sc)
            c = li['C']; newc = c + (li['corners'] - c) * sc[:, None, None]
            nl = {k: v for k, v in li.items() if k != '_S'}; nl['corners'] = newc.astype(np.float32); out.append(nl)
            stats.append((i, float(np.median(np.abs(sc - 1))), float(np.percentile(np.abs(sc - 1), 90))))
        newL = out
        # refresh depth maps for the next iteration
        photos = [(p[0], p[1], own_photo(l)[2], p[3]) for p, l in zip(photos, newL)] if iters > 1 else photos
        zmaps = [p[2] for p in photos]
    return newL, stats


def smooth_cells(l, sc, k=1):
    """3x3 cell median of the scale field (cells that are neighbours in the image grid)."""
    cols = l['w'] // CELL; idx = {int(c): n for n, c in enumerate(l['cells'])}
    out = sc.copy()
    for n, c in enumerate(l['cells']):
        cy, cx = divmod(int(c), cols); vals = []
        for dy in (-k, 0, k):
            for dx in (-k, 0, k):
                m = idx.get((cy + dy) * cols + cx + dx)
                if m is not None: vals.append(sc[m])
        out[n] = np.median(vals)
    return out


# ---------------------------------------------------------------- cost volumes + regularised solve (cheap to re-run with different parameters)
def cost_volumes(L, scales, kmax=6, win=16, ns=6, verbose=False):
    photos = [own_photo(l) for l in L]; out = []
    for i in range(len(L)):
        nb = neighbours(L, i, kmax)
        if len(nb) < 2: out.append(None); continue
        cs, conf = photo_costs(L, i, photos, scales, nb, win=win, ns=ns)
        out.append((cs, conf, nb))
        if verbose and i % 10 == 0: print('  cost layer', i, flush=True)
    return photos, out


def to_grid(l, vals, fill=np.nan):
    cols = l['w'] // CELL; rows = l['h'] // CELL
    g = np.full((rows, cols) + vals.shape[1:], fill, np.float32)
    g[l['cells'] // cols, l['cells'] % cols] = vals
    return g


def nanbox(g, k):
    """nan-aware k x k mean over the first two axes."""
    v = np.isfinite(g).astype(np.float32); z = np.where(np.isfinite(g), g, 0)
    ker = np.ones((k, k), np.float32)
    if g.ndim == 3:
        num = np.stack([cv2.filter2D(z[..., s], -1, ker, borderType=cv2.BORDER_CONSTANT) for s in range(g.shape[2])], -1)
        den = np.stack([cv2.filter2D(v[..., s], -1, ker, borderType=cv2.BORDER_CONSTANT) for s in range(g.shape[2])], -1)
    else:
        num = cv2.filter2D(z, -1, ker, borderType=cv2.BORDER_CONSTANT); den = cv2.filter2D(v, -1, ker, borderType=cv2.BORDER_CONSTANT)
    return np.where(den > 0, num / np.maximum(den, 1e-6), np.nan)


def solve(L, CV, scales, agg=3, prior=None, lam=0.3, min_conf=0.02, max_cost=0.5, fill_iters=6, med=3, want_info=False, sigma=0.0):
    """per layer: aggregate cost volume over agg x agg cells, add prior penalty, argmin (+parabola), keep only informative cells, diffuse into the rest, median-smooth."""
    res = []; infos = []
    for i, l in enumerate(L):
        if CV[i] is None: res.append(np.ones(len(l['cells']), np.float32)); infos.append(np.zeros(len(l['cells']), bool)); continue
        cs, conf, nb = CV[i]; N = len(cs)
        cols = l['w'] // CELL
        g = to_grid(l, np.where(cs >= 2.0, np.nan, cs))                                  # (rows, cols, S)
        ag = nanbox(g, agg) if agg > 1 else g
        flat = ag[l['cells'] // cols, l['cells'] % cols]                                  # (N,S)
        flat = np.where(np.isfinite(flat), flat, 2.0)
        p = np.ones(N, np.float32) if prior is None else prior[i]
        tot = flat + lam * 0.02 * ((scales[None, :] - p[:, None]) / 0.03) ** 2
        best = np.argmin(tot, 1); bi = np.clip(best, 1, len(scales) - 2); ar = np.arange(N)
        ya, yb, yc = tot[ar, bi - 1], tot[ar, bi], tot[ar, bi + 1]; den = ya - 2 * yb + yc
        dl = np.where(np.abs(den) > 1e-6, 0.5 * (ya - yc) / den, 0)
        s = np.where((best > 0) & (best < len(scales) - 1), scales[bi] + np.clip(dl, -1, 1) * (scales[1] - scales[0]), scales[best])
        okc = (conf > min_conf) & (flat[ar, best] < max_cost); infos.append(okc)
        sg = to_grid(l, np.where(okc, s, np.nan).astype(np.float32))
        # diffuse informative values into uninformative cells
        for _ in range(fill_iters):
            m = nanbox(sg, 3)
            sg = np.where(np.isfinite(sg), sg, m)
        sg = np.where(np.isfinite(sg), sg, 1.0)
        if med > 1:
            sg = cv2.medianBlur(sg.astype(np.float32), med)
        if sigma > 0:
            msk = np.zeros(sg.shape, np.float32); msk[l['cells'] // cols, l['cells'] % cols] = 1
            num = cv2.GaussianBlur(sg * msk, (0, 0), sigma); den = cv2.GaussianBlur(msk, (0, 0), sigma)
            sg = np.where(den > 1e-3, num / np.maximum(den, 1e-3), sg)
        res.append(sg[l['cells'] // cols, l['cells'] % cols].astype(np.float32))
    return (res, infos) if want_info else res


def apply(L, S):
    out = []
    for l, s in zip(L, S):
        nl = {k: v for k, v in l.items() if k != '_S'}; c = l['C']; nl['corners'] = (c + (l['corners'] - c) * s[:, None, None]).astype(np.float32); out.append(nl)
    return out


def consensus_pass(L, kmax=6, tau=0.15, min_supp=1, alpha=1.0, only=None):
    """one Jacobi pass: cell depth <- median of {own} U {neighbours' depth along the same ray within tau} (needs >= min_supp supporters); alpha blends with the old depth.
    only: optional list of boolean arrays (per layer, per cell) restricting which cells may move."""
    photos = [own_photo(l) for l in L]; zmaps = [p[2] for p in photos]; out = []
    for i, li in enumerate(L):
        nb = neighbours(L, i, kmax)
        if len(nb) < 2: out.append({k: v for k, v in li.items() if k != '_S'}); continue
        d, zc = consensus_depth(L, i, zmaps, nb)
        rel = zc / d[:, None]; supp = np.isfinite(zc) & (np.abs(rel - 1) < tau)
        vals = np.where(supp, rel, np.nan); allv = np.concatenate([np.ones((len(d), 1)), vals], 1)
        med = np.nanmedian(allv, axis=1)
        s = np.where(supp.sum(1) >= min_supp, med, 1.0)
        s = 1 + alpha * (s - 1)
        if only is not None: s = np.where(only[i], s, 1.0)
        nl = {k: v for k, v in li.items() if k != '_S'}; c = li['C']; nl['corners'] = (c + (li['corners'] - c) * s[:, None, None]).astype(np.float32); out.append(nl)
    return out
