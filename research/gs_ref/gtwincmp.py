"""Same-layout comparison for the supervision-form experiment: photo | device map | full640 | pixmatch | win | full160, for views 2 (earlier viewpoint), 41 (used), 5 and 45 (unused in the fit; neighbours fitted; start map saw them).
Rows per view: eyes/nose crop, smooth-surface crop, contour crop (all chosen from the PHOTO only, same box for every column), plus the full product. Local only."""
import os, json
import numpy as np, cv2
import gtlib as g
OUT = os.environ.get('OUTDIR', 'out_win'); P = g.Photos(); M0 = g.load_map()
tags = [t for t in ('full640', 'pixmatch', 'win', 'full160') if os.path.exists(os.path.join(OUT, f'map_{t}.npz'))]
maps = {'device map': M0}
for t in tags: z = np.load(os.path.join(OUT, f'map_{t}.npz')); maps[t] = {k: z[k] for k in z.files}
def put(img, text): im = (np.clip(img, 0, 1) * 255).astype(np.uint8).copy(); cv2.putText(im, text, (3, 13), cv2.FONT_HERSHEY_SIMPLEX, 0.42, (255, 255, 0), 1); return im
def boxes(i):
    gt, m = P.gt[i], P.mask[i]; eye = g.find_eyes(gt, m); out = {}
    if eye is not None: out['eyes/nose'] = eye['box']
    hf = np.abs(g.lum(gt) - cv2.GaussianBlur(g.lum(gt), (0, 0), 3.0)); k = 96
    mi = cv2.integral(m.astype(np.float32)); hi_ = cv2.integral(hf.astype(np.float32)); best = None; bc = None; ed = cv2.Canny((gt * 255).astype(np.uint8), 60, 140).astype(np.float32); ei = cv2.integral(ed)
    for y in range(0, g.EH - k, 8):
        for x in range(0, g.EW - k, 8):
            cov = (mi[y + k, x + k] - mi[y, x + k] - mi[y + k, x] + mi[y, x]) / (k * k); h = (hi_[y + k, x + k] - hi_[y, x + k] - hi_[y + k, x] + hi_[y, x]) / (k * k)
            if cov > 0.97 and (best is None or h < best[0]): best = (h, x, y)
            if 0.3 < cov < 0.7:
                e = (ei[y + k, x + k] - ei[y, x + k] - ei[y + k, x] + ei[y, x]); bc = (e, x, y) if (bc is None or e > bc[0]) else bc
    if best: out['smooth surface'] = (best[1], best[2], best[1] + k, best[2] + k)
    if bc: out['contour'] = (bc[1], bc[2], bc[1] + k, bc[2] + k)
    return out
for i in (2, 41, 5, 45):
    rows = []
    for nm, b in boxes(i).items():
        x0, y0, x1, y1 = b; sc = 3 if nm == 'eyes/nose' else 3; tiles = [put(P.gt[i][y0:y1, x0:x1], f'photo {nm}')]
        for t, M in maps.items(): img, al, _ = g.render(M, P.cam(i)); tiles.append(put(img[y0:y1, x0:x1], t))
        rows.append(np.concatenate([cv2.resize(t, None, fx=sc, fy=sc, interpolation=cv2.INTER_CUBIC) for t in tiles], 1))
    w = max(r.shape[1] for r in rows); rows = [np.pad(r, ((0, 0), (0, w - r.shape[1]), (0, 0))) for r in rows]
    label = 'unused in the fit (neighbours fitted; start map saw it)' if g.held(i) else 'used in the fit'
    im = np.concatenate(rows, 0); cv2.putText(im, f'view {i}: {label}', (4, im.shape[0] - 5), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
    cv2.imencode('.png', cv2.cvtColor(im, cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, f'cmp_crops_view{i}.png'))
    ys, xs = np.nonzero(P.mask[i]); box = (max(0, xs.min() - 15), max(0, ys.min() - 15), min(g.EW, xs.max() + 15), min(g.EH, ys.max() + 15)); x0, y0, x1, y1 = box
    tiles = [put(P.gt[i][y0:y1, x0:x1], f'photo v{i}')] + [put(g.render(M, P.cam(i))[0][y0:y1, x0:x1], t) for t, M in maps.items()]
    cv2.imencode('.png', cv2.cvtColor(np.concatenate(tiles, 1), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, f'cmp_product_view{i}.png'))
# where did the windows go? window visit count per Gaussian shown at view 41 (log colour); eye Gaussians reported in the json
if 'win' in tags:
    V = np.load(os.path.join(OUT, 'visits_win.npy')); vw = V[1]; z = np.load(os.path.join(OUT, 'map_win.npz')); cam = P.cam(41); img, al, st = g.render({k: z[k] for k in z.files}, cam); Pp = st['proj']
    canvas = np.zeros((g.EH, g.EW, 3), np.float32); ok = Pp[:, 0] > 0.5; u = np.clip(Pp[ok, 1].astype(int), 0, g.EW - 1); w = np.clip(Pp[ok, 2].astype(int), 0, g.EH - 1); val = np.log1p(vw[ok]) / max(1e-6, np.log1p(vw.max()))
    cm = cv2.applyColorMap((val * 255).astype(np.uint8)[:, None], cv2.COLORMAP_VIRIDIS)[:, 0, ::-1].astype(np.float32) / 255
    for a, b, c in zip(u, w, cm): cv2.circle(canvas, (int(a), int(b)), 2, tuple(float(x) for x in c), -1)
    g.imwrite(os.path.join(OUT, 'window_visits_view41.png'), np.concatenate([P.gt[41], canvas], 1))
rows = {}
for t in tags:
    S = json.load(open(os.path.join(OUT, f'win_{t}.json')))['summary']; rows[t] = S
print('arm | steps (full/window) | rendered Mpx | wall s | cpu s | s/step')
for t, S in rows.items(): print(t.ljust(9), S['steps'], f"({S['steps_full']}/{S['steps_window']})", '%.1f' % (S['rendered_pixels'] / 1e6), '%.0f' % S['wall_seconds'], '%.0f' % S['cpu_seconds'], '%.3f' % S['seconds_per_step'])
print('\narm | product PSNR fit/unused/early | edge PSNR fit | smooth HF fit | eye recovery fit/unused | eye PSNR fit/unused | dark IoU fit/unused | false dark unused | dark blobs unused | ghost far')
base = {t: json.load(open('out_gt/gt_base.json'))['summary']}
for t, S in rows.items():
    e = S['eval']; y = S['eye']; print(t.ljust(9), '%.2f/%.2f/%.2f' % (e['product_psnr']['fit'], e['product_psnr']['unused'], e['product_psnr']['early_0_20']), '| %.2f' % e['edge_psnr']['fit'], '| %.4f' % e['smooth_hf_render']['fit'], '| %.2f/%.2f' % (y['recovery']['fit'], y['recovery']['unused']),
                         '| %.2f/%.2f' % (y['eye_psnr']['fit'], y['eye_psnr']['unused']), '| %.2f/%.2f' % (y['dark_iou']['fit'], y['dark_iou']['unused']), '| %.2f' % y['false_dark']['unused'], '| %.1f' % y['dark_blobs']['unused'], '| %.4f' % e['ghost_alpha_far']['fit'])
print('\nwindow coverage (win arm):', json.dumps(rows['win']['visits'], default=float) if 'win' in rows else '-')
