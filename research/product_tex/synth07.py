"""Synthetic ground-truth scene (an armchair-like object with a face print) rendered along the real test_07 camera path, so that
 (a) the renderer can be tested with CORRECT geometry (is the ghost made by the renderer or by the depth?), and
 (b) registration methods can be scored against true depth / true novel views (incl. the app's low default pitch).
Synthetic success is NOT real-product success. Local only."""
import numpy as np, cv2


def sd_ellipsoid(p, c, r):
    q = (p - c) / r
    k0 = np.linalg.norm(q, axis=-1); k1 = np.linalg.norm(q / r, axis=-1)
    return k0 * (k0 - 1.0) / np.maximum(k1, 1e-6)


def sd_capsule(p, a, b, r):
    pa = p - a; ba = b - a
    h = np.clip((pa @ ba) / (ba @ ba), 0, 1)
    return np.linalg.norm(pa - h[..., None] * ba, axis=-1) - r


def sd_box(p, c, b, rr=0.02):
    q = np.abs(p - c) - b + rr
    return np.linalg.norm(np.maximum(q, 0), axis=-1) + np.minimum(q.max(-1), 0) - rr


def smin(a, b, k=0.06):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b * (1 - h) + a * h - k * h * (1 - h)


def sdf(p):
    body = sd_ellipsoid(p, np.array([0, -0.02, 0.0]), np.array([0.26, 0.26, 0.27]))
    back = sd_ellipsoid(p, np.array([0, 0.17, -0.20]), np.array([0.25, 0.24, 0.09]))
    armL = sd_capsule(p, np.array([-0.22, 0.10, -0.12]), np.array([-0.22, 0.10, 0.14]), 0.07)
    armR = sd_capsule(p, np.array([0.22, 0.10, -0.12]), np.array([0.22, 0.10, 0.14]), 0.07)
    d = smin(smin(smin(body, back), armL), armR)
    seat = sd_box(p, np.array([0, 0.115, 0.06]), np.array([0.15, 0.08, 0.17]), 0.04)
    d = np.maximum(d, -seat)
    return d


def normal(p, e=2e-3):
    gx = sdf(p + [e, 0, 0]) - sdf(p - [e, 0, 0]); gy = sdf(p + [0, e, 0]) - sdf(p - [0, e, 0]); gz = sdf(p + [0, 0, e]) - sdf(p - [0, 0, e])
    n = np.stack([gx, gy, gz], -1); return n / np.maximum(np.linalg.norm(n, axis=-1, keepdims=True), 1e-9)


def albedo(p):
    a = np.tile(np.array([0.90, 0.88, 0.82], np.float32), (len(p), 1))
    # brown outer back/shell
    shell = (p[:, 2] < -0.05) & (p[:, 1] < 0.28) & (np.linalg.norm(p[:, [0, 2]], axis=1) > 0.22)
    a[shell] = np.array([0.62, 0.42, 0.28], np.float32)
    # face print on the back's inner face (facing +z), eyes / nose / muzzle
    on = (p[:, 2] < -0.08) & (p[:, 2] > -0.16) & (p[:, 1] > 0.12)
    def blob(cx, cy, rx, ry): return on & ((((p[:, 0] - cx) / rx) ** 2 + ((p[:, 1] - cy) / ry) ** 2) < 1)
    a[blob(0, 0.20, 0.075, 0.055)] = np.array([0.70, 0.82, 0.95], np.float32)
    for sx in (-1, 1): a[blob(sx * 0.075, 0.285, 0.022, 0.022)] = np.array([0.05, 0.05, 0.06], np.float32)
    a[blob(0, 0.225, 0.028, 0.02)] = np.array([0.05, 0.05, 0.06], np.float32)
    # seam lines (cushion edges) and subtle stripes for texture
    seam = (np.abs(((p[:, 1] + 0.3) * 38) % 1 - 0.5) < 0.03) & (p[:, 1] < 0.12)
    a[seam] *= 0.82
    return a


def render(R, C, fx, fy, cx, cy, W, H, light=np.array([0.4, 0.8, 0.45], np.float32), iters=70):
    ys, xs = np.mgrid[0:H, 0:W]
    d = np.stack([(xs - cx) / fx, (ys - cy) / fy, np.ones_like(xs, dtype=np.float32)], -1).reshape(-1, 3).astype(np.float32) @ R.T.astype(np.float32)
    n = np.linalg.norm(d, axis=1, keepdims=True); d /= n
    o = np.asarray(C, np.float32)
    # start at the bounding sphere
    oc = o - ORIGIN; b = d @ oc; c = oc @ oc - 0.6 ** 2; disc = b * b - c
    t = np.where(disc > 0, np.maximum(-b - np.sqrt(np.maximum(disc, 0)), 0), 1e9).astype(np.float32)
    hit = np.zeros(len(d), bool); act = disc > 0
    for _ in range(iters):
        idx = np.nonzero(act)[0]
        if len(idx) == 0: break
        p = o + d[idx] * t[idx, None] - ORIGIN
        dist = sdf(p)
        t[idx] += dist
        done = dist < 5e-4; hit[idx[done]] = True
        far = t[idx] > 2.5
        act[idx[done | far]] = False
    rgb = np.zeros((len(d), 3), np.float32); z = np.full(len(d), np.inf, np.float32)
    h = np.nonzero(hit)[0]
    p = o + d[h] * t[h, None] - ORIGIN
    nr = normal(p); nr *= np.where((nr * d[h]).sum(1, keepdims=True) > 0, -1, 1)
    lam = np.clip((nr * light / np.linalg.norm(light)).sum(1), 0, 1)
    col = albedo(p) * (0.45 + 0.55 * lam[:, None])
    rgb[h] = np.clip(col, 0, 1)
    z[h] = (t[h] / n[h, 0]).astype(np.float32)               # camera z = ray distance * unit-dir z = t / |(x,y,1)|
    return rgb.reshape(H, W, 3), z.reshape(H, W), hit.reshape(H, W)


ORIGIN = np.zeros(3, np.float32)


def set_origin(o):
    global ORIGIN
    ORIGIN = np.asarray(o, np.float32)
