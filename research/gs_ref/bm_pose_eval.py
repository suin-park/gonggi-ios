"""Does consistent pose refinement reduce Bm ghosting? Strict P1 (12 held-out frames i%10==5 are used by no map / pose / photo / depth). PC research, photos local.
Arms: BASE = ARKit poses + map out_pj/map_base.npz ; JOINT / JOINT-S = refined training poses + the map that was fitted with them (out_pj/map_joint{TAG}.npz).
Bm = continuous 5-photo blend with the ORIGINAL (not completed) map depth, depth rendered at each source's own (refined) pose; sources = training frames. Held-out cameras: (a) recorded ARKit pose, (b) test-time aligned against the arm's map (camera only; identical procedure) .
Ghost proxy = luminance spread among the photos that pass the occlusion rule, around the eye/nose, ear, seat, rim anchors. usage: python bm_pose_eval.py [TAGS e.g. ,S]"""
import os, sys, json
import numpy as np, cv2
from bmcore import *
import gsref
tags = sys.argv[1].split(',') if len(sys.argv) > 1 else ['', 'S']; views = [i for i in range(P.n) if P.mask[i].sum() > 50]; held = [i for i in views if i % 10 == 5]; train = [i for i in views if i % 10 != 5]
md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}; cam0 = P.cam
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
def set_poses(d):
    def cam(i, w=EW, h=EH):
        c = dict(cam0(i, w, h))
        if i in d: p = d[i]; c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]
        return c
    P.cam = cam
def small(i): return cv2.resize(P.gt[i], (320, 240), interpolation=cv2.INTER_AREA), cv2.resize(P.mask[i].astype(np.uint8), (320, 240), interpolation=cv2.INTER_NEAREST) > 0
def residual(i, p, gts, ms, M):
    c = dict(cam0(i, 320, 240)); c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]; img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], c, **g.DISPLAY); return ((img - gts) * ms[..., None]).ravel()
def tt_pose(i, M, iters=8):
    gts, ms = small(i); p = np.zeros(6); lam = 1e-2; r = residual(i, p, gts, ms, M); f = float(r @ r); steps = np.array([0.002] * 6)
    for _ in range(iters):
        J = np.stack([(residual(i, p + np.eye(6)[k] * steps[k], gts, ms, M) - r) / steps[k] for k in range(6)], 1); A = J.T @ J; b = J.T @ r; moved = False
        for _ in range(4):
            d = -np.linalg.solve(A + lam * np.diag(np.diag(A) + 1e-9), b); r2 = residual(i, p + d, gts, ms, M); f2 = float(r2 @ r2)
            if f2 < f: p = p + d; r = r2; f = f2; lam = max(lam / 3, 1e-6); moved = True; break
            lam *= 4
        if not moved: break
    return p
lum = lambda x: 0.299 * x[..., 0] + 0.587 * x[..., 1] + 0.114 * x[..., 2]
def ghost(ct, parts, keeps):
    fl = np.stack([lum(p[2]) for p in parts]); fm = np.stack(keeps); cnt = fm.sum(0); mean = (fl * fm).sum(0) / np.maximum(cnt, 1); sd = np.sqrt((((fl - mean) ** 2) * fm).sum(0) / np.maximum(cnt, 1)); ok = cnt >= 2; o = {}
    for name, anc in ANCH.items():
        pt = (anc - ct['C']) @ ct['Rcw'].T; u = int((ct['fx'] * pt[0] / pt[2] + ct['cx']) * SS); v = int((ct['fy'] * pt[1] / pt[2] + ct['cy']) * SS); sl = (slice(max(0, v - 60), v + 60), slice(max(0, u - 80), u + 80)); oo = ok[sl]; o[name] = float(sd[sl][oo].mean()) if oo.sum() > 200 else float('nan')
    return o
def run(name, M, src_pose, held_pose):
    set_poses(src_pose); zc = {}
    def zf(i):
        if i not in zc:
            img, dep, Tf, st = gsref.render(M['mu'], M['logs'], M['quat'], M['col'], M['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf; zc[i] = np.where((al > 0.5) & md[i], dep / np.maximum(al, 1e-3), 0).astype(np.float32)
        return zc[i]
    out = {}
    for label, hp in (('arkit', {}), ('aligned', held_pose)):
        set_poses({**src_pose, **hp}); ps, ints, gh, g3 = [], [], [], []
        for f in held:
            ct = P.cam(f); gt = P.gt[f]; m = P.mask[f]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; im, al, parts, keeps = blend(ct, train, zf, want_parts=True)
            ps.append(float(-10 * np.log10(max(((im - gt) ** 2)[m].mean(), 1e-12)))); ints.append(float(-10 * np.log10(max(((im - gt) ** 2)[me].mean(), 1e-12)))); gh.append(ghost(ct, parts, keeps))
            i3 = g.render(M, ct)[0]; g3.append(float(-10 * np.log10(max(((i3 - gt) ** 2)[m].mean(), 1e-12))))
            if f in (45, 75) and label == 'aligned': g.imwrite(f'out_pj/bm_{name}_held{f}.png', im)
        out[label] = dict(bm_psnr=float(np.mean(ps)), bm_interior=float(np.mean(ints)), gs_psnr=float(np.mean(g3)), ghost={a: float(np.nanmean([x[a] for x in gh])) for a in ANCH})
    print(name, json.dumps(out), flush=True); return out
res = {}
MB = {k: v for k, v in np.load('out_pj/map_base.npz').items()}; ttB = {i: tt_pose(i, MB) for i in held}; res['BASE'] = run('BASE', MB, {}, ttB)
for t in tags:
    f = f'out_pj/map_joint{t}.npz'
    if not os.path.exists(f): print('missing', f); continue
    MJ = {k: v for k, v in np.load(f).items()}; pose = {int(k): np.array(v) for k, v in json.load(open(f'out_pj/poses_refined{t}.json')).items()} if os.path.exists(f'out_pj/poses_refined{t}.json') else None
    if t == '': pose = {int(k): np.array(v) for k, v in json.load(open('out_pj/poses_refined.json')).items()}
    ttJ = {i: tt_pose(i, MJ) for i in held}; res['JOINT' + t] = run('JOINT' + t, MJ, pose, ttJ)
json.dump(res, open('out_pj/bm_pose_eval.json', 'w'), indent=1)
