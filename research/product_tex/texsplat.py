"""Textured-surfel reference for the product reconstruction study (PC, NumPy/numba). Not the app implementation.

Surfel = planar quad (4 corner points on a plane through the depth sample) + TxT RGBA texture cut directly from the original 960x720 frame.
B = same surfels, texture collapsed to its mean colour, rendered as flat Gaussians (no optimisation).
C = same surfels, textured render. D = C + registration/fusion over time (see fuse.py).
"""
import numpy as np, cv2
from numba import njit, prange

MAX_RESID = 0.012
MIN_FRONTAL = 0.40
KSLOT = 3      # view-dependent texture slots per surfel (D2)
T = 8          # texels per side (== cell size in source pixels: 1 texel = 1 source pixel at 960x720)


def bilinear(img, u, v):
    """img HxWxC float32, u,v arrays (pixel-centre convention). Returns samples and in-bounds flag."""
    H, W = img.shape[:2]
    x0 = np.floor(u).astype(np.int32); y0 = np.floor(v).astype(np.int32)
    fx = (u - x0)[..., None]; fy = (v - y0)[..., None]
    inb = (x0 >= 0) & (y0 >= 0) & (x0 + 1 < W) & (y0 + 1 < H)
    x0c = np.clip(x0, 0, W - 2); y0c = np.clip(y0, 0, H - 2)
    a = img[y0c, x0c]; b = img[y0c, x0c + 1]; c = img[y0c + 1, x0c]; d = img[y0c + 1, x0c + 1]
    return (a * (1 - fx) * (1 - fy) + b * fx * (1 - fy) + c * (1 - fx) * fy + d * fx * fy), inb


class Surfels:
    """Struct-of-arrays map. corners: N x 4 x 3 (c00, c10, c01, c11 in world), tex: N x T x T x 4 (RGB 0..1, A)."""
    def __init__(self):
        self.P = np.zeros((0, 3), np.float32); self.N = np.zeros((0, 3), np.float32)
        self.corners = np.zeros((0, 4, 3), np.float32); self.tex = np.zeros((0, T, T, 4), np.float32)
        self.q = np.zeros(0, np.float32); self.born = np.zeros(0, np.int32); self.nobs = np.zeros(0, np.int32)
        self.cost = np.zeros((0, 7), np.float32); self.ncost = np.zeros(0, np.int32); self.sid = np.zeros(0, np.int64)
        self.viol = np.zeros(0, np.int32); self.geo_n = np.zeros(0, np.int32)
        self.srcC = np.zeros((0, 3), np.float32); self.tw = np.zeros(0, np.float32)
        self.texK = np.zeros((0, KSLOT, T, T, 3), np.float32); self.dirK = np.zeros((0, KSLOT, 3), np.float32); self.qK = np.zeros((0, KSLOT), np.float32); self.nslot = np.zeros(0, np.int32)
        self.next = 0

    def __len__(self): return len(self.P)

    def add(self, P, N, corners, tex, q, born, srcC=None):
        n = len(P)
        self.srcC = np.concatenate([self.srcC, np.zeros((n, 3), np.float32) if srcC is None else np.repeat(np.asarray(srcC, np.float32)[None], n, 0)]); self.tw = np.concatenate([self.tw, np.ones(n, np.float32)])
        tk = np.zeros((n, KSLOT, T, T, 3), np.float32); tk[:, 0] = tex[..., :3]
        dk = np.zeros((n, KSLOT, 3), np.float32)
        if srcC is not None:
            v = np.asarray(srcC, np.float32)[None] - P; dk[:, 0] = v / np.maximum(np.linalg.norm(v, axis=1, keepdims=True), 1e-6)
        qk = np.zeros((n, KSLOT), np.float32); qk[:, 0] = q
        self.texK = np.concatenate([self.texK, tk]); self.dirK = np.concatenate([self.dirK, dk]); self.qK = np.concatenate([self.qK, qk]); self.nslot = np.concatenate([self.nslot, np.ones(n, np.int32)])
        self.P = np.concatenate([self.P, P.astype(np.float32)]); self.N = np.concatenate([self.N, N.astype(np.float32)])
        self.corners = np.concatenate([self.corners, corners.astype(np.float32)]); self.tex = np.concatenate([self.tex, tex.astype(np.float32)])
        self.q = np.concatenate([self.q, q.astype(np.float32)]); self.born = np.concatenate([self.born, np.full(n, born, np.int32)])
        self.nobs = np.concatenate([self.nobs, np.ones(n, np.int32)]); self.cost = np.concatenate([self.cost, np.zeros((n, 7), np.float32)])
        self.ncost = np.concatenate([self.ncost, np.zeros(n, np.int32)]); self.sid = np.concatenate([self.sid, np.arange(self.next, self.next + n)])
        self.viol = np.concatenate([self.viol, np.zeros(n, np.int32)]); self.geo_n = np.concatenate([self.geo_n, np.zeros(n, np.int32)])
        self.next += n


class Frame:
    def __init__(self, img_hi, R, C, fx, fy, cx, cy):
        self.img = img_hi.astype(np.float32) / 255; self.R = R; self.C = C; self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.H, self.W = img_hi.shape[:2]

    def to_cam(self, X): return (X - self.C) @ self.R          # world -> camera (R is cam->world)

    def project(self, X):
        Xc = self.to_cam(X); z = Xc[..., 2]
        return self.fx * Xc[..., 0] / np.maximum(z, 1e-6) + self.cx, self.fy * Xc[..., 1] / np.maximum(z, 1e-6) + self.cy, z

    def ray(self, u, v):
        d = np.stack([(u - self.cx) / self.fx, (v - self.cy) / self.fy, np.ones_like(u)], -1)
        return d @ self.R.T                                   # world direction (not normalised, z_cam = 1)


def lap_sharp(gray):
    return float(np.mean(np.abs(cv2.Laplacian(gray, cv2.CV_32F))))


def sample_depth(Zlo, u, v, scale):
    """Zlo is a low-res depth map (HxW); (u,v) are hi-res pixel coords; scale = hi/lo."""
    ul = (u + 0.5) / scale - 0.5; vl = (v + 0.5) / scale - 0.5
    s, inb = bilinear(Zlo[..., None].astype(np.float32), ul, vl)
    return s[..., 0], inb


def build_from_frame(fr, Zlo, lab, born, scale=3.0, cell=T, reg_tau=0.05, min_prod=0.5, only=None):
    """Create surfels for every cell whose product-label fraction >= min_prod. fr: Frame (hi-res), Zlo: low-res depth, lab: mask at 320x240.
    only: optional boolean cell mask (cells to build). Returns Surfels-like dict of arrays."""
    H, W = fr.H, fr.W
    cy_n, cx_n = H // cell, W // cell
    # label per hi-res pixel (nearest)
    ys, xs = np.mgrid[0:H, 0:W]
    lab_hi = lab[np.minimum(lab.shape[0] - 1, ((ys + 0.5) * lab.shape[0] / H).astype(int)), np.minimum(lab.shape[1] - 1, ((xs + 0.5) * lab.shape[1] / W).astype(int))]
    prod = (lab_hi == 1)
    cellfrac = prod[:cy_n * cell, :cx_n * cell].reshape(cy_n, cell, cx_n, cell).mean((1, 3))
    sel = cellfrac >= min_prod
    if only is not None: sel &= only
    cy_i, cx_i = np.nonzero(sel)
    if len(cy_i) == 0: return None
    # per-texel depth (hi-res grid) from the low-res depth
    zhi, inb = sample_depth(Zlo, xs.astype(np.float32), ys.astype(np.float32), scale)
    zhi = zhi.astype(np.float32)
    # local plane normal per cell from depth gradient over a 3x3 cell window using least squares on 3D points
    gray = cv2.cvtColor((fr.img * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY).astype(np.float32) / 255
    n_out = len(cy_i)
    tex = np.zeros((n_out, T, T, 4), np.float32); corners = np.zeros((n_out, 4, 3), np.float32); Pc = np.zeros((n_out, 3), np.float32); Nn = np.zeros((n_out, 3), np.float32)
    q = np.zeros(n_out, np.float32); keep = np.ones(n_out, bool)
    for k in range(n_out):
        r, c = cy_i[k], cx_i[k]
        y0, x0 = r * cell, c * cell
        # neighbourhood window (3x3 cells) clipped
        ya, yb = max(0, y0 - cell), min(H, y0 + 2 * cell); xa, xb = max(0, x0 - cell), min(W, x0 + 2 * cell)
        sy, sx = np.mgrid[ya:yb:2, xa:xb:2]
        zz = zhi[ya:yb:2, xa:xb:2]
        pm = prod[ya:yb:2, xa:xb:2] & (zz > 0.2)
        if pm.sum() < 12: keep[k] = False; continue
        Xw = fr.C + np.stack([(sx[pm] - fr.cx) / fr.fx * zz[pm], (sy[pm] - fr.cy) / fr.fy * zz[pm], zz[pm]], -1) @ fr.R.T
        # robust plane via PCA on points near the cell-centre depth
        zc = zhi[y0 + cell // 2, x0 + cell // 2]
        if zc <= 0.2: keep[k] = False; continue
        m2 = np.abs(zz[pm] - zc) < reg_tau * 2 * zc
        if m2.sum() < 10: keep[k] = False; continue
        Xs = Xw[m2]; mu = Xs.mean(0)
        u_, s_, vt = np.linalg.svd(Xs - mu, full_matrices=False)
        n = vt[2]
        if s_[2] / np.sqrt(len(Xs)) > MAX_RESID * zc: keep[k] = False; continue          # plane fit too rough (edge / bumpy cell)
        ctr = fr.C + fr.ray(np.float32(x0 + cell / 2 - 0.5), np.float32(y0 + cell / 2 - 0.5)) * zc
        # orient normal towards camera
        if n @ (fr.C - ctr) < 0: n = -n
        if abs(n @ (fr.C - ctr)) / np.linalg.norm(fr.C - ctr) < MIN_FRONTAL: keep[k] = False; continue     # grazing view: stretched, unreliable texture
        # plane through ctr with normal n; corners = ray(corner pixel) ∩ plane
        cs = []
        for (du, dv) in ((0, 0), (1, 0), (0, 1), (1, 1)):
            d = fr.ray(np.float32(x0 + du * cell - 0.5), np.float32(y0 + dv * cell - 0.5))
            den = n @ d
            if abs(den) < 0.15 * np.linalg.norm(d): keep[k] = False; break     # near-grazing plane: skip
            t = (n @ (ctr - fr.C)) / den
            if t <= 0: keep[k] = False; break
            cs.append(fr.C + t * d)
        if not keep[k]: continue
        cs = np.array(cs, np.float32)
        if np.linalg.norm(cs[1] - cs[0]) > 6 * np.linalg.norm(cs[2] - cs[0]) or np.linalg.norm(cs[2] - cs[0]) > 6 * np.linalg.norm(cs[1] - cs[0]): keep[k] = False; continue
        corners[k] = cs; Pc[k] = ctr; Nn[k] = n
        patch = fr.img[y0:y0 + cell, x0:x0 + cell]
        # alpha: product label AND depth consistent with the plane at the texel
        tz = zhi[y0:y0 + cell, x0:x0 + cell]
        # plane depth at texel: intersection with the texel ray
        uu = np.arange(x0, x0 + cell, dtype=np.float32)[None, :].repeat(cell, 0); vv = np.arange(y0, y0 + cell, dtype=np.float32)[:, None].repeat(cell, 1)
        dd = fr.ray(uu, vv); den = dd @ n; tpl = (n @ (ctr - fr.C)) / np.where(np.abs(den) < 1e-6, 1e-6, den)
        okd = np.abs(tz - tpl) < reg_tau * 1.6 * zc
        a = (prod[y0:y0 + cell, x0:x0 + cell] & okd).astype(np.float32)
        if a.mean() < 0.25: keep[k] = False; continue
        tex[k, ..., :3] = patch; tex[k, ..., 3] = a
        g = gray[y0:y0 + cell, x0:x0 + cell]
        front = abs(n @ ((fr.C - ctr) / np.linalg.norm(fr.C - ctr)))
        q[k] = (0.05 + float(np.abs(np.diff(g, axis=0)).mean() + np.abs(np.diff(g, axis=1)).mean())) * front * (1.0 / (1 + 0.15 * zc))
    if not keep.any(): return None
    return dict(P=Pc[keep], N=Nn[keep], corners=corners[keep], tex=tex[keep], q=q[keep], cell=np.stack([cy_i[keep], cx_i[keep]], 1))


# ---- renderer ----------------------------------------------------------------------------------------------------------
@njit(cache=True, fastmath=True)
def _raster(order, corners, tex, W, H, fx, fy, cx, cy, Rt, C, bg_alpha_floor, grow):
    img = np.zeros((H, W, 3), np.float32); A = np.zeros((H, W), np.float32); D = np.zeros((H, W), np.float32)
    n = order.shape[0]
    for oi in range(n):
        i = order[oi]
        c = corners[i]
        # corners to camera
        px = np.empty(4); py = np.empty(4); pz = np.empty(4)
        ok = True
        for k in range(4):
            x = c[k, 0] - C[0]; y = c[k, 1] - C[1]; z = c[k, 2] - C[2]
            xc = Rt[0, 0] * x + Rt[0, 1] * y + Rt[0, 2] * z
            yc = Rt[1, 0] * x + Rt[1, 1] * y + Rt[1, 2] * z
            zc = Rt[2, 0] * x + Rt[2, 1] * y + Rt[2, 2] * z
            if zc < 0.05: ok = False; break
            px[k] = fx * xc / zc + cx; py[k] = fy * yc / zc + cy; pz[k] = zc
        if not ok: continue
        x0 = int(max(0, np.floor(min(px.min(), 1e9)) - 1)); x1 = int(min(W - 1, np.ceil(px.max()) + 1))
        y0 = int(max(0, np.floor(py.min()) - 1)); y1 = int(min(H - 1, np.ceil(py.max()) + 1))
        if x1 < x0 or y1 < y0 or (x1 - x0) > 400 or (y1 - y0) > 400: continue
        # plane basis in world: p(u,v) = c00 + u*e1 + v*e2
        e1x = c[1, 0] - c[0, 0]; e1y = c[1, 1] - c[0, 1]; e1z = c[1, 2] - c[0, 2]
        e2x = c[2, 0] - c[0, 0]; e2y = c[2, 1] - c[0, 1]; e2z = c[2, 2] - c[0, 2]
        nx = e1y * e2z - e1z * e2y; ny = e1z * e2x - e1x * e2z; nz = e1x * e2y - e1y * e2x
        nn = nx * nx + ny * ny + nz * nz
        if nn < 1e-14: continue
        e11 = e1x * e1x + e1y * e1y + e1z * e1z; e22 = e2x * e2x + e2y * e2y + e2z * e2z; e12 = e1x * e2x + e1y * e2y + e1z * e2z
        det = e11 * e22 - e12 * e12
        if det < 1e-18: continue
        Tn = tex.shape[1]
        for py_ in range(y0, y1 + 1):
            for px_ in range(x0, x1 + 1):
                # ray in world
                dx = (px_ - cx) / fx; dy = (py_ - cy) / fy
                wx = Rt[0, 0] * dx + Rt[1, 0] * dy + Rt[2, 0]
                wy = Rt[0, 1] * dx + Rt[1, 1] * dy + Rt[2, 1]
                wz = Rt[0, 2] * dx + Rt[1, 2] * dy + Rt[2, 2]
                den = nx * wx + ny * wy + nz * wz
                if abs(den) < 1e-12: continue
                t = (nx * (c[0, 0] - C[0]) + ny * (c[0, 1] - C[1]) + nz * (c[0, 2] - C[2])) / den
                if t <= 0.05: continue
                qx = C[0] + t * wx - c[0, 0]; qy = C[1] + t * wy - c[0, 1]; qz = C[2] + t * wz - c[0, 2]
                a1 = qx * e1x + qy * e1y + qz * e1z; a2 = qx * e2x + qy * e2y + qz * e2z
                u = (a1 * e22 - a2 * e12) / det; v = (a2 * e11 - a1 * e12) / det
                m = grow
                if u < -m or u > 1 + m or v < -m or v > 1 + m: continue
                uc = min(max(u, 0.0), 1.0); vc = min(max(v, 0.0), 1.0)
                fu = uc * Tn - 0.5; fv = vc * Tn - 0.5
                iu = int(np.floor(fu)); iv = int(np.floor(fv))
                du = fu - iu; dv = fv - iv
                iu0 = min(max(iu, 0), Tn - 1); iu1 = min(max(iu + 1, 0), Tn - 1); iv0 = min(max(iv, 0), Tn - 1); iv1 = min(max(iv + 1, 0), Tn - 1)
                al = (tex[i, iv0, iu0, 3] * (1 - du) * (1 - dv) + tex[i, iv0, iu1, 3] * du * (1 - dv) + tex[i, iv1, iu0, 3] * (1 - du) * dv + tex[i, iv1, iu1, 3] * du * dv)
                if al < 1e-3: continue
                r = (tex[i, iv0, iu0, 0] * (1 - du) * (1 - dv) + tex[i, iv0, iu1, 0] * du * (1 - dv) + tex[i, iv1, iu0, 0] * (1 - du) * dv + tex[i, iv1, iu1, 0] * du * dv)
                g = (tex[i, iv0, iu0, 1] * (1 - du) * (1 - dv) + tex[i, iv0, iu1, 1] * du * (1 - dv) + tex[i, iv1, iu0, 1] * (1 - du) * dv + tex[i, iv1, iu1, 1] * du * dv)
                b = (tex[i, iv0, iu0, 2] * (1 - du) * (1 - dv) + tex[i, iv0, iu1, 2] * du * (1 - dv) + tex[i, iv1, iu0, 2] * (1 - du) * dv + tex[i, iv1, iu1, 2] * du * dv)
                # painter's algorithm (far -> near): over-composite on top of what is there
                img[py_, px_, 0] = r * al + img[py_, px_, 0] * (1 - al)
                img[py_, px_, 1] = g * al + img[py_, px_, 1] * (1 - al)
                img[py_, px_, 2] = b * al + img[py_, px_, 2] * (1 - al)
                A[py_, px_] = al + A[py_, px_] * (1 - al)
                D[py_, px_] = t * 1.0
    return img, A, D


def render_textured(S, cam, W, H, grow=0.04, tex=None):
    """cam: Frame-like (R cam->world, C, fx, fy, cx, cy at W x H). Painter order far -> near by centre depth."""
    if len(S) == 0: return np.zeros((H, W, 3), np.float32), np.zeros((H, W), np.float32), np.zeros((H, W), np.float32)
    z = ((S.P - cam.C) @ cam.R)[:, 2]
    order = np.argsort(-z).astype(np.int64)
    return _raster(order, S.corners.astype(np.float64), (S.tex if tex is None else tex).astype(np.float32), W, H, cam.fx, cam.fy, cam.cx, cam.cy, cam.R.T.copy(), cam.C.astype(np.float64), 0.0, grow)


@njit(cache=True, fastmath=True)
def _raster_ids(order, corners, W, H, fx, fy, cx, cy, Rt, C, grow):
    """Opaque nearest-surface buffers (surfel id, camera z) ignoring texture alpha: geometric coverage of the map."""
    ids = np.full((H, W), -1, np.int64); zb = np.full((H, W), 1e9, np.float32)
    for oi in range(order.shape[0]):
        i = order[oi]
        c = corners[i]
        px = np.empty(4); py = np.empty(4)
        ok = True
        for k in range(4):
            x = c[k, 0] - C[0]; y = c[k, 1] - C[1]; z = c[k, 2] - C[2]
            xc = Rt[0, 0] * x + Rt[0, 1] * y + Rt[0, 2] * z
            yc = Rt[1, 0] * x + Rt[1, 1] * y + Rt[1, 2] * z
            zc = Rt[2, 0] * x + Rt[2, 1] * y + Rt[2, 2] * z
            if zc < 0.05: ok = False; break
            px[k] = fx * xc / zc + cx; py[k] = fy * yc / zc + cy
        if not ok: continue
        x0 = int(max(0, np.floor(px.min()) - 1)); x1 = int(min(W - 1, np.ceil(px.max()) + 1))
        y0 = int(max(0, np.floor(py.min()) - 1)); y1 = int(min(H - 1, np.ceil(py.max()) + 1))
        if x1 < x0 or y1 < y0 or (x1 - x0) > 300 or (y1 - y0) > 300: continue
        e1x = c[1, 0] - c[0, 0]; e1y = c[1, 1] - c[0, 1]; e1z = c[1, 2] - c[0, 2]
        e2x = c[2, 0] - c[0, 0]; e2y = c[2, 1] - c[0, 1]; e2z = c[2, 2] - c[0, 2]
        nx = e1y * e2z - e1z * e2y; ny = e1z * e2x - e1x * e2z; nz = e1x * e2y - e1y * e2x
        e11 = e1x * e1x + e1y * e1y + e1z * e1z; e22 = e2x * e2x + e2y * e2y + e2z * e2z; e12 = e1x * e2x + e1y * e2y + e1z * e2z
        det = e11 * e22 - e12 * e12
        if det < 1e-18: continue
        for py_ in range(y0, y1 + 1):
            for px_ in range(x0, x1 + 1):
                dx = (px_ - cx) / fx; dy = (py_ - cy) / fy
                wx = Rt[0, 0] * dx + Rt[1, 0] * dy + Rt[2, 0]
                wy = Rt[0, 1] * dx + Rt[1, 1] * dy + Rt[2, 1]
                wz = Rt[0, 2] * dx + Rt[1, 2] * dy + Rt[2, 2]
                den = nx * wx + ny * wy + nz * wz
                if abs(den) < 1e-12: continue
                t = (nx * (c[0, 0] - C[0]) + ny * (c[0, 1] - C[1]) + nz * (c[0, 2] - C[2])) / den
                if t <= 0.05 or t >= zb[py_, px_]: continue
                qx = C[0] + t * wx - c[0, 0]; qy = C[1] + t * wy - c[0, 1]; qz = C[2] + t * wz - c[0, 2]
                a1 = qx * e1x + qy * e1y + qz * e1z; a2 = qx * e2x + qy * e2y + qz * e2z
                u = (a1 * e22 - a2 * e12) / det; v = (a2 * e11 - a1 * e12) / det
                if u < -grow or u > 1 + grow or v < -grow or v > 1 + grow: continue
                ids[py_, px_] = i; zb[py_, px_] = t
    return ids, zb


def render_ids(S, cam, W, H, grow=0.02):
    if len(S) == 0: return np.full((H, W), -1, np.int64), np.full((H, W), 1e9, np.float32)
    z = ((S.P - cam.C) @ cam.R)[:, 2]
    order = np.argsort(z).astype(np.int64)
    return _raster_ids(order, S.corners.astype(np.float64), W, H, cam.fx, cam.fy, cam.cx, cam.cy, cam.R.T.copy(), cam.C.astype(np.float64), grow)


def blend_tex(S, cam):
    """View-dependent texture: for each surfel blend the two stored slots whose capture directions are closest to the novel view direction."""
    n = len(S)
    tex = S.tex.copy()
    if n == 0: return tex
    v = cam.C[None] - S.P; v = v / np.maximum(np.linalg.norm(v, axis=1, keepdims=True), 1e-6)
    cosv = np.einsum('nkc,nc->nk', S.dirK, v)
    valid = np.arange(KSLOT)[None, :] < S.nslot[:, None]
    cosv = np.where(valid, cosv, -2.0)
    ang = np.arccos(np.clip(cosv, -1, 1))
    ang = np.where(valid, ang, 9.0)
    order = np.argsort(ang, axis=1)
    i0 = order[:, 0]; i1 = order[:, 1]
    a0 = ang[np.arange(n), i0]; a1 = ang[np.arange(n), i1]
    w0 = 1.0 / (0.03 + a0); w1 = np.where(a1 < 8.0, 1.0 / (0.03 + a1), 0.0)
    w0n = (w0 / (w0 + w1))[:, None, None, None]
    t0 = S.texK[np.arange(n), i0]; t1 = S.texK[np.arange(n), i1]
    tex[..., :3] = t0 * w0n + t1 * (1 - w0n)
    return tex


@njit(cache=True, fastmath=True)
def _raster_zb(order, corners, tex, W, H, fx, fy, cx, cy, Rt, C, grow):
    """GPU-equivalent per-layer pass: z-buffered, alpha-tested (alpha < 0.5 discarded), bilinear RGB. Returns colour (unpremultiplied), depth (inf = empty)."""
    img = np.zeros((H, W, 3), np.float32); zb = np.full((H, W), 1e9, np.float32)
    for oi in range(order.shape[0]):
        i = order[oi]; c = corners[i]
        px = np.empty(4); py = np.empty(4); ok = True
        for k in range(4):
            x = c[k, 0] - C[0]; y = c[k, 1] - C[1]; z = c[k, 2] - C[2]
            xc = Rt[0, 0] * x + Rt[0, 1] * y + Rt[0, 2] * z
            yc = Rt[1, 0] * x + Rt[1, 1] * y + Rt[1, 2] * z
            zc = Rt[2, 0] * x + Rt[2, 1] * y + Rt[2, 2] * z
            if zc < 0.05: ok = False; break
            px[k] = fx * xc / zc + cx; py[k] = fy * yc / zc + cy
        if not ok: continue
        x0 = int(max(0, np.floor(px.min()) - 1)); x1 = int(min(W - 1, np.ceil(px.max()) + 1))
        y0 = int(max(0, np.floor(py.min()) - 1)); y1 = int(min(H - 1, np.ceil(py.max()) + 1))
        if x1 < x0 or y1 < y0 or (x1 - x0) > 400 or (y1 - y0) > 400: continue
        e1x = c[1, 0] - c[0, 0]; e1y = c[1, 1] - c[0, 1]; e1z = c[1, 2] - c[0, 2]
        e2x = c[2, 0] - c[0, 0]; e2y = c[2, 1] - c[0, 1]; e2z = c[2, 2] - c[0, 2]
        nx = e1y * e2z - e1z * e2y; ny = e1z * e2x - e1x * e2z; nz = e1x * e2y - e1y * e2x
        e11 = e1x * e1x + e1y * e1y + e1z * e1z; e22 = e2x * e2x + e2y * e2y + e2z * e2z; e12 = e1x * e2x + e1y * e2y + e1z * e2z
        det = e11 * e22 - e12 * e12
        if det < 1e-18: continue
        Tn = tex.shape[1]
        for py_ in range(y0, y1 + 1):
            for px_ in range(x0, x1 + 1):
                dx = (px_ - cx) / fx; dy = (py_ - cy) / fy
                wx = Rt[0, 0] * dx + Rt[1, 0] * dy + Rt[2, 0]; wy = Rt[0, 1] * dx + Rt[1, 1] * dy + Rt[2, 1]; wz = Rt[0, 2] * dx + Rt[1, 2] * dy + Rt[2, 2]
                den = nx * wx + ny * wy + nz * wz
                if abs(den) < 1e-12: continue
                t = (nx * (c[0, 0] - C[0]) + ny * (c[0, 1] - C[1]) + nz * (c[0, 2] - C[2])) / den
                if t <= 0.05 or t >= zb[py_, px_]: continue
                qx = C[0] + t * wx - c[0, 0]; qy = C[1] + t * wy - c[0, 1]; qz = C[2] + t * wz - c[0, 2]
                a1 = qx * e1x + qy * e1y + qz * e1z; a2 = qx * e2x + qy * e2y + qz * e2z
                u = (a1 * e22 - a2 * e12) / det; v = (a2 * e11 - a1 * e12) / det
                if u < -grow or u > 1 + grow or v < -grow or v > 1 + grow: continue
                uc = min(max(u, 0.0), 1.0); vc = min(max(v, 0.0), 1.0)
                fu = uc * Tn - 0.5; fv = vc * Tn - 0.5
                iu = int(np.floor(fu)); iv = int(np.floor(fv)); du = fu - iu; dv = fv - iv
                iu0 = min(max(iu, 0), Tn - 1); iu1 = min(max(iu + 1, 0), Tn - 1); iv0 = min(max(iv, 0), Tn - 1); iv1 = min(max(iv + 1, 0), Tn - 1)
                al = (tex[i, iv0, iu0, 3] * (1 - du) * (1 - dv) + tex[i, iv0, iu1, 3] * du * (1 - dv) + tex[i, iv1, iu0, 3] * (1 - du) * dv + tex[i, iv1, iu1, 3] * du * dv)
                if al < 0.5: continue
                for ch in range(3):
                    img[py_, px_, ch] = (tex[i, iv0, iu0, ch] * (1 - du) * (1 - dv) + tex[i, iv0, iu1, ch] * du * (1 - dv) + tex[i, iv1, iu0, ch] * (1 - du) * dv + tex[i, iv1, iu1, ch] * du * dv)
                zb[py_, px_] = t
    return img, zb


def render_layer_zb(S, cam, W, H, grow=0.04):
    if len(S) == 0: return np.zeros((H, W, 3), np.float32), np.full((H, W), 1e9, np.float32)
    z = ((S.P - cam.C) @ cam.R)[:, 2]
    order = np.argsort(z).astype(np.int64)
    return _raster_zb(order, S.corners.astype(np.float64), S.tex.astype(np.float32), W, H, cam.fx, cam.fy, cam.cx, cam.cy, cam.R.T.copy(), cam.C.astype(np.float64), grow)
