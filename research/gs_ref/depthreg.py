"""Causal initial-depth registration for the space Gaussian initialisation (PC study).
For frame i only PAST, non-held frames are references (held-out frames are never references and are never registered).
The original depth is kept (Z); the registered depth (Zr) is a separate array used only to initialise Gaussians.
Per 8x8 cell (320x240 depth grid): scale s in [0.85, 1.15] applied along the pixel rays; cost = ZNCC of the window against the reference photos (two best refs),
3x3 cell aggregation, parabola refinement. A cell is changed ONLY if all hold: enough valid depth, photo contrast, low cost, no depth boundary inside the cell window,
and the reprojected point is visible in the reference (reference depth agrees within 12 %, i.e. no occlusion / no foreign surface). Everything else keeps its original depth.
The change in neighbouring-depth agreement is a SELF-CONSISTENCY measure, not depth accuracy."""
import numpy as np, cv2

CELL = 8
SCALES = np.linspace(0.85, 1.15, 16)


def gray(img): return cv2.cvtColor(img, cv2.COLOR_RGB2GRAY).astype(np.float32) / 255


def bil(img, u, v):
    h, w = img.shape
    u0 = np.floor(u).astype(int); v0 = np.floor(v).astype(int); fu = u - u0; fv = v - v0
    u0c = np.clip(u0, 0, w - 2); v0c = np.clip(v0, 0, h - 2)
    a = img[v0c, u0c]; b = img[v0c, u0c + 1]; c = img[v0c + 1, u0c]; d = img[v0c + 1, u0c + 1]
    return (a * (1 - fu) + b * fu) * (1 - fv) + (c * (1 - fu) + d * fu) * fv


def pick_refs(D, i, ok, kmax=4, dmin=0.03, dmax=0.35, ang=35):
    out = []
    for j in range(i - 1, -1, -1):
        if not ok(j): continue
        d = np.linalg.norm(D['C'][j] - D['C'][i]); a = np.degrees(np.arccos(np.clip(D['R'][i][:, 2] @ D['R'][j][:, 2], -1, 1)))
        if dmin <= d <= dmax and a < ang: out.append((d + 0.004 * a, j))
    out.sort(); return [j for _, j in out[:kmax]]


def register_frame(D, i, refs, K, imgs_g, Z, win=12, ns=6, min_contrast=0.02, max_cost=0.5, max_edge=0.06, occl_tol=0.12):
    H, W = Z[i].shape; fx, fy, cx, cy = K[i]; Zi = Z[i]
    rows, cols = H // CELL, W // CELL
    off = (np.arange(ns) + 0.5) * (win / ns) - win / 2 + CELL / 2
    cost = np.full((rows, cols, len(SCALES)), np.nan, np.float32); contrast = np.zeros((rows, cols), np.float32); edge_ok = np.zeros((rows, cols), bool)
    Ri, Ci = D['R'][i], D['C'][i]; g_i = imgs_g[i]
    cr, cc = np.mgrid[0:rows, 0:cols]; x0 = (cc * CELL)[..., None, None]; y0 = (cr * CELL)[..., None, None]
    uu = np.clip(x0 + off[None, None, None, :], 0, W - 1.001) * np.ones((1, 1, ns, 1)); vv = np.clip(y0 + off[None, None, :, None], 0, H - 1.001) * np.ones((1, 1, 1, ns))
    uu = np.broadcast_to(uu, (rows, cols, ns, ns)); vv = np.broadcast_to(vv, (rows, cols, ns, ns))
    z = bil(Zi, uu, vv); zmin_ok = Zi[np.clip(vv.astype(int), 0, H - 1), np.clip(uu.astype(int), 0, W - 1)] > 0.2
    valid = (z > 0.2) & zmin_ok & (bil((Zi > 0.2).astype(np.float32), uu, vv) > 0.99)
    a = bil(g_i, uu, vv); nv = valid.sum((2, 3))
    am = np.where(valid, a, 0).sum((2, 3)) / np.maximum(nv, 1); contrast = np.sqrt(np.where(valid, (a - am[..., None, None]) ** 2, 0).sum((2, 3)) / np.maximum(nv, 1))
    # depth boundary inside the cell window: relative depth spread
    zz = np.where(valid, z, np.nan); spread = (np.nanmax(zz.reshape(rows, cols, -1), -1) - np.nanmin(zz.reshape(rows, cols, -1), -1)) / np.maximum(np.nanmedian(zz.reshape(rows, cols, -1), -1), 1e-3)
    edge_ok = np.nan_to_num(spread, nan=9) < max_edge
    ray = np.stack([(uu - cx) / fx, (vv - cy) / fy, np.ones_like(uu)], -1) @ Ri.T            # world directions
    best_two = [np.full((rows, cols, len(SCALES)), 2.0, np.float32) for _ in range(2)]
    minv = int(0.6 * ns * ns)
    for j in refs:
        Rj, Cj = D['R'][j], D['C'][j]; fxj, fyj, cxj, cyj = K[j]; gj = imgs_g[j]; Zj = Z[j]
        for si, s in enumerate(SCALES):
            X = Ci + ray * (z * s)[..., None]
            pc = (X - Cj) @ Rj; zj = pc[..., 2]
            uj = fxj * pc[..., 0] / np.maximum(zj, 1e-3) + cxj; vj = fyj * pc[..., 1] / np.maximum(zj, 1e-3) + cyj
            inside = valid & (zj > 0.2) & (uj >= 1) & (vj >= 1) & (uj < W - 2) & (vj < H - 2)
            ucl = np.clip(uj, 0, W - 1.001); vcl = np.clip(vj, 0, H - 1.001)
            zref = Zj[np.clip(np.round(vcl).astype(int), 0, H - 1), np.clip(np.round(ucl).astype(int), 0, W - 1)]
            vis = inside & (zref > 0.2) & (np.abs(zref - zj) < occl_tol * zj)                 # not occluded, not a foreign surface
            b = bil(gj, ucl, vcl); cnt = vis.sum((2, 3))
            am2 = np.where(vis, a, 0).sum((2, 3)) / np.maximum(cnt, 1); bm = np.where(vis, b, 0).sum((2, 3)) / np.maximum(cnt, 1)
            cov = np.where(vis, (a - am2[..., None, None]) * (b - bm[..., None, None]), 0).sum((2, 3))
            va = np.where(vis, (a - am2[..., None, None]) ** 2, 0).sum((2, 3)); vb = np.where(vis, (b - bm[..., None, None]) ** 2, 0).sum((2, 3))
            c = np.where(cnt >= minv, 1 - cov / np.sqrt(va * vb + 1e-6), 2.0).astype(np.float32)
            # keep the two lowest over refs
            lo, hi = best_two
            new_lo = np.minimum(lo[..., si], c); new_hi = np.where(c < lo[..., si], lo[..., si], np.minimum(hi[..., si], c))
            lo[..., si] = new_lo; hi[..., si] = new_hi
    cs = 0.5 * (best_two[0] + best_two[1]); cs = np.where(cs >= 2.0, np.nan, cs)
    # 3x3 aggregation over cells
    agg = np.stack([cv2.blur(np.nan_to_num(cs[..., s], nan=0), (3, 3)) / np.maximum(cv2.blur((~np.isnan(cs[..., s])).astype(np.float32), (3, 3)), 1e-3) for s in range(len(SCALES))], -1)
    cntv = np.stack([cv2.blur((~np.isnan(cs[..., s])).astype(np.float32), (3, 3)) for s in range(len(SCALES))], -1)
    agg = np.where(cntv > 0.05, agg, 2.0)
    tot = agg + 0.3 * 0.02 * ((SCALES - 1) / 0.03) ** 2
    bi = tot.argmin(-1); ar = np.arange(len(SCALES))
    cb = np.take_along_axis(agg, bi[..., None], -1)[..., 0]
    bic = np.clip(bi, 1, len(SCALES) - 2)
    ya = np.take_along_axis(tot, (bic - 1)[..., None], -1)[..., 0]; yb = np.take_along_axis(tot, bic[..., None], -1)[..., 0]; yc = np.take_along_axis(tot, (bic + 1)[..., None], -1)[..., 0]
    den = ya - 2 * yb + yc; dl = np.where(np.abs(den) > 1e-6, 0.5 * (ya - yc) / den, 0)
    sval = np.where((bi > 0) & (bi < len(SCALES) - 1), SCALES[bic] + np.clip(dl, -1, 1) * (SCALES[1] - SCALES[0]), SCALES[bi])
    info = (contrast > min_contrast) & (cb < max_cost) & edge_ok & (nv >= 0.6 * ns * ns)
    # median over informative neighbours only; cells without enough informative support stay unchanged
    sm = np.where(info, sval, np.nan); out = np.ones((rows, cols), np.float32)
    for r in range(rows):
        for c in range(cols):
            if not info[r, c]: continue
            w = sm[max(0, r - 1):r + 2, max(0, c - 1):c + 2]; w = w[~np.isnan(w)]
            out[r, c] = np.median(w)
    # per-pixel scale: bilinear interpolation of the informative cell scales, applied only inside informative cells
    m = info.astype(np.float32); num = cv2.resize(out * m, (W, H), interpolation=cv2.INTER_LINEAR); dn = cv2.resize(m, (W, H), interpolation=cv2.INTER_LINEAR)
    smap = np.where(dn > 1e-3, num / np.maximum(dn, 1e-3), 1.0)
    inside_info = cv2.resize(m, (W, H), interpolation=cv2.INTER_NEAREST) > 0
    Zr = np.where(inside_info & (Zi > 0), Zi * smap, Zi).astype(np.float32)
    return Zr, dict(informative=float(info.mean()), median_shift=float(np.median(np.abs(out[info] - 1))) if info.any() else 0.0, refs=len(refs))


def register_all(D, K, Z, held, kmax=4):
    n = len(Z); imgs_g = [gray(D['imgs320'][i]) for i in range(n)]; Zr = Z.copy(); stats = []
    ok = lambda j: (not held(j)) and Z[j].max() > 0
    for i in range(n):
        if held(i) or Z[i].max() <= 0: stats.append(None); continue
        refs = pick_refs(D, i, ok, kmax)
        if len(refs) < 2: stats.append(dict(informative=0.0, median_shift=0.0, refs=len(refs))); continue
        Zr[i], st = register_frame(D, i, refs, K, imgs_g, Z); stats.append(st)
    return Zr, stats


def consistency(D, K, Z, held, refs_fn, sample=4000, seed=0):
    """median relative disagreement between frame i's depth and the past references' own depth at the reprojected points (self-consistency only)."""
    rng = np.random.RandomState(seed); vals = []
    n = len(Z); H, W = Z[0].shape
    for i in range(n):
        if held(i) or Z[i].max() <= 0: continue
        refs = refs_fn(i)
        if not refs: continue
        ys, xs = np.nonzero(Z[i] > 0.2)
        if len(ys) == 0: continue
        sel = rng.choice(len(ys), min(sample, len(ys)), replace=False); y, x = ys[sel], xs[sel]
        fx, fy, cx, cy = K[i]; z = Z[i][y, x]
        X = D['C'][i] + np.stack([(x - cx) / fx * z, (y - cy) / fy * z, z], 1) @ D['R'][i].T
        for j in refs:
            pc = (X - D['C'][j]) @ D['R'][j]; fxj, fyj, cxj, cyj = K[j]
            u = fxj * pc[:, 0] / pc[:, 2] + cxj; v = fyj * pc[:, 1] / pc[:, 2] + cyj
            ok = (pc[:, 2] > 0.2) & (u >= 1) & (v >= 1) & (u < W - 2) & (v < H - 2)
            zr = Z[j][np.round(v[ok]).astype(int), np.round(u[ok]).astype(int)]
            good = zr > 0.2; d = np.abs(zr[good] - pc[ok, 2][good]) / pc[ok, 2][good]; d = d[d < 0.15]     # same-surface pairs only (no occlusion pairs)
            vals.append(d)
    d = np.concatenate(vals); return dict(median_rel=float(np.median(d)), p90_rel=float(np.percentile(d, 90)), pairs=int(len(d)))
