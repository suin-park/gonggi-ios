"""UPPER-BOUND study on test_09 (PC research, NOT real time, NOT the app): how good can this recording get when the real-time limits are removed?
Protocols (held-out frames are never used by the map, by the depth (stereo refs/anchors), nor by any fit):
  P1 = every 10th frame (i%10==5, 11 frames; nearest captured frame ~3-10 deg)      P2 = five blocks of 7 consecutive frames (17-23, 37-43, 57-63, 77-83, 97-103; 35 frames; nearest captured frame up to ~20+ deg)
Methods on the SAME photos/poses/masks and the PC causal depth of the protocol (PC-estimated, NOT the device depth):
  gs0   : PC engine sequential build (app-like insertion + 24 its/KF) - the start of the batch fit
  gsmax : gs0 + BATCH fit on all training frames (not sequential, all frames repeatedly), free geometry+colour+opacity, 640x480 full-frame supervision, product Charbonnier + 0.1*bg alpha, densification rounds (top 5% positional gradient), many steps
  ibr_pc  : re-projection of the 4 nearest training photos with the PC depth (non-causal source set)
  ibr_map : same, with the depth rendered from the gsmax map at each source camera
  Reported by distance bucket (angle of the best source). Poses = ARKit as recorded (no pose refinement: a separate lever). Photos = the stored 960x720 JPEG, evaluated at 640x480.
usage: python ub.py P1|P2 [steps]"""
import os, sys, json, time
PROTO = sys.argv[1]; STEPS = int(sys.argv[2]) if len(sys.argv) > 2 else 6000
DENS_FRAC = float(os.environ.get('DENS_FRAC', '0.05')); DENS_ROUNDS = int(os.environ.get('DENS_ROUNDS', '8')); MAXN = int(os.environ.get('MAXN', '1000000')); TAGX = os.environ.get('TAGX', '')   # capacity-expanded ceiling: DENS_FRAC/DENS_ROUNDS/MAXN
os.environ['N_FRAMES'] = '118'; os.environ['NPZ_PATH'] = f'C:/projects/gonggi-ios-tex3/research/product_tex/cache/t09f_{PROTO.lower()}_320.npz'
import numpy as np, cv2
import colorexplain as ce
from colorexplain import ctx, ColorRun, kf_step
import gtlib as g
import gsref
P = g.Photos(); n = P.n; OUT = os.environ.get('OUTDIR', 'out_ub'); os.makedirs(OUT, exist_ok=True)
BLOCKS = [(17, 23), (37, 43), (57, 63), (77, 83), (97, 103)]
HELD = set(i for i in range(n) if i % 10 == 5) if PROTO == 'P1' else set(i for a, b in BLOCKS for i in range(a, b + 1))
valid = lambda i: P.mask[i].sum() > 50
train = [i for i in range(n) if i not in HELD and valid(i) and ctx.D['Z'][i].max() > 0]; held = [i for i in sorted(HELD) if valid(i)]
print(PROTO, 'train frames', len(train), 'held-out frames', len(held), flush=True)
LR = dict(mu=2e-4, ls=1e-3, q=5e-4, o=0.04, c=0.012); yy, xx = np.mgrid[:g.EH, :g.EW]
dil = lambda m, k: cv2.dilate(m.astype(np.uint8), np.ones((k | 1, k | 1), np.uint8)) > 0
bg640 = {i: ~dil(P.mask[i], 31) for i in train}

# ---------------------------------------------------------------- evaluation helpers
def nearest(v, srcs, K=4):
    ct = P.cam(v); c = []
    for s in srcs:
        cs = P.cam(s); d = float(np.linalg.norm(cs['C'] - ct['C'])); a = float(np.degrees(np.arccos(np.clip(cs['Rcw'][2] @ ct['Rcw'][2], -1, 1)))); c.append((d + 0.004 * a, s, d, a))
    c.sort(); return c[:K]
def edge_psnr(img, i):
    gray = cv2.cvtColor((P.gt[i] * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY); e = (np.hypot(cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3), cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)) / 255 > 0.25) & (cv2.dilate(P.mask[i].astype(np.uint8), np.ones((5, 5), np.uint8)) > 0)
    return float(-10 * np.log10(max(((img - P.gt[i]) ** 2)[e].mean(), 1e-12)))
def score(img, al, i):
    eye = g.find_eyes(P.gt[i], P.mask[i]); mt = g.metrics(img, al, P.gt[i], P.mask[i], eye); mt['edge_psnr'] = edge_psnr(img, i)
    if eye is not None:
        gd = (P.gt[i].max(-1) < 85 / 255) & eye['face']; rd = (img.max(-1) < 85 / 255) & (al > 0.5) & eye['face']; mt['dark_iou'] = float((gd & rd).sum() / max(1, (gd | rd).sum()))
    return mt
def eval_gs(M, frames, tag, keep=()):
    res = {}
    for i in frames:
        img, al, _ = g.render(M, P.cam(i)); res[i] = score(img, al, i)
        if i in keep: g.imwrite(os.path.join(OUT, f'{PROTO}{TAGX}_{tag}_view{i}.png'), img)
    return res
def depth_pc(i):
    z = ctx.D['Z'][i].astype(np.float32) if i < ctx.n else None
    Zs = ctx.D['Z'][i]; ok = cv2.resize((Zs > 0).astype(np.uint8), (g.EW, g.EH), interpolation=cv2.INTER_NEAREST) > 0; zz = cv2.resize(Zs.astype(np.float32), (g.EW, g.EH), interpolation=cv2.INTER_LINEAR)
    return np.where(ok & (zz > 0.15) & (zz < 6), zz, 0)
def depth_map(M, i):
    img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], P.cam(i), **g.DISPLAY); A = 1 - Tf; z = dep / np.maximum(A, 1e-3); return np.where(A > 0.5, z, 0).astype(np.float32)
def warp(s, v, zfun):
    cs, ct = P.cam(s), P.cam(v); z = zfun(s); m = z > 0
    x = (xx[m] - cs['cx']) / cs['fx'] * z[m]; y = (yy[m] - cs['cy']) / cs['fy'] * z[m]; Xw = np.stack([x, y, z[m]], 1) @ cs['Rcw'] + cs['C']; pt = (Xw - ct['C']) @ ct['Rcw'].T; ok = pt[:, 2] > 0.1; pt = pt[ok]; col = P.gt[s][m][ok]
    u = ct['fx'] * pt[:, 0] / pt[:, 2] + ct['cx']; w = ct['fy'] * pt[:, 1] / pt[:, 2] + ct['cy']; o = np.argsort(-pt[:, 2]); u, w, col = u[o], w[o], col[o]
    img = np.zeros((g.EH, g.EW, 3), np.float32); fill = np.zeros((g.EH, g.EW), bool)
    for du in (0, 1):
        for dw in (0, 1):
            ui = np.floor(u).astype(int) + du; wi = np.floor(w).astype(int) + dw; k = (ui >= 0) & (ui < g.EW) & (wi >= 0) & (wi < g.EH); img[wi[k], ui[k]] = col[k]; fill[wi[k], ui[k]] = True
    return img, fill
def ibr(v, zfun, K=4):
    out = np.zeros((g.EH, g.EW, 3), np.float32); fill = np.zeros((g.EH, g.EW), bool)
    for _, s, d, a in nearest(v, train, K):
        im, f = warp(s, v, zfun); add = f & ~fill; out[add] = im[add]; fill |= f
    return out, fill

# ---------------------------------------------------------------- 1) sequential PC build (gs0)
t0 = time.time(); r = ColorRun(ctx, 'B'); r.cfg['ins_budget'] = 10 ** 9; r.th = None
for i in train: kf_step(r, i)
G = r.G; N0 = G.n; M = {k: getattr(G, nm)[:N0].copy() for k, nm in (('mu', 'mu'), ('logs', 'logs'), ('quat', 'quat'), ('col', 'col'), ('opa', 'opa'))}; t_build = time.time() - t0
print(f'gs0 built: {N0} Gaussians in {t_build:.0f}s', flush=True)
keepv = held[::max(1, len(held) // 6)]
res = {'gs0': eval_gs(M, held, 'gs0', keepv)}
# ---------------------------------------------------------------- 2) batch fit (gsmax) with densification
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
    avg = np.where(gcnt > 3, gacc / np.maximum(gcnt, 1), 0); k = max(1, int(DENS_FRAC * (avg > 0).sum())); top = np.argsort(-avg)[:k]; big = np.exp(M['logs'][top]).max(1) > 0.003; add = {kk: [] for kk in M}
    for j, isbig in zip(top, big):
        q = M['quat'][j]; x, y, z, w = q; R = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)], [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)], [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]], np.float32)
        ax = int(np.argmax(M['logs'][j])); off = R[:, ax] * 0.5 * float(np.exp(M['logs'][j][ax])) * (1 if isbig else 0.0)
        for kk in M:
            if kk == 'mu': add[kk].append(M[kk][j] + off)
            elif kk == 'logs': add[kk].append(M[kk][j] + (np.log(1 / 1.6) if isbig else 0))
            else: add[kk].append(M[kk][j])
        if isbig: M['mu'][j] = M['mu'][j] - off; M['logs'][j] = M['logs'][j] + np.log(1 / 1.6)
    for kk in M: M[kk] = np.concatenate([M[kk], np.array(add[kk], M[kk].dtype)], 0)
    nn = len(M['mu']); opt.grow(nn); return nn, k
rng = np.random.RandomState(7); opt = Adam(len(M['mu'])); gacc = np.zeros(len(M['mu']), np.float32); gcnt = np.zeros(len(M['mu']), np.int32); order = []; log = []
dens_at = set(np.linspace(STEPS // 8, STEPS * 7 // 8, DENS_ROUNDS).astype(int).tolist()); ckpt = {STEPS // 4, STEPS // 2, STEPS}; t0 = time.time()
for it in range(1, STEPS + 1):
    if not order: order = list(rng.permutation(train))
    i = order.pop(); cam = P.cam(i); gt = P.gt[i]; m = P.mask[i]
    img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **g.DISPLAY); A = 1 - Tf; rr = img - gt; npx = max(1, int(m.sum())); bg = bg640[i]
    dLdC = (rr / np.sqrt(rr * rr + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); dLdA = (0.1 * bg / max(1, int(bg.sum()))).astype(np.float32); dLdD = np.zeros_like(A, np.float32)
    gr = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, dLdC, dLdD, dLdA); gmu, glogs, gquat, gopa, gcol = [np.array(a) for a in gr[:5]]; vis = st['proj'][:, 0] > 0.5
    fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1); vis = vis & fin
    for a in (gmu, glogs, gquat, gcol): a[~fin] = 0
    gopa[~fin] = 0; opt.step(M, dict(mu=gmu, ls=glogs, q=gquat, o=gopa, c=gcol), vis)
    if len(gacc) != len(M['mu']): gacc = np.pad(gacc, (0, len(M['mu']) - len(gacc))); gcnt = np.pad(gcnt, (0, len(M['mu']) - len(gcnt)))
    gacc[vis] += np.linalg.norm(gmu[vis], axis=1) * npx; gcnt[vis] += 1
    if it in dens_at and len(M['mu']) < MAXN: nn, k = densify(M, opt, gacc, gcnt); gacc = np.zeros(nn, np.float32); gcnt = np.zeros(nn, np.int32); log.append(dict(it=it, gaussians=nn, densified=int(k)))
    if it % 500 == 0: print(PROTO, 'fit', it, 'L %.4f' % float(np.sqrt(rr * rr + 1e-4)[m].mean()), 'N', len(M['mu']), f'{time.time() - t0:.0f}s', flush=True)
    if it in ckpt: res[f'gsmax@{it}'] = eval_gs(M, held, f'gsmax{it}', keepv if it == STEPS else ()); print('checkpoint', it, 'held-out product PSNR %.2f' % np.mean([v['product_psnr'] for v in res[f'gsmax@{it}'].values()]), flush=True)
t_fit = time.time() - t0; res['gsmax'] = res[f'gsmax@{STEPS}']
# ---------------------------------------------------------------- 3) IBR with PC depth and with the gsmax map depth
cache_map = {}
def zmap(s):
    if s not in cache_map: cache_map[s] = depth_map(M, s)
    return cache_map[s]
res['ibr_pc'] = {}; res['ibr_map'] = {}; info = {}
for v in held:
    near = nearest(v, train, 4); info[v] = dict(best_source=near[0][1], dist_m=near[0][2], angle_deg=near[0][3])
    for nm, zf in (('ibr_pc', depth_pc), ('ibr_map', zmap)):
        img, fill = ibr(v, zf); res[nm][v] = score(img, fill.astype(np.float32), v); res[nm][v]['filled_in_product'] = float(fill[P.mask[v]].mean())
        if v in keepv: g.imwrite(os.path.join(OUT, f'{PROTO}{TAGX}_{nm}_view{v}.png'), img)
json.dump(dict(proto=PROTO, steps=STEPS, train=len(train), held=held, gaussians_gs0=int(N0), gaussians_gsmax=int(len(M['mu'])), seconds_build=t_build, seconds_fit=t_fit, densify=log, source_info={str(k): v for k, v in info.items()},
               results={m: {str(k): v for k, v in d.items()} for m, d in res.items()}), open(os.path.join(OUT, f'ub_{PROTO}{TAGX}.json'), 'w'), indent=1, default=float)
np.savez_compressed(os.path.join(OUT, f'map_gsmax_{PROTO}{TAGX}.npz'), **M)
# ---------------------------------------------------------------- summary by distance bucket
buckets = [(0, 6), (6, 12), (12, 20), (20, 91)]
print(f'\n{PROTO}: held-out product PSNR (dB) by the angle of the nearest captured source; n = frames')
meths = ['gs0', 'gsmax', 'ibr_pc', 'ibr_map']
print('bucket | n | ' + ' | '.join(meths) + ' | edge PSNR gsmax / ibr_map | eye recovery gsmax / ibr_map | smooth HF gsmax / ibr_map (photo 0.0036)')
for lo, hi in buckets:
    fs = [v for v in held if lo <= info[v]['angle_deg'] < hi]
    if not fs: continue
    mean = lambda m, k: np.nanmean([res[m][v].get(k, np.nan) for v in fs])
    print(f'{lo:2d}-{hi:2d} deg | {len(fs)} | ' + ' | '.join('%.2f' % mean(m, 'product_psnr') for m in meths) + ' | %.2f / %.2f' % (mean('gsmax', 'edge_psnr'), mean('ibr_map', 'edge_psnr')) + ' | %.2f / %.2f' % (mean('gsmax', 'recovery'), mean('ibr_map', 'recovery')) + ' | %.4f / %.4f' % (mean('gsmax', 'smooth_hf_render'), mean('ibr_map', 'smooth_hf_render')))
print('all  | %d | ' % len(held) + ' | '.join('%.2f' % np.mean([res[m][v]['product_psnr'] for v in held]) for m in meths))
print(f'gs0 {N0} Gaussians, build {t_build:.0f}s | gsmax {len(M["mu"])} Gaussians, fit {t_fit:.0f}s ({STEPS} steps, {STEPS * 307200 / 1e6:.0f} Mpx rendered)')
