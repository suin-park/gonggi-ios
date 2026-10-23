"""test_10 mask-reliability hull (PC research). Driver on top of a5_lib (= a3_hull library part).
H0  = tolerant hull (OUTFRAC 0.2, all source views)  -> previous V2
per-view score vs H0 projection: miss = part of the H0 silhouette the view's mask does not cover (mask lost a part), extra = part of the mask outside H0
H1  = strict hull (OUTFRAC=STRICT) carved only from views with miss <= MISS_T  -> V4 (silhouette+depth like V2)
Evaluation: same 12 leave-out frames (hull re-carved w/o |i-t|<=10) + flag whether the target's own GT mask is reliable; orbit wobble/flicker (V0, V2, V4, V4+EMA).
usage: CDIR=<a3 cache> python a5_rel.py <OUT>"""
import os, sys, json, time
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'a5_lib.py'), encoding='utf-8').read())
STRICT = float(os.environ.get('STRICT', 0.03)); MISS_T = float(os.environ.get('MISS_T', 0.10))
OUT2 = OUT


def score_views(surf, use):
    sc = {}
    for i in use:
        a = hull_alpha(surf, cam(i)) > 0.5; m = MASKD[i]; md_ = cv2.dilate(P.mask[i].astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
        ad = cv2.dilate(a.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
        sc[i] = (float((a & ~md_).sum() / max(1, a.sum())), float((m & ~ad).sum() / max(1, m.sum())))
    return sc


def hull_rel(use, tag):
    f = os.path.join(CD, f'hull_rel_{tag}_{STRICT}_{MISS_T}.npy'); fs = os.path.join(CD, f'hull_rel_{tag}_{STRICT}_{MISS_T}.json')
    if os.path.exists(f):
        return np.load(f), json.load(open(fs))
    h0f = os.path.join(CD, f'hull_surf_{tag}.npy')
    if os.path.exists(h0f):
        s0 = np.load(h0f)
    else:
        _, s0 = carve(use, 0.2); np.save(h0f, s0)
    sc = score_views(s0, use); good = [i for i in use if sc[i][0] <= MISS_T]
    _, s1 = carve(good, STRICT); np.save(f, s1)
    info = dict(n_use=len(use), n_good=len(good), dropped=[i for i in use if i not in good], miss_p50=float(np.median([v[0] for v in sc.values()])), miss_p90=float(np.percentile([v[0] for v in sc.values()], 90)), extra_p50=float(np.median([v[1] for v in sc.values()])))
    json.dump(info, open(fs, 'w')); return s1, info


res = {'note': 'PC research on test_10; A15 not measured', 'STRICT': STRICT, 'MISS_T': MISS_T, 'TOL_m': TOL, 'VOX_m': VOX}
t0 = time.time()
s0_all = np.load(os.path.join(CD, 'hull_surf_all.npy')) if os.path.exists(os.path.join(CD, 'hull_surf_all.npy')) else carve(views, 0.2)[1]
s1_all, info_all = hull_rel(views, 'all'); print('rel hull all', info_all, 'pts', len(s1_all), round(time.time() - t0, 1), flush=True)
res['hull_all'] = info_all
sc_all = score_views(s0_all, views)
az = {i: float(np.degrees(np.arctan2(*(cam0(i)['C'] - ctr)[[0, 2]]))) for i in views}
tests = [min(views, key=lambda i: abs(((az[i] - a + 180) % 360) - 180)) for a in range(-180, 180, 30)]
LO = []
for t in tests:
    srcs = [i for i in views if abs(i - t) > 10]; tag = f'lo{t}'
    s0 = np.load(os.path.join(CD, f'hull_surf_{tag}.npy')) if os.path.exists(os.path.join(CD, f'hull_surf_{tag}.npy')) else carve(srcs, 0.2)[1]
    s1, info = hull_rel(srcs, tag)
    ct = cam(t); gt = P.gt[t]; ga = matte(t); gm = ga > 0.5; band = cv2.dilate(gm.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
    row = dict(frame=t, az=round(az[t]), gt_mask_miss=round(sc_all[t][0], 3), gt_reliable=bool(sc_all[t][0] <= MISS_T), dropped=len(info['dropped']))
    tiles = [lab(gt * ga[..., None], 'photo')]
    for V, surf, vt in (('V0', s0, 'V0'), ('V2', s0, 'V2'), ('V4', s1, 'V2')):
        zf = zsrc_fn(vt, surf, tag if V != 'V4' else f'rel{STRICT}_{MISS_T}_{tag}'); im, a2 = frame(vt, ct, weights_for(ct, srcs), zf, surf)
        e = ((im - gt * ga[..., None]) ** 2)[band].mean(); sil = a2 > 0.5
        row[V] = dict(psnr=round(float(10 * np.log10(1 / max(e, 1e-12))), 2), iou=round(float((sil & gm).sum() / max(1, (sil | gm).sum())), 3)); tiles.append(lab(im, V))
    ys, xs = np.where(cv2.dilate(gm.astype(np.uint8), np.ones((61, 61), np.uint8)) > 0)
    cv2.imencode('.png', cv2.cvtColor(np.concatenate([x[ys.min():ys.max(), xs.min():xs.max()] for x in tiles], 1), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT2, f'rel_leaveout_f{t:03d}.png'))
    LO.append(row); print(row, flush=True)
res['leave_out'] = LO
for subset, rows in (('all', LO), ('gt_reliable', [r for r in LO if r['gt_reliable']])):
    res.setdefault('leave_out_median', {})[subset] = {V: dict(psnr=float(np.median([r[V]['psnr'] for r in rows])), iou=float(np.median([r[V]['iou'] for r in rows])), worse_iou_than_V0=int(sum(r[V]['iou'] < r['V0']['iou'] - 0.01 for r in rows))) for V in ('V0', 'V2', 'V4')} | {'n': len(rows)}
print('leave-out median', json.dumps(res['leave_out_median']), flush=True)
json.dump(res, open(os.path.join(OUT2, 'rel_result.json'), 'w'), indent=1)
# orbit
up = np.array([0, 1, 0.]); el0 = float(np.median([np.degrees(np.arcsin((cam0(i)['C'] - ctr)[1] / np.linalg.norm(cam0(i)['C'] - ctr))) for i in views]))
D0 = float(np.median([np.linalg.norm(cam0(i)['C'] - ctr) for i in views])); ref = cam(views[0]); ZOOM = 1.6


def look(C, tgt):
    z = tgt - C; z /= np.linalg.norm(z); x = np.cross(-up, z); x /= np.linalg.norm(x); yv = np.cross(z, x)
    c = dict(ref); c['C'] = C; c['Rcw'] = np.stack([x, yv, z]); c['fx'] = ref['fx'] * ZOOM; c['fy'] = ref['fy'] * ZOOM; return c


cams = []
for a in np.arange(-180, 180, 2.0):
    h = np.array([np.sin(np.radians(a)), 0, np.cos(np.radians(a))]); dv = h * np.cos(np.radians(el0)) + up * np.sin(np.radians(el0)); cams.append(look(ctr + dv * D0, ctr))
zf = {'V0': zsrc_fn('V0', s0_all, 'all'), 'V2': zsrc_fn('V2', s0_all, 'all'), 'V4': zsrc_fn('V2', s1_all, f'rel{STRICT}_{MISS_T}_all')}
seqs = {V: [] for V in ('V0', 'V2', 'V4', 'V4e')}; ema = {}
vw = cv2.VideoWriter(os.path.join(OUT2, 'rel_orbit_compare.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 15, (EW * 2, EH * 2))
for n, ct in enumerate(cams):
    w = weights_for(ct, views); tgt_ = {s: w.get(s, 0.0) for s in set(w) | set(ema)}
    ema = {s: (0.6 * ema.get(s, 0.0) + 0.4 * v) if n > 0 else v for s, v in tgt_.items()}; ema = dict(sorted(((s, v) for s, v in ema.items() if v > 1e-3), key=lambda kv: -kv[1])[:7])
    tiles = []
    for V, surf, wt, vt in (('V0', s0_all, w, 'V0'), ('V2', s0_all, w, 'V2'), ('V4', s1_all, w, 'V2'), ('V4e', s1_all, ema, 'V2')):
        im, a2 = frame(vt, ct, wt, zf['V0' if V == 'V0' else ('V2' if V == 'V2' else 'V4')], surf); seqs[V].append((im, a2))
        tiles.append(lab(im, {'V0': 'V0 now', 'V2': 'V2 tolerant hull', 'V4': 'V4 reliable-mask hull', 'V4e': 'V4 + weight smooth'}[V]))
    vw.write(cv2.cvtColor(np.concatenate([np.concatenate(tiles[:2], 1), np.concatenate(tiles[2:], 1)], 0), cv2.COLOR_RGB2BGR))
    if n % 45 == 0:
        print('orbit', n, flush=True)
vw.release()


def wobble(seq):
    oa, oc = [], []
    for k in range(1, len(seq) - 1):
        a0, a1, a2_ = seq[k - 1][1], seq[k][1], seq[k + 1][1]; d2 = np.abs(a2_ - 2 * a1 + a0)
        edge = cv2.morphologyEx((a1 > 0.5).astype(np.uint8), cv2.MORPH_GRADIENT, np.ones((3, 3), np.uint8)) > 0; oa.append(float(d2.sum() / max(1, edge.sum())))
        Lm = lambda im, a: (0.299 * im[..., 0] + 0.587 * im[..., 1] + 0.114 * im[..., 2]) / np.maximum(a, 1e-3)
        ins = cv2.erode(((a0 > 0.95) & (a1 > 0.95) & (a2_ > 0.95)).astype(np.uint8), np.ones((7, 7), np.uint8)) > 0
        oc.append(float(np.abs(Lm(seq[k + 1][0], a2_) - 2 * Lm(seq[k][0], a1) + Lm(seq[k - 1][0], a0))[ins].mean()) if ins.any() else 0.0)
    return dict(edge_wobble_mean=float(np.mean(oa)), edge_wobble_p95=float(np.percentile(oa, 95)), colour_flicker_mean=float(np.mean(oc)), colour_flicker_p95=float(np.percentile(oc, 95)))


res['orbit'] = {V: wobble(s) for V, s in seqs.items()}
print('orbit metrics', json.dumps(res['orbit']), flush=True)
json.dump(res, open(os.path.join(OUT2, 'rel_result.json'), 'w'), indent=1)
