"""PC research reference: dense-depth initialisation + on-device-style Gaussian optimisation, causal replay of a saved run.

Variants (same inputs, same depth initialisation, same insertion rule, same keyframe order; only optimisation differs):
  B  : optimisation OFF (initialisation + insertion only)
  C  : optimisation ON (colour/opacity warm-up, then geometry)
  Cc : optimisation ON but colour/opacity only (isolates the geometry-update contribution)
Held-out keyframes (index % 10 == 5) are never used for anything but evaluation (pose/K only).
"""
import argparse, json, time, sys
import numpy as np, cv2
import gsref

import os
W, H = int(os.environ.get('GS_W', 256)), int(os.environ.get('GS_H', 192))


def load(path):
    d = np.load(path)
    return {k: d[k] for k in d.files}


def cam_of(D, i):
    fx, fy, cx, cy = D['K'][i]
    return dict(Rcw=D['R'][i].T.astype(np.float64), C=D['C'][i].astype(np.float64), fx=float(fx), fy=float(fy), cx=float(cx), cy=float(cy), W=W, H=H)


def quat_from_R(R):
    """R columns are the axes (t1,t2,n) in world coords; returns (x,y,z,w)."""
    m = R
    tr = m[0, 0] + m[1, 1] + m[2, 2]
    if tr > 0:
        s = np.sqrt(tr + 1) * 2
        w = 0.25 * s; x = (m[2, 1] - m[1, 2]) / s; y = (m[0, 2] - m[2, 0]) / s; z = (m[1, 0] - m[0, 1]) / s
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.sqrt(1 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        w = (m[2, 1] - m[1, 2]) / s; x = 0.25 * s; y = (m[0, 1] + m[1, 0]) / s; z = (m[0, 2] + m[2, 0]) / s
    elif m[1, 1] > m[2, 2]:
        s = np.sqrt(1 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        w = (m[0, 2] - m[2, 0]) / s; x = (m[0, 1] + m[1, 0]) / s; y = 0.25 * s; z = (m[1, 2] + m[2, 1]) / s
    else:
        s = np.sqrt(1 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        w = (m[1, 0] - m[0, 1]) / s; x = (m[0, 2] + m[2, 0]) / s; y = (m[1, 2] + m[2, 1]) / s; z = 0.25 * s
    q = np.array([x, y, z, w], np.float32)
    return q / np.linalg.norm(q)


class GMap:
    def __init__(self):
        self.n = 0
        self.cap = 0
        self._alloc(65536)

    def _alloc(self, cap):
        def grow(a, shape):
            b = np.zeros(shape, a.dtype if a is not None else np.float32)
            if a is not None:
                b[:len(a)] = a
            return b
        names = dict(mu=(3, np.float32), logs=(3, np.float32), quat=(4, np.float32), col=(3, np.float32), opa=(None, np.float32),
                     m_mu=(3, np.float32), v_mu=(3, np.float32), m_ls=(3, np.float32), v_ls=(3, np.float32),
                     m_q=(4, np.float32), v_q=(4, np.float32), m_o=(None, np.float32), v_o=(None, np.float32),
                     m_c=(3, np.float32), v_c=(3, np.float32), nvis=(None, np.int32), born=(None, np.int32), src=(None, np.int8),
                     steps=(None, np.int32), ls0=(3, np.float32), mu0=(3, np.float32), col0=(3, np.float32),
                     votes=(None, np.int16), suspect=(None, np.int8), vkf=(None, np.int32), vpos=(3, np.float32), vdir=(3, np.float32),
                     sacc=(None, np.float32), scnt=(None, np.int32), parent=(None, np.int32), gid=(None, np.int32))
        for k, (dim, dt) in names.items():
            old = getattr(self, k, None)
            shape = (cap,) if dim is None else (cap, dim)
            b = np.zeros(shape, dt)
            if old is not None:
                b[:len(old)] = old
            setattr(self, k, b)
        self.cap = cap

    def add(self, mu, logs, quat, col, opa, src, born):
        n = len(mu)
        while self.n + n > self.cap:
            self._alloc(self.cap * 2)
        s = slice(self.n, self.n + n)
        self.mu[s] = mu; self.logs[s] = logs; self.quat[s] = quat; self.col[s] = col; self.opa[s] = opa
        self.src[s] = src; self.born[s] = born
        self.ls0[s] = logs; self.mu0[s] = mu; self.col0[s] = col
        self.vkf[s] = -1
        nid = getattr(self, 'next_id', 1)
        self.gid[s] = np.arange(nid, nid + n)
        self.next_id = nid + n
        self.n += n

    def keep(self, mask):
        idx = np.nonzero(mask[:self.n])[0]
        for k in ['mu', 'logs', 'quat', 'col', 'opa', 'm_mu', 'v_mu', 'm_ls', 'v_ls', 'm_q', 'v_q', 'm_o', 'v_o', 'm_c', 'v_c', 'nvis', 'born', 'src', 'steps', 'ls0', 'mu0', 'col0', 'votes', 'suspect', 'vkf', 'vpos', 'vdir', 'sacc', 'scnt', 'parent', 'gid']:
            a = getattr(self, k)
            a[:len(idx)] = a[idx]
        self.n = len(idx)

    def view(self):
        n = self.n
        return self.mu[:n], self.logs[:n], self.quat[:n], self.col[:n], self.opa[:n]


def point_map(Z, cam):
    ys, xs = np.mgrid[:H, :W].astype(np.float32)
    return np.stack([(xs - cam['cx']) / cam['fx'] * Z, (ys - cam['cy']) / cam['fy'] * Z, Z], -1)


# Numerical-health counters of the PC reference (reported by every run; nothing is silently zeroed).
STATS = dict(untrusted_normals=0, inserted=0, rejected_update_rows=0, nonfinite_inserts_dropped=0)


def normals_edges(Z, cam):
    """Per-pixel camera-frame normal, depth-edge flag, normal length and a TRUST flag.
    Original defect: the central difference left the first/last row/column at zero, so border pixels got a zero normal; later `t1 /= |t1|` produced NaN rotations that the
    projection validity test let through (NaN comparisons are false). Now: one-sided differences at borders, neighbour-validity check, and untrusted pixels get the
    camera-facing default normal and are reported (isotropic Gaussians are created there)."""
    Zs = cv2.GaussianBlur(Z, (0, 0), 1.2)
    Zs = np.where(Z > 0, Zs, 0)
    P = point_map(Zs, cam)
    dx = np.zeros_like(P); dy = np.zeros_like(P)
    dx[:, 1:-1] = P[:, 2:] - P[:, :-2]; dx[:, 0] = P[:, 1] - P[:, 0]; dx[:, -1] = P[:, -1] - P[:, -2]
    dy[1:-1] = P[2:] - P[:-2]; dy[0] = P[1] - P[0]; dy[-1] = P[-1] - P[-2]
    valid = (Zs > 0).astype(np.float32)
    nb = cv2.erode(valid, np.ones((3, 3), np.uint8), borderType=cv2.BORDER_REPLICATE) > 0         # whole 3x3 neighbourhood has depth
    n = np.cross(dx, dy)
    ln = np.linalg.norm(n, axis=-1, keepdims=True)
    scale = np.maximum(np.linalg.norm(dx, axis=-1, keepdims=True) * np.linalg.norm(dy, axis=-1, keepdims=True), 1e-12)
    trusted = nb & (ln[..., 0] > 1e-3 * scale[..., 0]) & np.isfinite(ln[..., 0])               # not (nearly) parallel difference vectors
    n = np.where(trusted[..., None], n / np.maximum(ln, 1e-12), np.array([0.0, 0.0, -1.0], np.float32))
    flip = (n * P).sum(-1) > 0          # normal must face the camera (P points away from camera)
    n[flip] *= -1
    # depth discontinuity: any 4-neighbour at distance 2 jumping by > 6 % (no wrap-around at the image border)
    edge = np.zeros((H, W), bool)
    for s in [(0, 2), (0, -2), (2, 0), (-2, 0)]:
        sh = np.roll(Z, s, axis=(0, 1))
        if s[0] > 0: sh[:s[0]] = 0
        if s[0] < 0: sh[s[0]:] = 0
        if s[1] > 0: sh[:, :s[1]] = 0
        if s[1] < 0: sh[:, s[1]:] = 0
        edge |= (sh > 0) & (np.abs(sh - Z) > 0.06 * Z)
    return n, edge, ln[..., 0], trusted


def make_gaussians(i, D, cam, sel, stereo_anchor, edge_ok=False):
    """Gaussians for the pixels in boolean mask `sel` of keyframe i (dense aligned depth D['Z'][i])."""
    Z = D['Z'][i]
    if CFG_SMOOTH:
        Z = np.where(Z > 0, cv2.bilateralFilter(Z.astype(np.float32), 7, 0.04 * float(np.median(Z[Z > 0])), 3), 0).astype(np.float32)
    n_cam, edge, _, trusted_n = normals_edges(Z, cam)
    sel = sel & (Z > 0.25) & (Z < 6)
    if not edge_ok:
        sel = sel & ~edge
    ys, xs = np.nonzero(sel)
    if len(ys) == 0:
        return None
    z = Z[ys, xs]
    P = np.stack([(xs - cam['cx']) / cam['fx'] * z, (ys - cam['cy']) / cam['fy'] * z, z], -1)
    Rwc = cam['Rcw'].T
    mu = (P @ Rwc.T + cam['C']).astype(np.float32)
    nc = n_cam[ys, xs]; tr = trusted_n[ys, xs]
    STATS['untrusted_normals'] += int((~tr).sum()); STATS['inserted'] += int(len(ys))
    # tangent frame in camera coords then world (basis vector chosen away from the normal; never a zero-length divide)
    a = np.where(np.abs(nc[:, :1]) < 0.9, np.array([[1., 0, 0]]), np.array([[0., 1, 0]]))
    t1 = np.cross(nc, a); l1 = np.linalg.norm(t1, axis=1, keepdims=True)
    assert (l1 > 1e-6).all(), 'degenerate tangent basis'
    t1 = t1 / l1
    t2 = np.cross(nc, t1)
    Rm = np.stack([t1 @ Rwc.T, t2 @ Rwc.T, nc @ Rwc.T], -1)       # (N,3,3) columns t1,t2,n in world
    quat = np.stack([quat_from_R(Rm[k]) for k in range(len(Rm))])
    stride = SAMPLE_STRIDE
    spacing = stride * z / cam['fx']
    st = np.clip(0.55 * spacing, 0.004, 0.08)
    cosv = np.clip(-(nc * P).sum(1) / np.linalg.norm(P, axis=1), 0.2, 1)
    sn = np.clip(0.2 * st, 0.002, 0.03)
    sn = np.where(tr, sn, st)                                  # untrusted normal: isotropic footprint (no thin disc pointing the wrong way)
    logs = np.log(np.stack([st, st, sn], 1)).astype(np.float32)
    okq = np.isfinite(quat).all(1) & np.isfinite(mu).all(1) & np.isfinite(logs).all(1)
    if not okq.all():
        STATS['nonfinite_inserts_dropped'] += int((~okq).sum())        # must stay 0; reported, never hidden
        keep = okq; mu = mu[keep]; quat = quat[keep]; ys = ys[keep]; xs = xs[keep]; logs = logs[keep]; tr = tr[keep]
    col = (D['imgs'][i][ys, xs] / 255.0).astype(np.float32)
    opa = np.full(len(z), 0.4, np.float32)
    src = stereo_anchor[ys, xs].astype(np.int8)
    return mu, logs, quat, col, opa, src


SAMPLE_STRIDE = int(os.environ.get('GS_STRIDE', 3))
CFG_SMOOTH = True


def set_smooth(v):
    global CFG_SMOOTH
    CFG_SMOOTH = v


class Optimizer:
    def __init__(self, cfg):
        self.cfg = cfg
        self.t = 0
        self.LR = dict(mu=cfg['lr_mu'], ls=cfg['lr_ls'], q=cfg['lr_q'], o=cfg['lr_o'], c=cfg['lr_c'])
        self.base_lr = dict(self.LR)

    def step(self, G, grads, geom, only_visible):
        gmu, glogs, gquat, gopa, gcol = grads
        n = G.n
        b1, b2, eps = 0.9, 0.99, 1e-8
        # reject non-finite gradients explicitly (NaN * 0 is still NaN, so masking by multiplication cannot protect the state)
        fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1)
        fin = fin & np.isfinite(G.mu[:n]).all(1) & np.isfinite(G.logs[:n]).all(1) & np.isfinite(G.quat[:n]).all(1)
        STATS['rejected_update_rows'] += int((only_visible & ~fin).sum())
        vis = only_visible & fin
        gmu = np.where(fin[:, None], gmu, 0); glogs = np.where(fin[:, None], glogs, 0); gquat = np.where(fin[:, None], gquat, 0); gopa = np.where(fin, gopa, 0); gcol = np.where(fin[:, None], gcol, 0)
        lr = self.LR
        sl = np.nonzero(vis)[0]
        if len(sl) == 0:
            return
        G.steps[sl] += 1
        c = G.steps[sl].astype(np.float32)[:, None]
        bc1 = 1 - b1 ** c
        bc2 = 1 - b2 ** c

        def upd(p, m, v, g, rate, mask=None):
            gs = g[sl]
            m[sl] = b1 * m[sl] + (1 - b1) * gs
            v[sl] = b2 * v[sl] + (1 - b2) * gs * gs
            cc = c if gs.ndim == 2 else c[:, 0]
            b1c = bc1 if gs.ndim == 2 else bc1[:, 0]
            b2c = bc2 if gs.ndim == 2 else bc2[:, 0]
            d = rate * (m[sl] / b1c) / (np.sqrt(v[sl] / b2c) + eps)
            if mask is not None:
                d = d * (mask[sl][:, None] if d.ndim == 2 else mask[sl])
            p[sl] -= d

        upd(G.col[:n], G.m_c[:n], G.v_c[:n], gcol, lr['c'])
        upd(G.opa[:n], G.m_o[:n], G.v_o[:n], gopa, lr['o'])
        if geom:
            gm = (G.steps[:n] > self.cfg['geom_warm'])
            upd(G.mu[:n], G.m_mu[:n], G.v_mu[:n], gmu, lr['mu'], gm)
            upd(G.logs[:n], G.m_ls[:n], G.v_ls[:n], glogs, lr['ls'], gm)
            upd(G.quat[:n], G.m_q[:n], G.v_q[:n], gquat, lr['q'], gm)
        # parameter ranges
        np.clip(G.col[:n], 0, 1, out=G.col[:n])
        if self.cfg['color_bound'] > 0:
            np.clip(G.col[:n], G.col0[:n] - self.cfg['color_bound'], G.col0[:n] + self.cfg['color_bound'], out=G.col[:n])
        np.clip(G.opa[:n], self.cfg['opa_min'], 6.0, out=G.opa[:n])
        ls = G.logs[:n]
        np.clip(ls, G.ls0[:n] - self.cfg['scale_down'], G.ls0[:n] + self.cfg['scale_up'], out=ls)
        if geom and self.cfg['mu_bound'] > 0:
            # bounded parameterisation: a gaussian may move at most mu_bound x its footprint from where it was initialised
            d = G.mu[:n] - G.mu0[:n]
            lim = self.cfg['mu_bound'] * np.exp(G.ls0[:n, :1])
            nd = np.linalg.norm(d, axis=1, keepdims=True)
            sc = np.minimum(1.0, lim / np.maximum(nd, 1e-9))
            G.mu[:n] = G.mu0[:n] + d * sc


def charbonnier_grad(r, eps=0.01):
    return r / np.sqrt(r * r + eps * eps)


def loss_and_grads(G, cam, tgt, anchors_z, lam_d):
    mu, logs, quat, col, opa = G.view()
    img, dep, Tf, st = gsref.render(mu, logs, quat, col, opa, cam)
    A = 1 - Tf
    r = img - tgt
    npix = H * W
    L1 = float(np.sqrt(r * r + 1e-4).mean())
    dLdC = charbonnier_grad(r) / (npix * 3)
    dLdD = np.zeros((H, W), np.float32)
    dLdA = np.zeros((H, W), np.float32)
    Ld = 0.0
    if anchors_z is not None and lam_d > 0:
        m = anchors_z > 0
        if m.any():
            rd = (dep - anchors_z * A)
            sgn = np.sign(rd) * m
            na = m.sum()
            Ld = float((np.abs(rd) / np.maximum(anchors_z, 1e-3))[m].mean())
            dLdD = lam_d * sgn / np.maximum(anchors_z, 1e-3) / na
            dLdA = -lam_d * sgn * anchors_z / np.maximum(anchors_z, 1e-3) / na
    g = gsref.backward(mu, logs, quat, col, opa, cam, st, Tf, dLdC, dLdD, dLdA)[:5]
    vis = st['proj'][:, 0] > 0.5
    return L1, Ld, g, vis, img, A


def psnr(a, b):
    mse = float(((a - b) ** 2).mean())
    return 99.0 if mse < 1e-12 else -10 * np.log10(mse)


def ssim(a, b):
    from skimage.metrics import structural_similarity
    return float(structural_similarity(a, b, channel_axis=2, data_range=1.0, win_size=7))


def evaluate(G, D, i):
    cam = cam_of(D, i)
    mu, logs, quat, col, opa = G.view()
    img, dep, Tf, _ = gsref.render(mu, logs, quat, col, opa, cam)
    tgt = D['imgs'][i].astype(np.float32) / 255
    A = 1 - Tf
    sup = A > 0.5
    out = dict(psnr=psnr(img, tgt), ssim=ssim(img, tgt), coverage=float(sup.mean()), hole=float((A < 0.1).mean()), alpha_mean=float(A.mean()), dark_frac=float((A < 0.8).mean()))
    if sup.any():
        out['psnr_supported'] = psnr(img[sup], tgt[sup])
    return out, img


def run(D, variant, cfg, out_dir=None, verbose=True):
    n = len(D['ids'])
    G = GMap()
    opt = Optimizer(cfg)
    rng = np.random.RandomState(7)
    HELD = lambda i: i % 10 == 5
    train_ids = []
    arrival = {}
    stats = []
    t_all = time.time()
    for i in range(n):
        if HELD(i):
            if G.n > 0:
                arrival[i], _ = evaluate(G, D, i)
            continue
        if D['Z'][i].max() <= 0:
            continue
        cam = cam_of(D, i)
        Z = D['Z'][i]
        anch = D['ZS'][i] > 0
        ys, xs = np.mgrid[:H, :W]
        grid = (ys % SAMPLE_STRIDE == SAMPLE_STRIDE // 2) & (xs % SAMPLE_STRIDE == SAMPLE_STRIDE // 2)
        added = 0
        if G.n == 0:
            sel = grid
        else:
            mu, logs, quat, col, opa = G.view()
            img, dep, Tf, _ = gsref.render(mu, logs, quat, col, opa, cam)
            A = 1 - Tf
            Dn = dep / np.maximum(A, 1e-3)
            sel = grid & ((A < cfg['ins_alpha']) | (anch & (A > 0.5) & (Dn > Z * 1.07)))
        # per-keyframe budget
        sel_idx = np.nonzero(sel.ravel())[0]
        if len(sel_idx) > cfg['ins_budget']:
            keep = rng.choice(sel_idx, cfg['ins_budget'], replace=False)
            sel = np.zeros(H * W, bool); sel[keep] = True; sel = sel.reshape(H, W)
        gg = make_gaussians(i, D, cam, sel, anch, edge_ok=bool(cfg['edge_ok']))
        if gg is not None:
            G.add(*gg, born=i)
            added = len(gg[0])
        train_ids.append(i)
        t_opt = time.time()
        iters = 0
        if variant in ('C', 'Cc') and G.n > 0:
            window = train_ids[-cfg['win_recent']:]
            past = [k for k in train_ids[:-cfg['win_recent']]]
            for it in range(cfg['iters']):
                cyc = cfg['win_recent'] + cfg['past_n']
                if it % cyc >= cfg['win_recent'] and past:
                    v = past[rng.randint(len(past))]
                else:
                    v = window[(it % cyc) % len(window)]
                camv = cam_of(D, v)
                tgt = D['imgs'][v].astype(np.float32) / 255
                az = np.where(D['ZS'][v] > 0, D['ZS'][v], 0).astype(np.float32)
                L1, Ld, g, vis, _, _ = loss_and_grads(G, camv, tgt, az, cfg['lam_d'] if variant == 'C' else 0.0)
                vis_full = np.zeros(G.cap, bool); vis_full[:G.n] = vis
                opt.step(G, g, geom=(variant == 'C'), only_visible=vis_full[:G.n])
                iters += 1
        opt_ms = (time.time() - t_opt) * 1000
        # prune: low opacity after enough updates
        if G.n > 0 and (len(train_ids) % 4 == 0):
            a0 = 0.99 / (1 + np.exp(-G.opa[:G.n]))
            kill = (a0 < 0.03) & (G.steps[:G.n] > 12)
            if kill.any():
                G.keep(~kill)
        stats.append(dict(i=i, n=G.n, added=added, iters=iters, opt_ms=round(opt_ms, 1)))
        if verbose and len(train_ids) % 20 == 0:
            print(variant, 'kf', i, 'N', G.n, 'added', added, 'opt_ms', round(opt_ms), flush=True)
    final = {}
    held = [i for i in range(n) if HELD(i)]
    for i in held:
        final[i], img = evaluate(G, D, i)
        if out_dir:
            cv2.imwrite(f"{out_dir}/{variant}_held{i:03d}.png", cv2.cvtColor((np.clip(img, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
    return dict(variant=variant, G=G, final=final, arrival=arrival, stats=stats, sec=time.time() - t_all)


DEFAULT_CFG = dict(iters=24, win_recent=3, past_n=2, lam_d=0.0, geom_warm=6, ins_alpha=0.6, ins_budget=2400,
                   lr_mu=2e-4, lr_ls=1e-3, lr_q=5e-4, lr_o=0.04, lr_c=0.012, scale_down=0.7, scale_up=0.5, mu_bound=3.0, smooth=1, color_bound=0.0, opa_min=-1.5, edge_ok=1)


def summarize(res):
    f = res['final']
    keys = ['psnr', 'ssim', 'coverage', 'hole', 'psnr_supported', 'alpha_mean', 'dark_frac']
    out = {k: float(np.mean([v[k] for v in f.values() if k in v])) for k in keys}
    out['n_gaussians'] = res['G'].n
    out['sec'] = res['sec']
    a = res['arrival']
    if a:
        out['arrival_psnr'] = float(np.mean([v['psnr'] for v in a.values()]))
        out['arrival_coverage'] = float(np.mean([v['coverage'] for v in a.values()]))
    return out


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('npz')
    ap.add_argument('--variants', default='B,C')
    ap.add_argument('--out', default='results')
    ap.add_argument('--iters', type=int, default=DEFAULT_CFG['iters'])
    ap.add_argument('--set', nargs='*', default=[])
    a = ap.parse_args()
    import os
    os.makedirs(a.out, exist_ok=True)
    D = load(a.npz)
    cfg = dict(DEFAULT_CFG)
    cfg['iters'] = a.iters
    for kv in a.set:
        k, v = kv.split('=')
        cfg[k] = type(DEFAULT_CFG[k])(float(v)) if not isinstance(DEFAULT_CFG[k], int) else int(float(v))
    set_smooth(bool(cfg['smooth']))
    summ = {}
    for v in a.variants.split(','):
        res = run(D, v, cfg, out_dir=a.out)
        summ[v] = summarize(res)
        json.dump(dict(final={str(k): vv for k, vv in res['final'].items()}, arrival={str(k): vv for k, vv in res['arrival'].items()}, stats=res['stats']),
                  open(f"{a.out}/{v}_detail.json", 'w'))
        print(v, json.dumps(summ[v]), flush=True)
    json.dump(dict(cfg=cfg, summary=summ), open(f"{a.out}/summary.json", 'w'), indent=1)
