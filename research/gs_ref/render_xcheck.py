"""Renderer cross-check: gsplat 1.4.0 (Nerfstudio) pure-PyTorch reference path (CPU) vs this project's numba renderer (gsref) on the SAME map (A 30 s) and the SAME cameras (46, 8, 108), 640x480.
Aligned: world->camera viewmat [Rcw | -Rcw C] (OpenCV axes: x right, y down, z forward = ours); pixel-centre convention (ours: centres at integers -> gsplat K cx+0.5, cy+0.5); quaternion xyzw -> wxyz; scales = exp(log_scale); opacity = a0 = 0.99*sigmoid(logit) (the app's OPA_MAX); colours raw RGB, linear, no SH; black background; EWA dilation eps2d 0.3 (ours DIL 0.3); near 0.05; no antialias, no sharpening, no exposure.
Known remaining differences: gsplat tile-radius / cutoff rule vs ours (Mahalanobis^2 <= 9), alpha clamp 0.999 vs 0.99*sigmoid, termination details. Numbers: mean abs / max abs difference and PSNR(gsref vs gsplat).  usage: python render_xcheck.py <OUTDIR>"""
import os, sys, json, time
os.environ['DATA'] = '09'; OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True)
import numpy as np, cv2, torch
import gtlib as g, gsref
from gsplat.cuda import _torch_impl as T
P = g.Photos(); PJ = json.load(open('C:/Users/emili/Downloads/best_3d_quality_before_friday/e2e_device09/cache/poses_all.json'))
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
def camr(i): c = dict(P.cam(i)); p = np.array(PJ[str(i)]); c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]; return c
M = {k: v.copy() for k, v in np.load('out_hk/map_A_160_plus_window_30s.npz').items()}
def gsplat_render(M, cam):
    W, H = 640, 480; means = torch.tensor(M['mu'], dtype=torch.float32); q = torch.tensor(np.concatenate([M['quat'][:, 3:4], M['quat'][:, :3]], 1), dtype=torch.float32); q = q / q.norm(dim=-1, keepdim=True); sc = torch.tensor(np.exp(M['logs']), dtype=torch.float32)
    op = torch.tensor(0.99 / (1 + np.exp(-M['opa'])), dtype=torch.float32); col = torch.tensor(M['col'], dtype=torch.float32)
    R = torch.tensor(cam['Rcw'], dtype=torch.float32); C = torch.tensor(cam['C'], dtype=torch.float32); vm = torch.eye(4); vm[:3, :3] = R; vm[:3, 3] = -R @ C; K = torch.tensor([[cam['fx'], 0, cam['cx'] + 0.5], [0, cam['fy'], cam['cy'] + 0.5], [0, 0, 1]], dtype=torch.float32)
    covars, _ = T._quat_scale_to_covar_preci(q, sc, compute_covar=True, compute_preci=False, triu=False)
    radii, means2d, depths, conics, _ = T._fully_fused_projection(means, covars, vm[None], K[None], W, H, eps2d=0.3, near_plane=0.05)
    tile = 16; tw = (W + tile - 1) // tile; th = (H + tile - 1) // tile
    tpg, ids, flat = T._isect_tiles(means2d, radii, depths, tile, tw, th, sort=True); offs = T._isect_offset_encode(ids, 1, tw, th)
    img, alpha = T._rasterize_to_pixels(means2d, conics, col[None].expand(1, -1, -1), op[None], W, H, tile, offs, flat, backgrounds=torch.zeros(1, 3), batch_per_iter=100)
    return img[0].numpy(), alpha[0, ..., 0].numpy()
rows = []; stats = {}
for i in (46, 8, 108):
    cam = camr(i); t0 = time.time(); a = g.render(M, cam); ours = a[0]; al_o = a[1]; t1 = time.time(); theirs, al_t = gsplat_render(M, cam); t2 = time.time()
    d = np.abs(ours - theirs); stats[i] = dict(mean_abs=float(d.mean()), max_abs=float(d.max()), psnr_between=float(-10 * np.log10(max(((ours - theirs) ** 2).mean(), 1e-12))), alpha_mean_abs=float(np.abs(al_o - al_t).mean()), seconds_ours=t1 - t0, seconds_gsplat_cpu_reference=t2 - t1)
    print(i, json.dumps(stats[i]), flush=True)
    crop = lambda x: cv2.resize((np.clip(x[100:340, 120:520], 0, 1) * 255).astype(np.uint8), (400, 240), interpolation=cv2.INTER_NEAREST); rows.append(np.concatenate([crop(P.gt[i]), crop(ours), crop(theirs), crop(np.repeat(np.clip(d * 8, 0, 1).mean(-1, keepdims=True), 3, 2))], 1))
cv2.imencode('.png', cv2.cvtColor(np.concatenate(rows, 0), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, 'renderer_xcheck_photo_ours_gsplat_diffx8.png')); json.dump(stats, open(os.path.join(OUT, 'renderer_xcheck.json'), 'w'), indent=1); print('done')
