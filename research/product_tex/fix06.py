"""Test_06 analysis harness (PC reference, local data only): read the saved .kmots, render every layer once per view, and evaluate selection / blending strategies on the buffers.
Never commit data. The app implementation is Swift (Gonggi/Experiments/TexLayers); this file mirrors the rules for comparison."""
import os, sys, json, struct
import numpy as np, cv2
import tex_data, texsplat as TS


class Cam:
    def __init__(self, R, C, fx, fy, cx, cy): self.R = R; self.C = C; self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy


def load_kmots(path):
    get, toc = tex_data.read_container(path)
    out = []
    for name in sorted(n for n in toc if n.startswith('layers/')):
        d = get(name); assert d[:4] == b'TSL1'
        off = 4
        lid, cnt = struct.unpack_from('<iI', d, off); off += 8
        ts = struct.unpack_from('<d', d, off)[0]; off += 8
        r = np.array(struct.unpack_from('<9f', d, off), np.float32).reshape(3, 3).T; off += 36   # columns -> R
        c = np.array(struct.unpack_from('<3f', d, off), np.float32); off += 12
        fx, fy, cx, cy = struct.unpack_from('<4f', d, off); off += 16
        w, h = struct.unpack_from('<II', d, off); off += 8
        gain = np.array(struct.unpack_from('<3f', d, off), np.float32); off += 12
        corners = np.frombuffer(d, np.float32, cnt * 16, off).reshape(cnt, 4, 4)[:, :, :3].copy(); off += cnt * 64
        tex = np.frombuffer(d, np.uint8, cnt * 256, off).reshape(cnt, 8, 8, 4).astype(np.float32) / 255; off += cnt * 256
        cells = np.frombuffer(d, np.uint16, cnt, off).copy()
        out.append(dict(id=lid, ts=ts, R=r, C=c, fx=fx, fy=fy, cx=cx, cy=cy, w=w, h=h, gain=gain, corners=corners, tex=tex, cells=cells))
    out.sort(key=lambda l: l['id'])
    return out


def surf(l):
    S = TS.Surfels.__new__(TS.Surfels)
    S.P = l['corners'].mean(1).astype(np.float32); S.corners = l['corners']; S.tex = l['tex']
    return S


def render_all(layers, cam, W, H, grow=0.04, only=None, cull=0):
    """Per-layer z-buffered, alpha-tested render of every layer (GPU-equivalent per-layer pass)."""
    ids = list(range(len(layers))) if only is None else list(only)
    rgb = np.zeros((len(ids), H, W, 3), np.float32); z = np.full((len(ids), H, W), np.inf, np.float32)
    for k, i in enumerate(ids):
        S = layers[i].get('_S') or surf(layers[i]); layers[i]['_S'] = S
        im, zb = TS.render_layer_zb(S, cam, W, H, grow, cull)
        rgb[k] = im; zz = zb.copy(); zz[zz > 1e8] = np.inf; z[k] = zz
    return ids, rgb, z


def score_of(l, cam, wd=0.3):
    return float(np.linalg.norm(l['C'] - cam.C) + wd * (1 - float(l['R'][:, 2] @ cam.R[:, 2])))


def blend_current(ids, rgb, z, sc, k=5, decay=6.0, tol=0.08):
    """What 3.0(24) does: the K best-scoring layers of the whole set, nearest valid depth defines the surface, layers within 8% of it are averaged."""
    order = np.argsort([sc[i] for i in ids])[:k]
    zz = z[order]; w = np.exp(-decay * np.array([sc[ids[j]] for j in order], np.float32))
    dmin = zz.min(0)
    A = np.isfinite(dmin)
    cons = np.isfinite(zz) & (np.abs(zz - dmin[None]) < tol * np.maximum(dmin, 0.3)[None])
    ww = cons * w[:, None, None]
    den = ww.sum(0)
    out = (rgb[order] * ww[..., None]).sum(0) / np.maximum(den, 1e-9)[..., None]
    return out * A[..., None], A.astype(np.float32)


# ---------------------------------------------------------------- strategies (operate on per-layer buffers of ONE view)
def _wmean(rgb, w):
    den = w.sum(0)
    return (rgb * w[..., None]).sum(0) / np.maximum(den, 1e-9)[..., None], den


HYB_VAR = 0.02
LAST_CNT = None
LAST_ZB = None


def blend_consensus(rgb, z, w, tol=0.06, mode='avg'):
    """Pick the surface that most weight agrees on (not the nearest depth), average only layers on that surface ('avg') or take the best single one ('rep')."""
    K = z.shape[0]
    fin = np.isfinite(z); zf = np.where(fin, z, 0)
    support = np.zeros(z.shape, np.float32)                        # support[k] = total weight of layers within tol of z[k]
    for k in range(K):
        for j in range(K):
            agree = fin[j] & fin[k] & (np.abs(z[j] - z[k]) < tol * np.maximum(z[k], 0.3))
            support[k] += np.where(agree, w[j], 0)
    support = np.where(fin, support, -1)
    # prefer higher support; tie-break nearer
    key = support - 1e-3 * np.where(fin, z, 0)
    best = key.argmax(0)                                           # (H,W)
    zb = np.take_along_axis(zf, best[None], 0)[0]
    cons = fin & (np.abs(z - zb[None]) < tol * np.maximum(zb, 0.3)[None])
    ww = cons * w
    A = fin.any(0)
    global LAST_CNT, LAST_ZB
    LAST_CNT = cons.sum(0); LAST_ZB = zb
    if mode == 'rep':
        kk = (ww).argmax(0)
        out = np.take_along_axis(rgb, kk[None, ..., None].repeat(3, -1), 0)[0]
    elif mode == 'hyb':
        out, den = _wmean(rgb, ww)
        var = (((rgb - out[None]) ** 2).sum(-1) * ww).sum(0) / np.maximum(den, 1e-9)
        kk = (ww).argmax(0)
        rep = np.take_along_axis(rgb, kk[None, ..., None].repeat(3, -1), 0)[0]
        out = np.where((var > HYB_VAR)[..., None], rep, out)
    else:
        out, _ = _wmean(rgb, ww)
    return out * A[..., None], A.astype(np.float32), support.max(0)


def pick_cov(ids, z, L, cam, k0=5, kmax=8, decay=6.0, min_gain=0.02, region=None):
    """Coverage-aware selection: start from the nearest layers, add further layers (up to kmax) that cover pixels still uncovered; order by view score."""
    sc = np.array([score_of(L[i], cam) for i in ids], np.float32)
    order = list(np.argsort(sc))
    chosen = order[:k0]
    cov = np.isfinite(z[chosen]).any(0)
    reg = np.ones_like(cov) if region is None else region
    for j in order[k0:]:
        if len(chosen) >= kmax: break
        gain = (np.isfinite(z[j]) & ~cov & reg).sum() / max(reg.sum(), 1)
        if gain >= min_gain:
            chosen.append(j); cov |= np.isfinite(z[j])
    w = np.exp(-decay * sc[chosen]).astype(np.float32)
    return chosen, w


def psnr_masked(img, gt, m): return float(-10 * np.log10(max(((img - gt) ** 2)[m].mean(), 1e-12)))


# ---------------------------------------------------------------- coarse (CPU-cheap) selection: what the app can do per frame without rendering every layer
GX, GY = 40, 30


def layer_samples(l, n=400):
    c = l['corners']; N = len(c)
    idx = np.arange(N) if N <= n else np.linspace(0, N - 1, n).astype(int)
    P = c[idx].mean(1); nrm = np.cross(c[idx, 1] - c[idx, 0], c[idx, 2] - c[idx, 0]).astype(np.float32)
    nrm /= np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-9)
    return P.astype(np.float32), nrm


def coarse_project(l, cam, W, H, samples):
    """Per coarse cell: nearest front-facing sample depth of this layer (inf = none)."""
    P, nrm = samples
    pc = (P - cam.C) @ cam.R
    z = pc[:, 2]
    front = (nrm * (P - cam.C)).sum(1) > 0.0           # n . (c0 - C) > 0  => viewed from the capture side
    fwd = z > 0.1
    u = cam.fx * pc[:, 0] / np.maximum(z, 1e-6) + cam.cx; v = cam.fy * pc[:, 1] / np.maximum(z, 1e-6) + cam.cy
    ok = front & fwd & (u >= 0) & (u < W) & (v >= 0) & (v < H)
    cell = (np.minimum(GY - 1, (v[ok] * GY / H).astype(int)) * GX + np.minimum(GX - 1, (u[ok] * GX / W).astype(int)))
    d = np.full(GX * GY, np.inf, np.float32); np.minimum.at(d, cell, z[ok].astype(np.float32))
    return d


def coarse_select(L, samples, cam, W, H, kmax=8, kmin=3, decay=6.0, tol=0.08, prev=None, bonus=0.1, min_gain=0.012, cand=None, qf=0.4, seed=0):
    n = len(L)
    sc = np.array([score_of(l, cam) for l in L], np.float32); w = np.exp(-decay * sc).astype(np.float32)
    pool = np.arange(n) if cand is None else np.argsort(sc)[:cand]
    if prev is not None and cand is not None: pool = np.unique(np.concatenate([pool, np.array(sorted(prev), int)]))
    D = np.full((n, GX * GY), np.inf, np.float32)
    for i in pool: D[i] = coarse_project(L[i], cam, W, H, samples[i])      # (n, cells)
    fin = np.isfinite(D)
    support = np.zeros(D.shape, np.float32)
    for k in pool:
        agree = fin & fin[k][None] & (np.abs(D - D[k][None]) < tol * np.maximum(D[k][None], 0.3))
        support[k] = (agree * w[:, None]).sum(0)
    support = np.where(fin, support, -1)
    best = (support - 1e-3 * np.where(fin, D, 0)).argmax(0)
    zstar = np.take_along_axis(np.where(fin, D, np.inf), best[None], 0)[0]
    cons = fin & (np.abs(D - zstar[None]) < tol * np.maximum(zstar[None], 0.3))
    nlay = cons.sum(0)
    target = np.isfinite(zstar) & (nlay >= 2)           # corroborated surface cells
    covered = np.zeros(D.shape[1], bool); chosen = []
    if seed > 0:
        sc_adj = sc - (0.03 * np.array([1.0 if (prev is not None and i in prev) else 0.0 for i in range(n)], np.float32))
        chosen = [int(j) for j in np.argsort(sc_adj)[:seed]]
        for j in chosen: covered |= cons[j]
    qual = np.where(sc < 0, 0, w)
    for it in range(len(chosen), kmax):
        gains = ((cons & target[None] & ~covered[None]).sum(1) / max(target.sum(), 1)) * (qf + w / max(w.max(), 1e-6))
        if prev is not None: gains = gains + np.array([bonus if i in prev else 0 for i in range(n)]) * (gains > 0)
        gains[chosen] = -1
        j = int(gains.argmax())
        if it >= kmin and gains[j] < min_gain: break
        if gains[j] <= 0 and it >= 1: break
        chosen.append(j); covered |= cons[j]
    if not chosen: chosen = list(np.argsort(sc)[:kmin])
    return chosen, w[chosen], float(covered[target].mean()) if target.any() else 1.0
