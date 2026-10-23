"""test_10 PC Bm (same chain as e2e_device baseline = what the app ports): pose refine all frames, depth from saved map, edge layer, K=5 blend, SS3, smooth_sil.
Tests: (A) leave-out at real photo poses (exclude self, or self +-G neighbours) vs the real photo; (B) panel edge-on novel views at in-band / out-of-band elevation; (C) panel thickness in the map."""
import os, sys, json, time
os.environ['DATA'] = '10'
sys.path.insert(0, r'C:\projects\gonggi-ios-gs3\research\gs_ref')
import numpy as np, cv2
from scipy import ndimage
import gsref, bmcore
from bm_edge import matte
P = bmcore.P; g = bmcore.g; EW, EH = bmcore.EW, bmcore.EH
OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True); CDIR = os.path.join(OUT, 'cache'); os.makedirs(CDIR, exist_ok=True)
M = g.load_map(); RW, RH = 320, 240
views = [i for i in range(P.n) if P.mask[i].sum() > 50 and P.fr[i]['trusted']]
md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}


def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12:
        return np.eye(3)
    k = r / th
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K


cam0 = P.cam
POSE = {}


def cam(i, w=EW, h=EH):
    c = dict(cam0(i, w, h))
    if i in POSE:
        p = POSE[i]; c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]
    return c


def R_(c):
    return gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], c, **g.DISPLAY)


def small(i):
    return cv2.resize(P.gt[i], (RW, RH), interpolation=cv2.INTER_AREA), cv2.resize(P.mask[i].astype(np.uint8), (RW, RH), interpolation=cv2.INTER_NEAREST) > 0


def residual(i, p, gts, ms):
    c = dict(cam0(i, RW, RH)); c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]
    return ((R_(c)[0] - gts) * ms[..., None]).ravel()


def refine_pose(i, iters=8):
    gts, ms = small(i); p = np.zeros(6); lam = 1e-2; r = residual(i, p, gts, ms); f0 = f = float(r @ r); steps = np.array([0.002] * 6)
    for _ in range(iters):
        J = np.stack([(residual(i, p + np.eye(6)[k] * steps[k], gts, ms) - r) / steps[k] for k in range(6)], 1); A = J.T @ J; b = J.T @ r; moved = False
        for _ in range(4):
            dd = -np.linalg.solve(A + lam * np.diag(np.diag(A) + 1e-9), b); r2 = residual(i, p + dd, gts, ms); f2 = float(r2 @ r2)
            if f2 < f:
                p = p + dd; r = r2; f = f2; lam = max(lam / 3, 1e-6); moved = True; break
            lam *= 4
        if not moved:
            break
    return p, f0, f


pf = os.path.join(CDIR, 'poses.json'); t0 = time.time()
if os.path.exists(pf):
    d = json.load(open(pf)); POSE.update({int(k): np.array(v[0]) for k, v in d.items()}); PC = {int(k): v[1:] for k, v in d.items()}
else:
    PC = {}
    for i in views:
        p, f0, f1 = refine_pose(i); POSE[i] = p; PC[i] = [f0, f1]
    json.dump({str(k): [POSE[k].tolist()] + PC[k] for k in POSE}, open(pf, 'w'))
print('pose refine s', round(time.time() - t0, 1), flush=True)
dp = np.array([np.linalg.norm(POSE[i][3:]) for i in views]) * 1000; da = np.array([np.degrees(np.linalg.norm(POSE[i][:3])) for i in views]); red = np.array([PC[i][1] / max(PC[i][0], 1e-9) for i in views])
print('pose delta mm p50/p90', np.percentile(dp, [50, 90]).round(1), 'deg', np.percentile(da, [50, 90]).round(2), 'cost after/before p50', np.median(red).round(3), flush=True)
P.cam = cam


def layer(i):
    a = matte(i); big = cv2.resize(a, (EW * 3, EH * 3), interpolation=cv2.INTER_CUBIC); big = cv2.GaussianBlur(big, (0, 0), 4.0); m = ndimage.binary_fill_holes((big > 0.5).astype(np.uint8)).astype(np.uint8)
    m = cv2.resize(m.astype(np.float32), (EW, EH), interpolation=cv2.INTER_AREA) > 0.5
    return cv2.dilate(m.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))) > 0


ZC = {}


def zsrc(i):
    if i not in ZC:
        f = os.path.join(CDIR, f'z_{i}.npy')
        if os.path.exists(f):
            ZC[i] = np.load(f)
        else:
            img, dep, Tf, st = R_(cam(i)); al = 1 - Tf
            z = np.where((al > 0.5) & md[i], dep / np.maximum(al, 1e-3), 0).astype(np.float32); z = np.where(layer(i), z, 0).astype(np.float32); np.save(f, z); ZC[i] = z
    return ZC[i]


def smooth_sil(pm, alp, sigma=1.5, lo=0.2, hi=0.6):
    col = pm / np.maximum(alp, 1e-3)[..., None]; have = alp > 0.02; d, (iy, ix) = ndimage.distance_transform_edt(~have, return_indices=True); col = np.where(have[..., None], col, col[iy, ix])
    b = cv2.GaussianBlur(alp, (0, 0), sigma); t = np.clip((b - lo) / (hi - lo), 0, 1); a2 = (t * t * (3 - 2 * t)).astype(np.float32)
    return (col * a2[..., None]).astype(np.float32), a2


bmcore.SS = 3; bmcore.HW = EW * 3; bmcore.HH = EH * 3


def bm(ct, srcs):
    im, al = bmcore.blend(ct, srcs, zsrc); return smooth_sil(im, al)


def gs(ct):
    img, dep, Tf, st = R_(ct); return img * (1 - Tf)[..., None], 1 - Tf


def nearest(ct, srcs):
    r = bmcore.ranked(ct, srcs); return r[0][2], float(np.linalg.norm(cam(r[0][1])['C'] - ct['C']))


def u8(x):
    return (np.clip(x, 0, 1) * 255).astype(np.uint8)


def save(nm, x):
    cv2.imencode('.png', cv2.cvtColor(u8(x) if x.dtype != np.uint8 else x, cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, nm))


def lab(x, t):
    x = u8(x).copy(); cv2.putText(x, t, (8, 22), 0, 0.55, (255, 255, 0), 2); return x


def crop(x, m, pad=40):
    ys, xs = np.where(m); y0, y1 = max(0, ys.min() - pad), min(EH, ys.max() + pad); x0, x1 = max(0, xs.min() - pad), min(EW, xs.max() + pad); return x[y0:y1, x0:x1]


res = {}
ctr = np.median(M['mu'][M['opa'] > 0.3], 0)
az = {i: float(np.degrees(np.arctan2(*(cam0(i)['C'] - ctr)[[0, 2]]))) for i in views}
tests = [min(views, key=lambda i: abs(((az[i] - a + 180) % 360) - 180)) for a in range(-180, 180, 30)]
A = []
for G in (0, 4, 10):
    for t in tests:
        srcs = [i for i in views if abs(i - t) > G]; ct = cam(t); pm, a2 = bm(ct, srcs); gi, ga = gs(ct)
        m = P.mask[t]; gt = P.gt[t]; ang, dist = nearest(ct, srcs)

        def ps(x):
            e = ((x - gt) ** 2)[m].mean(); return float(10 * np.log10(1 / max(e, 1e-12)))
        sil = a2 > 0.5; iou = float((sil & m).sum() / max(1, (sil | m).sum())); hole = float((m & (a2 < 0.5)).sum() / m.sum())
        leak = float((sil & ~cv2.dilate(m.astype(np.uint8), np.ones((5, 5), np.uint8)).astype(bool)).sum() / m.sum())
        A.append(dict(G=G, frame=t, az=round(az[t]), nearest_deg=round(ang, 1), nearest_cm=round(dist * 100, 1), bm_psnr=round(ps(pm), 2), gs_psnr=round(ps(gi), 2), bm_iou=round(iou, 3), bm_hole=round(hole, 3), bm_leak=round(leak, 3)))
        if G in (0, 10):
            save(f'A_G{G}_f{t:03d}.png', np.concatenate([crop(lab(gt * m[..., None], 'photo'), m), crop(lab(pm, f'Bm G{G}'), m), crop(lab(gi, '3DGS'), m)], 1))
        print(A[-1], flush=True)
res['leave_out'] = A
for G in (0, 4, 10):
    s = [a for a in A if a['G'] == G]
    print('G', G, 'nearest deg med', np.median([a['nearest_deg'] for a in s]), 'Bm psnr med', np.median([a['bm_psnr'] for a in s]), 'GS psnr med', np.median([a['gs_psnr'] for a in s]), 'Bm iou', np.median([a['bm_iou'] for a in s]), 'leak', np.median([a['bm_leak'] for a in s]), flush=True)
mu = M['mu']; keep = (M['opa'] > 0.3) & (np.linalg.norm(mu - ctr, axis=1) < 0.8); y = mu[:, 1]; ytop = np.percentile(y[keep], 98); ybot = np.percentile(y[keep], 2)
pan = keep & (y > ybot + 0.55 * (ytop - ybot)); X = mu[pan] - mu[pan].mean(0); w, V = np.linalg.eigh(X.T @ X); nrm = V[:, 0]; tt = X @ nrm
sc = np.exp(M['logs'][pan]).max(1)
res['panel'] = dict(n=int(pan.sum()), normal=nrm.tolist(), thick_p5_p95_cm=float((np.percentile(tt, 95) - np.percentile(tt, 5)) * 100), thick_std_cm=float(tt.std() * 100),
                    width_p5_p95_cm=float((np.percentile(X @ V[:, 2], 95) - np.percentile(X @ V[:, 2], 5)) * 100), gauss_max_scale_p50_cm=float(np.median(sc) * 100))
print('panel', res['panel'], flush=True)
pc = mu[pan].mean(0); up = np.array([0, 1, 0.]); side = np.cross(nrm, up); side /= np.linalg.norm(side); D0 = float(np.median([np.linalg.norm(cam0(i)['C'] - pc) for i in views]))
ref = cam(views[0]); B = []


def look(C, tgt, zoom):
    z = tgt - C; z /= np.linalg.norm(z); x = np.cross(-up, z); x /= np.linalg.norm(x); yv = np.cross(z, x)
    c = dict(ref); c['C'] = C; c['Rcw'] = np.stack([x, yv, z]); c['fx'] = ref['fx'] * zoom; c['fy'] = ref['fy'] * zoom; return c


for nm, dirv in (('edge_on', side), ('face_on', nrm), ('diag45', (side + nrm) / np.sqrt(2))):
    for sgn in (1, -1):
        for el in (0, 30, 60):
            h = dirv * sgn; h = h - (h @ up) * up; h /= np.linalg.norm(h); dv = h * np.cos(np.radians(el)) + up * np.sin(np.radians(el)); C = pc + dv * D0
            ct = look(C, pc, 2.0); pm, a2 = bm(ct, views); gi, ga = gs(ct); ang, dist = nearest(ct, views)
            B.append(dict(view=nm, side=sgn, elev=el, nearest_deg=round(ang, 1), nearest_cm=round(dist * 100, 1))); print(B[-1], flush=True)
            mm = (a2 > 0.1) | (ga > 0.1)
            if mm.sum() > 100:
                save(f'B_{nm}_{"p" if sgn > 0 else "n"}_el{el}.png', np.concatenate([crop(lab(pm, f'Bm {nm} el{el} near {ang:.0f}deg'), mm), crop(lab(gi, '3DGS'), mm)], 1))
res['novel'] = B
json.dump(res, open(os.path.join(OUT, 'bm_analysis.json'), 'w'), indent=1)
