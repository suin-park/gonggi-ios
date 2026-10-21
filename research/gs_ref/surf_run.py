"""usage: python surf_run.py P1|P2   -> out_surf/surf_<proto>.json, mesh_<proto>_{C0,C}.ply, held-out panels. See surf_lib.py for the design."""
import os, sys, json, time, hashlib
import numpy as np, cv2
from surf_lib import *
import gsref
PROTO = sys.argv[1]; OUT = os.environ.get('OUTDIR', 'out_surf'); os.makedirs(OUT, exist_ok=True); TAU_ = float(os.environ.get('TAU', TAU))
t0 = time.time(); S = Study(PROTO); P = S.P
print(PROTO, 'train', len(S.train), 'held-out', len(S.heldv), flush=True)
depths_raw = {i: S.depth_pc(i, 320, 240) for i in S.train}
depths_cons, kept = S.consistent_depths(TAU_)
print('consistency filter tau', TAU_, 'kept fraction of product depth px: mean %.3f  min %.3f  max %.3f' % (np.mean(list(kept.values())), min(kept.values()), max(kept.values())), f'{time.time()-t0:.0f}s', flush=True)
depths_al, scales = S.align_scales(depths_raw); print('frame depth scales after alignment: min %.3f max %.3f std %.3f' % (min(scales.values()), max(scales.values()), np.std(list(scales.values()))), flush=True)
depths_alc, kept2 = S.consistent_depths(TAU_, base=depths_al); print('after alignment kept fraction mean %.3f' % np.mean(list(kept2.values())), flush=True)
meshes = {'C0': S.fuse(depths_raw), 'Cf': S.fuse(depths_cons), 'C': S.fuse(depths_alc)}
for k, m in meshes.items(): o3d.io.write_triangle_mesh(os.path.join(OUT, f'mesh_{PROTO}_{k}.ply'), m); print(k, 'mesh verts', len(m.vertices), 'tris', len(m.triangles), flush=True)
z_ = np.load(f'out_ub/map_gsmax_{PROTO}.npz'); MAPD = {k: z_[k] for k in z_.files}; mapd = {}
def map_depth(i, w=EW, h=EH):
    key = (i, w)
    if key not in mapd:
        img, dep, Tf, st = gsref.render(MAPD['mu'], MAPD['logs'], MAPD['quat'], MAPD['col'], MAPD['opa'], P.cam(i), **g.DISPLAY); A = 1 - Tf; zz = np.where(A > 0.5, dep / np.maximum(A, 1e-3), 0).astype(np.float32); zz = np.where(S.md[i], zz, 0).astype(np.float32)
        mapd[(i, EW)] = zz; mapd[(i, 320)] = cv2.resize(zz, (320, 240), interpolation=cv2.INTER_NEAREST)
    return mapd[key]
meshes['Cm'] = S.fuse({i: map_depth(i, 320, 240) for i in S.train}); o3d.io.write_triangle_mesh(os.path.join(OUT, f'mesh_{PROTO}_Cm.ply'), meshes['Cm']); print('Cm mesh verts', len(meshes['Cm'].vertices), flush=True)
scenes = {k: S.mesh_scene(m) for k, m in meshes.items()}
# ---- depth providers for the SAME renderer: only geometry differs
cache = {}
def zfun(kind):
    def f(i):
        key = (kind, i)
        if key not in cache: cache[key] = S.depth_pc(i) if kind == 'B' else map_depth(i) if kind == 'Bm' else S.mesh_depth(scenes[kind], P.cam(i), S.md[i])
        return cache[key]
    return f
# ---- region: 3D centre of the dark eye/nose blobs (from train photos, back-projected with the C mesh depth), radius fixed a priori
cen = []
for i in S.train:
    e = g.find_eyes(P.gt[i], P.mask[i])
    if e is None: continue
    ys, xs = np.nonzero(e['blob']); z = S.mesh_depth(scenes['C'], P.cam(i), S.md[i])[int(ys.mean()), int(xs.mean())]
    if z <= 0: continue
    c = P.cam(i); cen.append(np.array([(xs.mean() - c['cx']) / c['fx'] * z, (ys.mean() - c['cy']) / c['fy'] * z, z]) @ c['Rcw'] + c['C'])
cen = np.array(cen); RC = np.median(cen, 0); print('eye/nose centre from', len(cen), 'train frames; spread (cm) %.1f' % (100 * np.linalg.norm(cen - RC, axis=1).mean()), RC.round(3), flush=True)
def region_mask(i):
    c = P.cam(i); pt = (RC - c['C']) @ c['Rcw'].T
    if pt[2] < 0.1: return np.zeros((EH, EW), bool)
    u = c['fx'] * pt[0] / pt[2] + c['cx']; v = c['fy'] * pt[1] / pt[2] + c['cy']; rpx = c['fx'] * REGION_R / pt[2]
    return P.mask[i] & (((xx - u) ** 2 + (yy - v) ** 2) < rpx ** 2)
# ---- observation evidence for the region (train frames that see region pixels, azimuth span of those cameras)
obs = []
for i in S.train:
    rm = region_mask(i)
    if rm.sum() > 300: v = RC - P.cam(i)['C']; obs.append((i, float(np.degrees(np.arctan2(-v[0], -v[2]))), int(rm.sum())))
az = np.array([a for _, a, _ in obs]); evidence = dict(train_frames_seeing_region=len(obs), frame_range=[int(min(o[0] for o in obs)), int(max(o[0] for o in obs))], azimuth_span_deg=float(az.max() - az.min()) if len(az) else 0, centre=RC.tolist(), radius_m=REGION_R, mean_region_px=float(np.mean([o[2] for o in obs])))
print('region evidence', evidence, flush=True)
# ---- A: 3DGS map
z = np.load(f'out_ub/map_gsmax_{PROTO}.npz'); MA = {k: z[k] for k in z.files}
def psnr(img, gt, m): return float(-10 * np.log10(max(((img - gt) ** 2)[m].mean(), 1e-12))) if m.sum() > 30 else float('nan')
def edge_mask(i):
    gray = cv2.cvtColor((P.gt[i] * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY); return (np.hypot(cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3), cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)) / 255 > 0.25) & dil(P.mask[i], 5)
rows = []
for v in S.heldv:
    ct = P.cam(v); gt = P.gt[v]; m = P.mask[v]; rm = region_mask(v); em = edge_mask(v); eye = g.find_eyes(gt, m); row = dict(frame=v, region_px=int(rm.sum()))
    imgA, alA, _ = g.render(MA, ct); imgs = {'A': imgA}
    for kind in ('B', 'Bm', 'C0', 'Cf', 'C', 'Cm'):
        img, fill, ang, parts, owner = ibr(S, ct, zfun(kind), return_parts=True); imgs[kind] = img
        sd, fr, npx = disagreement(parts, m); mt = g.metrics(img, fill.astype(np.float32), gt, m, eye)
        row[kind] = dict(psnr=psnr(img, gt, m), psnr_region=psnr(img, gt, rm & m), psnr_edge=psnr(img, gt, em), hole_frac=float(1 - fill[m].mean()), psnr_filled=psnr(img, gt, m & fill), disagree_sd=sd, disagree_frac=fr, recovery=mt.get('recovery', float('nan')), nearest_deg=ang)
    mtA = g.metrics(imgA, alA, gt, m, eye); row['A'] = dict(psnr=psnr(imgA, gt, m), psnr_region=psnr(imgA, gt, rm & m), psnr_edge=psnr(imgA, gt, em), recovery=mtA.get('recovery', float('nan')))
    rows.append(row); print(v, ' '.join(f"{k}:{row[k]['psnr']:.1f}/{row[k]['psnr_region']:.1f}" for k in ('A', 'B', 'Bm', 'C0', 'Cf', 'C', 'Cm')), ' dis B %.3f C %.3f' % (row['B']['disagree_sd'], row['C']['disagree_sd']), ' holes B %.3f C %.3f' % (row['B']['hole_frac'], row['C']['hole_frac']), flush=True)
    sh, _ = S.mesh_shade(scenes['Cm'], ct)
    tiles = [gt, imgs['A'], imgs['B'], imgs['C0'], imgs['Cf'], imgs['C'], imgs['Bm'], imgs['Cm'], sh]
    if v in S.heldv[::max(1, len(S.heldv) // 6)]: g.imwrite(os.path.join(OUT, f'{PROTO}_panel_{v}.png'), np.concatenate(tiles, 1))
def agg(k, f):
    a = [r[k][f] for r in rows if not np.isnan(r[k][f])]; return float(np.mean(a)) if a else float('nan')
summary = {k: {f: agg(k, f) for f in rows[0][k]} for k in ('A', 'B', 'Bm', 'C0', 'Cf', 'C', 'Cm')}
json.dump(dict(proto=PROTO, tau=TAU_, min_cons=MIN_CONS, neigh=NEIGH, voxel=VOXEL, trunc=TRUNC, region=evidence, kept_fraction={str(k): v for k, v in kept.items()}, depth_scales={str(k): v for k, v in scales.items()}, mesh={k: dict(verts=len(m.vertices), tris=len(m.triangles)) for k, m in meshes.items()}, frames=rows, summary=summary, seconds=time.time() - t0), open(os.path.join(OUT, f'surf_{PROTO}.json'), 'w'), indent=1)
print(json.dumps(summary, indent=1)); print('seconds', int(time.time() - t0))
