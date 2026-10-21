"""Alternating pose / map refinement vs fixed ARKit poses (PC research, photos local). Strict P1: the 12 held-out frames (i%10==5) are used by nothing (map, poses, photos).
Start map = out_ub/map_gsmax_P1.npz (built from the training frames only, ARKit poses).
 BASE : +TOTAL iterations of the same fit (640x480 full-frame supervision, same loss / LR / Adam as bestfit.py), ARKit poses unchanged.
 JOINT: ROUNDS x [ pose refinement of every training frame (6-DoF LM, finite-difference Jacobian, photometric loss against the FIXED map, 320x240, product pixels) ; TOTAL/ROUNDS map-fit iterations with the refined poses ].
Same total map iterations. Held-out frames are evaluated twice: (a) ARKit pose as recorded (no use of the held-out photo); (b) test-time pose alignment against the final map (uses the held-out photo for the CAMERA only; identical procedure for both arms, labelled as such).
Reported: product PSNR / interior PSNR / sharpness (Laplacian/photo) / eye recovery on held-out (a),(b) and on TRAIN views (fit quality, shows blur), pose correction magnitudes.
usage: ROUNDS=3 TOTAL=6000 python posejoint.py"""
import os, sys, json, time
import numpy as np, cv2
import gtlib as g
import gsref
TAG = os.environ.get('TAG', ''); SMOOTH = float(os.environ.get('SMOOTH', 0)); REUSE = os.environ.get('REUSE_BASE') == '1'; os.makedirs('out_pj', exist_ok=True); TOTAL = int(os.environ.get('TOTAL', 6000)); ROUNDS = int(os.environ.get('ROUNDS', 3))
os.environ.setdefault('NPZ_PATH', 'x')
P = g.Photos(); n = P.n; views = [i for i in range(n) if P.mask[i].sum() > 50]; DTAG = '' if os.environ.get('DATA', '09') == '09' else os.environ['DATA'] + '_'; ALL = os.environ.get('ALL') == '1'; held = [] if ALL else [i for i in views if i % 10 == 5]; train = views if ALL else [i for i in views if i % 10 != 5]
z_ = np.load(os.environ.get('STARTMAP', 'out_ub/map_gsmax_P1.npz')); START = {k: z_[k].copy() for k in z_.files}
LR0 = dict(mu=2e-4, ls=1e-3, q=5e-4, o=0.04, c=0.012); dil = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((31, 31), np.uint8)) > 0 for i in views}
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
POSE = {i: np.zeros(6) for i in views}
def cam_of(i, p, w=g.EW, h=g.EH): c = dict(P.cam(i, w, h)); c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]; return c
RW_ = int(os.environ.get('RES', 320)); RH_ = RW_ * 3 // 4
def small(i): return cv2.resize(P.gt[i], (RW_, RH_), interpolation=cv2.INTER_AREA), cv2.resize(P.mask[i].astype(np.uint8), (RW_, RH_), interpolation=cv2.INTER_NEAREST) > 0
def residual(i, p, gts, ms, M):
    img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam_of(i, p, RW_, RH_), **g.DISPLAY); return ((img - gts) * ms[..., None]).ravel()
def refine_pose(i, M, p0, iters=8):
    gts, ms = small(i); p = p0.copy(); lam = 1e-2; r = residual(i, p, gts, ms, M); f = float(r @ r); steps = np.array([0.002] * 6)
    for _ in range(iters):
        J = np.stack([(residual(i, p + np.eye(6)[k] * steps[k], gts, ms, M) - r) / steps[k] for k in range(6)], 1); A = J.T @ J; b = J.T @ r; moved = False
        for _ in range(4):
            d = -np.linalg.solve(A + lam * np.diag(np.diag(A) + 1e-9), b); r2 = residual(i, p + d, gts, ms, M); f2 = float(r2 @ r2)
            if f2 < f: p = p + d; r = r2; f = f2; lam = max(lam / 3, 1e-6); moved = True; break
            lam *= 4
        if not moved or (np.linalg.norm(d[:3]) < 1e-5 and np.linalg.norm(d[3:]) < 1e-5): break
    return p
class Adam:
    def __init__(s, M): s.m = {k: np.zeros_like(M[nm]) for k, nm in (('c', 'col'), ('o', 'opa'), ('mu', 'mu'), ('ls', 'logs'), ('q', 'quat'))}; s.v = {k: np.zeros_like(a) for k, a in s.m.items()}; s.t = np.zeros(len(M['mu']), np.int32)
    def step(s, M, grads, vis):
        sl = np.nonzero(vis)[0]
        if len(sl) == 0: return
        s.t[sl] += 1; c = s.t[sl].astype(np.float32)
        for key, name in (('c', 'col'), ('o', 'opa'), ('mu', 'mu'), ('ls', 'logs'), ('q', 'quat')):
            gs = grads[key][sl]; s.m[key][sl] = 0.9 * s.m[key][sl] + 0.1 * gs; s.v[key][sl] = 0.99 * s.v[key][sl] + 0.01 * gs * gs; cc = c[:, None] if gs.ndim == 2 else c
            M[name][sl] -= LR0[key] * (s.m[key][sl] / (1 - 0.9 ** cc)) / (np.sqrt(s.v[key][sl] / (1 - 0.99 ** cc)) + 1e-8)
        np.clip(M['col'], 0, 1, out=M['col']); np.clip(M['opa'], -3.0, 6.0, out=M['opa']); np.clip(M['logs'], np.log(5e-4), np.log(0.05), out=M['logs']); q = M['quat']; q /= np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-9)
def fit(M, iters, seed):
    opt = Adam(M); rng = np.random.RandomState(seed); order = []
    for it in range(iters):
        if not order: order = list(rng.permutation(train))
        i = order.pop(); cam = cam_of(i, POSE[i]); gt = P.gt[i]; m = P.mask[i]; bg = ~dil[i]
        img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **g.DISPLAY); A = 1 - Tf; r = img - gt; npx = max(1, int(m.sum()))
        dLdC = (r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); dLdA = (0.1 * bg / max(1, int(bg.sum()))).astype(np.float32); dLdD = np.zeros_like(A, np.float32)
        gr = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, dLdC, dLdD, dLdA); gmu, glogs, gquat, gopa, gcol = [np.array(a) for a in gr[:5]]; vis = st['proj'][:, 0] > 0.5
        fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1); vis = vis & fin
        for a in (gmu, glogs, gquat, gcol): a[~fin] = 0
        gopa[~fin] = 0; opt.step(M, dict(mu=gmu, ls=glogs, q=gquat, o=gopa, c=gcol), vis)
def evaluate(M, ids, pose_of):
    out = []
    for i in ids:
        cam = cam_of(i, pose_of(i)); gt = P.gt[i]; m = P.mask[i]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; img, al, _ = g.render(M, cam); eye = g.find_eyes(gt, m)
        lap = lambda x: float(np.abs(cv2.Laplacian(cv2.cvtColor((np.clip(x, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY), cv2.CV_32F))[me].mean())
        ps = lambda mm: float(-10 * np.log10(max(((img - gt) ** 2)[mm].mean(), 1e-12))); o = dict(psnr=ps(m), interior=ps(me), sharp=lap(img) / max(lap(gt), 1e-9))
        if eye is not None: o['recovery'] = g.metrics(img, al, gt, m, eye).get('recovery', float('nan'))
        out.append(o)
    return {k: float(np.nanmean([o[k] for o in out if k in o])) for k in out[0]}
t0 = time.time(); log = {}
# ---------------- BASE
if REUSE: MB = {k: v for k, v in np.load('out_pj/map_base.npz').items()}; t_base = 0.0
else: MB = {k: v.copy() for k, v in START.items()}; fit(MB, TOTAL, 1); t_base = time.time() - t0
print('base ready', int(t_base), flush=True)
# ---------------- JOINT
MJ = {k: v.copy() for k, v in START.items()}; t1 = time.time(); rounds = []
for r in range(ROUNDS):
    tp = time.time()
    for i in train: POSE[i] = refine_pose(i, MJ, POSE[i])
    if SMOOTH > 0:      # temporal smoothing of the pose corrections along the capture order (ARKit drift is slow; per-frame jitter is overfitting to the map)
        ids = np.array(train); D = np.stack([POSE[i] for i in train]); Ds = np.stack([np.sum([np.exp(-0.5 * ((ids - i) / SMOOTH) ** 2)[:, None] * D for _ in [0]], 0).sum(0) / np.exp(-0.5 * ((ids - i) / SMOOTH) ** 2).sum() for i in train])
        for k, i in enumerate(train): POSE[i] = Ds[k]
    mag = [(float(np.degrees(np.linalg.norm(POSE[i][:3]))), float(100 * np.linalg.norm(POSE[i][3:]))) for i in train]; fit(MJ, TOTAL // ROUNDS, 10 + r)
    rounds.append(dict(round=r + 1, pose_mean_deg=float(np.mean([m[0] for m in mag])), pose_mean_cm=float(np.mean([m[1] for m in mag])), seconds=time.time() - tp)); print(rounds[-1], flush=True)
t_joint = time.time() - t1
if ALL:
    np.savez_compressed(f'out_pj/{DTAG}all_map_base.npz', **MB); np.savez_compressed(f'out_pj/{DTAG}all_map_joint.npz', **MJ); json.dump({str(k): v.tolist() for k, v in POSE.items()}, open(f'out_pj/{DTAG}all_poses_refined.json', 'w'))
    r_ = dict(train_base=evaluate(MB, train[::3], lambda i: np.zeros(6)), train_joint=evaluate(MJ, train[::3], lambda i: POSE[i]), rounds=rounds, seconds=dict(base=t_base, joint=t_joint)); print(json.dumps(r_, indent=1)); json.dump(r_, open(f'out_pj/{DTAG}posejoint_all.json', 'w'), indent=1); sys.exit(0)
# ---------------- test-time alignment of the held-out cameras against each final map (same procedure for both)
def tt_pose(M): return {i: refine_pose(i, M, np.zeros(6)) for i in held}
ttB = tt_pose(MB); ttJ = tt_pose(MJ)
res = dict(
    BASE=dict(heldout_arkit=evaluate(MB, held, lambda i: np.zeros(6)), heldout_aligned=evaluate(MB, held, lambda i: ttB[i]), train=evaluate(MB, train[::3], lambda i: np.zeros(6))),
    JOINT=dict(heldout_arkit=evaluate(MJ, held, lambda i: np.zeros(6)), heldout_aligned=evaluate(MJ, held, lambda i: ttJ[i]), train_with_refined_poses=evaluate(MJ, train[::3], lambda i: POSE[i]), train_with_arkit=evaluate(MJ, train[::3], lambda i: np.zeros(6))),
    start=dict(heldout_arkit=evaluate(START, held, lambda i: np.zeros(6)), train=evaluate(START, train[::3], lambda i: np.zeros(6))), rounds=rounds, seconds=dict(base_fit=t_base, joint_total=t_joint), total_iters=TOTAL)
print(json.dumps(res, indent=1)); json.dump(res, open(f'out_pj/posejoint{TAG}.json', 'w'), indent=1)
np.savez_compressed('out_pj/map_base.npz', **MB) if not REUSE else None; np.savez_compressed(f'out_pj/map_joint{TAG}.npz', **MJ); json.dump({'tt_base': {str(k): v.tolist() for k, v in ttB.items()}, 'tt_joint': {str(k): v.tolist() for k, v in ttJ.items()}}, open(f'out_pj/tt_poses{TAG}.json', 'w')); json.dump({str(k): v.tolist() for k, v in POSE.items()}, open(f'out_pj/poses_refined{TAG}.json', 'w'))
for i in (45, 75, 105):
    if i in held: g.imwrite(f'out_pj/held{i}{TAG}_base.png', g.render(MB, cam_of(i, ttB[i]))[0]); g.imwrite(f'out_pj/held{i}{TAG}_joint.png', g.render(MJ, cam_of(i, ttJ[i]))[0])
