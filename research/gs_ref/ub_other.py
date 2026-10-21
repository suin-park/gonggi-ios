"""NOVEL-VIEW rotation test on OTHER products and OFF-PATH angles (PC research; local only - photos).
For one recording (DATA = 05 armchair, 08 parking-prohibition sign, 09 bear chair): build the map from ALL its frames (sequential PC engine + batch fit, as ub.py), then render 360-degree turntables around the product at:
  onpath : the capture's own elevation/radius (what the first video did: nearest recorded frame is only a few degrees away -> IBR just replays footage)
  high   : capture elevation + 30 deg (looking more from above, never recorded)
  low    : capture elevation - 30 deg (looking more from the side/below, never recorded)
  near   : capture radius x 0.6 (closer than recorded)
Panels: 3DGS batch | IBR (3DGS-map depth, 4 nearest photos) | HYBRID (IBR where the nearest recorded photo is <=10 deg away, 3DGS beyond 20 deg, linear cross-fade in between; IBR holes are filled by 3DGS).
Each frame is labelled with the angle to the nearest recorded camera, and the distribution of that angle per path is printed. For DATA=09 the map excludes the every-10th held-out frames (as P1).
usage: DATA=08 python ub_other.py [steps]"""
import os, sys, json, time
DATA = os.environ.get('DATA', '08'); STEPS = int(sys.argv[1]) if len(sys.argv) > 1 else 3000; os.environ['DATA'] = DATA
if DATA == '09': os.environ['NPZ_PATH'] = 'C:/projects/gonggi-ios-tex3/research/product_tex/cache/t09f_p1_320.npz'
import numpy as np, cv2
import colorexplain as ce
from colorexplain import ctx, ColorRun, kf_step
import gtlib as g
import gsref
P = g.Photos(); n = min(P.n, ctx.n); OUT = os.environ.get('OUTDIR', 'out_other'); os.makedirs(OUT, exist_ok=True)
HELD = set(i for i in range(n) if i % 10 == 5) if DATA == '09' else set()
train = [i for i in range(n) if i not in HELD and P.mask[i].sum() > 50 and ctx.D['Z'][i].max() > 0]
print(DATA, 'frames', n, 'train', len(train), flush=True)
LR = dict(mu=2e-4, ls=1e-3, q=5e-4, o=0.04, c=0.012); yy, xx = np.mgrid[:g.EH, :g.EW]; dil = lambda m, k: cv2.dilate(m.astype(np.uint8), np.ones((k | 1, k | 1), np.uint8)) > 0
# ---------------- map: sequential build + batch fit with densification
r = ColorRun(ctx, 'B'); r.cfg['ins_budget'] = 10 ** 9; r.th = None
for i in train: kf_step(r, i)
G = r.G; M = {k: getattr(G, k)[:G.n].copy() for k in ('mu', 'logs', 'quat', 'col')}; M['opa'] = G.opa[:G.n].copy(); print('built', len(M['mu']), flush=True)
class Adam:
    def __init__(s, nn): s.t = np.zeros(nn, np.int32); s.m = {k: None for k in LR}; s.v = {k: None for k in LR}
    def grow(s, nn):
        s.t = np.concatenate([s.t, np.zeros(nn - len(s.t), np.int32)])
        for k in LR:
            if s.m[k] is not None: z = np.zeros((nn - len(s.m[k]),) + s.m[k].shape[1:], np.float32); s.m[k] = np.concatenate([s.m[k], z]); s.v[k] = np.concatenate([s.v[k], z])
    def step(s, M, grads, vis):
        sl = np.nonzero(vis)[0]
        if len(sl) == 0: return
        s.t[sl] += 1; c = s.t[sl].astype(np.float32)
        for key, name in (('c', 'col'), ('o', 'opa'), ('mu', 'mu'), ('ls', 'logs'), ('q', 'quat')):
            if s.m[key] is None: s.m[key] = np.zeros_like(M[name]); s.v[key] = np.zeros_like(M[name])
            gs = grads[key][sl]; s.m[key][sl] = 0.9 * s.m[key][sl] + 0.1 * gs; s.v[key][sl] = 0.99 * s.v[key][sl] + 0.01 * gs * gs; cc = c[:, None] if gs.ndim == 2 else c
            M[name][sl] -= LR[key] * (s.m[key][sl] / (1 - 0.9 ** cc)) / (np.sqrt(s.v[key][sl] / (1 - 0.99 ** cc)) + 1e-8)
        np.clip(M['col'], 0, 1, out=M['col']); np.clip(M['opa'], -3.0, 6.0, out=M['opa']); np.clip(M['logs'], np.log(5e-4), np.log(0.05), out=M['logs']); q = M['quat']; q /= np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-9)
def densify(M, opt, gacc, gcnt):
    avg = np.where(gcnt > 3, gacc / np.maximum(gcnt, 1), 0); k = max(1, int(0.05 * (avg > 0).sum())); top = np.argsort(-avg)[:k]; big = np.exp(M['logs'][top]).max(1) > 0.003; add = {kk: [] for kk in M}
    for j, isbig in zip(top, big):
        q = M['quat'][j]; x, y, z, w = q; R = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)], [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)], [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]], np.float32)
        ax = int(np.argmax(M['logs'][j])); off = R[:, ax] * 0.5 * float(np.exp(M['logs'][j][ax])) * (1 if isbig else 0.0)
        for kk in M:
            if kk == 'mu': add[kk].append(M[kk][j] + off)
            elif kk == 'logs': add[kk].append(M[kk][j] + (np.log(1 / 1.6) if isbig else 0))
            else: add[kk].append(M[kk][j])
        if isbig: M['mu'][j] = M['mu'][j] - off; M['logs'][j] = M['logs'][j] + np.log(1 / 1.6)
    for kk in M: M[kk] = np.concatenate([M[kk], np.array(add[kk], M[kk].dtype)], 0)
    nn = len(M['mu']); opt.grow(nn); return nn
rng = np.random.RandomState(7); opt = Adam(len(M['mu'])); gacc = np.zeros(len(M['mu']), np.float32); gcnt = np.zeros(len(M['mu']), np.int32); order = []; dens_at = set(np.linspace(STEPS // 8, STEPS * 7 // 8, 8).astype(int).tolist()); bg = {i: ~dil(P.mask[i], 31) for i in train}; t0 = time.time()
for it in range(1, STEPS + 1):
    if not order: order = list(rng.permutation(train))
    i = order.pop(); cam = P.cam(i); gt = P.gt[i]; m = P.mask[i]
    img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **g.DISPLAY); A = 1 - Tf; rr = img - gt; npx = max(1, int(m.sum()))
    dLdC = (rr / np.sqrt(rr * rr + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); dLdA = (0.1 * bg[i] / max(1, int(bg[i].sum()))).astype(np.float32); dLdD = np.zeros_like(A, np.float32)
    gr = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, dLdC, dLdD, dLdA); gmu, glogs, gquat, gopa, gcol = [np.array(a) for a in gr[:5]]; vis = st['proj'][:, 0] > 0.5
    fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1); vis = vis & fin
    for a in (gmu, glogs, gquat, gcol): a[~fin] = 0
    gopa[~fin] = 0; opt.step(M, dict(mu=gmu, ls=glogs, q=gquat, o=gopa, c=gcol), vis)
    if len(gacc) != len(M['mu']): gacc = np.pad(gacc, (0, len(M['mu']) - len(gacc))); gcnt = np.pad(gcnt, (0, len(M['mu']) - len(gcnt)))
    gacc[vis] += np.linalg.norm(gmu[vis], axis=1) * npx; gcnt[vis] += 1
    if it in dens_at: nn = densify(M, opt, gacc, gcnt); gacc = np.zeros(nn, np.float32); gcnt = np.zeros(nn, np.int32)
    if it % 500 == 0: print(DATA, 'fit', it, 'N', len(M['mu']), f'{time.time() - t0:.0f}s', flush=True)
print('fit done', len(M['mu']), f'{time.time() - t0:.0f}s', flush=True)
np.savez_compressed(os.path.join(OUT, f'map_{DATA}.npz'), **M)
# ---------------- IBR with map depth
cm = {}
def depth_map(i):
    if i not in cm: img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], P.cam(i), **g.DISPLAY); A = 1 - Tf; cm[i] = np.where(A > 0.5, dep / np.maximum(A, 1e-3), 0).astype(np.float32)
    return cm[i]
def warp(s, ct):
    cs = P.cam(s); z = depth_map(s); m = z > 0; x = (xx[m] - cs['cx']) / cs['fx'] * z[m]; y = (yy[m] - cs['cy']) / cs['fy'] * z[m]; Xw = np.stack([x, y, z[m]], 1) @ cs['Rcw'] + cs['C']; pt = (Xw - ct['C']) @ ct['Rcw'].T; ok = pt[:, 2] > 0.1; pt = pt[ok]; col = P.gt[s][m][ok]
    u = ct['fx'] * pt[:, 0] / pt[:, 2] + ct['cx']; w = ct['fy'] * pt[:, 1] / pt[:, 2] + ct['cy']; o = np.argsort(-pt[:, 2]); u, w, col = u[o], w[o], col[o]; img = np.zeros((g.EH, g.EW, 3), np.float32); fill = np.zeros((g.EH, g.EW), bool)
    for du in (0, 1):
        for dw in (0, 1):
            ui = np.floor(u).astype(int) + du; wi = np.floor(w).astype(int) + dw; k = (ui >= 0) & (ui < g.EW) & (wi >= 0) & (wi < g.EH); img[wi[k], ui[k]] = col[k]; fill[wi[k], ui[k]] = True
    return img, fill
def ibr(ct, K=4):
    c = []
    for s in train:
        cs = P.cam(s); d = float(np.linalg.norm(cs['C'] - ct['C'])); a = float(np.degrees(np.arccos(np.clip(cs['Rcw'][2] @ ct['Rcw'][2], -1, 1)))); c.append((d + 0.004 * a, s, a))
    c.sort(); out = np.zeros((g.EH, g.EW, 3), np.float32); fill = np.zeros((g.EH, g.EW), bool)
    for _, s, a in c[:K]: im, f = warp(s, ct); add = f & ~fill; out[add] = im[add]; fill |= f
    return out, fill, min(c[0][2], 180.0)
# ---------------- camera paths
w = np.exp(M['opa']) / (1 + np.exp(M['opa'])); centre = np.array([np.average(M['mu'][:, k], weights=w) for k in range(3)])      # opacity-weighted centre of the (product-only) map
cs_ = np.array([P.cam(i)['C'] for i in train]); d = cs_ - centre; hr = np.linalg.norm(d[:, [0, 2]], axis=1); RAD = float(np.median(hr)); EL = float(np.median(np.arctan2(d[:, 1], hr)))
az_cap = np.degrees(np.arctan2(d[:, 2], d[:, 0])); print(f'centre {centre.round(2)}, radius {RAD:.2f} m, capture elevation {np.degrees(EL):.0f} deg, capture azimuth spread {np.ptp(az_cap):.0f} deg', flush=True)
def lookat(az, el, rad):
    c = centre + np.array([np.cos(el) * np.cos(az) * rad, np.sin(el) * rad, np.cos(el) * np.sin(az) * rad]); z = centre - c; z /= np.linalg.norm(z); dn = np.array([0, -1.0, 0]); y = dn - (dn @ z) * z; y /= np.linalg.norm(y); x = np.cross(y, z); f = P.cam(train[len(train) // 2])
    return dict(Rcw=np.stack([x, y, z], 1).T, C=c, fx=f['fx'], fy=f['fy'], cx=f['cx'], cy=f['cy'], W=g.EW, H=g.EH)
def tile(img, label, size=(400, 300)): im = cv2.resize((np.clip(img, 0, 1) * 255).astype(np.uint8), size, interpolation=cv2.INTER_AREA).copy(); cv2.putText(im, label, (6, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 0), 1); return im
PATHS = {'onpath': (EL, RAD), 'high': (min(np.radians(82), EL + np.radians(30)), RAD), 'low': (max(np.radians(5), EL - np.radians(30)), RAD), 'near': (EL, RAD * 0.6)}
summary = {}
for name, (el, rad) in PATHS.items():
    angs = []; writer = None
    for k, az in enumerate(np.linspace(0, 2 * np.pi, 90, endpoint=False)):
        ct = lookat(az, el, rad); gs_img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], ct, **g.DISPLAY); gs_img = np.asarray(gs_img); A = 1 - Tf
        ib, fill, ang = ibr(ct); angs.append(ang); wgt = float(np.clip((20 - ang) / 10, 0, 1)); hyb = np.where(fill[..., None], wgt * ib + (1 - wgt) * gs_img, gs_img)
        frame = np.concatenate([tile(gs_img, f'3DGS  [{name}]'), tile(ib, f'IBR  nearest photo {ang:.0f} deg'), tile(hyb, f'HYBRID (IBR weight {wgt:.2f})')], 1)
        if writer is None: writer = cv2.VideoWriter(os.path.join(OUT, f'video_{DATA}_{name}.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (frame.shape[1], frame.shape[0]))
        writer.write(cv2.cvtColor(frame, cv2.COLOR_RGB2BGR))
        if k % 15 == 0: cv2.imencode('.png', cv2.cvtColor(frame, cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, f'video_{DATA}_{name}_f{k:02d}.png'))
    writer.release(); a = np.array(angs); summary[name] = dict(elev_deg=float(np.degrees(el)), radius_m=float(rad), nearest_angle_median=float(np.median(a)), nearest_angle_p90=float(np.percentile(a, 90)), share_over_10=float((a > 10).mean()), share_over_20=float((a > 20).mean()))
    print(DATA, name, summary[name], flush=True)
json.dump(summary, open(os.path.join(OUT, f'paths_{DATA}.json'), 'w'), indent=1)
