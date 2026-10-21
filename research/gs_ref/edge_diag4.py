"""Why did bm_edge.json 'full' PSNR fall 32.99 -> ~25.5? Decompose the held-out error (strict P1, 12 held-out photos, held-out cameras test-time ALIGNED to the held-out photo against the fixed map = the evaluation photo was used to place the camera) into interior (mask eroded 9 px) and ring (mask minus interior)."""
import json, numpy as np, cv2
import bm_edge, bm_pose_eval_lib as L
from bm_edge import *
MJ = {k: v for k, v in np.load('out_pj/map_joint.npz').items()}; pose = {int(k): np.array(v) for k, v in json.load(open('out_pj/poses_refined.json')).items()}
set_poses({}); tt = {i: L.tt_pose(i, MJ) for i in held}; set_poses({**pose, **tt}); zc = {}
def zf(i):
    if i not in zc:
        img, dep, Tf, st = gsref.render(MJ['mu'], MJ['logs'], MJ['quat'], MJ['col'], MJ['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf; zc[i] = np.where((al > 0.5) & md[i], dep / np.maximum(al, 1e-3), 0).astype(np.float32)
    return zc[i]
acc = {k: dict(se_int=0.0, se_ring=0.0, n_int=0, n_ring=0, ring_alpha=[], ring_lum_ratio=[]) for k in ('old', 'new')}; fr = []
for f in held:
    ct = P.cam(f); gt = P.gt[f]; m = P.mask[f]; me = cv2.erode(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; ring = m & ~me
    io, ao = blend(ct, train, zf); inw, an = blend_a(ct, train, zf, SSn=3, ext=3)
    for nm, im, al in (('old', io, ao), ('new', inw, an)):
        e = ((im - gt) ** 2).sum(-1) / 3; a = acc[nm]; a['se_int'] += e[me].sum(); a['se_ring'] += e[ring].sum(); a['n_int'] += int(me.sum()); a['n_ring'] += int(ring.sum()); a['ring_alpha'].append(float(al[ring].mean())); a['ring_lum_ratio'].append(float((im[ring].mean() / max(gt[ring].mean(), 1e-6))))
out = {}
for nm, a in acc.items():
    n = a['n_int'] + a['n_ring']; mse = (a['se_int'] + a['se_ring']) / n; out[nm] = dict(full_psnr=float(-10 * np.log10(mse)), interior_psnr=float(-10 * np.log10(a['se_int'] / a['n_int'])), ring_psnr=float(-10 * np.log10(a['se_ring'] / a['n_ring'])), ring_pixel_fraction=a['n_ring'] / n, ring_share_of_total_squared_error=a['se_ring'] / (a['se_int'] + a['se_ring']), mean_alpha_in_ring=float(np.mean(a['ring_alpha'])), mean_render_to_photo_brightness_in_ring=float(np.mean(a['ring_lum_ratio'])))
print(json.dumps(out, indent=1)); json.dump(out, open('out_pj/edge_diag4.json', 'w'), indent=1)
