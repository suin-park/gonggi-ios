"""Sharper 3DGS study (PC research; strict P1: the 12 held-out frames i%10==5 are used by nothing; held-out cameras are test-time ALIGNED to the held-out photo against each arm's final map = camera only, identical procedure for every arm).
Start = out_pj/map_joint.npz (P1 pose-refined map) + out_pj/poses_refined.json (refined poses of the 98 training frames, kept FIXED). Every arm continues the same optimisation for TOTAL iterations (640x480 full-frame supervision, same loss / LR / Adam / seed):
  ctrl : no change (control)
  dens : + densification (8 rounds, top 10% positional gradient: split big / clone small) after the poses are consistent (earlier capacity tests were done with inconsistent ARKit poses)
  hf   : + high-frequency loss (L1-type on HP(img)-HP(gt), HP = x - gaussian(x, 2 px); lambda 0.5; analytic gradient (I-B)s)
  both : dens + hf
Metrics on held-out: product PSNR, interior PSNR, sharpness = Laplacian energy / photo (1.0 = like the photo), smooth-surface HF ratio, eye/nose recovery; train views (every 3rd, refined poses): PSNR, sharpness, recovery. Gaussian count, wall-clock.
usage: python sharp3dgs.py ctrl,dens,hf,both [TOTAL]"""
import os, sys, json, time
import numpy as np, cv2
import gtlib as g
import gsref
import bm_pose_eval_lib as L
arms = sys.argv[1].split(','); TOTAL = int(sys.argv[2]) if len(sys.argv) > 2 else 6000; OUT = 'out_sharp'; os.makedirs(OUT, exist_ok=True)
P = g.Photos(); views = [i for i in range(P.n) if P.mask[i].sum() > 50]; held = [i for i in views if i % 10 == 5]; train = [i for i in views if i % 10 != 5]
z_ = np.load('out_pj/map_joint.npz'); START = {k: z_[k].copy() for k in z_.files}; POSE = {int(k): np.array(v) for k, v in json.load(open('out_pj/poses_refined.json')).items()}
LR0 = dict(mu=2e-4, ls=1e-3, q=5e-4, o=0.04, c=0.012); dil = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((31, 31), np.uint8)) > 0 for i in views}
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
def cam_of(i, p): c = dict(P.cam(i)); c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]; return c
class Adam:
    NM = (('c', 'col'), ('o', 'opa'), ('mu', 'mu'), ('ls', 'logs'), ('q', 'quat'))
    def __init__(s, M): s.m = {k: np.zeros_like(M[nm]) for k, nm in s.NM}; s.v = {k: np.zeros_like(a) for k, a in s.m.items()}; s.t = np.zeros(len(M['mu']), np.int32)
    def grow(s, n):
        s.t = np.concatenate([s.t, np.zeros(n - len(s.t), np.int32)])
        for k in s.m: z = np.zeros((n - len(s.m[k]),) + s.m[k].shape[1:], np.float32); s.m[k] = np.concatenate([s.m[k], z]); s.v[k] = np.concatenate([s.v[k], z])
    def step(s, M, grads, vis):
        sl = np.nonzero(vis)[0]
        if len(sl) == 0: return
        s.t[sl] += 1; c = s.t[sl].astype(np.float32)
        for key, name in s.NM:
            gs = grads[key][sl]; s.m[key][sl] = 0.9 * s.m[key][sl] + 0.1 * gs; s.v[key][sl] = 0.99 * s.v[key][sl] + 0.01 * gs * gs; cc = c[:, None] if gs.ndim == 2 else c
            M[name][sl] -= LR0[key] * (s.m[key][sl] / (1 - 0.9 ** cc)) / (np.sqrt(s.v[key][sl] / (1 - 0.99 ** cc)) + 1e-8)
        np.clip(M['col'], 0, 1, out=M['col']); np.clip(M['opa'], -3.0, 6.0, out=M['opa']); np.clip(M['logs'], np.log(5e-4), np.log(0.05), out=M['logs']); q = M['quat']; q /= np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-9)
def densify(M, opt, gacc, gcnt, frac=0.10):
    avg = np.where(gcnt > 3, gacc / np.maximum(gcnt, 1), 0); k = max(1, int(frac * (avg > 0).sum())); top = np.argsort(-avg)[:k]; big = np.exp(M['logs'][top]).max(1) > 0.003; add = {kk: [] for kk in M}
    for j, isbig in zip(top, big):
        x, y, z, w = M['quat'][j]; R = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)], [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)], [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]], np.float32)
        ax = int(np.argmax(M['logs'][j])); off = R[:, ax] * 0.5 * float(np.exp(M['logs'][j][ax])) * (1 if isbig else 0.0)
        for kk in M:
            if kk == 'mu': add[kk].append(M[kk][j] + off)
            elif kk == 'logs': add[kk].append(M[kk][j] + (np.log(1 / 1.6) if isbig else 0))
            else: add[kk].append(M[kk][j])
        if isbig: M['mu'][j] = M['mu'][j] - off; M['logs'][j] = M['logs'][j] + np.log(1 / 1.6)
    for kk in M: M[kk] = np.concatenate([M[kk], np.array(add[kk], M[kk].dtype)], 0)
    opt.grow(len(M['mu'])); return M
def hp(x): return x - cv2.GaussianBlur(x, (0, 0), 2.0)
def fit(arm, seed=21):
    M = {k: v.copy() for k, v in START.items()}; opt = Adam(M); rng = np.random.RandomState(seed); order = []; use_d = arm in ('dens', 'both') or arm.startswith('dens_'); use_h = arm in ('hf', 'both'); use_a = 'aniso' in arm; LAM = 0.5; total = TOTAL * 2 if arm.endswith('_long') else TOTAL
    gacc = np.zeros(len(M['mu']), np.float32); gcnt = np.zeros(len(M['mu']), np.int32); dens_at = set(np.linspace(total // 9, total * 8 // 9, 8).astype(int).tolist()) if use_d else set(); t0 = time.time()
    for it in range(1, total + 1):
        if not order: order = list(rng.permutation(train))
        i = order.pop(); cam = cam_of(i, POSE[i]); gt = P.gt[i]; m = P.mask[i]; bg = ~dil[i]
        img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **g.DISPLAY); A = 1 - Tf; r = img - gt; npx = max(1, int(m.sum()))
        dLdC = r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)
        if use_h:
            rh = hp(r); s_ = rh / np.sqrt(rh * rh + 1e-4); gh = s_ - cv2.GaussianBlur(s_, (0, 0), 2.0); dLdC = dLdC + LAM * gh * m[..., None] / (npx * 3)
        dLdC = dLdC.astype(np.float32); dLdA = (0.1 * bg / max(1, int(bg.sum()))).astype(np.float32); dLdD = np.zeros_like(A, np.float32)
        gr = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, dLdC, dLdD, dLdA); gmu, glogs, gquat, gopa, gcol = [np.array(a) for a in gr[:5]]; vis = st['proj'][:, 0] > 0.5
        fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1); vis = vis & fin
        for a in (gmu, glogs, gquat, gcol): a[~fin] = 0
        gopa[~fin] = 0; opt.step(M, dict(mu=gmu, ls=glogs, q=gquat, o=gopa, c=gcol), vis)
        if use_a:      # anisotropy limit: the smallest scale of a Gaussian may not fall below max scale / 4 (no needle-like 'fur' Gaussians)
            sl = np.nonzero(vis)[0]; mx = M['logs'][sl].max(1, keepdims=True); M['logs'][sl] = np.maximum(M['logs'][sl], mx - np.log(4.0))
        if use_d:
            if len(gacc) != len(M['mu']): gacc = np.pad(gacc, (0, len(M['mu']) - len(gacc))); gcnt = np.pad(gcnt, (0, len(M['mu']) - len(gcnt)))
            gacc[vis] += np.linalg.norm(gmu[vis], axis=1) * npx; gcnt[vis] += 1
            if it in dens_at: M = densify(M, opt, gacc, gcnt); gacc = np.zeros(len(M['mu']), np.float32); gcnt = np.zeros(len(M['mu']), np.int32)
        if it % 500 == 0: print(arm, it, 'N', len(M['mu']), f'{time.time() - t0:.0f}s', flush=True)
    return M, time.time() - t0
def metrics(M, ids, camf):
    rows = []
    for i in ids:
        cam = camf(i); gt = P.gt[i]; m = P.mask[i]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; img, al, _ = g.render(M, cam); eye = g.find_eyes(gt, m)
        lap = lambda x: float(np.abs(cv2.Laplacian(cv2.cvtColor((np.clip(x, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY), cv2.CV_32F))[me].mean()); ps = lambda mm: float(-10 * np.log10(max(((img - gt) ** 2)[mm].mean(), 1e-12)))
        mt = g.metrics(img, al, gt, m, eye); r = dict(psnr=ps(m), interior=ps(me), sharp=lap(img) / max(lap(gt), 1e-9), smooth_hf_ratio=mt['smooth_hf_render'] / max(mt['smooth_hf_photo'], 1e-9) if np.isfinite(mt['smooth_hf_photo']) else float('nan'))
        if eye is not None: r['recovery'] = mt.get('recovery', float('nan')); r['eye_psnr'] = mt.get('eye_psnr', float('nan'))
        rows.append(r)
    return {k: float(np.nanmean([x[k] for x in rows if k in x])) for k in rows[0]}
res = json.load(open(f'{OUT}/sharp_results.json')) if os.path.exists(f'{OUT}/sharp_results.json') else {}
for arm in arms:
    M, sec = fit(arm); tt = {i: L.tt_pose(i, M) for i in held}
    res[arm] = dict(gaussians=int(len(M['mu'])), fit_seconds=sec, heldout_aligned=metrics(M, held, lambda i: cam_of(i, tt[i])), train_refined=metrics(M, train[::3], lambda i: cam_of(i, POSE[i])))
    np.savez_compressed(f'{OUT}/map_{arm}.npz', **M); json.dump(res, open(f'{OUT}/sharp_results.json', 'w'), indent=1)
    for i in (45, 75):
        if i in held: g.imwrite(f'{OUT}/held{i}_{arm}.png', g.render(M, cam_of(i, tt[i]))[0])
    print(arm, json.dumps(res[arm]), flush=True)
for i in (45, 75):
    if i in held: g.imwrite(f'{OUT}/held{i}_GT.png', P.gt[i])
