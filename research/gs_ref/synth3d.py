"""Synthetic ground-truth scene for the Gaussian engine (diagnostic only; exact poses and depth are NOT inputs a product can have).
Contents: a text plate (fine + coarse print), a 50-degree slanted checker board, a thin striped rod (8 mm radius), a foreground occluder sphere partly hiding the plate,
and a low-frequency background wall. World frame: x right, y down, z forward (camera at z~0 looking +z)."""
import numpy as np, cv2

_TEX = None


def tex_plate():
    global _TEX
    if _TEX is None:
        t = np.full((384, 640, 3), 235, np.uint8)
        cv2.putText(t, 'PARKING', (20, 150), cv2.FONT_HERSHEY_DUPLEX, 3.6, (20, 20, 160), 9, cv2.LINE_AA)               # coarse print
        cv2.putText(t, 'NO PARKING ZONE 0123456789', (20, 230), cv2.FONT_HERSHEY_SIMPLEX, 0.95, (30, 30, 30), 2, cv2.LINE_AA)  # fine print
        cv2.putText(t, 'abcdefghijklmnopqrstuvwxyz', (20, 275), cv2.FONT_HERSHEY_PLAIN, 1.5, (30, 30, 30), 1, cv2.LINE_AA)    # finest print
        for k in range(14): cv2.line(t, (20 + k * 44, 330), (20 + k * 44, 372), (0, 0, 0), 2 if k % 2 else 4)               # bars
        cv2.rectangle(t, (4, 4), (635, 379), (160, 20, 20), 6)
        _TEX = t
    return _TEX


def _plane_hit(o, d, p0, n):
    den = d @ n
    t = np.where(np.abs(den) > 1e-9, ((p0 - o) @ n) / den, np.inf)
    return np.where(t > 0, t, np.inf)


def render(R, C, fx, fy, cx, cy, W, H):
    ys, xs = np.mgrid[0:H, 0:W]
    d = np.stack([(xs - cx) / fx, (ys - cy) / fy, np.ones_like(xs, dtype=np.float32)], -1).reshape(-1, 3).astype(np.float32) @ R.T.astype(np.float32)
    dn = np.linalg.norm(d, axis=1, keepdims=True); d = d / dn; o = np.asarray(C, np.float32)
    n_px = len(d); best = np.full(n_px, np.inf, np.float32); rgb = np.zeros((n_px, 3), np.float32); ids = np.zeros(n_px, np.uint8)
    zfac = 1.0 / dn[:, 0]                                                    # camera z = t / |(x,y,1)|
    def put(t, color, mask=None, oid=0):
        nonlocal best, rgb, ids
        ok = np.isfinite(t) & (t < best)
        if mask is not None: ok &= mask
        best = np.where(ok, t, best); rgb = np.where(ok[:, None], color, rgb); ids = np.where(ok, oid, ids)
    # background wall z=2.6
    t = _plane_hit(o, d, np.array([0, 0, 2.6], np.float32), np.array([0, 0, -1], np.float32)); p = o + d * t[:, None]
    bg = 0.55 + 0.25 * np.sin(p[:, 0] * 2.1) * np.cos(p[:, 1] * 1.7); put(t, np.stack([bg, bg * 0.95, bg * 0.9], 1) * 255)
    # text plate at z = 1.5 (0.5 x 0.3 m), centre (0, -0.05)
    t = _plane_hit(o, d, np.array([0, 0, 1.5], np.float32), np.array([0, 0, -1], np.float32)); p = o + d * t[:, None]
    u = (p[:, 0] + 0.25) / 0.5; v = (p[:, 1] + 0.05 + 0.15) / 0.3; inside = (u >= 0) & (u < 1) & (v >= 0) & (v < 1)
    tx = tex_plate(); iu = np.clip((u * 639).astype(int), 0, 639); iv = np.clip((v * 383).astype(int), 0, 383)
    put(t, tx[iv, iu].astype(np.float32), inside, 1)
    # slanted checker board: plane through (0.45, 0.1, 1.6) tilted 50 deg about the y axis
    ang = np.radians(50); nrm = np.array([-np.sin(ang), 0, -np.cos(ang)], np.float32); p0 = np.array([0.45, 0.1, 1.6], np.float32)
    t = _plane_hit(o, d, p0, nrm); p = o + d * t[:, None]; e1 = np.array([np.cos(ang), 0, -np.sin(ang)], np.float32); e2 = np.array([0, 1, 0], np.float32)
    a = (p - p0) @ e1; b = (p - p0) @ e2; inside = (np.abs(a) < 0.22) & (np.abs(b) < 0.2)
    chk = (((np.floor(a / 0.025) + np.floor(b / 0.025)) % 2) * 160 + 60).astype(np.float32)
    put(t, np.stack([chk, chk * 0.8, 200 - chk * 0.5], 1), inside, 2)
    # thin rod: vertical cylinder radius 8 mm at x=-0.42, z=1.45, y in [-0.25, 0.2]
    ox, oz = d[:, 0], d[:, 2]; px_, pz_ = o[0] - (-0.42), o[2] - 1.45; r = 0.008
    A = ox * ox + oz * oz; B = 2 * (px_ * ox + pz_ * oz); Cq = px_ * px_ + pz_ * pz_ - r * r; disc = B * B - 4 * A * Cq
    t = np.where(disc > 0, (-B - np.sqrt(np.maximum(disc, 0))) / (2 * A), np.inf); t = np.where(t > 0, t, np.inf); p = o + d * t[:, None]
    inside = (p[:, 1] > -0.25) & (p[:, 1] < 0.2)
    stripe = ((np.floor(p[:, 1] / 0.012) % 2) * 190 + 40).astype(np.float32); put(t, np.stack([stripe, 40 + 0 * stripe, 40 + 0 * stripe], 1), inside, 3)
    # foreground occluder sphere radius 0.07 at (0.12, 0.0, 1.05)
    c = np.array([0.12, 0.0, 1.05], np.float32); oc = o - c; bq = d @ oc; cq = oc @ oc - 0.07 ** 2; disc = bq * bq - cq
    t = np.where(disc > 0, -bq - np.sqrt(np.maximum(disc, 0)), np.inf); t = np.where(t > 0, t, np.inf); p = o + d * t[:, None]
    nrm_s = (p - c) / 0.07; shade = 0.5 + 0.5 * np.clip(nrm_s @ np.array([0.4, -0.6, -0.7], np.float32), 0, 1)
    noise = 0.8 + 0.2 * np.sin(p[:, 0] * 90) * np.sin(p[:, 1] * 90 + p[:, 2] * 40)
    put(t, np.stack([200 * shade * noise, 90 * shade * noise, 40 * shade * noise], 1), None, 4)
    depth = np.where(np.isfinite(best), best * zfac, np.inf).reshape(H, W).astype(np.float32)
    return np.clip(rgb.reshape(H, W, 3) / 255.0, 0, 1).astype(np.float32), depth, ids.reshape(H, W)


def cameras(n=36, radius=0.35, look=np.array([0.05, 0.0, 1.5], np.float32)):
    cams = []
    for k in range(n):
        a = -0.5 + k / (n - 1)                                                      # -0.5..0.5 rad sweep
        C = np.array([radius * np.sin(a * 1.2), -0.03 * np.cos(a * 3), -0.1], np.float32)
        f = look - C; f /= np.linalg.norm(f); right = np.cross(f, np.array([0, 1, 0], np.float32)); right /= np.linalg.norm(right); down = np.cross(f, right)
        # camera axes (right, down, forward) as columns; with y down in the world, "down" = +y
        down = np.array([0, 1, 0], np.float32) - f * f[1]; down /= np.linalg.norm(down); right = np.cross(down, f)
        cams.append(dict(R=np.stack([right, down, f], 1).astype(np.float32), C=C))
    return cams
