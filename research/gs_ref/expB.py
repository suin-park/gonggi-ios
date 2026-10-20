"""Experiment B (gate 2): with EXACT poses and depth, can the engine represent fine detail, and which part of the pipeline (supervision resolution, hi-res ROI, splitting, budget) limits it?
Diagnostic only (exact geometry is not a product input). PC reference engine (numerically fixed). Same initial map for every variant; training views and held-out views disjoint.
Usage: python expB.py [iters]   (default 600 iterations per variant, equal-iteration comparison; plus time-matched and longer-budget comparisons)"""
import os, sys, json, time, copy
GRID = int(os.environ.get('GRID', '160')); os.environ['GS_W'] = str(GRID); os.environ['GS_H'] = str(GRID * 3 // 4); os.environ.setdefault('GS_STRIDE', '2')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import synth3d as S, pc_gs, pc_abc, gsref
from skimage.metrics import structural_similarity

ITERS = int(sys.argv[1]) if len(sys.argv) > 1 else 600
OUT = os.environ.get('OUT', 'out_B' + str(GRID) + os.environ.get('TAG', '')); os.makedirs(OUT, exist_ok=True)
NF, GW, GH, HW, HH, FX = 36, GRID, GRID * 3 // 4, 960, 720, 720.0
cams = S.cameras(NF); held = lambda i: i % 6 == 3

t0 = time.time()
hi, depth_hi, ids_hi = [], [], []
for c in cams:
    rgb, z, ids = S.render(c['R'], c['C'], FX, FX, (HW - 1) / 2, (HH - 1) / 2, HW, HH); hi.append((rgb * 255).astype(np.uint8)); depth_hi.append(z); ids_hi.append(ids)
print('rendered GT in', round(time.time() - t0), 's', flush=True)
K960 = np.array([[FX, FX, (HW - 1) / 2, (HH - 1) / 2]] * NF)
sc = GW / HW
EXPO = float(os.environ.get('EXPOSURE', '0')); JPEGQ = int(os.environ.get('JPEGQ', '0')); BLUR = float(os.environ.get('BLUR', '0')); EDGEOUT = float(os.environ.get('EDGEOUT', '0'))
rngx = np.random.RandomState(9)
if EXPO > 0 or JPEGQ > 0 or BLUR > 0:                                  # image-quality degradations applied to the TRAINING photographs only (evaluation GT stays clean)
    hi_train = []
    for i, h in enumerate(hi):
        a = h.astype(np.float32)
        if BLUR > 0: a = cv2.GaussianBlur(a, (0, 0), BLUR)
        if EXPO > 0: a = a * (1 + EXPO * (2 * rngx.rand() - 1)) * (1 + 0.04 * (2 * rngx.rand(3) - 1))
        a = np.clip(a, 0, 255).astype(np.uint8)
        if JPEGQ > 0: a = cv2.imdecode(cv2.imencode('.jpg', cv2.cvtColor(a, cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, JPEGQ])[1], 1)[:, :, ::-1].copy()
        hi_train.append(a)
else:
    hi_train = hi
imgs = np.stack([cv2.resize(h, (GW, GH), interpolation=cv2.INTER_AREA) for h in hi_train])
def gridz(z):  # exact depth sampled at the grid pixel centres (no averaging across depth edges)
    ys, xs = np.mgrid[0:GH, 0:GW]; u = np.clip(((xs + 0.5) / sc - 0.5).round().astype(int), 0, HW - 1); v = np.clip(((ys + 0.5) / sc - 0.5).round().astype(int), 0, HH - 1)
    zz = z[v, u]; return np.where(np.isfinite(zz), zz, 0).astype(np.float32)
Zg = np.stack([gridz(z) for z in depth_hi])
Kg = np.stack([[FX * sc, FX * sc, ((HW - 1) / 2 + .5) * sc - .5, ((HH - 1) / 2 + .5) * sc - .5]] * NF)
DEPTH_NOISE = float(os.environ.get('DEPTH_NOISE', '0')); POSE_DEG = float(os.environ.get('POSE_DEG', '0')); POSE_MM = float(os.environ.get('POSE_MM', '0'))
rngn = np.random.RandomState(3)
Zn = Zg.copy()
if DEPTH_NOISE > 0:
    for i in range(NF):                                           # frame scale error + smooth low-frequency warp (like the measured 1-3 % neighbour disagreement)
        sm = cv2.GaussianBlur(rngn.randn(GH, GW).astype(np.float32), (0, 0), 10 * GW / 160); sm = sm / max(sm.std(), 1e-6) * DEPTH_NOISE
        Zn[i] = np.where(Zg[i] > 0, Zg[i] * (1 + rngn.randn() * DEPTH_NOISE * 0.6 + sm), 0)
if float(os.environ.get('EDGEOUT', '0')) > 0:
    for i in range(NF):
        z = Zg[i]; jump = np.zeros(z.shape, bool)
        for sh in ((0, 1), (1, 0), (0, -1), (-1, 0)): jump |= (np.abs(np.roll(z, sh, (0, 1)) - z) > 0.12)
        jump = cv2.dilate(jump.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
        pick = jump & (rngn.rand(*z.shape) < float(os.environ['EDGEOUT'])); Zn[i] = np.where(pick, z * (1 + rngn.uniform(-0.25, 0.25, z.shape)), Zn[i])
Rn = np.stack([c['R'] for c in cams]); Cn = np.stack([c['C'] for c in cams])
if POSE_DEG > 0 or POSE_MM > 0:                                   # smooth random-walk pose error shared by training and evaluation (as ARKit drift would be)
    ang = np.cumsum(rngn.randn(NF, 3), 0); ang = ang - ang.mean(0); ang = ang / max(np.abs(ang).max(), 1e-6) * np.radians(POSE_DEG)
    tr = np.cumsum(rngn.randn(NF, 3), 0); tr = tr - tr.mean(0); tr = tr / max(np.abs(tr).max(), 1e-6) * POSE_MM / 1000
    for i in range(NF):
        Rn[i] = cv2.Rodrigues(ang[i])[0].astype(np.float32) @ Rn[i]; Cn[i] = Cn[i] + tr[i]
D = dict(ids=np.arange(NF), R=Rn, C=Cn, K=Kg, imgs=imgs, Z=Zn, ZS=Zn.copy())
ctx = pc_abc.Ctx(D, hi, K960)
ctx.hi_train = hi_train
train_ids = [i for i in range(NF) if not held(i)]; held_ids = [i for i in range(NF) if held(i)]

# ---- initial map (same for every variant): insertion only (0 optimisation iterations), exact depth
r0 = pc_abc.Run(ctx, 'B', iters=0); r0.run(held, verbose=False); G0 = r0.G; N0 = G0.n
print('initial map', N0, 'gaussians; STATS', pc_gs.STATS, flush=True)

if os.environ.get('EXPORT_MAP'):   # initial map (positions + colours) for the external-engine control; dataset itself is regenerated by research/public_engine/make_dataset.py
    np.save(os.environ['EXPORT_MAP'], np.concatenate([G0.mu[:G0.n], np.clip(G0.col[:G0.n], 0, 1)], 1).astype(np.float32)); print('exported map', G0.n); sys.exit(0)

NAMES = ['mu', 'logs', 'quat', 'col', 'opa', 'm_mu', 'v_mu', 'm_ls', 'v_ls', 'm_q', 'v_q', 'm_o', 'v_o', 'm_c', 'v_c', 'steps', 'ls0', 'mu0', 'col0', 'sacc', 'scnt', 'src', 'born', 'gid', 'parent', 'nvis', 'votes', 'suspect', 'vkf', 'vpos', 'vdir']
def clone(G):
    g = pc_gs.GMap()
    while g.cap < G.cap: g._alloc(g.cap * 2)
    for k in NAMES: getattr(g, k)[:G.n] = getattr(G, k)[:G.n]
    g.n = G.n; g.next_id = getattr(G, 'next_id', G.n + 1); return g

# ---- evaluation: held-out views at 640x480, region metrics from the object-id map and GT depth discontinuities
EW, EH = pc_abc.EVAL_W, pc_abc.EVAL_H
ids_e = [cv2.resize(i, (EW, EH), interpolation=cv2.INTER_NEAREST) for i in ids_hi]
dz = []
for z in depth_hi:
    zc = cv2.resize(np.where(np.isfinite(z), z, 0), (EW, EH), interpolation=cv2.INTER_NEAREST); jump = np.zeros((EH, EW), bool)
    for sh in ((0, 2), (2, 0), (0, -2), (-2, 0)): jump |= (np.abs(np.roll(zc, sh, (0, 1)) - zc) > 0.12)
    dz.append(cv2.dilate(jump.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0)
def evaluate(G, keep=False):
    rows = []; imgs_out = {}
    for h in held_ids:
        cam = ctx.cam_scaled(h, EW, EH); mu, logs, quat, col, opa = G.view()
        img, dep, Tf, _ = gsref.render(mu, logs, quat, col, opa, cam, **pc_abc.DISPLAY); gt = ctx.hi_eval[h]
        def psnr(m): return float(-10 * np.log10(max(((img - gt) ** 2)[m].mean(), 1e-12))) if m.sum() > 20 else float('nan')
        full = np.ones((EH, EW), bool); idm = ids_e[h]
        rod = cv2.dilate((idm == 3).astype(np.uint8), np.ones((5, 5), np.uint8)) > 0
        sm = structural_similarity(img, gt, channel_axis=2, data_range=1.0, win_size=7)
        gx = np.abs(cv2.Sobel(cv2.cvtColor((gt * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY), cv2.CV_32F, 1, 0, ksize=3)) / 255; edge = gx > 0.25
        rows.append(dict(psnr=psnr(full), ssim=float(sm), plate=psnr(idm == 1), text_edges=psnr((idm == 1) & edge), slope=psnr(idm == 2), rod=psnr(rod), sphere=psnr(idm == 4),
                         occl_boundary=psnr(dz[h]), coverage=float((1 - Tf >= 0.5).mean())))
        if keep: imgs_out[h] = img
    out = {k: float(np.nanmean([r[k] for r in rows])) for k in rows[0]}
    return (out, imgs_out) if keep else out

# ---- supervision targets and optimiser loop
def target(v, w, h, crop=None):
    t = cv2.resize(hi_train[v], (w, h), interpolation=cv2.INTER_AREA).astype(np.float32) / 255 if crop is None else hi_train[v][crop[1]:crop[1] + crop[3], crop[0]:crop[0] + crop[2]].astype(np.float32) / 255
    return t
def run_variant(name, sup, iters, roi=False, split=False, time_budget=None, checkpoints=(100, 200, 400, 600, 800, 1200, 1500)):
    G = clone(G0); cfg = dict(pc_gs.DEFAULT_CFG); opt = pc_gs.Optimizer(cfg); rng = np.random.RandomState(7); rules = pc_abc.DISPLAY
    dummy = pc_abc.Run(ctx, 'C'); dummy.G = G; tiles = np.zeros((NF, 48), np.int32); res = {}; t_start = time.time(); sup_pix = 0; roi_pix = 0; roi_n = 0; splits0 = 0
    w, h = {'low': (160, 120), 'mid': (320, 240), 'orig': (640, 480)}[sup]
    _cam = ctx.cam_scaled(train_ids[0], w, h); _t = target(train_ids[0], w, h)
    print(f'[{name}] GRID={GRID} supervision {w}x{h} target shape {_t.shape} cam W,H {_cam["W"]},{_cam["H"]} fx {_cam["fx"]:.2f} cx {_cam["cx"]:.2f} cy {_cam["cy"]:.2f} | cfg lr_mu {cfg["lr_mu"]} iters {iters} seed 7 | modules {os.path.dirname(pc_gs.__file__)} | out {OUT}', flush=True)
    for it in range(1, iters + 1):
        v = train_ids[rng.randint(len(train_ids))]
        cam = ctx.cam_scaled(v, w, h); L1, g, vis, img, A, st, r = pc_abc.loss_grads(G, cam, target(v, w, h), None, cfg, rules)
        vf = np.zeros(G.n, bool); vf[:] = vis[:G.n]; opt.step(G, g[:5], geom=True, only_visible=vf); sup_pix += w * h
        if roi and it % 2 == 0:
            tv = train_ids[rng.randint(len(train_ids))]; ec = np.ones(48)                      # distributed tiles: least-refined cell of a random view, ties random
            c = int(np.argmin(tiles[tv] + rng.rand(48) * 0.5)); tiles[tv, c] += 1
            cw, ch = 192, 144; cx = (c % 8 + 0.5) / 8 * HW; cy = (c // 8 + 0.5) / 6 * HH; x0 = int(max(0, min(HW - cw, int(cx) - cw // 2))); y0 = int(max(0, min(HH - ch, int(cy) - ch // 2)))
            cam = ctx.cam_scaled(tv, HW, HH, crop=(x0, y0, cw, ch)); tgt = target(tv, cw, ch, crop=(x0, y0, cw, ch)); touched = set()
            for _ in range(3):
                L1, g, vis, img, A, st, r = pc_abc.loss_grads(G, cam, tgt, None, cfg, rules); vf = np.zeros(G.n, bool); vf[:] = vis[:G.n]; opt.step(G, g[:5], geom=True, only_visible=vf)
                m2 = g[5] * (cw * ch * 3); idx = np.nonzero(vf)[0]; first = G.scnt[idx] == 0
                G.sacc[idx] = np.where(first, m2[idx], 0.7 * G.sacc[idx] + 0.3 * m2[idx]); G.scnt[idx] += 1; touched.update(idx.tolist()); roi_pix += cw * ch; roi_n += 1
            if split and it % 40 == 0:
                dummy.stats['splits'] = splits0; dummy.split(touched); splits0 = dummy.stats['splits']
        if it in checkpoints or it == iters or (time_budget and time.time() - t_start >= time_budget):
            e = evaluate(G); e.update(iters=it, seconds=time.time() - t_start, gaussians=int(G.n), supervised_pixels_full=sup_pix, roi_pixels=roi_pix, roi_windows=roi_n, splits=splits0); res[it] = e
            print(f'{name:32s} it {it:5d} t {e["seconds"]:6.1f}s N {G.n} psnr {e["psnr"]:.2f} ssim {e["ssim"]:.3f} plate {e["plate"]:.2f} textedge {e["text_edges"]:.2f} slope {e["slope"]:.2f} rod {e["rod"]:.2f} occl {e["occl_boundary"]:.2f}', flush=True)
            if time_budget and time.time() - t_start >= time_budget: break
    return res, G

results = {'noise': dict(depth=DEPTH_NOISE, pose_deg=POSE_DEG, pose_mm=POSE_MM), 'initial_map_gaussians': int(N0), 'init': evaluate(G0), 'config': dict(frames=NF, train=len(train_ids), held=len(held_ids), grid=[GW, GH], iterations=ITERS)}
print('initial map (no optimisation) held-out:', {k: round(v, 3) for k, v in results['init'].items()}, flush=True)
runs = {}
ALL = (('S0 low 160x120', 'low', False, False), ('S1 mid 320x240', 'mid', False, False), ('S2 orig-derived 640x480', 'orig', False, False),
       ('S3 low + hi-res ROI tiles', 'low', True, False), ('S4 low + ROI tiles + split', 'low', True, True))
ONLY = os.environ.get('ONLY')
for name, sup, roi, split in [v for v in ALL if not ONLY or v[0].split()[0] in ONLY.split(',')]:
    res, G = run_variant(name, sup, ITERS, roi, split); results[name] = res; runs[name] = G
if os.environ.get('RENDER_PATH'):
    pj = [c for c in json.load(open(os.path.join(os.environ['RENDER_PATH'], 'cams.json'))) if c['tag'] == 'path']
    for name, Gx in runs.items():
        d_ = f'{OUT}/path_{name.split()[0]}'; os.makedirs(d_, exist_ok=True)
        for m, c in enumerate(pj):
            cam = dict(Rcw=np.array(c['R'], np.float64).T, C=np.array(c['C'], np.float64), fx=FX * EW / HW, fy=FX * EW / HW, cx=319.5, cy=239.5, W=EW, H=EH); mu, logs, quat, col, opa = Gx.view()
            img = gsref.render(mu, logs, quat, col, opa, cam, **pc_abc.DISPLAY)[0]; cv2.imwrite(f'{d_}/t_p{m:02d}.png', cv2.cvtColor((np.clip(img, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
        for h in held_ids:
            cam = ctx.cam_scaled(h, EW, EH); mu, logs, quat, col, opa = Gx.view(); img = gsref.render(mu, logs, quat, col, opa, cam, **pc_abc.DISPLAY)[0]
            cv2.imwrite(f'{d_}/t_h{h:02d}.png', cv2.cvtColor((np.clip(img, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
json.dump(results, open(f'{OUT}/results_B_iters{ITERS}.json', 'w'), indent=1)
# time-matched: give S0 the wall time S2 used
if 'S2 orig-derived 640x480' not in results: print('done'); sys.exit(0)
t_s2 = results['S2 orig-derived 640x480'][max(results['S2 orig-derived 640x480'])]['seconds']
res, G = run_variant('S0 low, time-matched to S2', 'low', 100000, False, False, time_budget=t_s2, checkpoints=()); results['S0 time-matched'] = res; runs['S0 time-matched'] = G
json.dump(results, open(f'{OUT}/results_B_iters{ITERS}.json', 'w'), indent=1)
# images: GT | S0 | S2 | S3 | S4 on two held-out views, plus crops of the plate print
for name in [n_ for n_ in ('S0 low 160x120', 'S2 orig-derived 640x480', 'S4 low + ROI tiles + split') if n_ in runs]:
    e, im = evaluate(runs[name], keep=True)
    for h in held_ids[:3]: cv2.imwrite(f'{OUT}/{name.split()[0]}_held{h:02d}.png', cv2.cvtColor((np.clip(im[h], 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
for h in held_ids[:3]: cv2.imwrite(f'{OUT}/GT_held{h:02d}.png', cv2.cvtColor((ctx.hi_eval[h] * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
print('done')
