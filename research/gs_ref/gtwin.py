"""Supervision-form comparison on the device-saved test_09 map (PC possibility experiment, NOT the app): how much of the 640x480 full-frame fitting gain (B) is kept by
'160x120 full frame + native-resolution partial windows'? Same start map, photos, loss, learning rates, optimiser, seed, evaluation (640x480, same views/regions), NO added Gaussians.
Arms (all start from the saved map; geometry + colour + opacity free, as B):
  full640  : every optimiser step supervises one 640x480 full frame                       (the B baseline)
  full160  : every step supervises one 160x120 full frame (area-downscaled photo)
  win      : steps alternate: 160x120 full frame (view i) / 192x144 NATIVE crop of the 960x720 original of the same view (camera K shifted by the crop origin, no upsampling)
  pixmatch : full640 with as many steps as makes its processed pixels equal to win's
Window choice: whole product, not the eyes - 4 random windows overlapping the product mask >= 40% are drawn, the one whose Gaussians were supervised least often is used (visit counts per Gaussian are recorded).
Time: wall + CPU seconds of the fitting loop only; run ONE process at a time. usage: python gtwin.py <arm> [steps]"""
import os, sys, json, time
import numpy as np, cv2
import gtlib as g
import gsref
arm = sys.argv[1]; STEPS = int(sys.argv[2]) if len(sys.argv) > 2 else 3000
OUT = os.environ.get('OUTDIR', 'out_win'); os.makedirs(OUT, exist_ok=True); TAG = os.environ.get('TAG', arm)
M = g.load_map(); P = g.Photos()
LR = dict(mu=2e-4, ls=1e-3, q=5e-4, o=0.04, c=0.012)
fit_views = [i for i in range(P.n) if not g.held(i) and P.mask[i].sum() > 50]; unused = [i for i in range(P.n) if g.held(i) and P.mask[i].sum() > 50]
rng = np.random.RandomState(7); wrng = np.random.RandomState(11)
WW, WH = 192, 144; FW, FH = 160, 120
full = {i: cv2.resize(P.hi[i], (FW, FH), interpolation=cv2.INTER_AREA).astype(np.float32) / 255 for i in fit_views}
fmask = {i: cv2.resize(P.fr[i]['mask'], (FW, FH), interpolation=cv2.INTER_NEAREST) == 1 for i in fit_views}      # label 1 = product (0 unknown, 2 background)
mask960 = {i: cv2.resize(P.fr[i]['mask'], (960, 720), interpolation=cv2.INTER_NEAREST) == 1 for i in fit_views}
hi = {i: P.hi[i] for i in fit_views}
dil = lambda m, k: cv2.dilate(m.astype(np.uint8), np.ones((k | 1, k | 1), np.uint8)) > 0
bgf = {i: ~dil(fmask[i], 8) for i in fit_views}; bg960 = {i: ~dil(mask960[i], 31) for i in fit_views}; bg640 = {i: ~dil(P.mask[i], 31) for i in fit_views}

class Adam:
    def __init__(s, n): s.m = {k: np.zeros_like(M[nm]) for k, nm in (('c', 'col'), ('o', 'opa'), ('mu', 'mu'), ('ls', 'logs'), ('q', 'quat'))}; s.v = {k: np.zeros_like(a) for k, a in s.m.items()}; s.t = np.zeros(n, np.int32)
    def step(s, Mw, grads, vis):
        sl = np.nonzero(vis)[0]
        if len(sl) == 0: return
        s.t[sl] += 1; c = s.t[sl].astype(np.float32)
        for key, name in (('c', 'col'), ('o', 'opa'), ('mu', 'mu'), ('ls', 'logs'), ('q', 'quat')):
            gs = grads[key][sl]; s.m[key][sl] = 0.9 * s.m[key][sl] + 0.1 * gs; s.v[key][sl] = 0.99 * s.v[key][sl] + 0.01 * gs * gs
            cc = c[:, None] if gs.ndim == 2 else c
            Mw[name][sl] -= LR[key] * (s.m[key][sl] / (1 - 0.9 ** cc)) / (np.sqrt(s.v[key][sl] / (1 - 0.99 ** cc)) + 1e-8)
        np.clip(Mw['col'], 0, 1, out=Mw['col']); np.clip(Mw['opa'], -3.0, 6.0, out=Mw['opa']); np.clip(Mw['logs'], np.log(5e-4), np.log(0.05), out=Mw['logs'])
        q = Mw['quat']; q /= np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-9)

def sup_step(Mw, opt, cam, gt, m, bg):
    img, dep, Tf, st = gsref.render(Mw['mu'], Mw['logs'], Mw['quat'], Mw['col'], Mw['opa'], cam, **g.DISPLAY); A = 1 - Tf
    r = img - gt; npx = max(1, int(m.sum()))
    dLdC = (r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); dLdA = (0.1 * bg / max(1, int(bg.sum()))).astype(np.float32); dLdD = np.zeros_like(A, np.float32)
    gr = gsref.backward(Mw['mu'], Mw['logs'], Mw['quat'], Mw['col'], Mw['opa'], cam, st, Tf, dLdC, dLdD, dLdA)
    gmu, glogs, gquat, gopa, gcol = gr[:5]; vis = st['proj'][:, 0] > 0.5
    fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1); vis = vis & fin
    for a in (gmu, glogs, gquat, gcol): a[~fin] = 0
    gopa[~fin] = 0
    opt.step(Mw, dict(mu=gmu, ls=glogs, q=gquat, o=gopa, c=gcol), vis)
    return st, vis, float(np.sqrt(r * r + 1e-4)[m].mean())

def in_window_gaussians(st, x0, y0, w, h, scale):
    """Gaussians (original indices) visible in the render st whose projected centre lies inside the crop [x0,x0+w)x[y0,y0+h) given in original-960 pixels (scale = render width / 960)."""
    P_ = st['proj']; orig = st['orig'] if 'orig' in st else None
    ok = P_[:, 0] > 0.5; u = P_[:, 1] / scale; v = P_[:, 2] / scale
    return ok & (u >= x0) & (u < x0 + w) & (v >= y0) & (v < y0 + h)

def run():
    Mw = {k: v.copy() for k, v in M.items() if k in ('mu', 'logs', 'quat', 'col', 'opa')}; n = len(Mw['mu']); opt = Adam(n)
    visits_full = np.zeros(n, np.int32); visits_win = np.zeros(n, np.int32); px_render = 0; px_sup = 0; steps_full = steps_win = 0; log = []
    t_wall = time.time(); t_cpu = time.process_time(); order = []
    nsteps = STEPS
    if arm == 'base': nsteps = 0
    if arm == 'pixmatch': nsteps = int(round(((STEPS // 2) * FW * FH + (STEPS - STEPS // 2) * WW * WH) / (g.EW * g.EH)))
    for it in range(nsteps):
        if not order: order = list(rng.permutation(fit_views))
        if arm in ('full640', 'pixmatch'):
            i = order.pop(); cam = P.cam(i); st, vis, L = sup_step(Mw, opt, cam, P.gt[i], P.mask[i], bg640[i]); visits_full += vis; px_render += g.EW * g.EH; px_sup += int(P.mask[i].sum()); steps_full += 1
        elif arm == 'full160':
            i = order.pop(); cam = P.cam(i, FW, FH); st, vis, L = sup_step(Mw, opt, cam, full[i], fmask[i], bgf[i]); visits_full += vis; px_render += FW * FH; px_sup += int(fmask[i].sum()); steps_full += 1
        else:   # win: even step = full 160x120 of view i, odd step = native 192x144 crop of the same view's 960x720 original
            if it % 2 == 0:
                cur = order.pop(); cam = P.cam(cur, FW, FH); st, vis, L = sup_step(Mw, opt, cam, full[cur], fmask[cur], bgf[cur]); visits_full += vis; px_render += FW * FH; px_sup += int(fmask[cur].sum()); steps_full += 1; last_st = st
            else:
                i = cur; m960 = mask960[i]; best = None
                for _ in range(4):
                    ys, xs = np.nonzero(m960); k = wrng.randint(len(ys)); x0 = int(np.clip(xs[k] - WW // 2, 0, 960 - WW)); y0 = int(np.clip(ys[k] - WH // 2, 0, 720 - WH))
                    cover = m960[y0:y0 + WH, x0:x0 + WW].mean()
                    if cover < 0.4: continue
                    inw = in_window_gaussians(last_st, x0, y0, WW, WH, FW / 960.0); score = float(visits_win[inw].mean()) if inw.any() else 1e9
                    if best is None or score < best[0]: best = (score, x0, y0)
                if best is None: continue
                _, x0, y0 = best; f = P.fr[i]; cam = P.cam(i, 960, 720); cam = dict(cam); cam['cx'] -= x0; cam['cy'] -= y0; cam['W'] = WW; cam['H'] = WH     # native pixels: K stays at 960 scale, principal point shifted by the crop origin
                gt = hi[i][y0:y0 + WH, x0:x0 + WW].astype(np.float32) / 255; m = m960[y0:y0 + WH, x0:x0 + WW]; bg = bg960[i][y0:y0 + WH, x0:x0 + WW]
                st, vis, L = sup_step(Mw, opt, cam, gt, m, bg); visits_win += vis; px_render += WW * WH; px_sup += int(m.sum()); steps_win += 1
        if it % 200 == 0: log.append(dict(it=it, loss=L, wall=time.time() - t_wall)); print(arm, it, round(L, 4), f'{time.time() - t_wall:.0f}s', flush=True)
    wall = time.time() - t_wall; cpu = time.process_time() - t_cpu
    # evaluation (identical to gtfit)
    res = {}; imgs = {}; keyv = [v for v in (2, 5, 8, 41, 42, 45, 55, 117) if v < P.n]
    for i in fit_views + unused:
        cam = P.cam(i); img, al, _ = g.render(Mw, cam); eye = g.find_eyes(P.gt[i], P.mask[i]); res[i] = g.metrics(img, al, P.gt[i], P.mask[i], eye); res[i]['used'] = i in fit_views
        gray = cv2.cvtColor((P.gt[i] * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY); e = (np.hypot(cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3), cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)) / 255 > 0.25) & (cv2.dilate(P.mask[i].astype(np.uint8), np.ones((5, 5), np.uint8)) > 0)
        res[i]['edge_psnr'] = float(-10 * np.log10(max(((img - P.gt[i]) ** 2)[e].mean(), 1e-12)))
        if eye is not None:
            gd = (P.gt[i].max(-1) < 85 / 255) & eye['face']; rd = (img.max(-1) < 85 / 255) & (al > 0.5) & eye['face']; res[i]['dark_iou'] = float((gd & rd).sum() / max(1, (gd | rd).sum()))
            nb = cv2.connectedComponents(cv2.morphologyEx(rd.astype(np.uint8), cv2.MORPH_OPEN, np.ones((3, 3), np.uint8)))[0] - 1; res[i]['dark_blobs'] = int(nb)
            res[i]['false_dark'] = float((rd & ~(cv2.dilate(gd.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0)).sum() / max(1, rd.sum()))
        if i in keyv: imgs[i] = img
    agg = lambda k, sel: float(np.nanmean([res[i][k] for i in sel if k in res[i]])) if any(k in res[i] for i in sel) else float('nan')
    eyes_fit = [i for i in fit_views if 'recovery' in res[i]]; eyes_un = [i for i in unused if 'recovery' in res[i]]; early = [i for i in fit_views if i <= 20]
    # visit counts: all supervised Gaussians, and the eye-region Gaussians (centres inside the eye blob dilated, in the eye views 2/41/42 - used only to REPORT, never to choose windows)
    eyeG = np.zeros(n, bool)
    for v in (2, 41, 42):
        eye = g.find_eyes(P.gt[v], P.mask[v])
        if eye is None: continue
        cam = P.cam(v); img, al, st = g.render(Mw, cam); Pp = st['proj']; u = np.clip(Pp[:, 1].astype(int), 0, g.EW - 1); w = np.clip(Pp[:, 2].astype(int), 0, g.EH - 1); box = cv2.dilate(eye['blob'].astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
        eyeG |= (Pp[:, 0] > 0.5) & box[w, u]
    prod_vis = visits_full + visits_win; seen = prod_vis > 0
    if not seen.any(): seen[:] = True      # arm 'base' (no fitting): visit statistics are all zero
    summary = dict(arm=arm, tag=TAG, steps=nsteps, steps_full=steps_full, steps_window=steps_win, rendered_pixels=int(px_render), supervised_product_pixels=int(px_sup), wall_seconds=wall, cpu_seconds=cpu,
                   seconds_per_step=wall / max(1, nsteps), gaussians=n, eye_views_fit=len(eyes_fit), eye_views_unused=len(eyes_un),
                   visits=dict(full_median=float(np.median(visits_full[seen])), window_median=float(np.median(visits_win[seen])), window_zero_share=float((visits_win[seen] == 0).mean()), window_p10=float(np.percentile(visits_win[seen], 10)),
                               eye_gaussians=int(eyeG.sum()), eye_window_mean=float(visits_win[eyeG].mean()) if eyeG.any() else None, all_window_mean=float(visits_win[seen].mean()), eye_full_mean=float(visits_full[eyeG].mean()) if eyeG.any() else None, all_full_mean=float(visits_full[seen].mean())),
                   eval={k: dict(fit=agg(k, fit_views), unused=agg(k, unused), early_0_20=agg(k, early)) for k in ('product_psnr', 'edge_psnr', 'smooth_hf_render', 'ghost_alpha_far', 'alpha_product')},
                   eye={k: dict(fit=agg(k, eyes_fit), unused=agg(k, eyes_un)) for k in ('eye_psnr', 'face_psnr', 'recovery', 'dark_iou', 'dark_blobs', 'false_dark')}, log=log)
    json.dump(dict(summary=summary, per_view={str(k): v for k, v in res.items()}), open(os.path.join(OUT, f'win_{TAG}.json'), 'w'), indent=1, default=float)
    np.savez_compressed(os.path.join(OUT, f'map_{TAG}.npz'), **Mw); np.save(os.path.join(OUT, f'visits_{TAG}.npy'), np.stack([visits_full, visits_win]))
    for i, im in imgs.items(): g.imwrite(os.path.join(OUT, f'render_{TAG}_view{i}.png'), im)
    print(json.dumps({k: v for k, v in summary.items() if k != 'log'}, indent=1, default=float))
run()
