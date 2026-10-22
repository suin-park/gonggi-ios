"""Controlled colour-recovery study (PC research; strict P1 inputs: the 12 held-out frames i%10==5 are used by nothing).
STATE (frozen): start map out_ub/map_gsmax_P1.npz (2,348 Gaussians) + ONE round of pose refinement (cached poses out_pj/ctrl_poses.json). Only the colours may change.
STEP 1 identity checks: sha256 of geometry (mu, logs, quat), opacity, refined poses, masks, input photos for (original state) and (colours reset); they must match. Putting the original colours back must give bit-identical renders and identical scores.
STEP 2 controlled recovery: the map's OWN render at every training pose is the 'ground truth' (so exact colours exist). Colours are reset to a flat value and recovered with (a) independent weighted average (closed form, diagonal normal equation), (b) the average followed by Jacobi residual passes, (c) Adam on colours, (d) matrix-free CGLS on the full least-squares problem (joint update of overlapping Gaussians). Failure here is a bug / algorithm limit, NOT a real-photo depth issue.
Also: linearity of the render in the colours, fixed-point check (at the true colours the update must be zero), per-Gaussian visibility weight distribution.
usage: python ctrlcolor.py [STEP3=1 for the real-photo comparison]"""
import os, sys, json, time, hashlib
import numpy as np, cv2
SRC = open('posejoint.py', encoding='utf-8').read().split("t0 = time.time(); log = {}")[0]
sys.argv = ['x']; os.environ.pop('ALL', None); ns = {'__name__': 'pj'}; exec(SRC, ns)
import gsref, gtlib as g
P = ns['P']; train = ns['train']; held = ns['held']; START = ns['START']; refine_pose = ns['refine_pose']; cam_of = ns['cam_of']; POSE = ns['POSE']; views = ns['views']
OUT = 'out_pj'; pf = f'{OUT}/ctrl_poses.json'
if os.path.exists(pf): POSE.update({int(k): np.array(v) for k, v in json.load(open(pf)).items()}); t_pose = 0.0; print('poses loaded from cache', flush=True)
else:
    M_ = {k: v.copy() for k, v in START.items()}; t0 = time.time()
    for i in train: POSE[i] = refine_pose(i, M_, POSE[i])
    t_pose = time.time() - t0; json.dump({str(k): v.tolist() for k, v in POSE.items()}, open(pf, 'w')); print('pose refinement %.1fs' % t_pose, flush=True)
M0 = {k: v.copy() for k, v in START.items()}; FLAT = np.array([0.72, 0.66, 0.56], np.float32)
def sha(*arrs): h = hashlib.sha256(); [h.update(np.ascontiguousarray(a).tobytes()) for a in arrs]; return h.hexdigest()[:16]
def state_hashes(M): return dict(geometry=sha(M['mu'], M['logs'], M['quat']), opacity=sha(M['opa']), colours=sha(M['col']), poses=sha(np.stack([POSE[i] for i in train])), masks=sha(*[P.mask[i] for i in views]), input_photos=sha(*[P.hi[i] for i in views]))
H_orig = state_hashes(M0); Mr = {k: v.copy() for k, v in M0.items()}; Mr['col'][:] = FLAT; H_reset = state_hashes(Mr)
same = {k: H_orig[k] == H_reset[k] for k in H_orig}; print('hashes original :', H_orig); print('hashes colours reset :', H_reset); print('identical (expected: all True except colours):', same, flush=True)
# ---- restore test: original colours back -> bit-identical renders and identical scores
Mx = {k: v.copy() for k, v in Mr.items()}; Mx['col'][:] = M0['col']; ok_bits = []; scores = []
for i in train[:6]:
    a = g.render(M0, cam_of(i, POSE[i]))[0]; b = g.render(Mx, cam_of(i, POSE[i]))[0]; ok_bits.append(bool(np.array_equal(a, b))); gt = P.gt[i]; m = P.mask[i]; scores.append((float(-10 * np.log10(((a - gt) ** 2)[m].mean())), float(-10 * np.log10(((b - gt) ** 2)[m].mean()))))
print('restore: bit-identical renders on 6 views:', all(ok_bits), '| scores original vs restored:', [(round(x, 4), round(y, 4)) for x, y in scores], '| colours hash equal:', sha(Mx['col']) == H_orig['colours'], flush=True)
# ---- linear operators on the colours (matrix-free), geometry/opacity/poses frozen
D = g.DISPLAY; CAMS = {i: cam_of(i, POSE[i]) for i in train}
def render_raw(col, i):
    img, dep, Tf, st = gsref.render(M0['mu'], M0['logs'], M0['quat'], col, M0['opa'], CAMS[i], **D); return img, Tf, st
Zr = None
def Aop(col, S):       # A c : renders restricted to the support S_i
    return {i: render_raw(col, i)[0] * S[i][..., None] for i in train}
def ATop(res, S):      # A^T r : the renderer's backward pass w.r.t. colour with dLdC = r*S
    out = np.zeros_like(M0['col']); zero = None
    for i in train:
        img, Tf, st = render_raw(M0['col'], i); zero = np.zeros(Tf.shape, np.float32); out += np.nan_to_num(np.array(gsref.backward(M0['mu'], M0['logs'], M0['quat'], M0['col'], M0['opa'], CAMS[i], st, Tf, (res[i] * S[i][..., None]).astype(np.float32), zero, zero)[4]))
    return out
def weights_diag(S):   # diag(A^T A) per Gaussian = sum w^2 ... computed as A^T(A 1) is not diag; use the independent-average denominator  sum_p w_g(p) S(p)
    out = np.zeros(len(M0['col']), np.float32)
    for i in train:
        img, Tf, st = render_raw(M0['col'], i); zero = np.zeros(Tf.shape, np.float32); out += np.nan_to_num(np.array(gsref.backward(M0['mu'], M0['logs'], M0['quat'], M0['col'], M0['opa'], CAMS[i], st, Tf, np.repeat(S[i][..., None], 3, 2).astype(np.float32), zero, zero)[4][:, 0]))
    return out
# linearity of the render in the colours
i0 = train[10]; c1 = np.random.RandomState(1).rand(*M0['col'].shape).astype(np.float32) * 0.5; c2 = np.random.RandomState(2).rand(*M0['col'].shape).astype(np.float32) * 0.5
a = render_raw(c1, i0)[0] + render_raw(c2, i0)[0]; b = render_raw(c1 + c2, i0)[0]; print('linearity (render(c1)+render(c2) vs render(c1+c2)) max abs diff: %.2e ; scale test: %.2e' % (np.abs(a - b).max(), np.abs(render_raw(2 * c1, i0)[0] - 2 * render_raw(c1, i0)[0]).max()), flush=True)
# ---- targets = the map's own renders ('ground truth' exists)
T = {i: render_raw(M0['col'], i)[0] for i in train}; S = {i: (1 - render_raw(M0['col'], i)[1] > 0.02).astype(np.float32) for i in train}      # support: pixels the target actually covers
den = weights_diag(S); print('Gaussians: %d | with visible weight < 1e-3: %d | median weight %.2f' % (len(den), int((den < 1e-3).sum()), float(np.median(den))), flush=True)
def err(col):
    """colour error vs the true colours on Gaussians with visible weight >= 1.0, + image PSNR on the training targets (support) and on held-out cameras (ARKit pose, target = original map's render)."""
    ok = den >= 1.0; rm = float(np.sqrt(((col[ok] - M0['col'][ok]) ** 2).mean())); M1 = {k: v for k, v in M0.items()}; M1 = dict(M0); M1['col'] = col
    ps = []
    for i in train[::4]: im = g.render(M1, CAMS[i])[0]; m = S[i] > 0; ps.append(float(-10 * np.log10(max(((im - T[i]) ** 2)[m].mean(), 1e-12))))
    ph = []
    for i in held[:6]:
        c = g.render(M0, P.cam(i))[0]; im = g.render(M1, P.cam(i))[0]; al = g.render(M0, P.cam(i))[1] > 0.02; ph.append(float(-10 * np.log10(max(((im - c) ** 2)[al].mean(), 1e-12))))
    return dict(colour_rmse_visible=rm, psnr_train_vs_target=float(np.mean(ps)), psnr_heldout_cams_vs_original_render=float(np.mean(ph)))
res = {}
def record(name, col, secs): res[name] = dict(seconds=secs, **err(col)); print(name, '%.1fs' % secs, json.dumps({k: round(v, 3) for k, v in res[name].items()}), flush=True); json.dump(res, open(f'{OUT}/ctrlcolor.json', 'w'), indent=1)
# fixed point check: at the TRUE colours the residual update must be zero
rt = {i: (T[i] - render_raw(M0['col'], i)[0]) * S[i][..., None] for i in train}; num = ATop(rt, S); print('fixed point: |A^T residual| max at true colours = %.2e (expected ~0)' % np.abs(num).max(), flush=True)
b_vec = ATop({i: T[i] for i in train}, S)
# (a) independent average
t0 = time.time(); col = np.tile(FLAT, (len(M0['col']), 1)).astype(np.float32); ok = den > 1e-4; col[ok] = np.clip(b_vec[ok] / den[ok, None], 0, 1); record('a_independent_average_1pass', col, time.time() - t0)
# (b) + Jacobi residual passes
def jacobi(col, n):
    for _ in range(n):
        r = {i: (T[i] - render_raw(col, i)[0]) * S[i][..., None] for i in train}; num = ATop(r, S); col = col.copy(); col[ok] = np.clip(col[ok] + num[ok] / den[ok, None], 0, 1)
    return col
t0 = time.time(); colb = jacobi(col, 2); record('b_average_plus_2_jacobi', colb, time.time() - t0 + res['a_independent_average_1pass']['seconds'])
t0 = time.time(); colb10 = jacobi(colb, 8); record('b_average_plus_10_jacobi', colb10, time.time() - t0 + res['b_average_plus_2_jacobi']['seconds'])
# (d) CGLS: min ||A c - T||^2 over the support (joint update of overlapping Gaussians), no clamp inside the iterations (clamp only at the end)
def cgls(col0, iters):
    x = col0.copy(); r = {i: (T[i] - render_raw(x, i)[0]) * S[i][..., None] for i in train}; s = ATop(r, S); p = s.copy(); gamma = float((s ** 2).sum()); hist = []
    for it in range(iters):
        q = Aop(p, S); qq = sum(float((q[i] ** 2).sum()) for i in train)
        if qq < 1e-20: break
        al = gamma / qq; x += al * p
        for i in train: r[i] = r[i] - al * q[i]
        s = ATop(r, S); g2 = float((s ** 2).sum()); hist.append(float(np.sqrt(sum(float((r[i] ** 2).sum()) for i in train)))); p = s + (g2 / gamma) * p; gamma = g2
    return x, hist
t0 = time.time(); xc, hist = cgls(np.tile(FLAT, (len(M0['col']), 1)).astype(np.float32), 10); record('d_cgls_10_iterations', np.clip(xc, 0, 1), time.time() - t0); print('CGLS residual norms:', [round(h, 3) for h in hist], flush=True)
t0 = time.time(); xc2, hist2 = cgls(np.tile(FLAT, (len(M0['col']), 1)).astype(np.float32), 30); record('d_cgls_30_iterations', np.clip(xc2, 0, 1), time.time() - t0); print('CGLS residual norms (30):', [round(h, 3) for h in hist2[::3]], flush=True)
json.dump(dict(hashes_original=H_orig, hashes_colours_reset=H_reset, identical=same, restore_bit_identical=all(ok_bits), results=res), open(f'{OUT}/ctrlcolor.json', 'w'), indent=1)
