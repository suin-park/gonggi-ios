"""Silhouette-only evaluation (strict P1, held-out cameras test-time ALIGNED to the held-out photo = camera only; JOINT arm). Reference silhouette = guided-filter matte of the held-out photo > 0.5 (same method as the source mattes: NOT independent ground truth).
Candidates: S_bm = existing Bm binary silhouette (bmcore.blend coverage>0.5) | S_3dgs = 3DGS render alpha>0.5 | S_bm_smooth = Bm coverage blurred (sigma 1.5 px) >0.4 | S_3dgs_ramp is the same as S_3dgs here.
Metrics: IoU to reference, mean boundary distance (px), contour roughness = rms deviation of the contour from its 4-px Gaussian-smoothed version (pixel-grid stairs of any binary mask give ~0.4-0.5), ring lost/added px."""
import json, numpy as np, cv2
import bm_edge, bm_pose_eval_lib as L
from bm_edge import *
from scipy import ndimage
MJ = {k: v for k, v in np.load('out_pj/map_joint.npz').items()}; pose = {int(k): np.array(v) for k, v in json.load(open('out_pj/poses_refined.json')).items()}
set_poses({}); tt = {i: L.tt_pose(i, MJ) for i in held}; set_poses({**pose, **tt}); zc = {}
def zf(i):
    if i not in zc:
        img, dep, Tf, st = gsref.render(MJ['mu'], MJ['logs'], MJ['quat'], MJ['col'], MJ['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf; zc[i] = np.where((al > 0.5) & md[i], dep / np.maximum(al, 1e-3), 0).astype(np.float32)
    return zc[i]
def rough(m):
    cs, _ = cv2.findContours(m.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    if not cs: return float('nan')
    c = max(cs, key=len)[:, 0].astype(np.float32); k = np.exp(-0.5 * (np.arange(-12, 13) / 4.0) ** 2); k /= k.sum(); sm = np.stack([np.convolve(np.r_[c[-12:, i], c[:, i], c[:12, i]], k, 'valid') for i in (0, 1)], 1); return float(np.sqrt((np.linalg.norm(c - sm, axis=1) ** 2).mean()))
def bdist(a, b):      # mean distance from a's boundary to b's boundary
    ea = a & ~(cv2.erode(a.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0); dt = ndimage.distance_transform_edt(~(b & ~(cv2.erode(b.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0))); return float(dt[ea].mean())
R = {}
for f in held:
    ct = P.cam(f); ref = matte(f) > 0.5; io, ao = blend(ct, train, zf); i3, a3, _ = g.render(MJ, ct)
    cands = {'Bm_binary': ao > 0.5, '3DGS_alpha': a3 > 0.5, 'Bm_smoothed': cv2.GaussianBlur((ao > 0.5).astype(np.float32), (0, 0), 1.5) > 0.4, 'matte_reference': ref}
    for n, s in cands.items():
        s = ndimage.binary_fill_holes(s); inter = (s & ref).sum(); R.setdefault(n, []).append(dict(iou=float(inter / max((s | ref).sum(), 1)), bd=bdist(s, ref), rough=rough(s), added=int((s & ~ref).sum()), lost=int((ref & ~s).sum())))
summ = {n: {k: float(np.nanmean([x[k] for x in v])) for k in v[0]} for n, v in R.items()}; print(json.dumps(summ, indent=1)); json.dump(summ, open('out_pj/sil_eval.json', 'w'), indent=1)
