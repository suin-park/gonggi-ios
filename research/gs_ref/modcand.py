"""Candidate chosen from the blur observation (blur_diag): 'contrast-straddle split'. Gaussians whose footprint covers both dark and bright photo pixels (weighted luminance std inside the footprint, accumulated over all training views) are split in two (scale/1.6, +-0.5 sigma along the major axis, colour/opacity inherited = ORIGINAL COLOURS KEPT); then normal optimisation continues.
Start = real device-saved map (out_pj/start_09_device.npz = test_09 .kmogs, 6,890 Gaussians, device colours) with the refined poses of the e2e run (poses_all.json; frames i%10==5 are NOT used by the optimisation = 'neighbour' views; their cameras are test-time aligned per arm = camera only, evaluation cost).
Arms, SAME wall-clock budget (selection + split time is counted in the candidate's budget; scoring/rendering excluded):
  base : continue the normal optimisation (all parameters, 640x480 supervision, same loss / LR / Adam)
  cand : straddle-score + split, then the same optimisation for the rest of the budget
Views reported: observed (training frames, refined poses), neighbour (held i%10==5), earlier directions (frames <= 25), return direction (frames >= 100). Images first (photo | device map as saved | base | cand).
NOT a strict held-out: the device map saw every frame.  usage: python modcand.py [BUDGET_SECONDS=240]"""
import os, sys, json, time
BUD = float(sys.argv[1]) if len(sys.argv) > 1 else 240.0
SRC = open('posejoint.py', encoding='utf-8').read().split("t0 = time.time(); log = {}")[0]
os.environ['STARTMAP'] = 'out_pj/start_09_device.npz'; sys.argv = ['x']; os.environ.pop('ALL', None); ns = {'__name__': 'pj'}; exec(SRC, ns)
import numpy as np, cv2
import gsref, gtlib as g
import bm_pose_eval_lib as L
P = ns['P']; train = ns['train']; held = ns['held']; START = ns['START']; cam_of = ns['cam_of']; POSE = ns['POSE']; Adam0 = ns['Adam']; views = ns['views']; dil = ns['dil']
PJ = json.load(open('C:/Users/emili/Downloads/best_3d_quality_before_friday/e2e_device09/cache/poses_all.json'))
for i in views: POSE[i] = np.array(PJ[str(i)])
CAMS = {i: cam_of(i, POSE[i]) for i in train}; D = g.DISPLAY; OUT = 'out_mod'; os.makedirs(OUT, exist_ok=True)
LR0 = ns['LR0']
class Adam(Adam0):
    def grow_by(s, n_new, parents):       # children inherit the parent's moments (halved) and step count
        for k in s.m: s.m[k] = np.concatenate([s.m[k], s.m[k][parents]]); s.v[k] = np.concatenate([s.v[k], s.v[k][parents]])
        s.t = np.concatenate([s.t, s.t[parents]])
def score_straddle(M):
    num1 = np.zeros(len(M['col']), np.float32); num2 = np.zeros_like(num1); den = np.zeros_like(num1)
    for i in train:
        cam = CAMS[i]; img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **D); z0 = np.zeros(Tf.shape, np.float32); gt = P.gt[i]; m = P.mask[i].astype(np.float32); Lm = (0.299 * gt[..., 0] + 0.587 * gt[..., 1] + 0.114 * gt[..., 2]) * m
        for X, acc in ((Lm, num1), (Lm * Lm / np.maximum(m, 1e-6) * m, num2), (m, den)):
            acc += np.nan_to_num(np.array(gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, np.repeat(X[..., None], 3, 2).astype(np.float32), z0, z0)[4][:, 0]))
    mean = num1 / np.maximum(den, 1e-6); var = np.maximum(num2 / np.maximum(den, 1e-6) - mean ** 2, 0); return np.sqrt(var), den
def split(M, opt, ids):
    add = {k: [] for k in M}
    for j in ids:
        x, y, z, w = M['quat'][j]; R = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)], [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)], [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]], np.float32)
        ax = int(np.argmax(M['logs'][j])); off = R[:, ax] * 0.5 * float(np.exp(M['logs'][j][ax]))
        for kk in M:
            if kk == 'mu': add[kk].append(M[kk][j] + off)
            elif kk == 'logs': add[kk].append(M[kk][j] + np.log(1 / 1.6))
            else: add[kk].append(M[kk][j])
        M['mu'][j] = M['mu'][j] - off; M['logs'][j] = M['logs'][j] + np.log(1 / 1.6)
    for kk in M: M[kk] = np.concatenate([M[kk], np.array(add[kk], M[kk].dtype)], 0)
    opt.grow_by(len(ids), np.array(ids)); return M
def fit_timed(M, budget, seed, do_split):
    opt = Adam(M); rng = np.random.RandomState(seed); order = []; t0 = time.time(); info = {}
    if do_split:
        s, den = score_straddle(M); ok = den > np.median(den); thr = np.percentile(s[ok], 80); ids = np.nonzero(ok & (s >= thr))[0]; M = split(M, opt, ids); info = dict(split_count=int(len(ids)), score_threshold=float(thr), select_split_seconds=time.time() - t0, gaussians_after=int(len(M['mu'])))
    n = 0
    while time.time() - t0 < budget:
        if not order: order = list(rng.permutation(train))
        i = order.pop(); cam = CAMS[i]; gt = P.gt[i]; m = P.mask[i]; bg = ~dil[i]
        img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, **D); A = 1 - Tf; r = img - gt; npx = max(1, int(m.sum()))
        dLdC = (r / np.sqrt(r * r + 1e-4) * m[..., None] / (npx * 3)).astype(np.float32); dLdA = (0.1 * bg / max(1, int(bg.sum()))).astype(np.float32); dLdD = np.zeros_like(A, np.float32)
        gr = gsref.backward(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], cam, st, Tf, dLdC, dLdD, dLdA); gmu, glogs, gquat, gopa, gcol = [np.array(a) for a in gr[:5]]; vis = st['proj'][:, 0] > 0.5
        fin = np.isfinite(gmu).all(1) & np.isfinite(glogs).all(1) & np.isfinite(gquat).all(1) & np.isfinite(gopa) & np.isfinite(gcol).all(1); vis = vis & fin
        for a in (gmu, glogs, gquat, gcol): a[~fin] = 0
        gopa[~fin] = 0; opt.step(M, dict(mu=gmu, ls=glogs, q=gquat, o=gopa, c=gcol), vis); n += 1
    info.update(iterations=n, total_seconds=time.time() - t0, gaussians=int(len(M['mu']))); return M, info
def metrics(M, ids, camf):
    rows = []
    for i in ids:
        cam = camf(i); gt = P.gt[i]; m = P.mask[i]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; img, al, _ = g.render(M, cam); eye = g.find_eyes(gt, m)
        lap = lambda x: float(np.abs(cv2.Laplacian(cv2.cvtColor((np.clip(x, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY), cv2.CV_32F))[me].mean()); ps = lambda mm: float(-10 * np.log10(max(((img - gt) ** 2)[mm].mean(), 1e-12)))
        r = dict(psnr=ps(m), sharp=lap(img) / max(lap(gt), 1e-9))
        if eye is not None: r['recovery'] = g.metrics(img, al, gt, m, eye).get('recovery', float('nan')); r['eye_psnr'] = g.metrics(img, al, gt, m, eye).get('eye_psnr', float('nan'))
        rows.append(r)
    return {k: float(np.nanmean([x[k] for x in rows if k in x])) for k in rows[0]}
def evaluate(M, tt):
    early = [i for i in train if i <= 25]; late = [i for i in train if i >= 100]; mid = [i for i in train if 26 <= i <= 99][::3]
    return dict(observed_mid=metrics(M, mid, lambda i: CAMS[i]), earlier_directions=metrics(M, early, lambda i: CAMS[i]), return_direction=metrics(M, late, lambda i: CAMS[i]), neighbour_heldout_aligned=metrics(M, held, lambda i: cam_of(i, tt[i])))
res = {}; maps = {}; tts = {}
M0 = {k: v.copy() for k, v in START.items()}; tt0 = {i: L.tt_pose(i, M0) for i in held}; res['device_map_as_saved'] = dict(gaussians=len(M0['mu']), **evaluate(M0, tt0)); maps['device'] = M0; tts['device'] = tt0
for name, ds in (('base', False), ('cand', True)):
    M = {k: v.copy() for k, v in START.items()}; M, info = fit_timed(M, BUD, 3, ds); tt = {i: L.tt_pose(i, M) for i in held}; res[name] = dict(info=info, **evaluate(M, tt)); maps[name] = M; tts[name] = tt
    np.savez_compressed(f'{OUT}/map_{name}.npz', **M); json.dump(res, open(f'{OUT}/modcand.json', 'w'), indent=1); print(name, json.dumps(info), flush=True)
# ---- images FIRST: photo | device map as saved | base | cand, eye region, four views
rows = []
for i, lab in ((46, '관측'), (45, '이웃(보류)'), (12, '이전 촬영 방향'), (110, '처음 방향으로 복귀')):
    gt = P.gt[i]; e = g.find_eyes(gt, P.mask[i])
    if e is None: continue
    x0, y0, x1, y1 = e['box']; cx, cy = (x0 + x1) // 2, (y0 + y1) // 2; w, h = 200, 150; X0 = int(np.clip(cx - w // 2, 0, 640 - w)); Y0 = int(np.clip(cy - h // 2, 0, 480 - h)); cr = lambda im: cv2.resize((np.clip(im[Y0:Y0 + h, X0:X0 + w], 0, 1) * 255).astype(np.uint8), (400, 300), interpolation=cv2.INTER_NEAREST); cells = [cr(gt)]
    for nm in ('device', 'base', 'cand'):
        cam = CAMS[i] if i in CAMS else cam_of(i, tts[nm][i]); cells.append(cr(g.render(maps[nm], cam)[0]))
    rows.append(np.concatenate(cells, 1)); print('image row', i, lab, flush=True)
cv2.imencode('.png', cv2.cvtColor(np.concatenate(rows, 0), cv2.COLOR_RGB2BGR))[1].tofile(f'{OUT}/zoom_photo_device_base_cand.png')
print(json.dumps({k: {a: {b: round(c, 3) for b, c in v.items()} for a, v in d.items() if a != 'info' and isinstance(v, dict)} for k, d in res.items() if k != 'device_map_as_saved'}, indent=1)); print('done')
