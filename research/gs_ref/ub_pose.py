"""Pose lever on the upper bound: how much of the held-out gap is the ARKit pose error of the EVALUATION camera? The gsmax map (from ub.py) is kept FIXED; each held-out frame's camera is corrected by a small 6-DoF update (rotation vector, translation) that minimises
the photometric error on its own product pixels (Levenberg-Marquardt with finite-difference Jacobian at 320x240), i.e. test-time pose optimisation. Only the CAMERA is changed (the map never sees the held-out photo), but the photo IS used to align the camera: this is an upper-bound diagnostic, not a real-time method.
Then the render and the IBR (map depth) are evaluated at 640x480 with the corrected camera. Correction magnitudes are reported (deg, cm). usage: python ub_pose.py P1|P2"""
import os, sys, json
import numpy as np, cv2
sys.path.insert(0, '.')
import gtlib as g
import gsref
PROTO = sys.argv[1]; TAGX = os.environ.get('TAGX', ''); OUT = os.environ.get('OUTDIR', 'out_ub')
P = g.Photos(); n = P.n; z = np.load(os.path.join(OUT, f'map_gsmax_{PROTO}{TAGX}.npz')); M = {k: z[k] for k in z.files}
BLOCKS = [(17, 23), (37, 43), (57, 63), (77, 83), (97, 103)]
HELD = set(i for i in range(n) if i % 10 == 5) if PROTO == 'P1' else set(i for a, b in BLOCKS for i in range(a, b + 1))
valid = lambda i: P.mask[i].sum() > 50
train = [i for i in range(n) if i not in HELD and valid(i)]; held = [i for i in sorted(HELD) if valid(i)]
yy, xx = np.mgrid[:g.EH, :g.EW]
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
def cam_with(v, p, w=g.EW, h=g.EH):
    c = dict(P.cam(v, w, h)); c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]; return c
def small(v): return cv2.resize(P.gt[v], (320, 240), interpolation=cv2.INTER_AREA), cv2.resize(P.mask[v].astype(np.uint8), (320, 240), interpolation=cv2.INTER_NEAREST) > 0
def residual(v, p, gts, ms, Mx):
    img, dep, Tf, st = gsref.render(Mx['mu'], Mx['logs'], Mx['quat'], Mx['col'], Mx['opa'], cam_with(v, p, 320, 240), **g.DISPLAY); return ((img - gts) * ms[..., None]).ravel()
def refine(v, Mx, iters=10):
    gts, ms = small(v); p = np.zeros(6); lam = 1e-2; r = residual(v, p, gts, ms, Mx); f = float(r @ r); steps = np.array([0.002] * 3 + [0.002] * 3)
    for _ in range(iters):
        J = np.stack([(residual(v, p + np.eye(6)[k] * steps[k], gts, ms, Mx) - r) / steps[k] for k in range(6)], 1); A = J.T @ J; b = J.T @ r
        for _ in range(4):
            d = -np.linalg.solve(A + lam * np.diag(np.diag(A) + 1e-9), b); r2 = residual(v, p + d, gts, ms, Mx); f2 = float(r2 @ r2)
            if f2 < f: p = p + d; r = r2; f = f2; lam = max(lam / 3, 1e-6); break
            lam *= 4
        else: break
        if np.linalg.norm(d[:3]) < 1e-5 and np.linalg.norm(d[3:]) < 1e-5: break
    return p
def psnr(img, v): m = P.mask[v]; return float(-10 * np.log10(max(((img - P.gt[v]) ** 2)[m].mean(), 1e-12)))
# IBR with the map depth (as in ub.py)
def depth_map(i):
    img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], P.cam(i), **g.DISPLAY); A = 1 - Tf; zz = dep / np.maximum(A, 1e-3); return np.where(A > 0.5, zz, 0).astype(np.float32)
cache = {}
def zmap(s):
    if s not in cache: cache[s] = depth_map(s)
    return cache[s]
def warp(s, ct):
    cs = P.cam(s); zz = zmap(s); m = zz > 0; x = (xx[m] - cs['cx']) / cs['fx'] * zz[m]; y = (yy[m] - cs['cy']) / cs['fy'] * zz[m]; Xw = np.stack([x, y, zz[m]], 1) @ cs['Rcw'] + cs['C']; pt = (Xw - ct['C']) @ ct['Rcw'].T; ok = pt[:, 2] > 0.1; pt = pt[ok]; col = P.gt[s][m][ok]
    u = ct['fx'] * pt[:, 0] / pt[:, 2] + ct['cx']; w = ct['fy'] * pt[:, 1] / pt[:, 2] + ct['cy']; o = np.argsort(-pt[:, 2]); u, w, col = u[o], w[o], col[o]; img = np.zeros((g.EH, g.EW, 3), np.float32); fill = np.zeros((g.EH, g.EW), bool)
    for du in (0, 1):
        for dw in (0, 1):
            ui = np.floor(u).astype(int) + du; wi = np.floor(w).astype(int) + dw; k = (ui >= 0) & (ui < g.EW) & (wi >= 0) & (wi < g.EH); img[wi[k], ui[k]] = col[k]; fill[wi[k], ui[k]] = True
    return img, fill
def ibr(v, ct, K=4):
    c = []
    for s in train:
        cs = P.cam(s); d = float(np.linalg.norm(cs['C'] - ct['C'])); a = float(np.degrees(np.arccos(np.clip(cs['Rcw'][2] @ ct['Rcw'][2], -1, 1)))); c.append((d + 0.004 * a, s))
    c.sort(); out = np.zeros((g.EH, g.EW, 3), np.float32); fill = np.zeros((g.EH, g.EW), bool)
    for _, s in c[:K]: im, f = warp(s, ct); add = f & ~fill; out[add] = im[add]; fill |= f
    return out
rows = []
print(PROTO, 'held-out frames', len(held), '| pose refinement of the EVALUATION cameras only (map fixed)')
print('frame | correction (deg, cm) | 3DGS PSNR ARKit -> refined | IBR(map) PSNR ARKit -> refined')
for v in held:
    p = refine(v, M); img0, _, _ = g.render(M, P.cam(v)); img1, _, _ = g.render(M, cam_with(v, p)); i0 = ibr(v, P.cam(v)); i1 = ibr(v, cam_with(v, p))
    r = dict(frame=v, rot_deg=float(np.degrees(np.linalg.norm(p[:3]))), trans_cm=float(100 * np.linalg.norm(p[3:])), gs_before=psnr(img0, v), gs_after=psnr(img1, v), ibr_before=psnr(i0, v), ibr_after=psnr(i1, v)); rows.append(r)
    print(f"{v:3d} | {r['rot_deg']:.2f} deg, {r['trans_cm']:.1f} cm | {r['gs_before']:.2f} -> {r['gs_after']:.2f} | {r['ibr_before']:.2f} -> {r['ibr_after']:.2f}", flush=True)
    if v in held[::max(1, len(held) // 4)]:
        g.imwrite(os.path.join(OUT, f'{PROTO}{TAGX}_pose_gs_view{v}.png'), img1); g.imwrite(os.path.join(OUT, f'{PROTO}{TAGX}_pose_ibr_view{v}.png'), i1)
mean = lambda k: float(np.mean([r[k] for r in rows]))
print(f"\nmean: correction {mean('rot_deg'):.2f} deg / {mean('trans_cm'):.1f} cm | 3DGS {mean('gs_before'):.2f} -> {mean('gs_after'):.2f} | IBR(map) {mean('ibr_before'):.2f} -> {mean('ibr_after'):.2f}")
json.dump(rows, open(os.path.join(OUT, f'ub_pose_{PROTO}{TAGX}.json'), 'w'), indent=1)
