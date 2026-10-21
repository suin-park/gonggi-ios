"""End-to-end processing of the PHONE-SAVED data of test_09 (PC research; no map regeneration, no batch training).
Inputs (both exported by the app): product-gs-*.kmogs (device-saved Gaussian map, 6,890 Gaussians) + *.kmoreplay (960x720 JPEG keyframes, ARKit pose, K, 320x240 product masks).
Chain: read saved data -> depth prepared (rendered from the saved map at each source pose; NOT stored on the phone today) -> 1 round of 6-DoF photometric pose refinement (320x240, against the FIXED saved map) -> current best edge processing (per-photo smooth mask +3 px tolerance gate, 3x internal resolution, output silhouette clean-up) -> first Bm frame.
MODE=all : refine all frames, then first frame (the 'full' chain)    MODE=lazy : refine only the 8 frames nearest (ARKit) to the first camera, depth/matte for the 6 nearest after refinement (the frames the first screen needs; the rest would be refined in the background)
CACHE=fresh : caches deleted, everything computed    CACHE=warm : pose/depth/matte results loaded from the caches written by a previous fresh run (photo decode and map parse always run)
Timed: every stage wall-clock (time.perf_counter). NOT timed (written separately): score computation, comparison-video encoding, the demo camera anchor.
usage: MODE=all|lazy CACHE=fresh|warm python e2e_device.py <OUTDIR>"""
import os, sys, json, time, shutil
T = {}; t_proc = time.perf_counter()
def tick(name, t0): T[name] = time.perf_counter() - t0
RES = int(os.environ.get('RES', 320)); RW, RH = RES, RES * 3 // 4; RSUF = '' if RES == 320 else f'_r{RES}'; MODE = os.environ.get('MODE', 'all'); CACHE = os.environ.get('CACHE', 'fresh'); OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True); CDIR = os.path.join(OUT, 'cache'); sys.argv = ['x', 'A', OUT]
t0 = time.perf_counter(); import numpy as np, cv2; from scipy import ndimage; tick('00_imports_numpy_cv2_scipy', t0)
t0 = time.perf_counter(); import gsref; tick('01_import_renderer(numba cache load)', t0)
t0 = time.perf_counter(); import bmcore; tick('02_read_replay_decode_960x720_jpeg_masks_resize', t0)            # bmcore.P = gtlib.Photos(): tex_data.load (JPEG decode + masks) + 640x480 resize for every frame
P = bmcore.P; g = bmcore.g; EW, EH = bmcore.EW, bmcore.EH
t0 = time.perf_counter(); Mdev = g.load_map(); tick('03_read_device_map_kmogs', t0)
t0 = time.perf_counter(); import bm_edge; from bm_edge import matte; tick('04_import_edge_modules', t0)
views = [i for i in range(P.n) if P.mask[i].sum() > 50]; md = {i: cv2.dilate(P.mask[i].astype(np.uint8), np.ones((15, 15), np.uint8)) > 0 for i in views}
os.makedirs(CDIR, exist_ok=True)
if CACHE == 'fresh':       # delete the shared depth/mask caches and THIS run's pose cache only (other runs' pose caches are kept)
    for f_ in os.listdir(CDIR):
        if not f_.startswith('poses_') or f_ == f'poses_{MODE}{RSUF}.json': os.remove(os.path.join(CDIR, f_))
def ck(name): return os.path.join(CDIR, name)
def rotvec(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    k = r / th; K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]]); return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K
cam0 = P.cam; POSE = {}
def set_cam():
    def cam(i, w=EW, h=EH):
        c = dict(cam0(i, w, h))
        if i in POSE: p = POSE[i]; c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]
        return c
    P.cam = cam
set_cam()
t_demo0 = time.perf_counter()
# ---------------- demo camera (first screen): path of the earlier videos, defined in the WORLD frame from the ARKit poses (the map is not modified, so before/after share it)
anchor_img, dep, Tf, st = gsref.render(Mdev['mu'], Mdev['logs'], Mdev['quat'], Mdev['col'], Mdev['opa'], cam0(46), **g.DISPLAY); al = 1 - Tf; zz = np.where(al > 0.5, dep / np.maximum(al, 1e-3), 0); c46 = cam0(46)
u, v = 275, 285; best = None
for r in range(0, 40):
    ys, xs = np.mgrid[v - r:v + r + 1, u - r:u + r + 1]; ok = [(abs(y - v) + abs(x - u), y, x) for y, x in zip(ys.ravel(), xs.ravel()) if 0 <= y < 480 and 0 <= x < 640 and zz[y, x] > 0]
    if ok: best = min(ok); break
_, y, x = best; d = zz[y, x]; FACE = np.array([(x - c46['cx']) / c46['fx'] * d, (y - c46['cy']) / c46['fy'] * d, d]) @ c46['Rcw'] + c46['C']
def first_cam(ZOOM=1.6, F0=37):
    fi = F0 + 0.5; a = int(np.floor(fi)); t = fi - a; A_, B_ = cam0(a), cam0(a + 1); R = (1 - t) * A_['Rcw'] + t * B_['Rcw']; U, _, Vt = np.linalg.svd(R); R = U @ Vt
    if np.linalg.det(R) < 0: R = U @ np.diag([1, 1, -1]) @ Vt
    c = dict(A_); C = (1 - t) * A_['C'] + t * B_['C']; z = FACE - C; z /= np.linalg.norm(z); y0 = R[1]; y = y0 - (y0 @ z) * z; y /= np.linalg.norm(y); x = np.cross(y, z); c['C'] = C; c['Rcw'] = np.stack([x, y, z]); c['fx'] *= ZOOM; c['fy'] *= ZOOM; return c
ct = first_cam(); T['demo_camera_anchor_NOT_counted'] = time.perf_counter() - t_demo0
# ---------------- pose refinement (1 round, vs the fixed device map)
def small(i): return cv2.resize(P.gt[i], (RW, RH), interpolation=cv2.INTER_AREA), cv2.resize(P.mask[i].astype(np.uint8), (RW, RH), interpolation=cv2.INTER_NEAREST) > 0
def residual(i, p, gts, ms):
    c = dict(cam0(i, RW, RH)); c['Rcw'] = rotvec(p[:3]) @ c['Rcw']; c['C'] = c['C'] + p[3:]; img, dep, Tf, st = gsref.render(Mdev['mu'], Mdev['logs'], Mdev['quat'], Mdev['col'], Mdev['opa'], c, **g.DISPLAY); return ((img - gts) * ms[..., None]).ravel()
def refine_pose(i, iters=8):
    gts, ms = small(i); p = np.zeros(6); lam = 1e-2; r = residual(i, p, gts, ms); f = float(r @ r); steps = np.array([0.002] * 6)
    for _ in range(iters):
        J = np.stack([(residual(i, p + np.eye(6)[k] * steps[k], gts, ms) - r) / steps[k] for k in range(6)], 1); A = J.T @ J; b = J.T @ r; moved = False
        for _ in range(4):
            dd = -np.linalg.solve(A + lam * np.diag(np.diag(A) + 1e-9), b); r2 = residual(i, p + dd, gts, ms); f2 = float(r2 @ r2)
            if f2 < f: p = p + dd; r = r2; f = f2; lam = max(lam / 3, 1e-6); moved = True; break
            lam *= 4
        if not moved: break
    return p
def ranked_arkit(ctx, ids):
    out = []
    for s in ids: cs = cam0(s); dd = float(np.linalg.norm(cs['C'] - ctx['C'])); a = float(np.degrees(np.arccos(np.clip(cs['Rcw'][2] @ ctx['Rcw'][2], -1, 1)))); out.append((dd + 0.004 * a, s))
    out.sort(); return [s for _, s in out]
need = views if MODE == 'all' else ranked_arkit(ct, views)[:8]
pf = ck(f'poses_{MODE}{RSUF}.json')
t0 = time.perf_counter()
if CACHE == 'warm' and os.path.exists(pf): POSE.update({int(k): np.array(v) for k, v in json.load(open(pf)).items()})
else:
    for i in need: POSE[i] = refine_pose(i)
    json.dump({str(k): v.tolist() for k, v in POSE.items()}, open(pf, 'w'))
tick(f'10_pose_refinement_1round_{len(need)}_frames', t0); T['10_frames_refined'] = len(need)
# ---------------- BEFORE: ARKit poses (no refinement) vs AFTER, same world-frame camera
set_cam(); POSE_AFTER = dict(POSE)
# ---------------- depth for the sources + per-photo masks (current best edge processing)
def zraw(i):
    img, dep, Tf, st = gsref.render(Mdev['mu'], Mdev['logs'], Mdev['quat'], Mdev['col'], Mdev['opa'], P.cam(i), **g.DISPLAY); al = 1 - Tf; return np.where((al > 0.5) & md[i], dep / np.maximum(al, 1e-3), 0).astype(np.float32)
lay_tol = 3
def layer(i):
    a = matte(i); big = cv2.resize(a, (EW * 3, EH * 3), interpolation=cv2.INTER_CUBIC); big = cv2.GaussianBlur(big, (0, 0), 4.0); m = ndimage.binary_fill_holes((big > 0.5).astype(np.uint8)).astype(np.uint8)
    m = cv2.resize(m.astype(np.float32), (EW, EH), interpolation=cv2.INTER_AREA) > 0.5; return cv2.dilate(m.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * lay_tol + 1, 2 * lay_tol + 1))) > 0
Z = {}; LAY = {}; tz = {'depth': 0.0, 'mask': 0.0}
def get_src(i, tag):
    key = (i, tag)
    if key not in Z:
        fz, fl = ck(f'z_{tag}_{i}.npy'), ck(f'lay_{i}.npy')
        t1 = time.perf_counter(); Z[key] = np.load(fz) if (CACHE == 'warm' and os.path.exists(fz)) else zraw(i)
        if not (CACHE == 'warm' and os.path.exists(fz)): np.save(fz, Z[key])
        tz['depth'] += time.perf_counter() - t1; t1 = time.perf_counter()
        if i not in LAY: LAY[i] = np.load(fl) if (CACHE == 'warm' and os.path.exists(fl)) else layer(i)
        if not (CACHE == 'warm' and os.path.exists(fl)): np.save(fl, LAY[i])
        tz['mask'] += time.perf_counter() - t1
    return np.where(LAY[i], Z[key], 0).astype(np.float32)
from bmcore import blend
def smooth_sil(pm, alp, sigma=1.5, lo=0.2, hi=0.6):
    col = pm / np.maximum(alp, 1e-3)[..., None]; have = alp > 0.02; d, (iy, ix) = ndimage.distance_transform_edt(~have, return_indices=True); col = np.where(have[..., None], col, col[iy, ix]); b = cv2.GaussianBlur(alp, (0, 0), sigma); t = np.clip((b - lo) / (hi - lo), 0, 1); a2 = (t * t * (3 - 2 * t)).astype(np.float32); return (col * a2[..., None]).astype(np.float32), a2
def set_ss(n): bmcore.SS = n; bmcore.HW = EW * n; bmcore.HH = EH * n
def first_frame(tag):
    POSE.clear()
    if tag == 'after': POSE.update(POSE_AFTER)
    set_ss(3); t1 = time.perf_counter(); im, alp = blend(ct, views if MODE == 'all' else need, lambda i: get_src(i, tag)); t_blend = time.perf_counter() - t1; pm, a2 = smooth_sil(im, alp); return pm, a2, t_blend
tz['depth'] = tz['mask'] = 0.0; t_all = time.perf_counter(); pm_a, a_a, tb_a = first_frame('after'); t_total_after = time.perf_counter() - t_all
T['20_after_depth_render_for_sources'] = tz['depth']; T['21_after_matte_layer_masks'] = tz['mask']; T['22_after_Bm_blend_SS3_incl_gpu_free_cpu_splat'] = tb_a - tz['depth'] - tz['mask']; T['23_silhouette_cleanup'] = t_total_after - tb_a
T['TOTAL_user_chain_wall_clock_s'] = sum(v for k, v in T.items() if k[:2].isdigit() and k != '10_frames_refined'); T['process_wall_clock_incl_demo_anchor_s'] = time.perf_counter() - t_proc
# ---------------- NOT timed as user processing: before-image (for the comparison), saving
tz['depth'] = tz['mask'] = 0.0; pm_b, a_b, tb_b = first_frame('before')
bg = np.zeros((EH, EW, 3), np.float32)
for nm, pm, a in (('after', pm_a, a_a), ('before', pm_b, a_b)): cv2.imencode('.png', cv2.cvtColor((np.clip(pm, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, f'first_frame_{MODE}_{CACHE}{RSUF}_{nm}.png'))
T['mode'] = MODE; T['cache'] = CACHE; T['note'] = 'PC (numpy/numba CPU, 8 threads); A15 time NOT predicted'; json.dump(T, open(os.path.join(OUT, f'timing_{MODE}_{CACHE}{RSUF}.json'), 'w'), indent=1); print(json.dumps(T, indent=1))
