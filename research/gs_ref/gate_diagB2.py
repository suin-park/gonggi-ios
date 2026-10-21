"""Silhouette vs the COARSE product mask itself (the segmentation the dataset has; labels==1 at 640x480), strict P1, JOINT arm, held-out cameras test-time aligned (camera only)."""
import sys; sys.argv = ['x', 'B', 'out_pj']
import json, numpy as np, cv2
src = open('bm_gate.py', encoding='utf-8').read().split("if PH == 'A':")[0]; exec(src)
import bm_pose_eval_lib as L
from bm_edge import set_poses
held = [i for i in views if i % 10 == 5]; train = [i for i in views if i % 10 != 5]; MJ = {k: v for k, v in np.load('out_pj/map_joint.npz').items()}; pose = {int(k): np.array(v) for k, v in json.load(open('out_pj/poses_refined.json')).items()}
set_poses({}); tt = {i: L.tt_pose(i, MJ) for i in held}; set_poses({**pose, **tt}); zf = depth_fn(MJ); zg = lambda i: np.where(gmask(i), zf(i), 0).astype(np.float32); R = {}
for f in held:
    ct = P.cam(f); m = ndimage.binary_fill_holes(P.mask[f]); set_ss(2); io, ao = blend(ct, train, zf); set_ss(3); ig, ag = blend(ct, train, zg); i3, a3, _ = g.render(MJ, ct); mt = bm_edge.matte(f) > 0.5
    for n, s in {'Bm_old': ao > 0.5, 'Bm_gate': ag > 0.5, '3DGS': a3 > 0.5, 'matte(tight)': mt}.items():
        s = ndimage.binary_fill_holes(s); R.setdefault(n, []).append(dict(iou=float((s & m).sum() / max((s | m).sum(), 1)), bd=bdist(s, m), added=int((s & ~m).sum()), lost=int((m & ~s).sum()), area_ratio=float(s.sum() / m.sum())))
summ = {n: {k: float(np.mean([x[k] for x in v])) for k in v[0]} for n, v in R.items()}; print(json.dumps(summ, indent=1)); json.dump(summ, open('out_pj/gate_diagB2.json', 'w'), indent=1)
