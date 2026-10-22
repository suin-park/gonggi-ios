"""Fast colouring of an existing Gaussian map from posed photos (PC research; strict P1: 12 held-out frames i%10==5 used by nothing; held-out cameras test-time aligned to the held-out photo against each arm's final map = camera only, identical procedure).
Start = out_ub/map_gsmax_P1.npz (PC-built map from the training frames; its build time is NOT counted) -> 1 round of pose refinement (counted) -> colouring arms, geometry/opacity FROZEN for F1..F3 (only colours change):
  F0 : start colours, refined poses                                  (reference)
  F1 : visibility-weighted least-squares colour in ONE pass, using the renderer's own backward pass (non-iterative): colour_g = sum_views sum_pixels w_g(p) I(p) / sum_views sum_pixels w_g(p), w_g = T*alpha of Gaussian g at pixel p, product-mask pixels only
  F2 : F1 followed by 2 residual-correction passes (colour_g += sum w (I - render) / sum w)   (a few diagonal Gauss-Newton / Jacobi steps)
  F3 : gradient descent on colour only, 500 iterations (reference for the 'ordinary' way)
Metrics (held-out, aligned): product PSNR, interior PSNR, sharpness (Laplacian energy / photo), eye recovery; wall-clock of each arm.
Prior art note: 'Instant Colorization of Gaussian Splats' (arXiv 2604.17155) describes a non-iterative visibility-weighted least-squares colouring; this file only reproduces the idea to measure it on our data."""
import os, sys, json, time
import numpy as np, cv2
SRC = open('posejoint.py', encoding='utf-8').read().split("t0 = time.time(); log = {}")[0]
sys.argv = ['x']; os.environ.pop('ALL', None); ns = {'__name__': 'pj'}; exec(SRC, ns)
import bm_pose_eval_lib as L
import gsref, gtlib as g
P = ns['P']; train = ns['train']; held = ns['held']; START = ns['START']; refine_pose = ns['refine_pose']; cam_of = ns['cam_of']; POSE = ns['POSE']
M0 = {k: v.copy() for k, v in START.items()}
RESET = os.environ.get('RESET') == '1'
if RESET: M0['col'][:] = np.array([0.72, 0.66, 0.56], np.float32)      # 'uncoloured geometry' scenario: colours discarded, geometry/opacity kept
t0 = time.time()
for i in train: POSE[i] = refine_pose(i, M0, POSE[i])
t_pose = time.time() - t0; print('pose refinement 1 round: %.1fs' % t_pose, flush=True)
def passes(M, mode, n_pass):
    """mode 'ls': colour = num/den. mode 'res': colour += num_res/den."""
    for ps in range(n_pass):
        num = np.zeros_like(M['col']); den = np.zeros(len(M['col']), np.float32)
        for i in train:
            cam = cam_of(i, POSE[i]); gt = P.gt[i]; m = P.mask[i][..., None].astype(np.float32)
            img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **g.DISPLAY); zero = np.zeros(Tf.shape, np.float32)
            tgt = (gt * m if (mode == 'ls' and ps == 0) else (gt - img) * m).astype(np.float32)
            g1 = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, tgt, zero, zero)[4]
            g0 = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, np.repeat(m, 3, 2).astype(np.float32), zero, zero)[4][:, 0]
            num += np.nan_to_num(np.array(g1)); den += np.nan_to_num(np.array(g0))
        ok = den > 1e-4
        if mode == 'ls' and ps == 0: M['col'][ok] = np.clip(num[ok] / den[ok, None], 0, 1)
        else: M['col'][ok] = np.clip(M['col'][ok] + num[ok] / den[ok, None], 0, 1)
def metrics(M, ids, camf):
    rows = []
    for i in ids:
        cam = camf(i); gt = P.gt[i]; m = P.mask[i]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; img, al, _ = g.render(M, cam); eye = g.find_eyes(gt, m)
        lap = lambda x: float(np.abs(cv2.Laplacian(cv2.cvtColor((np.clip(x, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY), cv2.CV_32F))[me].mean()); ps = lambda mm: float(-10 * np.log10(max(((img - gt) ** 2)[mm].mean(), 1e-12)))
        r = dict(psnr=ps(m), interior=ps(me), sharp=lap(img) / max(lap(gt), 1e-9))
        if eye is not None: r['recovery'] = g.metrics(img, al, gt, m, eye).get('recovery', float('nan'))
        rows.append(r)
    return {k: float(np.nanmean([x[k] for x in rows if k in x])) for k in rows[0]}
res = {}
def evaluate(name, M, secs):
    tt = {i: L.tt_pose(i, M) for i in held}; res[name] = dict(seconds=secs, heldout_aligned=metrics(M, held, lambda i: cam_of(i, tt[i])), train_refined=metrics(M, train[::3], lambda i: cam_of(i, POSE[i])))
    json.dump(res, open(f"out_pj/fastcolor{'_reset' if RESET else ''}.json", 'w'), indent=1); h = res[name]['heldout_aligned']; print(name, '%.0fs' % secs, 'held psnr %.2f int %.2f sharp %.3f rec %.3f' % (h['psnr'], h['interior'], h['sharp'], h.get('recovery', float('nan'))), flush=True)
evaluate('F0_start_colours_refined_poses', M0, t_pose)
M = {k: v.copy() for k, v in M0.items()}; t0 = time.time(); passes(M, 'ls', 1); evaluate('F1_closed_form_1pass', M, t_pose + time.time() - t0)
t0 = time.time(); passes(M, 'res', 2); evaluate('F2_closed_form_plus_2_residual_passes', M, t_pose + res['F1_closed_form_1pass']['seconds'] - t_pose + time.time() - t0)
M = {k: v.copy() for k, v in M0.items()}; t0 = time.time()
# gradient descent on colour only (500 its): re-use the pose-joint optimiser with only the colour group updating
Adam = ns['Adam']; opt = Adam(M); rng = np.random.RandomState(5); order = []
NIT = int(os.environ.get('NIT', 500))
for it in range(NIT):
    if not order: order = list(rng.permutation(train))
    i = order.pop(); cam = cam_of(i, POSE[i]); gt = P.gt[i]; m = P.mask[i]; img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **g.DISPLAY); A = 1 - Tf; r = img - gt; npx = max(1, int(m.sum()))
    dLdC = (r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); z0 = np.zeros_like(A, np.float32); gr = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, dLdC, z0, z0); vis = st['proj'][:, 0] > 0.5
    zer = np.zeros_like(M['mu']); opt.step(M, dict(mu=zer, ls=zer, q=np.zeros_like(M['quat']), o=np.zeros(len(M['opa']), np.float32), c=np.array(gr[4])), vis)
evaluate(f'F3_gradient_colour_only_{NIT}its', M, t_pose + time.time() - t0)
