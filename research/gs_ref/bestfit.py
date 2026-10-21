"""Best-quality 3DGS (PC offline, NOT the app, NOT real time). Start map = out_gt/map_B.npz = the DEVICE-saved map (6,890 Gaussians) after the earlier 3000-iteration fit with 640x480 full-frame supervision (geometry+colour+opacity, no new Gaussians).
This continues the SAME optimisation (same loss / learning rates / Adam / 640x480 supervision) for more iterations on ALL recorded frames with a product mask (the final demo uses the whole recording: NOT a held-out evaluation).
No Gaussian splitting/cloning, no new resolutions. Checkpoints (map + fixed-camera metrics + cumulative wall-clock) every CKPT iterations so the best checkpoint can be chosen instead of assuming the last is best.
usage: ARM=const|decay python bestfit.py TOTAL_ITERS [CKPT]   (decay: learning rate linearly to 10% over the run; const: the earlier constant rates)"""
import os, sys, json, time
import numpy as np, cv2
import gtlib as g
import gsref
TOTAL = int(sys.argv[1]); CKPT = int(sys.argv[2]) if len(sys.argv) > 2 else 1500; ARM = os.environ.get('ARM', 'const'); OUT = os.environ.get('OUTDIR', 'out_best'); os.makedirs(OUT, exist_ok=True)
START = os.environ.get('START', 'out_gt/map_B.npz'); z = np.load(START); M = {k: z[k].copy() for k in z.files}; P = g.Photos()
LR0 = dict(mu=2e-4, ls=1e-3, q=5e-4, o=0.04, c=0.012)
views = [i for i in range(P.n) if P.mask[i].sum() > 50]
FIXED = [v for v in (2, 12, 20, 37, 40, 43, 46, 49, 52, 55, 100, 110, 117) if v in views]       # fixed evaluation cameras: early / eye-visible front / return
rng = np.random.RandomState(11)
dil = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((31, 31), np.uint8)) > 0 for i in views}
class Adam:
    def __init__(s, n): s.m = {k: np.zeros_like(M[nm]) for k, nm in (('c', 'col'), ('o', 'opa'), ('mu', 'mu'), ('ls', 'logs'), ('q', 'quat'))}; s.v = {k: np.zeros_like(a) for k, a in s.m.items()}; s.t = np.zeros(n, np.int32)
    def step(s, M, grads, vis, scale):
        sl = np.nonzero(vis)[0]
        if len(sl) == 0: return
        s.t[sl] += 1; c = s.t[sl].astype(np.float32)
        for key, name in (('c', 'col'), ('o', 'opa'), ('mu', 'mu'), ('ls', 'logs'), ('q', 'quat')):
            gs = grads[key][sl]; s.m[key][sl] = 0.9 * s.m[key][sl] + 0.1 * gs; s.v[key][sl] = 0.99 * s.v[key][sl] + 0.01 * gs * gs; cc = c[:, None] if gs.ndim == 2 else c
            M[name][sl] -= scale * LR0[key] * (s.m[key][sl] / (1 - 0.9 ** cc)) / (np.sqrt(s.v[key][sl] / (1 - 0.99 ** cc)) + 1e-8)
        np.clip(M['col'], 0, 1, out=M['col']); np.clip(M['opa'], -3.0, 6.0, out=M['opa']); np.clip(M['logs'], np.log(5e-4), np.log(0.05), out=M['logs']); q = M['quat']; q /= np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-9)
def evaluate(M, views_):
    out = {}
    for i in views_:
        img, al, _ = g.render(M, P.cam(i)); eye = g.find_eyes(P.gt[i], P.mask[i]); out[i] = g.metrics(img, al, P.gt[i], P.mask[i], eye)
    return out
def summ(res):
    f = lambda sel, k: float(np.nanmean([res[i][k] for i in sel if k in res[i]])) if any(k in res[i] for i in sel) else float('nan')
    early = [i for i in res if i <= 20]; front = [i for i in res if 37 <= i <= 55]; late = [i for i in res if i >= 100]
    return dict(psnr_early=f(early, 'product_psnr'), psnr_front=f(front, 'product_psnr'), psnr_late=f(late, 'product_psnr'), recovery_front=f(front, 'recovery'), eye_psnr_front=f(front, 'eye_psnr'),
                smooth_hf_ratio=f(res, 'smooth_hf_render') / max(f(res, 'smooth_hf_photo'), 1e-9) if False else float(np.nanmean([res[i]['smooth_hf_render'] / max(res[i]['smooth_hf_photo'], 1e-9) for i in res])), ghost_alpha_far=f(res, 'ghost_alpha_far'), alpha_product=f(res, 'alpha_product'))
opt = Adam(len(M['mu'])); log = []; t_cum = 0.0; order = []
r0 = evaluate(M, FIXED); log.append(dict(it=0, arm=ARM, wall_s=0.0, **summ(r0))); print(json.dumps(log[-1]), flush=True)
np.savez_compressed(os.path.join(OUT, f'map_{ARM}_it0.npz'), **M)
t_start = time.time()
for it in range(1, TOTAL + 1):
    if not order: order = list(rng.permutation(views))
    i = order.pop(); cam = P.cam(i); gt = P.gt[i]; m = P.mask[i]; bg = ~dil[i]
    scale = 1.0 if ARM == 'const' else 1.0 - 0.9 * (it - 1) / TOTAL
    img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **g.DISPLAY); A = 1 - Tf; r = img - gt; npx = max(1, int(m.sum()))
    dLdC = (r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); dLdA = (0.1 * bg / max(1, int(bg.sum()))).astype(np.float32); dLdD = np.zeros_like(A, np.float32)
    gr = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, dLdC, dLdD, dLdA); gmu, glogs, gquat, gopa, gcol = [np.array(a) for a in gr[:5]]
    vis = st['proj'][:, 0] > 0.5; fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1); vis = vis & fin
    for a in (gmu, glogs, gquat, gcol): a[~fin] = 0
    gopa[~fin] = 0; opt.step(M, dict(mu=gmu, ls=glogs, q=gquat, o=gopa, c=gcol), vis, scale)
    if it % 100 == 0: print(ARM, it, 'L', round(float(np.sqrt(r * r + 1e-4)[m].mean()), 4), f'{time.time() - t_start + t_cum:.0f}s', flush=True)
    if it % CKPT == 0 or it == TOTAL:
        wall = time.time() - t_start; np.savez_compressed(os.path.join(OUT, f'map_{ARM}_it{it}.npz'), **M)      # checkpoint write + evaluation are excluded from the optimisation wall-clock
        r_ = evaluate(M, FIXED); log.append(dict(it=it, arm=ARM, opt_wall_s=wall, **summ(r_))); print(json.dumps(log[-1]), flush=True); json.dump(log, open(os.path.join(OUT, f'log_{ARM}.json'), 'w'), indent=1)
        t_start += time.time() - t_start - wall          # shift so evaluation time is not counted
print('done', ARM)
