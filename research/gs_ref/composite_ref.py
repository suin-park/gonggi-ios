"""Slow, explicit CPU compositing reference written from the OFFICIAL graphdeco-inria/diff-gaussian-rasterization, commit 59f5f77e3ddbac3ed9db93ec2cfe99ed6c5d121d (2023-08-27, 'Added submodule license'), files cuda_rasterizer/forward.cu (renderCUDA, preprocessCUDA, computeCov2D) and auxiliary.h (in_frustum, getRect, ndc2Pix), read from raw.githubusercontent.com at that commit.
Official per-pixel rule (renderCUDA): candidates = Gaussians whose tile rectangle [floor((u-r)/16), floor((u+r+15)/16)) x same for y contains the pixel's tile, r = ceil(3*sqrt(lambda_max)) (covariance incl. +0.3 dilation); sorted by view depth z (radix sort, stable in Gaussian index); for each: d = (u,v) - pixel (pixel centre at integer coords); power = -0.5*(a*dx^2 + c*dy^2) - b*dx*dy; if power > 0 skip; alpha = min(0.99, opacity * exp(power)) where opacity = sigmoid(logit) (applied ONCE outside); if alpha < 1/255 skip; test_T = T*(1-alpha); if test_T < 1e-4: STOP (this Gaussian is NOT added); C += colour*alpha*T (colour is straight, NOT premultiplied); T = test_T.  out = C + T*background.  View-space near cull: z <= 0.2.  (computeCov2D also clamps x/z, y/z at 1.3*tan(fov) in the Jacobian: NOT replicated here - the projected values are shared.)
SCOPE: this checks the COMPOSITING and the candidate collection / depth sort given COMMON projected values (u, v, z, conic, radius, opacity logit) taken from this project's projection (which matched gsplat's projection to ~1e-4 px earlier). It does not check projection, the Jacobian clamp, SH/colour handling, or the Swift/Metal implementations, and it does not prove the whole renderer correct.
Variants (each step changes ONE rule; the app's documented deliberate rules are listed in the report as intended, not errors):
  R0  official exactly (opacity sigmoid, alpha cap 0.99, no Mahalanobis cutoff, official tile rect, stop-before-crossing, near 0.2)
  R1  R0 with the app's opacity convention a0 = 0.99*sigmoid (no cap needed)
  R2  R1 + Mahalanobis^2 <= 9 cutoff (gsref qcut)
  R3  R2 + the Gaussian that crosses T<1e-4 is INCLUDED and the loop breaks afterwards, our tile range inclusive, near = gsref near (0.15) + capmode-2 validity  == gsref's documented rule re-implemented independently
"""
import numpy as np
TILE = 16
def gather(proj, tiles, grid, variant, near_official=0.2):
    """candidate ids for each requested tile (tx,ty) in depth order (stable in index)."""
    valid = proj[:, 0] > 0.5; z = proj[:, 3]; u = proj[:, 1]; v = proj[:, 2]; r = np.ceil(proj[:, 8]) if variant == 'R0' or variant == 'R1' or variant == 'R2' else proj[:, 8]; out = {}
    if variant in ('R0',): valid = valid & (z > near_official)
    gx, gy = grid
    for (tx, ty) in tiles:
        if variant == 'R3':
            x0 = np.clip(np.floor((u - r) / TILE), 0, gx - 1); x1 = np.clip(np.floor((u + r) / TILE), 0, gx - 1); y0 = np.clip(np.floor((v - r) / TILE), 0, gy - 1); y1 = np.clip(np.floor((v + r) / TILE), 0, gy - 1); m = valid & (x0 <= tx) & (tx <= x1) & (y0 <= ty) & (ty <= y1)
        else:
            x0 = np.clip(np.trunc((u - r) / TILE), 0, gx); x1 = np.clip(np.trunc((u + r + TILE - 1) / TILE), 0, gx); y0 = np.clip(np.trunc((v - r) / TILE), 0, gy); y1 = np.clip(np.trunc((v + r + TILE - 1) / TILE), 0, gy); m = valid & (x0 <= tx) & (tx < x1) & (y0 <= ty) & (ty < y1)
        idx = np.nonzero(m)[0]; out[(tx, ty)] = idx[np.argsort(z[idx], kind='stable')]
    return out
def pixel(px, py, cand, proj, logit, col, variant, trace=False):
    f32 = np.float32; T = f32(1.0); C = np.zeros(3, np.float32); lst = []
    for i in cand:
        dx = f32(proj[i, 1] - px); dy = f32(proj[i, 2] - py); a, b, c = proj[i, 4], proj[i, 5], proj[i, 6]; q = a * dx * dx + f32(2) * b * dx * dy + c * dy * dy; power = f32(-0.5) * (a * dx * dx + c * dy * dy) - b * dx * dy
        if variant == 'R0':
            if power > 0: continue
            sig = f32(1.0 / (1.0 + np.exp(-float(logit[i])))); al = min(f32(0.99), sig * f32(np.exp(power)))
        else:
            if variant in ('R2', 'R3') and q > 9.0: continue
            al = proj[i, 7] * f32(np.exp(-0.5 * q))
        if al < f32(1.0 / 255.0): continue
        if variant == 'R3':
            w = al * T; C += col[i] * w; lst.append((int(i), float(w))); T = T * (f32(1) - al)
            if T < f32(1e-4): break
        else:
            tT = T * (f32(1) - al)
            if tT < f32(1e-4): break
            C += col[i] * al * T; lst.append((int(i), float(al * T))); T = tT
    return C, 1.0 - float(T), lst
