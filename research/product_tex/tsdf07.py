"""Fused reference surface (PC prototype): small truncated-signed-distance volume around the product, integrated from the layers' own depth maps,
then every layer cell is re-seated along ITS OWN RAY at the fused surface. Photos/textures are untouched.
A cell with no fused support keeps its original position; scale is clamped.
"""
import numpy as np
import align07 as A


class Vol:
    def __init__(self, lo, hi, vox):
        self.lo = lo.astype(np.float32); self.vox = float(vox)
        self.dim = np.ceil((hi - lo) / vox).astype(int) + 1
        self.T = np.zeros(self.dim, np.float32); self.W = np.zeros(self.dim, np.float32)
        gx, gy, gz = np.meshgrid(*[np.arange(n) for n in self.dim], indexing='ij')
        self.X = (np.stack([gx, gy, gz], -1).reshape(-1, 3) * vox + self.lo).astype(np.float32)

    def integrate(self, l, z_small, mu, step=3, wmap=None):
        """z_small: depth map of layer l sampled every `step` px of the layer image (inf = none). Pixel centre (j,i) of z_small <-> full-res pixel (j*step+step/2, i*step+step/2)."""
        pc = (self.X - l['C']) @ l['R']; z = pc[:, 2]
        u = (l['fx'] * pc[:, 0] / np.maximum(z, 1e-3) + l['cx']) / step - 0.5; v = (l['fy'] * pc[:, 1] / np.maximum(z, 1e-3) + l['cy']) / step - 0.5
        h, w = z_small.shape
        ui = np.round(u).astype(int); vi = np.round(v).astype(int)
        ok = (z > 0.1) & (ui >= 0) & (ui < w) & (vi >= 0) & (vi < h)
        zo = np.full(len(z), np.inf, np.float32); zo[ok] = z_small[vi[ok], ui[ok]]
        sdf = zo - z
        use = np.isfinite(zo) & (sdf > -mu)
        d = np.clip(sdf / mu, -1, 1)
        wt = np.ones(len(z), np.float32) if wmap is None else np.where(use, wmap[np.clip(vi, 0, h - 1), np.clip(ui, 0, w - 1)], 0)
        idx = np.nonzero(use)[0]
        Tf = self.T.reshape(-1); Wf = self.W.reshape(-1)
        Tf[idx] = (Tf[idx] * Wf[idx] + d[idx] * wt[idx]) / (Wf[idx] + wt[idx]); Wf[idx] += wt[idx]

    def sample(self, P):
        g = (P - self.lo) / self.vox
        i0 = np.floor(g).astype(int); f = g - i0
        out = np.zeros(len(P), np.float32); wsum = np.zeros(len(P), np.float32); ok = np.ones(len(P), bool)
        for dx in (0, 1):
            for dy in (0, 1):
                for dz in (0, 1):
                    ii = i0 + np.array([dx, dy, dz]); inb = ((ii >= 0) & (ii < self.dim)).all(1); ok &= inb
                    iic = np.clip(ii, 0, self.dim - 1)
                    wgt = (f[:, 0] if dx else 1 - f[:, 0]) * (f[:, 1] if dy else 1 - f[:, 1]) * (f[:, 2] if dz else 1 - f[:, 2])
                    t = self.T[iic[:, 0], iic[:, 1], iic[:, 2]]; w = self.W[iic[:, 0], iic[:, 1], iic[:, 2]]
                    out += wgt * t; wsum += wgt * (w >= 1.5)
        full = ok & (wsum > 0.999)
        return out, full


def fuse_depth(L, vox=0.01, mu=0.06, min_w=2, smin=0.8, smax=1.25, nsteps=80, rng=(0.75, 1.3), verbose=False, zstep=3):
    photos = [A.own_photo(l) for l in L]
    pts = np.concatenate([l['corners'].mean(1) for l in L])
    lo = np.percentile(pts, 1, axis=0) - 0.10; hi = np.percentile(pts, 99, axis=0) + 0.10
    V = Vol(lo, hi, vox)
    for l, p in zip(L, photos):
        zs = p[2][zstep // 2::zstep, zstep // 2::zstep]
        V.integrate(l, zs, mu, step=zstep)
    scales = []
    for i, l in enumerate(L):
        ctr, n = A.cell_geom(l); x0, y0 = A.cell_xy(l)
        d0 = ((ctr - l['C']) @ l['R'])[:, 2]
        ray = ctr - l['C']; ray = ray / np.linalg.norm(ray, axis=1, keepdims=True)
        # march along the ray in depth-scale space
        ts = np.linspace(rng[0], rng[1], nsteps)
        prev_v = None; found = np.zeros(len(ctr), bool); s_out = np.ones(len(ctr), np.float32)
        dist0 = np.linalg.norm(ctr - l['C'], axis=1)
        for k, t in enumerate(ts):
            P = l['C'] + ray * (dist0 * t)[:, None]
            val, full = V.sample(P)
            if prev_v is not None:
                cross = (prev_v[0] > 0) & (val <= 0) & prev_v[1] & full & ~found
                if cross.any():
                    a = prev_v[0][cross]; b = val[cross]; frac = a / np.maximum(a - b, 1e-6)
                    s_out[cross] = ts[k - 1] + frac * (ts[k] - ts[k - 1]); found |= cross
            prev_v = (val, full)
        s_out = np.where(found, np.clip(s_out, smin, smax), 1.0)
        scales.append((s_out, found))
        if verbose and i % 10 == 0: print('  layer', i, 'found %.2f' % found.mean(), 'median |s-1| %.3f' % np.median(np.abs(s_out[found] - 1)) if found.any() else '', flush=True)
    return scales, V


def apply_scales(L, scales):
    out = []
    for l, (s, _) in zip(L, scales):
        nl = {k: v for k, v in l.items() if k != '_S'}; c = l['C']; nl['corners'] = (c + (l['corners'] - c) * s[:, None, None]).astype(np.float32); out.append(nl)
    return out
