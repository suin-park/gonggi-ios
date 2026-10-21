"""GT-quality possibility study (PC, NOT the app): can the device-saved Gaussian map of test_09 express the photo's eyes/nose/face pattern and smooth surface?
Conditions (identical views, loss, iteration count, learning rates, seed; only the free parameter set differs):
  base   : the device map as saved (no fitting)
  A      : geometry frozen (mu, scale, rotation) -> colour + opacity fitted
  B      : geometry also fitted (mu, scale, rotation)
  C      : B + one densification pass schedule (split/clone the Gaussians with the largest positional gradient, fixed rule, no sweep)
Fit set = frames i%10 != 5 with a product mask (the app used all of them too). 'Unused' = i%10 == 5: NOT used in this fitting, but the starting map HAS seen them -> not a strict held-out.
Loss: Charbonnier on product-mask pixels at 640x480 + 0.1 * alpha on sure-background pixels (>=15 px outside the mask). No photo background composition is used for evaluation.
usage: python gtfit.py <cond> [iters]   outputs -> OUTDIR (default out_gt)"""
import os, sys, json, time
import numpy as np, cv2
import gtlib as g
import gsref
cond = sys.argv[1]; ITERS = int(sys.argv[2]) if len(sys.argv) > 2 else 1200
OUT = os.environ.get('OUTDIR', 'out_gt'); os.makedirs(OUT, exist_ok=True); SUP = int(os.environ.get('SUP', '640')); TAG = os.environ.get('TAG', cond)   # SUP = supervision width (evaluation is always 640x480)
M = g.load_map(); P = g.Photos()
RESET = os.environ.get('RESET') == '1'   # colours/opacity reset to one flat value (the device's photo-derived colours are discarded): colour/opacity are then fitted from the non-held frames only -> the held-out frames' PHOTO information never enters the colours (the device GEOMETRY did see all views)
if RESET and cond != 'base': M['col'][:] = np.array([0.72, 0.66, 0.56], np.float32); M['opa'][:] = 0.4
LR = dict(mu=2e-4, ls=1e-3, q=5e-4, o=0.04, c=0.012)          # the app's own learning rates (GSOOptConfig), used unchanged
fit_views = [i for i in range(P.n) if not g.held(i) and P.mask[i].sum() > 50]; unused = [i for i in range(P.n) if g.held(i) and P.mask[i].sum() > 50]
BOUND = os.environ.get('BOUND') == '1'   # the app's own parameter bounds (GSOOptConfig): |mu - mu0| <= 3*max(exp(ls0)), log-scale within [ls0-0.7, ls0+0.5]
MU0 = M['mu'].copy(); LS0 = M['logs'].copy()
BLOCK = os.environ.get('BLOCK')   # e.g. 40-49: a contiguous block of views is removed from the fit (a harder 'unused' test than every-10th frames, whose neighbours are all in the fit)
if BLOCK:
    lo, hi_ = map(int, BLOCK.split('-')); unused = [i for i in range(lo, hi_ + 1) if P.mask[i].sum() > 50]; fit_views = [i for i in range(P.n) if P.mask[i].sum() > 50 and i not in unused]
rng = np.random.RandomState(7)
SH = SUP * 3 // 4
GTs = {i: (cv2.resize(P.gt[i], (SUP, SH), interpolation=cv2.INTER_AREA) if SUP != 640 else P.gt[i]) for i in fit_views}
MKs = {i: (cv2.resize(P.mask[i].astype(np.uint8), (SUP, SH), interpolation=cv2.INTER_NEAREST) > 0 if SUP != 640 else P.mask[i]) for i in fit_views}
dil = {i: cv2.dilate(MKs[i].astype(np.uint8), np.ones((31 * SUP // 640 | 1, 31 * SUP // 640 | 1), np.uint8)) > 0 for i in fit_views}

class Adam:
    def __init__(s, n): s.m = {k: None for k in LR}; s.v = {k: None for k in LR}; s.t = np.zeros(n, np.int32)
    def step(s, M, grads, groups, vis):
        sl = np.nonzero(vis)[0]
        if len(sl) == 0: return
        s.t[sl] += 1; c = s.t[sl].astype(np.float32)
        for key, name, gr in (('c', 'col', grads['c']), ('o', 'opa', grads['o']), ('mu', 'mu', grads['mu']), ('ls', 'logs', grads['ls']), ('q', 'quat', grads['q'])):
            if key not in groups: continue
            if s.m[key] is None or len(s.m[key]) != len(M[name]):
                old = s.m[key]; s.m[key] = np.zeros_like(M[name]); s.v[key] = np.zeros_like(M[name])
                if old is not None: s.m[key][:len(old)] = old; s.v[key][:len(old)] = s.v_old[key]
            gs = gr[sl]; s.m[key][sl] = 0.9 * s.m[key][sl] + 0.1 * gs; s.v[key][sl] = 0.99 * s.v[key][sl] + 0.01 * gs * gs
            cc = c[:, None] if gs.ndim == 2 else c
            d = LR[key] * (s.m[key][sl] / (1 - 0.9 ** cc)) / (np.sqrt(s.v[key][sl] / (1 - 0.99 ** cc)) + 1e-8); M[name][sl] -= d
        np.clip(M['col'], 0, 1, out=M['col']); np.clip(M['opa'], -3.0, 6.0, out=M['opa']); np.clip(M['logs'], np.log(5e-4), np.log(0.05), out=M['logs'])
        if BOUND and len(M['mu']) == len(MU0):
            lim = 3.0 * np.exp(LS0).max(1, keepdims=True); M['mu'][:] = MU0 + np.clip(M['mu'] - MU0, -lim, lim); M['logs'][:] = np.clip(M['logs'], LS0 - 0.7, LS0 + 0.5)
        q = M['quat']; q /= np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-9)

def evaluate(M, tag, save_views=()):
    res = {}; imgs = {}
    for i in fit_views + unused:
        cam = P.cam(i); img, al, _ = g.render(M, cam); eye = g.find_eyes(P.gt[i], P.mask[i]); res[i] = g.metrics(img, al, P.gt[i], P.mask[i], eye); res[i]['used'] = i in fit_views
        if i in save_views: imgs[i] = img
    return res, imgs

def agg(res, key, sel): v = [res[i][key] for i in sel if key in res[i] and np.isfinite(res[i][key])]; return float(np.mean(v)) if v else float('nan')

def run():
    groups = {'base': set(), 'A': {'c', 'o'}, 'B': {'c', 'o', 'mu', 'ls', 'q'}, 'C': {'c', 'o', 'mu', 'ls', 'q'}}[cond]
    Mw = {k: v.copy() for k, v in M.items()}; n0 = len(Mw['mu']); t_fit = 0.0; log = []; accum = None; peak = 0
    try:
        import psutil; proc = psutil.Process(os.getpid())
    except Exception: proc = None
    opt = Adam(n0); densify_at = set(range(ITERS // 4, ITERS, max(1, ITERS // 8))) if cond == 'C' else set()
    gacc = np.zeros(n0, np.float32); gcnt = np.zeros(n0, np.int32)
    t0 = time.time()
    if groups:
        order = []
        for it in range(ITERS):
            if not order: order = list(rng.permutation(fit_views))
            i = order.pop(); cam = P.cam(i, SUP, SH); gt = GTs[i]; m = MKs[i]
            img, dep, Tf, st = gsref.render(Mw['mu'], Mw['logs'], Mw['quat'], Mw['col'], Mw['opa'], cam, **g.DISPLAY); A = 1 - Tf
            r = img - gt; npx = max(1, int(m.sum())); bg = ~dil[i]
            dLdC = (r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); dLdA = (0.1 * bg / max(1, int(bg.sum()))).astype(np.float32); dLdD = np.zeros_like(A, np.float32)
            gr = gsref.backward(Mw['mu'], Mw['logs'], Mw['quat'], Mw['col'], Mw['opa'], cam, st, Tf, dLdC, dLdD, dLdA)
            gmu, glogs, gquat, gopa, gcol = gr[:5]; vis = st['proj'][:, 0] > 0.5
            fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1); vis = vis & fin
            for a in (gmu, glogs, gquat, gcol): a[~fin] = 0
            gopa[~fin] = 0
            opt.step(Mw, dict(mu=gmu, ls=glogs, q=gquat, o=gopa, c=gcol), groups, vis)
            if cond == 'C':
                if len(gacc) != len(Mw['mu']): gacc = np.pad(gacc, (0, len(Mw['mu']) - len(gacc))); gcnt = np.pad(gcnt, (0, len(Mw['mu']) - len(gcnt)))
                gacc[vis] += np.linalg.norm(gmu[vis], axis=1) * npx; gcnt[vis] += 1
                if it in densify_at:
                    avg = np.where(gcnt > 3, gacc / np.maximum(gcnt, 1), 0); k = max(1, int(0.05 * (avg > 0).sum())); top = np.argsort(-avg)[:k]
                    big = np.exp(Mw['logs'][top]).max(1) > 0.003; add = {kk: [] for kk in Mw}
                    for j, isbig in zip(top, big):
                        for kk in Mw:
                            if kk == 'logs': add[kk].append(Mw[kk][j] + (np.log(1 / 1.6) if isbig else 0))
                            elif kk == 'mu':
                                ax = int(np.argmax(Mw['logs'][j])); q = Mw['quat'][j]; x, y, z, w = q
                                R = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)], [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)], [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]], np.float32)
                                off = R[:, ax] * 0.5 * float(np.exp(Mw['logs'][j][ax])) * (1 if isbig else 0.0); add[kk].append(Mw[kk][j] + off)
                                if isbig: Mw[kk][j] = Mw[kk][j] - off
                            elif kk == 'logs': pass
                            else: add[kk].append(Mw[kk][j])
                    for j, isbig in zip(top, big):
                        if isbig: Mw['logs'][j] = Mw['logs'][j] + np.log(1 / 1.6)
                    for kk in Mw: Mw[kk] = np.concatenate([Mw[kk], np.array(add[kk], Mw[kk].dtype)], 0)
                    nn = len(Mw['mu']); opt.t = np.concatenate([opt.t, np.zeros(nn - len(opt.t), np.int32)])
                    for key in ('c', 'o', 'mu', 'ls', 'q'):
                        if opt.m[key] is not None:
                            opt.v_old = {kk: opt.v[kk] for kk in opt.v}; z0 = np.zeros((nn - len(opt.m[key]),) + opt.m[key].shape[1:], np.float32); opt.m[key] = np.concatenate([opt.m[key], z0]); opt.v[key] = np.concatenate([opt.v[key], z0])
                    gacc = np.zeros(nn, np.float32); gcnt = np.zeros(nn, np.int32); log.append(dict(it=it, gaussians=nn, densified=int(k)))
            if it % 100 == 0:
                L = float(np.sqrt(r * r + 1e-4)[m].mean()); log.append(dict(it=it, loss_product=L, gaussians=len(Mw['mu']))); print(cond, it, 'L', round(L, 4), 'N', len(Mw['mu']), f'{time.time() - t0:.0f}s', flush=True)
                if proc: peak = max(peak, proc.memory_info().rss / 1e6)
    t_fit = time.time() - t0
    # evaluation
    key_views = [v for v in (2, 41, 42, 45, 117) if v < P.n]
    res, imgs = evaluate(Mw, cond, save_views=key_views + [i for i in range(0, 60, 6)])
    eyes_fit = [i for i in fit_views if 'recovery' in res[i]]; eyes_unused = [i for i in unused if 'recovery' in res[i]]
    early = [i for i in fit_views if i <= 20]; late = [i for i in fit_views if i >= 90]
    summary = dict(cond=cond, tag=TAG, app_bounds=BOUND, supervision_width=SUP, iters=ITERS if groups else 0, gaussians=int(len(Mw['mu'])), fit_seconds=t_fit, peak_rss_mb=peak, views_fit=len(fit_views), views_unused=len(unused), eye_views_fit=len(eyes_fit), eye_views_unused=len(eyes_unused),
                   eval={k: dict(fit=agg(res, k, fit_views), unused=agg(res, k, unused), early_0_20=agg(res, k, early), late_90_117=agg(res, k, late)) for k in ('product_psnr', 'alpha_product', 'ghost_alpha_far', 'smooth_hf_render', 'smooth_hf_photo')},
                   eye={k: dict(fit=agg(res, k, eyes_fit), unused=agg(res, k, eyes_unused)) for k in ('eye_psnr', 'face_psnr', 'recovery', 'contrast_render', 'contrast_photo')}, log=log)
    json.dump(dict(summary=summary, per_view={str(k): v for k, v in res.items()}), open(os.path.join(OUT, f'gt_{TAG}.json'), 'w'), indent=1, default=float)
    np.savez_compressed(os.path.join(OUT, f'map_{TAG}.npz'), **Mw)
    for i, im in imgs.items(): g.imwrite(os.path.join(OUT, f'render_{TAG}_view{i}.png'), im)
    print(json.dumps({k: v for k, v in summary.items() if k != 'log'}, indent=1, default=float))
run()
