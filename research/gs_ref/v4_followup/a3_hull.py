"""test_10 edge-wobble experiment (PC research; photos stay local).
Variants (all: same refined poses, same K=5 nearest photos, same occlusion rule, SS2, smooth_sil as the app baseline):
  V0  baseline        : depth = saved-map depth (alpha>0.5, mask+7px) cut by the per-photo edge layer; output silhouette = Bm coverage (current app/PC chain)
  V1  hull depth      : depth = visual-hull front surface (carved from all trusted Vision masks) inside the edge layer; output silhouette = hull projected at the target
  V2  map+hull        : map depth where it agrees with the hull surface within TOL, hull depth elsewhere; output silhouette = hull at the target
  V3  V2 + smoothing  : per-source blend weights low-passed across frames (EMA) with up to K+2 sources kept while fading (orbit video only)
Metrics:
  leave-out at 12 photo poses (sources exclude |i-t|<=10; the hull is re-carved WITHOUT those views): PSNR in the GT matte, silhouette IoU vs the GT matte (>0.5)
  orbit (elev = capture median, 360 deg in 2 deg steps): temporal second difference of alpha per edge pixel (wobble, px-ish) and of luma inside (colour flicker); 3DGS = rigid reference
usage: python a3_hull.py <OUT>"""
import os, sys, json, time
os.environ['DATA'] = '10'
sys.path.insert(0, r'C:\projects\gonggi-ios-gs3\research\gs_ref')
import numpy as np, cv2
from scipy import ndimage
import gsref, bmcore
from bm_edge import matte
P = bmcore.P; g = bmcore.g; EW, EH = bmcore.EW, bmcore.EH
OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True)
CA = r'C:\Users\emili\Downloads\best_3d_quality_before_friday\test10_analysis\cache'
CD = os.path.join(OUT, 'cache'); os.makedirs(CD, exist_ok=True)
M = g.load_map()
views = [i for i in range(P.n) if P.mask[i].sum() > 50 and P.fr[i]['trusted']]
md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}
TOL = float(os.environ.get('TOL', 0.02)); VOX = float(os.environ.get('VOX', 0.005)); SS = 2
OUTFRAC = float(os.environ.get('OUTFRAC', 0.2))


def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12:
        return np.eye(3)
    k = r / th
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K


cam0 = P.cam
POSE = {int(k): np.array(v[0]) for k, v in json.load(open(os.path.join(CA, 'poses.json'))).items()}


def cam(i, w=EW, h=EH):
    c = dict(cam0(i, w, h))
    if i in POSE:
        p = POSE[i]; c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]
    return c


P.cam = cam
bmcore.SS = SS; bmcore.HW = EW * SS; bmcore.HH = EH * SS
HW, HH = EW * SS, EH * SS
yy, xx = np.mgrid[:EH, :EW]


def R_(c):
    return gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], c, **g.DISPLAY)


# ---------------- per-photo inputs (cached)
def cached(name, fn):
    f = os.path.join(CD, name)
    if os.path.exists(f):
        return np.load(f)
    a = fn(); np.save(f, a); return a


def zmap(i):
    def f():
        img, dep, Tf, st = R_(cam(i)); al = 1 - Tf
        return np.where((al > 0.5) & md[i], dep / np.maximum(al, 1e-3), 0).astype(np.float32)
    return cached(f'zmap_{i}.npy', f)


def layer(i):
    def f():
        a = matte(i); big = cv2.resize(a, (EW * 3, EH * 3), interpolation=cv2.INTER_CUBIC); big = cv2.GaussianBlur(big, (0, 0), 4.0)
        m = ndimage.binary_fill_holes((big > 0.5).astype(np.uint8)).astype(np.uint8)
        m = cv2.resize(m.astype(np.float32), (EW, EH), interpolation=cv2.INTER_AREA) > 0.5
        return cv2.dilate(m.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))) > 0
    return cached(f'layer_{i}.npy', f)


# ---------------- visual hull
ctr = np.median(M['mu'][M['opa'] > 0.3], 0)
sel = (M['opa'] > 0.3) & (np.linalg.norm(M['mu'] - ctr, axis=1) < 0.8)
lo = np.percentile(M['mu'][sel], 0.5, 0) - 0.06; hi = np.percentile(M['mu'][sel], 99.5, 0) + 0.06
ax = [np.arange(lo[k], hi[k], VOX) for k in range(3)]
G = np.stack(np.meshgrid(*ax, indexing='ij'), -1).reshape(-1, 3).astype(np.float32); GS = tuple(len(a) for a in ax)
print('hull grid', GS, len(G), flush=True)
MASKD = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((5, 5), np.uint8)) > 0 for i in views}


def carve(use):
    out = np.zeros(len(G), np.int32); seen = np.zeros(len(G), np.int32)
    for i in use:
        c = cam(i); pt = (G - c['C']) @ c['Rcw'].T; z = pt[:, 2]; ok = z > 0.05
        u = np.round(c['fx'] * pt[:, 0] / np.maximum(z, 1e-6) + c['cx']).astype(np.int64); v = np.round(c['fy'] * pt[:, 1] / np.maximum(z, 1e-6) + c['cy']).astype(np.int64)
        inf = ok & (u >= 0) & (u < EW) & (v >= 0) & (v < EH); m = np.zeros(len(G), bool); m[inf] = MASKD[i][v[inf], u[inf]]
        seen += inf; out += inf & ~m
    occ = (seen >= 10) & (out <= np.maximum(3, OUTFRAC * seen))
    o = occ.reshape(GS).astype(np.float32); o = ndimage.gaussian_filter(o, 1.0) > 0.5
    o = ndimage.binary_fill_holes(o)
    lab, n = ndimage.label(o)
    if n > 1:
        sz = ndimage.sum(o, lab, range(1, n + 1)); o = lab == (1 + int(np.argmax(sz)))
    surf = o & ~ndimage.binary_erosion(o)
    return o, G[surf.ravel()]


def splat_depth(pts, c, ssn=1):
    W, H = c['W'] * ssn, c['H'] * ssn
    pt = (pts - c['C']) @ c['Rcw'].T; z = pt[:, 2]; ok = z > 0.05; pt = pt[ok]; z = z[ok]
    u = (c['fx'] * pt[:, 0] / z + c['cx'] + 0.5) * ssn - 0.5; v = (c['fy'] * pt[:, 1] / z + c['cy'] + 0.5) * ssn - 0.5
    fp = np.clip(np.ceil(VOX * c['fx'] * ssn / z * 1.5), 1, 8).astype(int)
    zb = np.full((H, W), np.inf, np.float32); o = np.argsort(-z); u, v, z, fp = u[o], v[o], z[o], fp[o]
    for f in np.unique(fp):
        s = fp == f
        for du in range(f):
            for dv in range(f):
                ui = np.floor(u[s] - (f - 1) / 2).astype(int) + du; vi = np.floor(v[s] - (f - 1) / 2).astype(int) + dv; k = (ui >= 0) & (ui < W) & (vi >= 0) & (vi < H)
                np.minimum.at(zb, (vi[k], ui[k]), z[s][k].astype(np.float32))
    return zb


def hull_alpha(surf, c):
    zb = splat_depth(surf, c, 1); m = np.isfinite(zb).astype(np.uint8)
    m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8)); m = ndimage.binary_fill_holes(m).astype(np.float32)
    b = cv2.GaussianBlur(m, (0, 0), 1.0); t = np.clip((b - 0.3) / 0.4, 0, 1); return (t * t * (3 - 2 * t)).astype(np.float32)


def hull_depth(surf, i):
    zb = splat_depth(surf, cam(i), 1); zb = np.where(np.isfinite(zb), zb, 0).astype(np.float32)
    return zb


def zsrc_fn(variant, surf, tag):
    C = {}

    def f(i):
        if i in C:
            return C[i]
        L = layer(i); zm = zmap(i)
        if variant == 'V0':
            z = np.where(L, zm, 0)
        else:
            zh = cached(f'zhull_{tag}_{i}.npy', lambda: hull_depth(surf, i))
            if variant == 'V1':
                z = np.where(L, np.where(zh > 0, zh, zm), 0)
            else:
                agree = (zm > 0) & (zh > 0) & (np.abs(zm - zh) <= TOL)
                z = np.where(L, np.where(agree, zm, np.where(zh > 0, zh, zm)), 0)
        C[i] = z.astype(np.float32); return C[i]
    return f


# ---------------- blend with explicit weights (same rules as bmcore.blend)
def weights_for(ct, srcs, K=5):
    r = bmcore.ranked(ct, srcs); K = min(K, len(r) - 1); dK = r[K][0]
    return {s: max(0.0, 1 - d / dK) ** 3 for d, s, a in r[:K] if d < dK}


def blend_w(ct, wts, zfun):
    parts = [(w, s) + bmcore.warp_ss(s, ct, zfun(s)) for s, w in wts.items() if w > 1e-4]
    if not parts:
        return np.zeros((EH, EW, 3), np.float32), np.zeros((EH, EW), np.float32)
    zmin = np.min(np.stack([p[3] for p in parts]), 0); num = np.zeros((HH, HW, 3), np.float32); den = np.zeros((HH, HW), np.float32)
    for w, s, im, zb in parts:
        keep = np.isfinite(zb) & (zb <= zmin * 1.04 + 0.01); ww = (w * keep).astype(np.float32); num += im * ww[..., None]; den += ww
    cov = den > 0; col = np.where(cov[..., None], num / np.maximum(den, 1e-9)[..., None], 0)
    lo_ = (col * cov[..., None]).reshape(EH, SS, EW, SS, 3).mean((1, 3)); al = cov.reshape(EH, SS, EW, SS).mean((1, 3)).astype(np.float32)
    return lo_.astype(np.float32), al


def smooth_sil(pm, alp, sigma=1.5, lo_=0.2, hi_=0.6):
    col = pm / np.maximum(alp, 1e-3)[..., None]; have = alp > 0.02
    if have.any():
        d, (iy, ix) = ndimage.distance_transform_edt(~have, return_indices=True); col = np.where(have[..., None], col, col[iy, ix])
    b = cv2.GaussianBlur(alp, (0, 0), sigma); t = np.clip((b - lo_) / (hi_ - lo_), 0, 1); a2 = (t * t * (3 - 2 * t)).astype(np.float32)
    return col.astype(np.float32), a2


def frame(variant, ct, wts, zfun, surf):
    pm, al = blend_w(ct, wts, zfun); col, a2 = smooth_sil(pm, al)
    if variant != 'V0':
        a2 = hull_alpha(surf, ct)
    return (col * a2[..., None]).astype(np.float32), a2


def u8(x):
    return (np.clip(x, 0, 1) * 255).astype(np.uint8)


def lab(x, t):
    x = u8(x).copy(); cv2.putText(x, t, (8, 24), 0, 0.65, (255, 255, 0), 2); return x


def gtm(i):
    a = matte(i); return a


res = {'note': 'PC research on test_10 device data; A15 not measured; hull carved from Vision masks (dilated 2 px, <=OUTFRAC out votes).', 'TOL_m': TOL, 'OUTFRAC': OUTFRAC, 'VOX_m': VOX}
t0 = time.time()
occ_all, surf_all = carve(views); print('hull all: occupied', int(occ_all.sum()), 'surface pts', len(surf_all), 'carve s', round(time.time() - t0, 1), flush=True)
np.save(os.path.join(CD, 'hull_surf_all.npy'), surf_all)
res['hull'] = dict(grid=list(GS), occupied=int(occ_all.sum()), surface=int(len(surf_all)))
# hull vs map panel thickness check
pt = surf_all
# ---------------- (1) leave-out
az = {i: float(np.degrees(np.arctan2(*(cam0(i)['C'] - ctr)[[0, 2]]))) for i in views}
tests = [min(views, key=lambda i: abs(((az[i] - a + 180) % 360) - 180)) for a in range(-180, 180, 30)]
LO = []
for t in tests:
    srcs = [i for i in views if abs(i - t) > 10]; tag = f'lo{t}'
    hf = os.path.join(CD, f'hull_surf_{tag}.npy')
    if os.path.exists(hf):
        surf = np.load(hf)
    else:
        _, surf = carve(srcs); np.save(hf, surf)
    ct = cam(t); gt = P.gt[t]; ga = gtm(t); gm = ga > 0.5; row = dict(frame=t, az=round(az[t]))
    tiles = [lab(gt * ga[..., None], 'photo')]
    for V in ('V0', 'V1', 'V2'):
        zf = zsrc_fn(V, surf, tag); im, a2 = frame(V, ct, weights_for(ct, srcs), zf, surf)
        e = ((im - gt * ga[..., None]) ** 2)[cv2.dilate(gm.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0].mean()
        sil = a2 > 0.5; row[V] = dict(psnr=round(float(10 * np.log10(1 / max(e, 1e-12))), 2), iou=round(float((sil & gm).sum() / max(1, (sil | gm).sum())), 3))
        tiles.append(lab(im, V))
    gi, dep, Tf, _ = R_(ct); gimg = gi * (1 - Tf)[..., None]; e = ((gimg - gt * ga[..., None]) ** 2)[cv2.dilate(gm.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0].mean()
    row['3DGS'] = dict(psnr=round(float(10 * np.log10(1 / max(e, 1e-12))), 2), iou=round(float((((1 - Tf) > 0.5) & gm).sum() / max(1, (((1 - Tf) > 0.5) | gm).sum())), 3)); tiles.append(lab(gimg, '3DGS'))
    ys, xs = np.where(cv2.dilate(gm.astype(np.uint8), np.ones((61, 61), np.uint8)) > 0)
    cv2.imencode('.png', cv2.cvtColor(np.concatenate([x[ys.min():ys.max(), xs.min():xs.max()] for x in tiles], 1), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, f'leaveout_f{t:03d}.png'))
    LO.append(row); print(row, flush=True)
res['leave_out'] = LO
for V in ('V0', 'V1', 'V2', '3DGS'):
    res.setdefault('leave_out_median', {})[V] = dict(psnr=float(np.median([r[V]['psnr'] for r in LO])), iou=float(np.median([r[V]['iou'] for r in LO])))
print('leave-out median', res['leave_out_median'], flush=True)
json.dump(res, open(os.path.join(OUT, 'result.json'), 'w'), indent=1)
# ---------------- (2) orbit video + wobble metric
up = np.array([0, 1, 0.]); el0 = float(np.median([np.degrees(np.arcsin((cam0(i)['C'] - ctr)[1] / np.linalg.norm(cam0(i)['C'] - ctr))) for i in views]))
D0 = float(np.median([np.linalg.norm(cam0(i)['C'] - ctr) for i in views])); ref = cam(views[0]); ZOOM = 1.6


def look(C, tgt):
    z = tgt - C; z /= np.linalg.norm(z); x = np.cross(-up, z); x /= np.linalg.norm(x); yv = np.cross(z, x)
    c = dict(ref); c['C'] = C; c['Rcw'] = np.stack([x, yv, z]); c['fx'] = ref['fx'] * ZOOM; c['fy'] = ref['fy'] * ZOOM; return c


STEP = float(os.environ.get('STEP', 2.0)); azs = np.arange(-180, 180, STEP)
cams = []
for a in azs:
    h = np.array([np.sin(np.radians(a)), 0, np.cos(np.radians(a))]); dv = h * np.cos(np.radians(el0)) + up * np.sin(np.radians(el0)); cams.append(look(ctr + dv * D0, ctr))
seqs = {V: [] for V in ('V0', 'V1', 'V2', 'V3', '3DGS')}
zf = {V: zsrc_fn(V, surf_all, 'all') for V in ('V0', 'V1', 'V2')}; zf['V3'] = zf['V2']
ema = {}; A_EMA = float(os.environ.get('EMA', 0.6))
vw = cv2.VideoWriter(os.path.join(OUT, 'orbit_compare.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 15, (EW * 2, EH * 2))
t1 = time.time()
for n, ct in enumerate(cams):
    w = weights_for(ct, views)
    tgt = {s: w.get(s, 0.0) for s in set(w) | set(ema)}
    ema = {s: (A_EMA * ema.get(s, 0.0) + (1 - A_EMA) * v) if n > 0 else v for s, v in tgt.items()}
    ema = dict(sorted(((s, v) for s, v in ema.items() if v > 1e-3), key=lambda kv: -kv[1])[:7])
    tiles = []
    for V in ('V0', 'V2', 'V3'):
        im, a2 = frame(V, ct, ema if V == 'V3' else w, zf[V], surf_all); seqs[V].append((im, a2)); tiles.append(lab(im, {'V0': 'V0 now', 'V2': 'V2 map+hull', 'V3': 'V3 +weight smooth'}[V]))
    im1, a1 = frame('V1', ct, w, zf['V1'], surf_all); seqs['V1'].append((im1, a1))
    gi, dep, Tf, _ = R_(ct); seqs['3DGS'].append((gi * (1 - Tf)[..., None], (1 - Tf).astype(np.float32))); tiles.append(lab(gi * (1 - Tf)[..., None], '3DGS (rigid ref)'))
    vw.write(cv2.cvtColor(np.concatenate([np.concatenate(tiles[:2], 1), np.concatenate(tiles[2:], 1)], 0), cv2.COLOR_RGB2BGR))
    if n % 30 == 0:
        print('orbit frame', n, len(cams), round(time.time() - t1, 1), flush=True)
vw.release()


def wobble(seq):
    out_a, out_c = [], []
    for k in range(1, len(seq) - 1):
        a0, a1, a2_ = seq[k - 1][1], seq[k][1], seq[k + 1][1]; d2 = np.abs(a2_ - 2 * a1 + a0)
        edge = cv2.morphologyEx((a1 > 0.5).astype(np.uint8), cv2.MORPH_GRADIENT, np.ones((3, 3), np.uint8)) > 0
        out_a.append(float(d2.sum() / max(1, edge.sum())))
        L = lambda im, a: (0.299 * im[..., 0] + 0.587 * im[..., 1] + 0.114 * im[..., 2]) / np.maximum(a, 1e-3)
        inside = (a0 > 0.95) & (a1 > 0.95) & (a2_ > 0.95); inside = cv2.erode(inside.astype(np.uint8), np.ones((7, 7), np.uint8)) > 0
        out_c.append(float(np.abs(L(seq[k + 1][0], a2_) - 2 * L(seq[k][0], a1) + L(seq[k - 1][0], a0))[inside].mean()) if inside.any() else 0.0)
    return dict(edge_wobble_mean=float(np.mean(out_a)), edge_wobble_p95=float(np.percentile(out_a, 95)), colour_flicker_mean=float(np.mean(out_c)), colour_flicker_p95=float(np.percentile(out_c, 95)))


res['orbit'] = dict(elev_deg=el0, dist_m=D0, zoom=ZOOM, step_deg=STEP, frames=len(cams), ema=A_EMA, metrics={V: wobble(s) for V, s in seqs.items()})
print('orbit metrics', json.dumps(res['orbit']['metrics'], indent=1), flush=True)
json.dump(res, open(os.path.join(OUT, 'result.json'), 'w'), indent=1)
