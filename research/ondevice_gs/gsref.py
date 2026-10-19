"""Reference differentiable 3D Gaussian rasterizer (CPU, numba) for the on-device GS optimizer design.

Semantics mirror the app's Metal renderer (RTGaussian.metal): EWA splat with +0.3 px^2 dilation,
alpha = a0*exp(-0.5 d^T Sigma2^-1 d), Mahalanobis cutoff d2 > 9, alpha < 1/255 skipped, depth-sorted (near first)
over-operator, black background. The Swift implementation (GSORaster.swift) is a line-by-line port of this file; the
gradients are validated by finite differences (test_grad.py) before porting. This is a PC research reference, not an A15
measurement.

Conventions: world->camera p = Rcw (mu - C) with Rcw = pose.rot^T. u = fx x/z + cx (pixel centres at integers).
Quaternion (x, y, z, w), normalised inside. Opacity a0 = 0.99 * sigmoid(logit). Scale s = exp(log_scale).
"""
import numpy as np
from numba import njit, prange

DIL = 0.3
ALPHA_MIN = 1.0 / 255.0
OPA_MAX = 0.99
TILE = 16


@njit(cache=True)
def _rotmat(qx, qy, qz, qw):
    R = np.empty((3, 3), np.float32)
    R[0, 0] = 1 - 2 * (qy * qy + qz * qz)
    R[1, 0] = 2 * (qx * qy + qz * qw)
    R[2, 0] = 2 * (qx * qz - qy * qw)
    R[0, 1] = 2 * (qx * qy - qz * qw)
    R[1, 1] = 1 - 2 * (qx * qx + qz * qz)
    R[2, 1] = 2 * (qy * qz + qx * qw)
    R[0, 2] = 2 * (qx * qz + qy * qw)
    R[1, 2] = 2 * (qy * qz - qx * qw)
    R[2, 2] = 1 - 2 * (qx * qx + qy * qy)
    return R


@njit(cache=True)
def _project_one(i, mu, logs, quat, opa, Rcw, C, fx, fy, cx, cy, W, H, near, qcut, capmode, capval, out):
    # out columns: 0 valid, 1 u, 2 v, 3 z, 4 ca, 5 cb, 6 cc, 7 a0, 8 radius
    out[i, 0] = 0
    d0 = mu[i, 0] - C[0]
    d1 = mu[i, 1] - C[1]
    d2 = mu[i, 2] - C[2]
    px = Rcw[0, 0] * d0 + Rcw[0, 1] * d1 + Rcw[0, 2] * d2
    py = Rcw[1, 0] * d0 + Rcw[1, 1] * d1 + Rcw[1, 2] * d2
    pz = Rcw[2, 0] * d0 + Rcw[2, 1] * d1 + Rcw[2, 2] * d2
    if pz < near:
        return
    qx = quat[i, 0]
    qy = quat[i, 1]
    qz = quat[i, 2]
    qw = quat[i, 3]
    qn = np.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
    if qn < 1e-12:
        return
    qx /= qn
    qy /= qn
    qz /= qn
    qw /= qn
    R = _rotmat(qx, qy, qz, qw)
    iz = 1.0 / pz
    A = np.empty(3, np.float32)
    B = np.empty(3, np.float32)
    for k in range(3):
        sk = np.exp(logs[i, k])
        m0 = R[0, k] * sk
        m1 = R[1, k] * sk
        m2 = R[2, k] * sk
        t0 = Rcw[0, 0] * m0 + Rcw[0, 1] * m1 + Rcw[0, 2] * m2
        t1 = Rcw[1, 0] * m0 + Rcw[1, 1] * m1 + Rcw[1, 2] * m2
        t2 = Rcw[2, 0] * m0 + Rcw[2, 1] * m1 + Rcw[2, 2] * m2
        A[k] = fx * iz * t0 - fx * px * iz * iz * t2
        B[k] = fy * iz * t1 - fy * py * iz * iz * t2
    sa = A[0] * A[0] + A[1] * A[1] + A[2] * A[2] + DIL
    sb = A[0] * B[0] + A[1] * B[1] + A[2] * B[2]
    sc = B[0] * B[0] + B[1] * B[1] + B[2] * B[2] + DIL
    det = sa * sc - sb * sb
    if det <= 1e-12:
        return
    mid = 0.5 * (sa + sc)
    rad = np.sqrt(max(0.25 * (sa - sc) * (sa - sc) + sb * sb, 0.0))
    if capmode == 1:
        # legacy Metal vertex stage: each principal axis radius (3 sigma) is clamped to capval pixels while the fragment keeps the +-3 mapping,
        # i.e. the ellipse is squeezed. Emulate by clamping the eigenvalues of the 2D covariance.
        l1 = mid + rad
        l2 = max(mid - rad, 1e-4)
        c1 = min(3.0 * np.sqrt(l1), capval) / 3.0
        c2 = min(3.0 * np.sqrt(l2), capval) / 3.0
        if 3.0 * np.sqrt(l1) > capval or 3.0 * np.sqrt(l2) > capval:
            ex = sb
            ey = l1 - sa
            ln = np.sqrt(ex * ex + ey * ey)
            if ln > 1e-6:
                ex /= ln
                ey /= ln
            else:
                ex = 1.0 if sa >= sc else 0.0
                ey = 0.0 if sa >= sc else 1.0
            n1 = c1 * c1
            n2 = c2 * c2
            sa = n1 * ex * ex + n2 * ey * ey
            sc = n1 * ey * ey + n2 * ex * ex
            sb = (n1 - n2) * ex * ey
            det = sa * sc - sb * sb
            if det <= 1e-12:
                return
            mid = 0.5 * (sa + sc)
            rad = np.sqrt(max(0.25 * (sa - sc) * (sa - sc) + sb * sb, 0.0))
    elif capmode == 2:
        if 3.0 * np.sqrt(mid + rad) > capval * max(fx, fy):
            return
    r = np.sqrt(qcut) * np.sqrt(mid + rad)
    u = fx * px * iz + cx
    v = fy * py * iz + cy
    if u + r < 0 or v + r < 0 or u - r > W - 1 or v - r > H - 1:
        return
    out[i, 0] = 1
    out[i, 1] = u
    out[i, 2] = v
    out[i, 3] = pz
    out[i, 4] = sc / det
    out[i, 5] = -sb / det
    out[i, 6] = sa / det
    out[i, 7] = OPA_MAX / (1.0 + np.exp(-opa[i]))
    out[i, 8] = r


@njit(cache=True, parallel=True)
def _project_all(mu, logs, quat, opa, Rcw, C, fx, fy, cx, cy, W, H, near, qcut, capmode, capval):
    N = mu.shape[0]
    out = np.zeros((N, 9), np.float32)
    for i in prange(N):
        _project_one(i, mu, logs, quat, opa, Rcw, C, fx, fy, cx, cy, W, H, near, qcut, capmode, capval, out)
    return out


@njit(cache=True)
def _bin(idx, proj, tw, th):
    nt = tw * th
    cnt = np.zeros(nt + 1, np.int64)
    for a in range(idx.shape[0]):
        i = idx[a]
        u = proj[i, 1]
        v = proj[i, 2]
        r = proj[i, 8]
        x0 = max(0, int(np.floor((u - r) / TILE)))
        x1 = min(tw - 1, int(np.floor((u + r) / TILE)))
        y0 = max(0, int(np.floor((v - r) / TILE)))
        y1 = min(th - 1, int(np.floor((v + r) / TILE)))
        for ty in range(y0, y1 + 1):
            for tx in range(x0, x1 + 1):
                cnt[ty * tw + tx + 1] += 1
    for t in range(nt):
        cnt[t + 1] += cnt[t]
    items = np.empty(cnt[nt], np.int32)
    fill = cnt[:-1].copy()
    for a in range(idx.shape[0]):
        i = idx[a]
        u = proj[i, 1]
        v = proj[i, 2]
        r = proj[i, 8]
        x0 = max(0, int(np.floor((u - r) / TILE)))
        x1 = min(tw - 1, int(np.floor((u + r) / TILE)))
        y0 = max(0, int(np.floor((v - r) / TILE)))
        y1 = min(th - 1, int(np.floor((v + r) / TILE)))
        for ty in range(y0, y1 + 1):
            for tx in range(x0, x1 + 1):
                t = ty * tw + tx
                items[fill[t]] = i
                fill[t] += 1
    return cnt, items


@njit(cache=True, parallel=True)
def _raster_fwd(proj, col, cnt, items, W, H, tw, th, qcut, amin, tmin):
    img = np.zeros((H, W, 3), np.float32)
    dep = np.zeros((H, W), np.float32)
    Tf = np.ones((H, W), np.float32)
    last = np.zeros((H, W), np.int32)
    nt = tw * th
    for t in prange(nt):
        ty = t // tw
        tx = t % tw
        s = cnt[t]
        e = cnt[t + 1]
        for py in range(ty * TILE, min(H, ty * TILE + TILE)):
            for px in range(tx * TILE, min(W, tx * TILE + TILE)):
                T = np.float32(1.0)
                r = np.float32(0.0)
                g = np.float32(0.0)
                b = np.float32(0.0)
                d = np.float32(0.0)
                n = 0
                for a in range(s, e):
                    i = items[a]
                    dx = px - proj[i, 1]
                    dy = py - proj[i, 2]
                    q = proj[i, 4] * dx * dx + 2 * proj[i, 5] * dx * dy + proj[i, 6] * dy * dy
                    n += 1
                    if q > qcut:
                        continue
                    al = proj[i, 7] * np.exp(-0.5 * q)
                    if al < amin:
                        continue
                    w = al * T
                    r += w * col[i, 0]
                    g += w * col[i, 1]
                    b += w * col[i, 2]
                    d += w * proj[i, 3]
                    T *= (1.0 - al)
                    if T < tmin:
                        break
                img[py, px, 0] = r
                img[py, px, 1] = g
                img[py, px, 2] = b
                dep[py, px] = d
                Tf[py, px] = T
                last[py, px] = n
    return img, dep, Tf, last


def render(mu, logs, quat, col, opa, cam, near=0.05, qcut=9.0, amin=ALPHA_MIN, tmin=1e-4, capmode=0, capval=0.0):
    """cam: dict(Rcw 3x3, C 3, fx, fy, cx, cy, W, H). Returns img (H,W,3), depth (H,W; alpha-weighted sum, not normalised),
    T (H,W) final transmittance, state (for backward)."""
    W, H = cam['W'], cam['H']
    proj = _project_all(mu, logs, quat, opa, cam['Rcw'].astype(np.float32), cam['C'].astype(np.float32),
                        np.float32(cam['fx']), np.float32(cam['fy']), np.float32(cam['cx']), np.float32(cam['cy']),
                        W, H, np.float32(near), np.float32(qcut), int(capmode), np.float32(capval))
    tw = (W + TILE - 1) // TILE
    th = (H + TILE - 1) // TILE
    idx = np.nonzero(proj[:, 0] > 0.5)[0]
    idx = idx[np.argsort(proj[idx, 3], kind='stable')].astype(np.int32)
    cnt, items = _bin(idx, proj, tw, th)
    img, dep, Tf, last = _raster_fwd(proj, col, cnt, items, W, H, tw, th, np.float32(qcut), np.float32(amin), np.float32(tmin))
    return img, dep, Tf, dict(proj=proj, cnt=cnt, items=items, last=last, tw=tw, th=th, W=W, H=H, qcut=qcut, amin=amin)


@njit(cache=True, parallel=True)
def _raster_bwd(proj, col, cnt, items, W, H, tw, th, Tf, last, dLdC, dLdD, dLdA, nchunk, qcut, amin):
    N = proj.shape[0]
    # accumulators: 0 u, 1 v, 2 ca, 3 cb, 4 cc, 5 a0, 6..8 colour, 9 z
    G = np.zeros((nchunk, N, 10), np.float32)
    nt = tw * th
    per = (nt + nchunk - 1) // nchunk
    for ch in prange(nchunk):
        for t in range(ch * per, min(nt, (ch + 1) * per)):
            ty = t // tw
            tx = t % tw
            s = cnt[t]
            for py in range(ty * TILE, min(H, ty * TILE + TILE)):
                for px in range(tx * TILE, min(W, tx * TILE + TILE)):
                    n = last[py, px]
                    T = Tf[py, px]
                    gr = dLdC[py, px, 0]
                    gg = dLdC[py, px, 1]
                    gb = dLdC[py, px, 2]
                    gd = dLdD[py, px]
                    ga = dLdA[py, px]
                    acc_a = np.float32(0.0)
                    acc_r = np.float32(0.0)
                    acc_g = np.float32(0.0)
                    acc_b = np.float32(0.0)
                    acc_d = np.float32(0.0)
                    last_a = np.float32(0.0)
                    lr = np.float32(0.0)
                    lg = np.float32(0.0)
                    lb = np.float32(0.0)
                    ld = np.float32(0.0)
                    for a in range(s + n - 1, s - 1, -1):
                        i = items[a]
                        dx = px - proj[i, 1]
                        dy = py - proj[i, 2]
                        q = proj[i, 4] * dx * dx + 2 * proj[i, 5] * dx * dy + proj[i, 6] * dy * dy
                        if q > qcut:
                            continue
                        Gk = np.exp(-0.5 * q)
                        al = proj[i, 7] * Gk
                        if al < amin:
                            continue
                        T = T / (1.0 - al)
                        w = al * T
                        G[ch, i, 6] += w * gr
                        G[ch, i, 7] += w * gg
                        G[ch, i, 8] += w * gb
                        G[ch, i, 9] += w * gd
                        acc_r = last_a * lr + (1 - last_a) * acc_r
                        acc_g = last_a * lg + (1 - last_a) * acc_g
                        acc_b = last_a * lb + (1 - last_a) * acc_b
                        acc_d = last_a * ld + (1 - last_a) * acc_d
                        acc_a = last_a + (1 - last_a) * acc_a
                        cr = col[i, 0]
                        cg = col[i, 1]
                        cb2 = col[i, 2]
                        zi = proj[i, 3]
                        lr = cr
                        lg = cg
                        lb = cb2
                        ld = zi
                        last_a = al
                        dLda = ((cr - acc_r) * gr + (cg - acc_g) * gg + (cb2 - acc_b) * gb + (zi - acc_d) * gd + (1.0 - acc_a) * ga) * T
                        G[ch, i, 5] += dLda * Gk                      # d/d a0
                        dq = dLda * proj[i, 7] * Gk * (-0.5)         # d/d(mahalanobis q)
                        G[ch, i, 2] += dq * dx * dx
                        G[ch, i, 3] += dq * 2 * dx * dy
                        G[ch, i, 4] += dq * dy * dy
                        G[ch, i, 0] += dq * (-(2 * proj[i, 4] * dx + 2 * proj[i, 5] * dy))
                        G[ch, i, 1] += dq * (-(2 * proj[i, 5] * dx + 2 * proj[i, 6] * dy))
    return G.sum(axis=0)


@njit(cache=True, parallel=True)
def _params_bwd(g2, proj, mu, logs, quat, opa, Rcw, C, fx, fy):
    N = mu.shape[0]
    gmu = np.zeros((N, 3), np.float32)
    glogs = np.zeros((N, 3), np.float32)
    gquat = np.zeros((N, 4), np.float32)
    gopa = np.zeros(N, np.float32)
    gcol = np.zeros((N, 3), np.float32)
    for i in prange(N):
        if proj[i, 0] < 0.5:
            continue
        gcol[i, 0] = g2[i, 6]
        gcol[i, 1] = g2[i, 7]
        gcol[i, 2] = g2[i, 8]
        sg = 1.0 / (1.0 + np.exp(-opa[i]))
        gopa[i] = g2[i, 5] * OPA_MAX * sg * (1 - sg)
        d0 = mu[i, 0] - C[0]
        d1 = mu[i, 1] - C[1]
        d2 = mu[i, 2] - C[2]
        px = Rcw[0, 0] * d0 + Rcw[0, 1] * d1 + Rcw[0, 2] * d2
        py = Rcw[1, 0] * d0 + Rcw[1, 1] * d1 + Rcw[1, 2] * d2
        pz = Rcw[2, 0] * d0 + Rcw[2, 1] * d1 + Rcw[2, 2] * d2
        iz = 1.0 / pz
        qn = np.sqrt(quat[i, 0] ** 2 + quat[i, 1] ** 2 + quat[i, 2] ** 2 + quat[i, 3] ** 2)
        qx = quat[i, 0] / qn
        qy = quat[i, 1] / qn
        qz = quat[i, 2] / qn
        qw = quat[i, 3] / qn
        R = _rotmat(qx, qy, qz, qw)
        s = np.empty(3, np.float32)
        for k in range(3):
            s[k] = np.exp(logs[i, k])
        Tm = np.empty((3, 3), np.float32)
        A = np.empty(3, np.float32)
        B = np.empty(3, np.float32)
        for k in range(3):
            m0 = R[0, k] * s[k]
            m1 = R[1, k] * s[k]
            m2 = R[2, k] * s[k]
            Tm[0, k] = Rcw[0, 0] * m0 + Rcw[0, 1] * m1 + Rcw[0, 2] * m2
            Tm[1, k] = Rcw[1, 0] * m0 + Rcw[1, 1] * m1 + Rcw[1, 2] * m2
            Tm[2, k] = Rcw[2, 0] * m0 + Rcw[2, 1] * m1 + Rcw[2, 2] * m2
            A[k] = fx * iz * Tm[0, k] - fx * px * iz * iz * Tm[2, k]
            B[k] = fy * iz * Tm[1, k] - fy * py * iz * iz * Tm[2, k]
        ca = proj[i, 4]
        cb = proj[i, 5]
        cc = proj[i, 6]
        # conic Q = Sigma2^-1; dL/dSigma2 = -Q G Q with G = dL/dQ (symmetric; off-diagonal halves)
        gca = g2[i, 2]
        h = 0.5 * g2[i, 3]
        gcc = g2[i, 4]
        qg00 = ca * gca + cb * h
        qg01 = ca * h + cb * gcc
        qg10 = cb * gca + cc * h
        qg11 = cb * h + cc * gcc
        m00 = qg00 * ca + qg01 * cb
        m01 = qg00 * cb + qg01 * cc
        m11 = qg10 * cb + qg11 * cc
        dsa = -m00
        dsc = -m11
        dsb = -2.0 * m01
        dA = np.empty(3, np.float32)
        dB = np.empty(3, np.float32)
        for k in range(3):
            dA[k] = 2 * dsa * A[k] + dsb * B[k]
            dB[k] = dsb * A[k] + 2 * dsc * B[k]
        J00 = fx * iz
        J02 = -fx * px * iz * iz
        J11 = fy * iz
        J12 = -fy * py * iz * iz
        dJ00 = 0.0
        dJ02 = 0.0
        dJ11 = 0.0
        dJ12 = 0.0
        dTm = np.zeros((3, 3), np.float32)
        for k in range(3):
            dJ00 += dA[k] * Tm[0, k]
            dJ02 += dA[k] * Tm[2, k]
            dJ11 += dB[k] * Tm[1, k]
            dJ12 += dB[k] * Tm[2, k]
            dTm[0, k] = J00 * dA[k]
            dTm[1, k] = J11 * dB[k]
            dTm[2, k] = J02 * dA[k] + J12 * dB[k]
        gpx = g2[i, 0] * fx * iz + dJ02 * (-fx * iz * iz)
        gpy = g2[i, 1] * fy * iz + dJ12 * (-fy * iz * iz)
        gpz = (g2[i, 0] * (-fx * px * iz * iz) + g2[i, 1] * (-fy * py * iz * iz) + g2[i, 9]
               + dJ00 * (-fx * iz * iz) + dJ02 * (2 * fx * px * iz * iz * iz)
               + dJ11 * (-fy * iz * iz) + dJ12 * (2 * fy * py * iz * iz * iz))
        for a in range(3):
            gmu[i, a] = Rcw[0, a] * gpx + Rcw[1, a] * gpy + Rcw[2, a] * gpz
        dR = np.zeros((3, 3), np.float32)
        for k in range(3):
            dM0 = Rcw[0, 0] * dTm[0, k] + Rcw[1, 0] * dTm[1, k] + Rcw[2, 0] * dTm[2, k]
            dM1 = Rcw[0, 1] * dTm[0, k] + Rcw[1, 1] * dTm[1, k] + Rcw[2, 1] * dTm[2, k]
            dM2 = Rcw[0, 2] * dTm[0, k] + Rcw[1, 2] * dTm[1, k] + Rcw[2, 2] * dTm[2, k]
            glogs[i, k] = (R[0, k] * dM0 + R[1, k] * dM1 + R[2, k] * dM2) * s[k]
            dR[0, k] = dM0 * s[k]
            dR[1, k] = dM1 * s[k]
            dR[2, k] = dM2 * s[k]
        # partials of R entries wrt normalised quaternion:
        # R00=1-2(y2+z2) R10=2(xy+zw) R20=2(xz-yw) R01=2(xy-zw) R11=1-2(x2+z2) R21=2(yz+xw) R02=2(xz+yw) R12=2(yz-xw) R22=1-2(x2+y2)
        gx = 2 * (qy * dR[1, 0] + qz * dR[2, 0] + qy * dR[0, 1] - 2 * qx * dR[1, 1] + qw * dR[2, 1]
                  + qz * dR[0, 2] - qw * dR[1, 2] - 2 * qx * dR[2, 2])
        gy = 2 * (-2 * qy * dR[0, 0] + qx * dR[1, 0] - qw * dR[2, 0] + qx * dR[0, 1] + qz * dR[2, 1]
                  + qw * dR[0, 2] + qz * dR[1, 2] - 2 * qy * dR[2, 2])
        gz = 2 * (-2 * qz * dR[0, 0] + qw * dR[1, 0] + qx * dR[2, 0] - qw * dR[0, 1] - 2 * qz * dR[1, 1]
                  + qy * dR[2, 1] + qx * dR[0, 2] + qy * dR[1, 2])
        gw = 2 * (qz * dR[1, 0] - qy * dR[2, 0] - qz * dR[0, 1] + qx * dR[2, 1] + qy * dR[0, 2] - qx * dR[1, 2])
        dot = gx * qx + gy * qy + gz * qz + gw * qw
        gquat[i, 0] = (gx - dot * qx) / qn
        gquat[i, 1] = (gy - dot * qy) / qn
        gquat[i, 2] = (gz - dot * qz) / qn
        gquat[i, 3] = (gw - dot * qw) / qn
    return gmu, glogs, gquat, gopa, gcol


def backward(mu, logs, quat, col, opa, cam, state, Tf, dLdC, dLdD, dLdA=None, nchunk=8):
    """Gradients of a scalar loss given dL/dImage (H,W,3) and dL/dDepth (H,W) (depth = alpha-weighted sum)."""
    proj = state['proj']
    if dLdA is None:
        dLdA = np.zeros_like(dLdD)
    g2 = _raster_bwd(proj, col, state['cnt'], state['items'], cam['W'], cam['H'], state['tw'], state['th'],
                     Tf, state['last'], dLdC.astype(np.float32), dLdD.astype(np.float32), dLdA.astype(np.float32), nchunk,
                     np.float32(state['qcut']), np.float32(state['amin']))
    return _params_bwd(g2, proj, mu, logs, quat, opa, cam['Rcw'].astype(np.float32), cam['C'].astype(np.float32),
                       np.float32(cam['fx']), np.float32(cam['fy']))
