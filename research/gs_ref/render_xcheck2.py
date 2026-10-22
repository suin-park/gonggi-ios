"""Renderer cross-check, part that can run on this PC: gsplat 1.4.0's rasterisation reference path needs the CUDA extension (rasterize_to_indices_in_range -> _C is None on this CPU-only machine), so it cannot run here. What CAN run on CPU is gsplat's pure-PyTorch PROJECTION (quat/scale -> 3D covariance -> EWA 2D mean / conic / depth / radius). It is compared with this project's projection (gsref._project_all) for the SAME Gaussians (A 30 s map) and the SAME cameras (46, 8, 108): camera convention, intrinsics (pixel-centre +0.5 shift), quaternion order, scale and covariance interpretation, EWA dilation 0.3.
Compositing / opacity / colour handling is NOT cross-checked (no runnable reference): the final raster is only compared with the app's documented rule in gsref.py. usage: python render_xcheck2.py <OUTDIR>"""
import os, sys, json
os.environ['DATA'] = '09'; OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True)
import numpy as np, torch
import gtlib as g, gsref
from gsplat.cuda import _torch_impl as T
P = g.Photos(); PJ = json.load(open('C:/Users/emili/Downloads/best_3d_quality_before_friday/e2e_device09/cache/poses_all.json'))
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
def camr(i): c = dict(P.cam(i)); p = np.array(PJ[str(i)]); c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]; return c
M = {k: v.copy() for k, v in np.load('out_hk/map_A_160_plus_window_30s.npz').items()}; W, H = 640, 480; out = {}
means = torch.tensor(M['mu'], dtype=torch.float32); q = torch.tensor(np.concatenate([M['quat'][:, 3:4], M['quat'][:, :3]], 1), dtype=torch.float32); q = q / q.norm(dim=-1, keepdim=True); sc = torch.tensor(np.exp(M['logs']), dtype=torch.float32)
covars, _ = T._quat_scale_to_covar_preci(q, sc, compute_covar=True, compute_preci=False, triu=False)
for i in (46, 8, 108):
    cam = camr(i); R = torch.tensor(cam['Rcw'], dtype=torch.float32); C = torch.tensor(cam['C'], dtype=torch.float32); vm = torch.eye(4); vm[:3, :3] = R; vm[:3, 3] = -R @ C
    K = torch.tensor([[cam['fx'], 0, cam['cx'] + 0.5], [0, cam['fy'], cam['cy'] + 0.5], [0, 0, 1]], dtype=torch.float32)
    radii, m2, dep, con, _ = T._fully_fused_projection(means, covars, vm[None], K[None], W, H, eps2d=0.3, near_plane=0.05)
    proj = gsref._project_all(M['mu'], M['logs'], M['quat'], M['opa'], cam['Rcw'].astype(np.float32), cam['C'].astype(np.float32), np.float32(cam['fx']), np.float32(cam['fy']), np.float32(cam['cx']), np.float32(cam['cy']), W, H, np.float32(0.05), np.float32(9.0), int(g.DISPLAY['capmode']), np.float32(g.DISPLAY['capval']))
    both = (radii[0].numpy() > 0) & (proj[:, 0] > 0.5); n = int(both.sum()); mt = m2[0].numpy()[both] - 0.5; mo = proj[both, 1:3]; dt = dep[0].numpy()[both]; do = proj[both, 3]; ct = con[0].numpy()[both]; co = proj[both, 4:7]
    # gsplat conic = (a, b, c) of the inverse 2D covariance [[a, b], [b, c]]; ours: out4 = sc/det, out5 = -sb/det, out6 = sa/det  (= inverse covariance [[out4, out5], [out5, out6]])
    rel = np.abs(ct - co) / np.maximum(np.abs(co), 1e-9)
    out[i] = dict(gaussians_projected_in_both=n, only_gsplat=int(((radii[0].numpy() > 0) & ~(proj[:, 0] > 0.5)).sum()), only_ours=int(((~(radii[0].numpy() > 0)) & (proj[:, 0] > 0.5)).sum()), mean2d_abs_diff_px_median=float(np.median(np.abs(mt - mo))), mean2d_abs_diff_px_max=float(np.abs(mt - mo).max()),
                  depth_abs_diff_m_max=float(np.abs(dt - do).max()), conic_rel_diff_median=float(np.median(rel)), conic_rel_diff_p99=float(np.percentile(rel, 99)))
    print(i, json.dumps(out[i]), flush=True)
json.dump(out, open(os.path.join(OUT, 'renderer_xcheck_projection.json'), 'w'), indent=1); print('done')
