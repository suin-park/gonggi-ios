"""V0 (existing Bm) vs V4 (reliable-mask hull) vs V4e (V4 + blend-weight smoothing) on one dataset, FIXED settings from test_10
(VOX 5 mm, H0 OUTFRAC 0.2, MISS_T 0.10, STRICT 0.03, TOL 2 cm, EMA 0.6). No tuning per dataset.
Weight rule = app (BmRenderer): k=min(5,n-1), base^3, no small-weight cut, nearest-photo fallback; EMA runs on sum-normalised weights (scale-free), keeps the 7 largest, drops < 1e-3 of the max.
Outputs: leave-out (12 frames by azimuth; sources and hull exclude |i-t|<=10; the saved map has seen every view -> NOT an independent unseen test),
orbit at the capture-median elevation (2 deg steps) with nearest-photo angle per frame, metrics split nearest<=10 deg ('in range') vs >10 deg,
elevation sweep sheet. usage: DATA=.. POSES=.. CDIR=.. python a10_run.py <OUT>"""
import os, sys, json, time
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'a5_lib.py'), encoding='utf-8').read())
STRICT, MISS_T = 0.03, 0.10
assert OUTFRAC == 0.2 and VOX == 0.005 and TOL == 0.02


def score_views(surf, use):
    sc = {}
    for i in use:
        a = hull_alpha(surf, cam(i)) > 0.5; md_ = cv2.dilate(P.mask[i].astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
        sc[i] = float((a & ~md_).sum() / max(1, a.sum()))
    return sc


def hulls(use, tag):
    f0 = os.path.join(CD, f'hull_surf_{tag}.npy'); f1 = os.path.join(CD, f'hull_rel_{tag}_{STRICT}_{MISS_T}.npy'); fj = f1.replace('.npy', '.json')
    s0 = np.load(f0) if os.path.exists(f0) else carve(use, 0.2)[1]
    np.save(f0, s0)
    if os.path.exists(f1):
        return s0, np.load(f1), json.load(open(fj))
    sc = score_views(s0, use); good = [i for i in use if sc[i] <= MISS_T]; _, s1 = carve(good, STRICT); np.save(f1, s1)
    info = dict(n_use=len(use), n_good=len(good), dropped=[i for i in use if i not in good]); json.dump(info, open(fj, 'w')); return s0, s1, info


def ema_step(prev, w, n):
    tot = sum(w.values()); w = {s: v / tot for s, v in w.items()}
    if n == 0 or not prev:
        e = dict(w)
    else:
        e = {s: 0.6 * prev.get(s, 0.0) + 0.4 * w.get(s, 0.0) for s in set(prev) | set(w)}
    mx = max(e.values()); return dict(sorted(((s, v) for s, v in e.items() if v >= 1e-3 * mx), key=lambda kv: -kv[1])[:7])


res = {'dataset': os.environ['DATA'], 'settings': dict(VOX=VOX, OUTFRAC_H0=0.2, MISS_T=MISS_T, STRICT=STRICT, TOL=TOL, EMA=0.6, SS=SS),
       'note': 'PC only; A15 not measured; leave-out excludes target +-10 from sources and hull, but the saved device map was trained on all frames'}
t0 = time.time(); s0_all, s1_all, info_all = hulls(views, 'all'); res['hull_all'] = dict(info_all, surface_v0hull=len(s0_all), surface_v4=len(s1_all), seconds=round(time.time() - t0, 1))
print('hull all', res['hull_all']['n_good'], '/', res['hull_all']['n_use'], flush=True)
az = {i: float(np.degrees(np.arctan2(*(cam0(i)['C'] - ctr)[[0, 2]]))) for i in views}
el = {i: float(np.degrees(np.arcsin((cam0(i)['C'] - ctr)[1] / np.linalg.norm(cam0(i)['C'] - ctr)))) for i in views}
res['coverage'] = dict(elev_min=min(el.values()), elev_max=max(el.values()), elev_median=float(np.median(list(el.values()))))
tests = sorted(set(min(views, key=lambda i: abs(((az[i] - a + 180) % 360) - 180)) for a in range(-180, 180, 30)))
LO = []
for t in tests:
    srcs = [i for i in views if abs(i - t) > 10]; tag = f'lo{t}'; s0, s1, info = hulls(srcs, tag)
    ct = cam(t); gt = P.gt[t]; ga = matte(t); gm = ga > 0.5; band = cv2.dilate(gm.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0; w = weights_for(ct, srcs)
    row = dict(frame=t, az=round(az[t]), el=round(el[t]), nearest_deg=round(bmcore.ranked(ct, srcs)[0][2], 1), target_dropped_as_unreliable=t in info_all['dropped'])
    tiles = [lab(P.gt[t], 'photo (raw)'), lab(gt * ga[..., None], 'photo x auto matte')]
    for V, surf, vt, ztag in (('V0', s0, 'V0', tag), ('V4', s1, 'V2', f'rel{STRICT}_{MISS_T}_{tag}')):
        im, a2 = frame(vt, ct, w, zsrc_fn(vt, surf, ztag), surf); e = ((im - gt * ga[..., None]) ** 2)[band].mean(); sil = a2 > 0.5
        row[V] = dict(psnr_vs_auto_matte=round(float(10 * np.log10(1 / max(e, 1e-12))), 2), iou_vs_auto_matte=round(float((sil & gm).sum() / max(1, (sil | gm).sum())), 3)); tiles.append(lab(im, V))
        np.save(os.path.join(CD, f'lo_sil_{V}_{t}.npy'), sil)
    ys, xs = np.where(cv2.dilate(gm.astype(np.uint8), np.ones((61, 61), np.uint8)) > 0)
    cv2.imencode('.png', cv2.cvtColor(np.concatenate([x[ys.min():ys.max(), xs.min():xs.max()] for x in tiles], 1), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, f'leaveout_f{t:03d}.png'))
    LO.append(row); print(row, flush=True)
res['leave_out'] = LO
res['leave_out_median'] = {V: dict(psnr=float(np.median([r[V]['psnr_vs_auto_matte'] for r in LO])), iou=float(np.median([r[V]['iou_vs_auto_matte'] for r in LO])),
                                   n_iou_lower_than_V0=int(sum(r[V]['iou_vs_auto_matte'] < r['V0']['iou_vs_auto_matte'] - 0.01 for r in LO))) for V in ('V0', 'V4')}
print('leave-out median', res['leave_out_median'], flush=True)
json.dump(res, open(os.path.join(OUT, 'result.json'), 'w'), indent=1)
# ---- orbit
up = np.array([0, 1, 0.]); el0 = res['coverage']['elev_median']; D0 = float(np.median([np.linalg.norm(cam0(i)['C'] - ctr) for i in views])); ref = cam(views[0]); ZOOM = 1.6


def look(C, tgt):
    z = tgt - C; z /= np.linalg.norm(z); x = np.cross(-up, z)
    if np.linalg.norm(x) < 1e-6:
        x = np.array([1., 0, 0])
    x /= np.linalg.norm(x); yv = np.cross(z, x); c = dict(ref); c['C'] = C; c['Rcw'] = np.stack([x, yv, z]); c['fx'] = ref['fx'] * ZOOM; c['fy'] = ref['fy'] * ZOOM; return c


def orbit_cam(a, e):
    h = np.array([np.sin(np.radians(a)), 0, np.cos(np.radians(a))]); dv = h * np.cos(np.radians(e)) + up * np.sin(np.radians(e)); return look(ctr + dv * D0, ctr)


zf = {'V0': zsrc_fn('V0', s0_all, 'all'), 'V4': zsrc_fn('V2', s1_all, f'rel{STRICT}_{MISS_T}_all')}
seqs = {V: [] for V in ('V0', 'V4', 'V4e')}; near = []; ema = {}
vw = cv2.VideoWriter(os.path.join(OUT, 'orbit_V0_V4_V4e.mp4'), cv2.VideoWriter_fourcc(*'mp4v'), 15, (EW * 3, EH))
for n, a in enumerate(np.arange(-180, 180, 2.0)):
    ct = orbit_cam(a, el0); w = weights_for(ct, views); ema = ema_step(ema, w, n); near.append(bmcore.ranked(ct, views)[0][2]); tiles = []
    for V, surf, wt, vt, z_ in (('V0', s0_all, w, 'V0', zf['V0']), ('V4', s1_all, w, 'V2', zf['V4']), ('V4e', s1_all, ema, 'V2', zf['V4'])):
        im, a2 = frame(vt, ct, wt, z_, surf); seqs[V].append((im, a2)); tiles.append(lab(im, f'{V} az{a:.0f} near{near[-1]:.0f}'))
    vw.write(cv2.cvtColor(np.concatenate(tiles, 1), cv2.COLOR_RGB2BGR))
    if n % 45 == 0:
        print('orbit', n, flush=True)
vw.release()


def wobble(seq, idx):
    oa, oc = [], []
    for k in idx:
        if k < 1 or k >= len(seq) - 1:
            continue
        a0, a1, a2_ = seq[k - 1][1], seq[k][1], seq[k + 1][1]; d2 = np.abs(a2_ - 2 * a1 + a0)
        edge = cv2.morphologyEx((a1 > 0.5).astype(np.uint8), cv2.MORPH_GRADIENT, np.ones((3, 3), np.uint8)) > 0; oa.append(float(d2.sum() / max(1, edge.sum())))
        Lm = lambda im, a: (0.299 * im[..., 0] + 0.587 * im[..., 1] + 0.114 * im[..., 2]) / np.maximum(a, 1e-3)
        ins = cv2.erode(((a0 > 0.95) & (a1 > 0.95) & (a2_ > 0.95)).astype(np.uint8), np.ones((7, 7), np.uint8)) > 0
        oc.append(float(np.abs(Lm(seq[k + 1][0], a2_) - 2 * Lm(seq[k][0], a1) + Lm(seq[k - 1][0], a0))[ins].mean()) if ins.any() else 0.0)
    return dict(n=len(oa), alpha_2nd_diff_per_edge_px=float(np.mean(oa)) if oa else None, luma_2nd_diff_inside=float(np.mean(oc)) if oc else None)


near = np.array(near); inr = [k for k in range(len(near)) if near[k] <= 10]; outr = [k for k in range(len(near)) if near[k] > 10]
res['orbit'] = dict(elev=el0, frames=len(near), nearest_deg_p50=float(np.median(near)), nearest_deg_max=float(near.max()), in_range_frames=len(inr),
                    metrics={V: dict(all=wobble(s, range(len(s))), in_range=wobble(s, inr), out_of_range=wobble(s, outr)) for V, s in seqs.items()},
                    metric_note='alpha_2nd_diff_per_edge_px = sum|a(t+1)-2a(t)+a(t-1)| / edge-pixel count (screen-space temporal alpha change; NOT a pixel displacement or perceived-wobble %)')
print('orbit', json.dumps(res['orbit']['metrics']), flush=True)
json.dump(res, open(os.path.join(OUT, 'result.json'), 'w'), indent=1)
# ---- elevation sweep
grid = []
for e in (res['coverage']['elev_min'] - 30, res['coverage']['elev_min'] - 15, el0, res['coverage']['elev_max'] + 15, res['coverage']['elev_max'] + 30):
    e = float(np.clip(e, -60, 85)); line = []
    for a in (0, 90, 180, 270):
        ct = orbit_cam(a, e); w = weights_for(ct, views); nd = bmcore.ranked(ct, views)[0][2]
        i0, _ = frame('V0', ct, w, zf['V0'], s0_all); i4, _ = frame('V2', ct, w, zf['V4'], s1_all); line.append(np.concatenate([lab(i0, f'V0 el{e:.0f} az{a} near{nd:.0f}'), lab(i4, 'V4')], 1))
    grid.append(np.concatenate(line, 1))
big = np.concatenate(grid, 0); big = cv2.resize(big, (big.shape[1] // 2, big.shape[0] // 2), interpolation=cv2.INTER_AREA)
cv2.imencode('.png', cv2.cvtColor(big, cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, 'elevation_V0_V4.png'))
print('done', flush=True)
