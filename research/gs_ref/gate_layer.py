"""Per-layer edge smoothing at creation time: each source photo gets ONE smooth binary layer mask (matte upsampled x3 bicubic, gaussian sigma 4 hi-res px, >0.5, hole-filled, downsampled) plus a tolerance dilation TOL px (absorbs the few-px silhouette disagreement between views). Used as the gate (depth only inside the layer mask); everything else as bm_gate.py. Strict P2 PSNR criterion (<=0.3 dB loss vs original Bm) and strict P1 silhouette vs the coarse mask."""
import sys; PHASE = sys.argv[1]; sys.argv = ['x', 'A', 'out_pj']
import json, numpy as np, cv2
src = open('bm_gate.py', encoding='utf-8').read().split("if PH == 'A':")[0]; exec(src)
import bm_pose_eval_lib as L
from bm_edge import set_poses
lay = {}
def layer(i, tol):
    key = (i, tol)
    if key not in lay:
        a = bm_edge.matte(i); big = cv2.resize(a, (EW * 3, EH * 3), interpolation=cv2.INTER_CUBIC); big = cv2.GaussianBlur(big, (0, 0), 4.0); m = (big > 0.5).astype(np.uint8); m = ndimage.binary_fill_holes(m).astype(np.uint8)
        m = cv2.resize(m.astype(np.float32), (EW, EH), interpolation=cv2.INTER_AREA) > 0.5
        if tol > 0: m = cv2.dilate(m.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * tol + 1, 2 * tol + 1))) > 0
        lay[key] = m
    return lay[key]
if PHASE == 'A':
    BL = [(17, 23), (37, 43), (57, 63), (77, 83), (97, 103)]; HELD = set(i for a, b in BL for i in range(a, b + 1)); train = [i for i in views if i not in HELD]; held = [i for i in views if i in HELD]
    z_ = np.load('out_ub/map_gsmax_P2.npz'); M = {k: z_[k] for k in z_.files}; zf = depth_fn(M); R = {}
    for nm, tol in (('original', None), ('layer_tol2', 2), ('layer_tol3', 3)):
        zfn = zf if tol is None else (lambda i, t=tol: np.where(layer(i, t), zf(i), 0).astype(np.float32)); set_ss(2 if tol is None else 3); ps, pi = [], []
        for f in held:
            ct = P.cam(f); gt = P.gt[f]; m = P.mask[f]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; im, al = blend(ct, train, zfn); ps.append(float(-10 * np.log10(max(((im - gt) ** 2)[m].mean(), 1e-12)))); pi.append(float(-10 * np.log10(max(((im - gt) ** 2)[me].mean(), 1e-12))))
        R[nm] = dict(full=float(np.mean(ps)), interior=float(np.mean(pi))); print(nm, R[nm], flush=True)
    json.dump(R, open('out_pj/layer_A.json', 'w'), indent=1)
else:
    held = [i for i in views if i % 10 == 5]; train = [i for i in views if i % 10 != 5]; MJ = {k: v for k, v in np.load('out_pj/map_joint.npz').items()}; pose = {int(k): np.array(v) for k, v in json.load(open('out_pj/poses_refined.json')).items()}
    set_poses({}); tt = {i: L.tt_pose(i, MJ) for i in held}; set_poses({**pose, **tt}); zf = depth_fn(MJ); R = {}
    for f in held:
        ct = P.cam(f); m = ndimage.binary_fill_holes(P.mask[f]); set_ss(2); io, ao = blend(ct, train, zf); cands = {'Bm_old': ao > 0.5}
        for tol in (2, 3):
            set_ss(3); ig, ag = blend(ct, train, lambda i, t=tol: np.where(layer(i, t), zf(i), 0).astype(np.float32)); isg, asg = smooth_sil(ig, ag); cands[f'layer_tol{tol}'] = ag > 0.5; cands[f'layer_tol{tol}_smoothed'] = asg > 0.5
        for n, s in cands.items(): s = ndimage.binary_fill_holes(s); R.setdefault(n, []).append(dict(iou=float((s & m).sum() / max((s | m).sum(), 1)), bd=bdist(s, m), rough=rough(s), added=int((s & ~m).sum()), lost=int((m & ~s).sum()), area_ratio=float(s.sum() / m.sum())))
    summ = {n: {k: float(np.mean([x[k] for x in v])) for k in v[0]} for n, v in R.items()}; print(json.dumps(summ, indent=1)); json.dump(summ, open('out_pj/layer_B.json', 'w'), indent=1)
