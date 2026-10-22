"""Do the high-resolution details enter the optimisation and SURVIVE the following updates?  (PC research, test_09 device-saved map; NOT strict held-out: the map saw every frame.)
FIXED before running (recorded):
  Start: device-saved map (out_pj/start_09_device.npz, 6,890 Gaussians, device colours), refined poses of the e2e run (poses_all.json) used for EVERY camera of BOTH arms (training and evaluation cameras identical and NOT re-aligned per arm), same photos / masks, same initial Adam state (zeros, per-Gaussian step counts), same seeds (view order RandomState(7), window RandomState(11)), same LR / losses / clamps / no extra constraints / no validation-rollback / no insertion / no split (NOT implemented on the PC side: the app's validation+rollback, constraints, exposure normalisation, error/stale window selection, 3 refine its per slice).
  Arm A (control, closest existing PC form of the app): alternating steps  even = 160x120 full frame of view i (area-downscaled photo) | odd = 192x144 NATIVE crop of the 960x720 original of the same view (window = 4 random windows overlapping the product >= 40%, take the one whose Gaussians were supervised least often)   [gtwin.py 'win' rule].
  Arm B (candidate): identical, except every 4th low-resolution full-frame update (even-step index 3 mod 4) is a 640x480 full-frame update of the same view. One rule, no ratio / threshold search.
Budget: SAME cumulative optimisation wall-clock; checkpoints at 10 s and 30 s (diagnostics, scoring and image rendering are excluded from the clock).
Diagnostics (state is never modified: renders only, probes run on copies): at 3 blocks (first window update after 5 s, 15 s, 25 s of optimisation) quality of [current view | earliest direction (frame 8) | return direction (frame 108)] right AFTER the window update, right AFTER the next low-resolution update, and after a PROBE of 10 further low-resolution-only updates on a copy of the state.
usage: python hires_keep.py"""
import os, sys, json, time, copy
os.environ['STARTMAP'] = 'out_pj/start_09_device.npz'; SRC = open('posejoint.py', encoding='utf-8').read().split("t0 = time.time(); log = {}")[0]
sys.argv = ['x']; os.environ.pop('ALL', None); ns = {'__name__': 'pj'}; exec(SRC, ns)
import numpy as np, cv2
import gsref, gtlib as g
P = ns['P']; train = ns['train']; held = ns['held']; START = ns['START']; POSE = ns['POSE']; views = ns['views']; rotvec = ns['rotvec']
PJ = json.load(open('C:/Users/emili/Downloads/best_3d_quality_before_friday/e2e_device09/cache/poses_all.json'))
for i in views: POSE[i] = np.array(PJ[str(i)])
D = g.DISPLAY; OUT = 'out_hk'; os.makedirs(OUT, exist_ok=True)
def camp(i, w, h): c = dict(P.cam(i, w, h)); p = POSE[i]; c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]; return c
FW, FH, WW, WH = 160, 120, 192, 144
dil = lambda m, k: cv2.dilate(m.astype(np.uint8), np.ones((k | 1, k | 1), np.uint8)) > 0
full = {i: cv2.resize(P.hi[i], (FW, FH), interpolation=cv2.INTER_AREA).astype(np.float32) / 255 for i in train}
fmask = {i: cv2.resize(P.fr[i]['mask'], (FW, FH), interpolation=cv2.INTER_NEAREST) == 1 for i in train}; mask960 = {i: cv2.resize(P.fr[i]['mask'], (960, 720), interpolation=cv2.INTER_NEAREST) == 1 for i in train}
bgf = {i: ~dil(fmask[i], 8) for i in train}; bg960 = {i: ~dil(mask960[i], 31) for i in train}; bg640 = {i: ~dil(P.mask[i], 31) for i in train}; hi = {i: P.hi[i] for i in train}
CAM640 = {i: camp(i, 640, 480) for i in views}; CAM160 = {i: camp(i, FW, FH) for i in train}; CAM960 = {i: camp(i, 960, 720) for i in train}
class Adam:
    NM = (('c', 'col'), ('o', 'opa'), ('mu', 'mu'), ('ls', 'logs'), ('q', 'quat'))
    def __init__(s, M): s.m = {k: np.zeros_like(M[nm]) for k, nm in s.NM}; s.v = {k: np.zeros_like(a) for k, a in s.m.items()}; s.t = np.zeros(len(M['mu']), np.int32)
    def copy(s): c = Adam.__new__(Adam); c.m = {k: v.copy() for k, v in s.m.items()}; c.v = {k: v.copy() for k, v in s.v.items()}; c.t = s.t.copy(); return c
    def step(s, M, grads, vis):
        sl = np.nonzero(vis)[0]
        if len(sl) == 0: return
        s.t[sl] += 1; c = s.t[sl].astype(np.float32)
        for key, name in s.NM:
            gs = grads[key][sl]; s.m[key][sl] = 0.9 * s.m[key][sl] + 0.1 * gs; s.v[key][sl] = 0.99 * s.v[key][sl] + 0.01 * gs * gs; cc = c[:, None] if gs.ndim == 2 else c
            M[name][sl] -= ns['LR0'][key] * (s.m[key][sl] / (1 - 0.9 ** cc)) / (np.sqrt(s.v[key][sl] / (1 - 0.99 ** cc)) + 1e-8)
        np.clip(M['col'], 0, 1, out=M['col']); np.clip(M['opa'], -3.0, 6.0, out=M['opa']); np.clip(M['logs'], np.log(5e-4), np.log(0.05), out=M['logs']); q = M['quat']; q /= np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-9)
def sup_step(M, opt, cam, gt, m, bg):
    img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **D); A = 1 - Tf; r = img - gt; npx = max(1, int(m.sum()))
    dLdC = (r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); dLdA = (0.1 * bg / max(1, int(bg.sum()))).astype(np.float32); dLdD = np.zeros_like(A, np.float32)
    gr = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, dLdC, dLdD, dLdA); gmu, glogs, gquat, gopa, gcol = [np.array(a) for a in gr[:5]]; vis = st['proj'][:, 0] > 0.5
    fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1); vis = vis & fin
    for a in (gmu, glogs, gquat, gcol): a[~fin] = 0
    gopa[~fin] = 0; opt.step(M, dict(mu=gmu, ls=glogs, q=gquat, o=gopa, c=gcol), vis); return st, vis, int(m.sum())
def in_window(st, x0, y0, w, h, scale):
    P_ = st['proj']; ok = P_[:, 0] > 0.5; u = P_[:, 1] / scale; v = P_[:, 2] / scale; return ok & (u >= x0) & (u < x0 + w) & (v >= y0) & (v < y0 + h)
EARLY, RET = 8, 108
def Q(M, cur):
    out = {}
    for tag, i in (('current', cur), ('earliest', EARLY), ('return', RET)):
        img, al, _ = g.render(M, CAM640[i]); gt = P.gt[i]; m = P.mask[i]; eye = g.find_eyes(gt, m); r = dict(psnr=float(-10 * np.log10(max(((img - gt) ** 2)[m].mean(), 1e-12))))
        if eye is not None: mt = g.metrics(img, al, gt, m, eye); r['recovery'] = float(mt.get('recovery', np.nan)); r['eye_psnr'] = float(mt.get('eye_psnr', np.nan))
        out[tag] = r
    return out
def metrics(M, ids):
    rows = []
    for i in ids:
        img, al, _ = g.render(M, CAM640[i]); gt = P.gt[i]; m = P.mask[i]; eye = g.find_eyes(gt, m); r = dict(psnr=float(-10 * np.log10(max(((img - gt) ** 2)[m].mean(), 1e-12))))
        if eye is not None: mt = g.metrics(img, al, gt, m, eye); r['recovery'] = float(mt.get('recovery', np.nan)); r['eye_psnr'] = float(mt.get('eye_psnr', np.nan))
        rows.append(r)
    return {k: float(np.nanmean([x[k] for x in rows if k in x])) for k in rows[0]}
def evaluate(M):
    return dict(observed_mid=metrics(M, [i for i in train if 26 <= i <= 99][::3]), earlier_directions=metrics(M, [i for i in train if i <= 25]), return_direction=metrics(M, [i for i in train if i >= 100]), neighbour_fixed_cameras=metrics(M, held))
def run_arm(name, replace_every, budget=30.0, ck=(10.0, 30.0), diag_at=(5.0, 15.0, 25.0)):
    M = {k: v.copy() for k, v in START.items()}; opt = Adam(M); rng = np.random.RandomState(7); wrng = np.random.RandomState(11); order = []; visits_win = np.zeros(len(M['mu']), np.int32)
    t_opt = 0.0; it = 0; cur = None; last_st = None; last_scale = FW / 960.0; cnt = dict(full160=0, full640=0, window=0, px_full160=0, px_full640=0, px_window=0); ck_i = 0; diag_i = 0; maps = {}; evals = {}; diag = []; pending = None; want_next_low = None
    while ck_i < len(ck):
        t0 = time.perf_counter(); is_win = False
        if it % 2 == 0:
            if not order: order = list(rng.permutation(train))
            cur = order.pop(); idx = it // 2
            if replace_every and idx % replace_every == replace_every - 1:
                st, vis, npx = sup_step(M, opt, CAM640[cur], P.gt[cur], P.mask[cur], bg640[cur]); cnt['full640'] += 1; cnt['px_full640'] += npx; last_scale = 640 / 960.0
            else:
                st, vis, npx = sup_step(M, opt, CAM160[cur], full[cur], fmask[cur], bgf[cur]); cnt['full160'] += 1; cnt['px_full160'] += npx; last_scale = FW / 960.0
            last_st = st
        else:
            i = cur; m960 = mask960[i]; best = None
            for _ in range(4):
                ys, xs = np.nonzero(m960); k = wrng.randint(len(ys)); x0 = int(np.clip(xs[k] - WW // 2, 0, 960 - WW)); y0 = int(np.clip(ys[k] - WH // 2, 0, 720 - WH))
                if m960[y0:y0 + WH, x0:x0 + WW].mean() < 0.4: continue
                inw = in_window(last_st, x0, y0, WW, WH, last_scale); score = float(visits_win[inw].mean()) if inw.any() else 1e9
                if best is None or score < best[0]: best = (score, x0, y0)
            if best is not None:
                _, x0, y0 = best; cam = dict(CAM960[i]); cam['cx'] -= x0; cam['cy'] -= y0; cam['W'] = WW; cam['H'] = WH
                st, vis, npx = sup_step(M, opt, cam, hi[i][y0:y0 + WH, x0:x0 + WW].astype(np.float32) / 255, mask960[i][y0:y0 + WH, x0:x0 + WW], bg960[i][y0:y0 + WH, x0:x0 + WW]); visits_win += vis; cnt['window'] += 1; cnt['px_window'] += npx; is_win = True
        t_opt += time.perf_counter() - t0; it += 1
        # ---- diagnostics (not on the clock, no state change)
        if is_win and diag_i < len(diag_at) and t_opt >= diag_at[diag_i]:
            blk = dict(block=diag_i + 1, t_opt=t_opt, iteration=it, current_view=int(cur), after_window=Q(M, cur)); pending = blk; want_next_low = True; diag_i += 1
        elif pending is not None and not is_win and want_next_low:
            pending['after_next_low_res'] = Q(M, pending['current_view']); Mp = {k: v.copy() for k, v in M.items()}; op = opt.copy(); prng = np.random.RandomState(99)
            for _ in range(10): j = train[prng.randint(len(train))]; sup_step(Mp, op, CAM160[j], full[j], fmask[j], bgf[j])
            pending['after_10_more_low_res_probe'] = Q(Mp, pending['current_view']); diag.append(pending); pending = None; want_next_low = None
        if ck_i < len(ck) and t_opt >= ck[ck_i]:
            maps[ck[ck_i]] = {k: v.copy() for k, v in M.items()}; evals[ck[ck_i]] = dict(optimisation_seconds=t_opt, iterations=it, **cnt, supervised_product_pixels=cnt['px_full160'] + cnt['px_full640'] + cnt['px_window'], gaussians=int(len(M['mu'])), **evaluate(M)); print(name, 'checkpoint', ck[ck_i], 's it', it, json.dumps({k: v for k, v in cnt.items()}), flush=True); ck_i += 1
    return maps, evals, diag
res = {}; allmaps = {}
M0 = {k: v.copy() for k, v in START.items()}; res['device_map_as_saved'] = evaluate(M0)
for name, rep in (('A_160_plus_window', 0), ('B_every4th_lowres_replaced_by_640', 4)):
    maps, evals, diag = run_arm(name, rep); res[name] = dict(checkpoints=evals, diagnostics=diag); allmaps[name] = maps
    for c, mm in maps.items(): np.savez_compressed(f'{OUT}/map_{name}_{int(c)}s.npz', **mm)
    json.dump(res, open(f'{OUT}/hires_keep.json', 'w'), indent=1)
for v in ('observed_mid', 'earlier_directions', 'return_direction', 'neighbour_fixed_cameras'):
    print(v); print('   device', {k: round(x, 3) for k, x in res['device_map_as_saved'][v].items()})
    for name in ('A_160_plus_window', 'B_every4th_lowres_replaced_by_640'):
        for c in (10.0, 30.0): print('  ', name[:1], int(c), 's', {k: round(x, 3) for k, x in res[name]['checkpoints'][c][v].items()})
print('done')
