"""Videos 01/02 for the surface-photo study (PC OFFLINE render of the research code; NOT the app, NOT real time; contains user photos -> local only).
Virtual camera path on the observed front of the chair: travel along the recorded path (in-between poses, incl. held-out gaps), vertical bob, dolly toward the eye/nose centre and back, return. Sources = P1 training photos only.
Panels (each 640x480, no zoom, same exposure/colour for all): A 3DGS | B IBR PC per-frame depth | C IBR on shared mesh (Cm: TSDF of 3DGS-map depths) | reference photo (other viewpoint) | Bm control (per-frame map depth, same input as C) | C untextured shading.
Magenta = surface that the shared mesh says is observed but the method did not reconstruct (failure), black = no mesh there / background."""
import os, sys, json
import numpy as np, cv2
sys.argv = ['surf_run.py', 'P1']
from surf_lib import *
import gsref
OUT = os.environ.get('OUTDIR', 'out_surf'); PROTO = 'P1'; S = Study(PROTO); P = S.P
mesh = o3d.io.read_triangle_mesh(os.path.join(OUT, f'mesh_{PROTO}_Cm.ply')); sc = S.mesh_scene(mesh)
z_ = np.load(f'out_ub/map_gsmax_{PROTO}.npz'); MAPD = {k: z_[k] for k in z_.files}
cB, cBm, cC = {}, {}, {}
def zB(i):
    if i not in cB: cB[i] = S.depth_pc(i)
    return cB[i]
def zBm(i):
    if i not in cBm:
        img, dep, Tf, st = gsref.render(MAPD['mu'], MAPD['logs'], MAPD['quat'], MAPD['col'], MAPD['opa'], P.cam(i), **g.DISPLAY); A = 1 - Tf; cBm[i] = np.where((A > 0.5) & S.md[i], dep / np.maximum(A, 1e-3), 0).astype(np.float32)
    return cBm[i]
def zC(i):
    if i not in cC: cC[i] = S.mesh_depth(sc, P.cam(i), S.md[i])
    return cC[i]
# ---- path
ev = [i for i in range(P.n) if P.mask[i].sum() > 50 and g.find_eyes(P.gt[i], P.mask[i]) is not None]
runs, cur = [], [ev[0]]
for i in ev[1:]:
    if i - cur[-1] <= 2: cur.append(i)
    else: runs.append(cur); cur = [i]
runs.append(cur); run = max(runs, key=len); f0, f1 = run[0], run[-1]; print('eye-visible run', f0, f1, len(run), flush=True)
cs_ = np.array([P.cam(i)['C'] for i in ev]); d = np.array([P.cam(i)['Rcw'] for i in ev])
cen = []
for i in run[::3]:
    e = g.find_eyes(P.gt[i], P.mask[i]); ys, xs = np.nonzero(e['blob']); zz = S.mesh_depth(sc, P.cam(i), S.md[i])[int(ys.mean()), int(xs.mean())]
    if zz > 0: c = P.cam(i); cen.append(np.array([(xs.mean() - c['cx']) / c['fx'] * zz, (ys.mean() - c['cy']) / c['fy'] * zz, zz]) @ c['Rcw'] + c['C'])
RC = np.median(np.array(cen), 0)
def interp(fi):
    a = int(np.floor(fi)); t = fi - a; a = min(max(a, 0), P.n - 2); A, B_ = P.cam(a), P.cam(a + 1); R = (1 - t) * A['Rcw'] + t * B_['Rcw']; U, _, Vt = np.linalg.svd(R); R = U @ Vt
    if np.linalg.det(R) < 0: R = U @ np.diag([1, 1, -1]) @ Vt
    c = dict(A); c['C'] = (1 - t) * A['C'] + t * B_['C']; c['Rcw'] = R; return c
NF = 300; cams = []; tags = []
for k in range(NF):
    u = k / (NF - 1); prog = 0.5 - 0.5 * np.cos(2 * np.pi * u) if False else (u * 3 if u < 1 / 3 else (1.0 if u < 2 / 3 else 1 - (u - 2 / 3) * 3))      # travel f0->f1 | hold & approach | travel back
    fi = f0 + 0.5 + (f1 - f0 - 1) * prog; c = interp(fi); up = -c['Rcw'][1]; fw = c['Rcw'][2]
    bob = 0.04 * np.sin(2 * np.pi * 3 * u); dolly = 0.0
    if 1 / 3 <= u < 2 / 3: dolly = 0.15 * np.sin(np.pi * (u - 1 / 3) * 3)                  # up to 15% of the distance to the eye/nose centre
    dist = np.linalg.norm(RC - c['C']); c['C'] = c['C'] + up * bob + fw * dolly * dist; cams.append(c)
    tags.append('travel' if u < 1 / 3 else ('approach+bob' if u < 2 / 3 else 'travel back'))
def put(img, txt, y=18, col=(255, 255, 0)):
    im = (np.clip(img, 0, 1) * 255).astype(np.uint8).copy(); cv2.putText(im, txt, (6, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, col, 1, cv2.LINE_AA); return im
def mag(img, fill, hit): o = img.copy(); o[hit & ~fill] = (1, 0, 1); return o
ownc = np.array([[(37 * k) % 256, (91 * k + 60) % 256, (151 * k + 120) % 256] for k in range(200)], np.uint8)
wA = cv2.VideoWriter(os.path.join(OUT, '01_compare_observed_surface.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (1920, 960)); wB = cv2.VideoWriter(os.path.join(OUT, '02_geometry_and_texture.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 12, (1920, 480))
rows = []; prev_primary = None; flash = 0
for k, ct in enumerate(cams):
    sh, hit = S.mesh_shade(sc, ct); hit &= True
    imB, fB, aB, pB, oB = ibr(S, ct, zB, return_parts=True); imBm, fBm, aBm, pBm, oBm = ibr(S, ct, zBm, return_parts=True); imC, fC, aC, pC, oC = ibr(S, ct, zC, return_parts=True)
    imA, alA, _ = g.render(dict(mu=MAPD['mu'], logs=MAPD['logs'], quat=MAPD['quat'], col=MAPD['col'], opa=MAPD['opa']), ct)
    near = min(S.train, key=lambda s: np.linalg.norm(P.cam(s)['C'] - ct['C']) + 0.004 * np.degrees(np.arccos(np.clip(P.cam(s)['Rcw'][2] @ ct['Rcw'][2], -1, 1))))
    ref = P.gt[near]
    dB = disagreement(pB, hit)[0]; dBm = disagreement(pBm, hit)[0]; dC = disagreement(pC, hit)[0]
    rows.append(dict(k=k, phase=tags[k], hole_frac={'A': float((hit & (alA < 0.5)).sum() / max(hit.sum(), 1)), 'B': float((hit & ~fB).sum() / max(hit.sum(), 1)), 'Bm': float((hit & ~fBm).sum() / max(hit.sum(), 1)), 'C': float((hit & ~fC).sum() / max(hit.sum(), 1))}, disagree_sd={'B': dB, 'Bm': dBm, 'C': dC}, nearest_deg=aC))
    sty = [put(mag(imA, alA > 0.5, hit), f'A 3DGS map (PC offline)'), put(mag(imB, fB, hit), f'B IBR per-frame PC depth  nearest {aB:.0f}deg'), put(mag(imC, fC, hit), 'C IBR on shared mesh (same renderer)'),
           put(ref, f'reference photo (other viewpoint, frame {near})'), put(mag(imBm, fBm, hit), 'Bm control: per-frame map depth'), put(sh, 'C geometry only (no photo)')]
    for i_, t_ in enumerate(sty): cv2.putText(t_, 'PC offline render | virtual camera: no GT | magenta=observed surface not reconstructed', (6, 470), cv2.FONT_HERSHEY_SIMPLEX, 0.38, (200, 200, 200), 1, cv2.LINE_AA)
    sty[5] = sty[5]; frame = np.concatenate([np.concatenate(sty[:3], 1), np.concatenate(sty[3:], 1)], 0); wA.write(cv2.cvtColor(frame, cv2.COLOR_RGB2BGR))
    # video 02: shape vs photo, source-switch marker
    prim = int(np.bincount(oC[oC >= 0].ravel()).argmax()) if (oC >= 0).any() else -1
    if prev_primary is not None and prim != prev_primary: flash = 4
    prev_primary = prim; own = np.zeros((EH, EW, 3), np.uint8); own[oC >= 0] = ownc[oC[oC >= 0] % 200]
    p2 = [put(sh, f'C geometry only  [{tags[k]}]'), put(mag(imC, fC, hit), f'C photo projection  primary source {prim}'), put(own.astype(np.float32) / 255, 'which photo supplies each pixel')]
    if flash > 0:
        for t_ in p2: cv2.rectangle(t_, (0, 0), (639, 479), (255, 0, 0), 8)
        cv2.putText(p2[1], 'SOURCE SWITCH', (200, 60), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (255, 60, 60), 2, cv2.LINE_AA); flash -= 1
    for t_ in p2: cv2.putText(t_, 'PC offline render | virtual camera: no GT', (6, 470), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (200, 200, 200), 1, cv2.LINE_AA)
    wB.write(cv2.cvtColor(np.concatenate(p2, 1), cv2.COLOR_RGB2BGR))
    if k % 50 == 0:
        g.imwrite(os.path.join(OUT, f'video01_f{k:03d}.png'), frame / 255.0); print(k, flush=True)
wA.release(); wB.release(); json.dump(rows, open(os.path.join(OUT, 'video_path_metrics.json'), 'w'), indent=1)
for ph in ('travel', 'approach+bob', 'travel back'):
    r = [x for x in rows if x['phase'] == ph]
    print(ph, 'holes', {m: round(float(np.mean([x['hole_frac'][m] for x in r])), 4) for m in ('A', 'B', 'Bm', 'C')}, 'disagree', {m: round(float(np.nanmean([x['disagree_sd'][m] for x in r])), 4) for m in ('B', 'Bm', 'C')})
