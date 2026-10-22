"""ONE candidate chosen from the fur diagnosis (diag_fur.py): a DEPTH HIGH-PASS regulariser on the rendered expected depth, applied only where the surface is judged smooth. What it suppresses: millimetre-scale depth irregularity (the pebble relief) of Gaussians that all belong to one smooth surface patch; what it keeps: curvature (only x - gaussian(x, 1.5 px) is penalised, a plane or a smooth curve has ~0 high-pass), the photo RGB loss (eye/nose paint is colour, untouched), real depth steps (ears, occlusion edges: |high-pass| > 1 cm -> gate off), thin structures and the outline (gate = product mask eroded by 4 px at 160x120 and rendered alpha > 0.9), photo edges (photo luminance gradient above 0.03 at 160x120 -> gate off).
Loss  L_d = sum_p gate_p * rho(HP(Dhat)_p) / N_gate,  rho(x) = sqrt(x^2 + 1e-6) [m],  Dhat = dep / alpha ;  dL/dDhat = (s*gate - blur(s*gate))/N_gate with s = rho'  ->  dLdD = lam * dL/dDhat / alpha ; dLdA = -lam * dL/dDhat * Dhat / alpha  (added to the existing gradient inputs of the unchanged engine backward pass).
Strength lam: ONE value, fixed by the rule  lam = 0.1 * ||grad_params(L_photo)|| / ||grad_params(L_d, lam=1)||  measured once on the start map over 20 training views at 160x120 (the depth term starts with 10 % of the photo term's gradient norm) - recorded below, not searched.
Applied on the 160x120 full-frame steps only (the 192x144 native windows are unchanged); its computation time is inside the optimisation budget.
Both arms continue from the A 30 s map (out_hk/map_A_160_plus_window_30s.npz) with a fresh Adam state, same schedule of control A (160x120 full / 192x144 native window alternation), same seeds (view order 7, window 11), LR, clamps; same fixed refined cameras; budget +30 s of optimisation.
Not strict held-out (the device map saw every frame).   usage: python fur_fix.py [check|run]"""
import os, sys, json, time
MODE = sys.argv[1] if len(sys.argv) > 1 else 'run'
src = open('hires_keep.py', encoding='utf-8').read().split("EARLY, RET = 8, 108")[0]
exec(src)       # setup: P, train, held, POSE, camp, full/fmask/mask960/bg*, CAM160/CAM640/CAM960, Adam, sup_step, in_window, gsref, g, cv2, np ...
STARTA = {k: v.copy() for k, v in np.load('out_hk/map_A_160_plus_window_30s.npz').items()}
OUTD = 'out_fur'; os.makedirs(OUTD, exist_ok=True)
SIG = 1.5; EDGE_TAU = 0.01; PHOTO_GRAD = 0.03; ERODE = 9
def blur(x): return cv2.GaussianBlur(x, (0, 0), SIG, borderType=cv2.BORDER_REFLECT)
def depth_term(dep, Tf, gate_in, frozen_gate=None, frozen_ok=None):
    """returns (loss, dLdD, dLdA, gate); gate_in = static part of the gate (mask eroded & photo-smooth). frozen_gate: use this gate instead of recomputing (finite-difference test)."""
    al = 1 - Tf; ok = frozen_ok if frozen_ok is not None else (al > 0.9); Dh = np.where(ok, dep / np.maximum(al, 1e-3), 0).astype(np.float32); hpv = Dh - blur(Dh)
    gate = frozen_gate if frozen_gate is not None else (gate_in & ok & (np.abs(hpv) < EDGE_TAU) & (cv2.erode(ok.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0))
    n = max(1, int(gate.sum())); rho = np.sqrt(hpv * hpv + 1e-6); s = (hpv / rho) * gate; gD = (s - blur(s)) / n; loss = float((rho * gate).sum() / n)
    dLdD = np.where(ok, gD / np.maximum(al, 1e-3), 0).astype(np.float32); dLdA = np.where(ok, -gD * Dh / np.maximum(al, 1e-3), 0).astype(np.float32); return loss, dLdD, dLdA, gate
photo_smooth = {}
def static_gate(i):
    if i not in photo_smooth:
        gt = full[i]; gl = cv2.GaussianBlur(0.299 * gt[..., 0] + 0.587 * gt[..., 1] + 0.114 * gt[..., 2], (0, 0), 1.0); gx = cv2.Sobel(gl, cv2.CV_32F, 1, 0, ksize=3) / 8; gy = cv2.Sobel(gl, cv2.CV_32F, 0, 1, ksize=3) / 8
        photo_smooth[i] = (np.hypot(gx, gy) < PHOTO_GRAD) & (cv2.erode(fmask[i].astype(np.uint8), np.ones((ERODE, ERODE), np.uint8)) > 0)
    return photo_smooth[i]
# ---------------- value / gradient check on a small input
def check():
    """(1) engine backward wrt mu for sum(w*dep) and sum(w*alpha) vs central differences (smooth settings qcut 36, amin/tmin 1e-6, eps 1e-3); (2) depth-term gradient wrt Dhat through the blur (float64); (3) chain rule Dhat = dep/alpha -> (dLdD, dLdA) (float64)."""
    rng = np.random.RandomState(3); N = 40; M = dict(mu=np.concatenate([rng.randn(N, 2) * 0.12, 1.0 + rng.randn(N, 1) * 0.03], 1).astype(np.float32), logs=np.log(np.full((N, 3), 0.045, np.float32) * rng.uniform(0.8, 1.2, (N, 3))).astype(np.float32),
                                          quat=(lambda q: q / np.linalg.norm(q, axis=1, keepdims=True))(rng.randn(N, 4)).astype(np.float32), col=rng.rand(N, 3).astype(np.float32), opa=np.full(N, 3.0, np.float32))
    cam = dict(Rcw=np.eye(3), C=np.zeros(3), fx=60.0, fy=60.0, cx=24.0, cy=18.0, W=48, H=36)
    fw = lambda Mx: (lambda r: (r[1], r[2], r[3]))(gsref.render(Mx['mu'], Mx['logs'], Mx['quat'], Mx['col'], Mx['opa'], cam, **g.DISPLAY, qcut=36.0, amin=1e-6, tmin=1e-6)); Wt = np.random.RandomState(9).rand(36, 48).astype(np.float32); res_ = {}
    for name, lf, mk in (('engine_depth_grad', lambda dep, Tf: float((Wt * dep).sum()), lambda: (Wt, np.zeros_like(Wt))), ('engine_alpha_grad', lambda dep, Tf: float((Wt * (1 - Tf)).sum()), lambda: (np.zeros_like(Wt), Wt))):
        dep, Tf, st = fw(M); dD, dA = mk(); gr = np.array(gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, np.zeros((36, 48, 3), np.float32), dD.astype(np.float32), dA.astype(np.float32))[0]); rel = []
        for j in range(8):
            for ax in range(3):
                e = 1e-3; Mp = {k: v.copy() for k, v in M.items()}; Mm = {k: v.copy() for k, v in M.items()}; Mp['mu'][j, ax] += e; Mm['mu'][j, ax] -= e; fd = (lf(*fw(Mp)[:2]) - lf(*fw(Mm)[:2])) / (2 * e); rel.append((fd, float(gr[j, ax])))
        rel = np.array(rel); big = np.abs(rel[:, 0]) > 0.05 * np.abs(rel[:, 0]).max(); err = np.abs(rel[:, 0] - rel[:, 1]) / np.maximum(np.abs(rel[:, 0]), 1e-9); res_[name] = float(err[big].max()); print(f'{name}: {int(big.sum())} components, max relative error {res_[name]:.2e} (median {np.median(err[big]):.2e})', flush=True)
    b64 = lambda x: cv2.GaussianBlur(x, (0, 0), SIG, borderType=cv2.BORDER_REFLECT); Dh = (0.8 + 0.01 * np.random.RandomState(2).randn(36, 48)); gate = np.ones((36, 48), bool)
    def Lterm(D): h = D - b64(D); return float((np.sqrt(h * h + 1e-6) * gate).sum() / gate.sum())
    h = Dh - b64(Dh); s_ = (h / np.sqrt(h * h + 1e-6)) * gate; gD = (s_ - b64(s_)) / gate.sum(); worst = 0
    for _ in range(12):
        y = np.random.randint(10, 26); x = np.random.randint(10, 38); e = 1e-6; Dp = Dh.copy(); Dm = Dh.copy(); Dp[y, x] += e; Dm[y, x] -= e; fd = (Lterm(Dp) - Lterm(Dm)) / (2 * e); worst = max(worst, abs(fd - gD[y, x]) / max(abs(fd), abs(gD[y, x]), 1e-12))
    res_['term_grad_through_blur_float64'] = float(worst); print('depth term gradient wrt Dhat (float64, through the blur): worst relative error %.2e' % worst, flush=True)
    dep = 0.8 * (0.5 + 0.4 * np.random.RandomState(4).rand(36, 48)); al = 0.5 + 0.5 * np.random.RandomState(5).rand(36, 48); LT = lambda de, a: Lterm(de / a); D0 = dep / al; h = D0 - b64(D0); s_ = (h / np.sqrt(h * h + 1e-6)) * gate; gD = (s_ - b64(s_)) / gate.sum(); worst = 0
    for _ in range(12):
        y = np.random.randint(10, 26); x = np.random.randint(10, 38); e = 1e-6; dp = dep.copy(); dm = dep.copy(); dp[y, x] += e; dm[y, x] -= e; ap = al.copy(); am = al.copy(); ap[y, x] += e; am[y, x] -= e
        fdD = (LT(dp, al) - LT(dm, al)) / (2 * e); fdA = (LT(dep, ap) - LT(dep, am)) / (2 * e); aD = gD[y, x] / al[y, x]; aA = -gD[y, x] * D0[y, x] / al[y, x]; worst = max(worst, abs(fdD - aD) / max(abs(fdD), 1e-12), abs(fdA - aA) / max(abs(fdA), 1e-12))
    res_['chain_rule_float64'] = float(worst); print('chain rule Dhat = dep/alpha -> dLdD, dLdA (float64): worst relative error %.2e' % worst, flush=True)
    flat = np.full((36, 48), 0.8); ramp = np.tile(np.linspace(0.8, 0.9, 48), (36, 1)); print('value checks: flat depth loss %.6f (rho(0)=0.001) ; linear ramp interior high-pass max %.2e (curvature-free, not penalised)' % (Lterm(flat), float(np.abs(ramp - b64(ramp))[:, 10:-10].max())), flush=True)
    return res_
if MODE == 'check': check(); sys.exit(0)
check_err = check()
# ---------------- lambda rule
def grad_norm(M, i, lam, use_depth):
    cam = CAM160[i]; img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **g.DISPLAY); m = fmask[i]; bg = bgf[i]; r = img - full[i]; npx = max(1, int(m.sum()))
    if not use_depth: dLdC = (r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); dLdA = (0.1 * bg / max(1, int(bg.sum()))).astype(np.float32); dLdD = np.zeros_like(Tf, np.float32)
    else: _, dLdD, dLdA, _ = depth_term(dep, Tf, static_gate(i)); dLdD = lam * dLdD; dLdA = lam * dLdA; dLdC = np.zeros((*Tf.shape, 3), np.float32)
    gr = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, dLdC, dLdD, dLdA); return float(np.sqrt(sum(float((np.nan_to_num(np.array(a)) ** 2).sum()) for a in gr[:5])))
rng0 = np.random.RandomState(5); vs = [train[k] for k in rng0.choice(len(train), 20, replace=False)]
gp = np.mean([grad_norm(STARTA, i, 1.0, False) for i in vs]); gd = np.mean([grad_norm(STARTA, i, 1.0, True) for i in vs]); LAM = 0.1 * gp / gd; print('lambda rule: |grad photo| %.4g, |grad depth (lam=1)| %.4g -> lam = %.4g' % (gp, gd, LAM), flush=True)
# ---------------- runs
def sup_step2(M, opt, cam, gt, m, bg, use, gate_in=None):
    img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **g.DISPLAY); A = 1 - Tf; r = img - gt; npx = max(1, int(m.sum()))
    dLdC = (r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); dLdA = (0.1 * bg / max(1, int(bg.sum()))).astype(np.float32); dLdD = np.zeros_like(A, np.float32); ld = 0.0
    if use: ld, dD, dA, gate = depth_term(dep, Tf, gate_in); dLdD = dLdD + LAM * dD; dLdA = dLdA + LAM * dA
    gr = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, dLdC, dLdD, dLdA); gmu, glogs, gquat, gopa, gcol = [np.array(a) for a in gr[:5]]; vis = st['proj'][:, 0] > 0.5
    fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1); vis = vis & fin
    for a in (gmu, glogs, gquat, gcol): a[~fin] = 0
    gopa[~fin] = 0; opt.step(M, dict(mu=gmu, ls=glogs, q=gquat, o=gopa, c=gcol), vis); return st, vis, int(m.sum()), ld
def run(name, use, budget=30.0):
    M = {k: v.copy() for k, v in STARTA.items()}; opt = Adam(M); rng = np.random.RandomState(7); wrng = np.random.RandomState(11); order = []; visits_win = np.zeros(len(M['mu']), np.int32); t_opt = 0.0; it = 0; cur = None; last_st = None; n160 = nw = 0; ldsum = 0.0
    while t_opt < budget:
        t0 = time.perf_counter()
        if it % 2 == 0:
            if not order: order = list(rng.permutation(train))
            cur = order.pop(); st, vis, npx, ld = sup_step2(M, opt, CAM160[cur], full[cur], fmask[cur], bgf[cur], use, static_gate(cur) if use else None); last_st = st; n160 += 1; ldsum += ld
        else:
            i = cur; m960 = mask960[i]; best = None
            for _ in range(4):
                ys, xs = np.nonzero(m960); k = wrng.randint(len(ys)); x0 = int(np.clip(xs[k] - WW // 2, 0, 960 - WW)); y0 = int(np.clip(ys[k] - WH // 2, 0, 720 - WH))
                if m960[y0:y0 + WH, x0:x0 + WW].mean() < 0.4: continue
                inw = in_window(last_st, x0, y0, WW, WH, FW / 960.0); score = float(visits_win[inw].mean()) if inw.any() else 1e9
                if best is None or score < best[0]: best = (score, x0, y0)
            if best is not None:
                _, x0, y0 = best; cam = dict(CAM960[i]); cam['cx'] -= x0; cam['cy'] -= y0; cam['W'] = WW; cam['H'] = WH
                st, vis, npx, _ = sup_step2(M, opt, cam, hi[i][y0:y0 + WH, x0:x0 + WW].astype(np.float32) / 255, mask960[i][y0:y0 + WH, x0:x0 + WW], bg960[i][y0:y0 + WH, x0:x0 + WW], False); visits_win += vis; nw += 1
        t_opt += time.perf_counter() - t0; it += 1
    return M, dict(optimisation_seconds=t_opt, iterations=it, full160=n160, windows=nw, mean_depth_term_loss=ldsum / max(1, n160))
def metrics(M, ids):
    rows = []
    for i in ids:
        img, al, _ = g.render(M, CAM640[i]); gt = P.gt[i]; m = P.mask[i]; eye = g.find_eyes(gt, m); r = dict(psnr=float(-10 * np.log10(max(((img - gt) ** 2)[m].mean(), 1e-12))))
        if eye is not None: mt = g.metrics(img, al, gt, m, eye); r['recovery'] = float(mt.get('recovery', np.nan)); r['eye_psnr'] = float(mt.get('eye_psnr', np.nan))
        rows.append(r)
    return {k: float(np.nanmean([x[k] for x in rows if k in x])) for k in rows[0]}
def evaluate(M): return dict(observed_mid=metrics(M, [i for i in train if 26 <= i <= 99][::3]), earlier_directions=metrics(M, [i for i in train if i <= 25]), return_direction=metrics(M, [i for i in train if i >= 100]), neighbour_fixed_cameras=metrics(M, held))
res = dict(gradient_checks=check_err, lam=LAM, lam_rule='0.1*|grad photo|/|grad depth(lam=1)| on the A-30s map, 20 training views, 160x120', start_A_30s=evaluate(STARTA)); maps = {}
for name, use in (('control_general_30s_more', False), ('candidate_depth_highpass_30s_more', True)):
    M, info = run(name, use); res[name] = dict(info=info, **evaluate(M)); maps[name] = M; np.savez_compressed(f'{OUTD}/map_{name}.npz', **M); json.dump(res, open(f'{OUTD}/fur_fix.json', 'w'), indent=1); print(name, json.dumps(info), flush=True)
for v in ('observed_mid', 'earlier_directions', 'return_direction', 'neighbour_fixed_cameras'):
    print(v, 'start', {k: round(x, 2) for k, x in res['start_A_30s'][v].items()})
    for name in maps: print('   ', name[:9], {k: round(x, 2) for k, x in res[name][v].items()})
print('done')
