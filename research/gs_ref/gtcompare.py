"""Same-viewpoint photo/base/A/B/C comparison images + orbit (rotation) renders for the GT-quality study. Local only (contains the user's photos)."""
import os, sys, json
import numpy as np, cv2
import gtlib as g
OUT = os.environ.get('OUTDIR', 'out_gt'); P = g.Photos(); M0 = g.load_map()
TAGS = os.environ.get('MAPS', 'A,B,C').split(','); SUF = os.environ.get('SUF', '')
conds = [c for c in TAGS if os.path.exists(os.path.join(OUT, f'map_{c}.npz'))]
LAB = {'A': 'A color+opacity', 'B': 'B +geometry', 'C': 'C +densify', 'A_reset': 'A strict-colour', 'B_reset': 'B strict-colour'}
maps = {'device map': M0}
for c in conds: z = np.load(os.path.join(OUT, f'map_{c}.npz')); maps[LAB.get(c, c)] = {k: z[k] for k in z.files}
meta_c = np.array([0.022736966609954834, -0.87748324871063232, -0.65346729755401611], np.float64)
def put(img, text): im = (np.clip(img, 0, 1) * 255).astype(np.uint8).copy(); cv2.putText(im, text, (4, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 0), 1); return im
def crops(i, box, scale):
    x0, y0, x1, y1 = box; tiles = [put(P.gt[i][y0:y1, x0:x1], f'photo v{i}')]
    for nm, M in maps.items(): img, al, _ = g.render(M, P.cam(i)); tiles.append(put(img[y0:y1, x0:x1], nm))
    return np.concatenate([cv2.resize(t, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC) for t in tiles], 1)
rows = []
used = lambda i: 'unused in the fit (start map saw it)' if g.held(i) else 'used in the fit'
for i in (2, 8, 41, 42, 45, 5, 55):
    if i >= P.n: continue
    eye = g.find_eyes(P.gt[i], P.mask[i])
    if eye is None: continue
    x0, y0, x1, y1 = eye['box']; im = crops(i, (x0, y0, x1, y1), 3); cv2.putText(im, used(i), (4, im.shape[0] - 6), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
    cv2.imencode('.png', cv2.cvtColor(im, cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, f'cmp_face{SUF}_view{i}.png'))
# full product view side by side (photo | each map) for a used and an unused view
for i in (41, 45, 5):
    if i >= P.n: continue
    ys, xs = np.nonzero(P.mask[i]); box = (max(0, xs.min() - 20), max(0, ys.min() - 20), min(g.EW, xs.max() + 20), min(g.EH, ys.max() + 20))
    im = crops(i, box, 1); cv2.imencode('.png', cv2.cvtColor(im, cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, f'cmp_product{SUF}_view{i}.png'))
# orbit: look-at cameras around the product centre; radius/elevation from the real capture cameras
cs = np.array([P.fr[i]['C'] for i in range(P.n) if P.mask[i].sum() > 50]); d = cs - meta_c; hr = np.linalg.norm(d[:, [0, 2]], axis=1); rad = float(np.median(hr)); el = float(np.median(np.arctan2(d[:, 1], hr)))
print('orbit radius %.3f m, elevation %.1f deg (median of capture cameras)' % (rad, np.degrees(el)))
def lookat(az, dist=None):
    dist = dist or rad; c = meta_c + np.array([np.cos(el) * np.cos(az) * dist, np.sin(el) * dist, np.cos(el) * np.sin(az) * dist]); z = (meta_c - c); z /= np.linalg.norm(z)
    dn = np.array([0, -1.0, 0]); y = dn - (dn @ z) * z; y /= np.linalg.norm(y); x = np.cross(y, z); Rwc = np.stack([x, y, z], 1)
    f = P.fr[41]; return dict(Rcw=Rwc.T, C=c, fx=f['fx'] * EWs, fy=f['fy'] * EWs, cx=(f['cx'] + .5) * EWs - .5, cy=(f['cy'] + .5) * EWs - .5, W=g.EW, H=g.EH)
EWs = g.EW / 960.0
# convention check: the real pose 41 looked at through my look-at construction must agree on the forward axis and 'down' direction
f = P.fr[41]; fw = f['R'][:, 2]; to_c = (meta_c - f['C']); to_c /= np.linalg.norm(to_c); print('pose-41 forward vs direction to product centre: cos = %.3f (R[:,1]·up = %.2f; y axis points down if negative)' % (fw @ to_c, f['R'][:, 1] @ np.array([0, 1.0, 0])))
azs = np.linspace(0, 2 * np.pi, 12, endpoint=False); sheet = []
for nm, M in maps.items():
    row = []
    for k, az in enumerate(azs):
        img, al, _ = g.render(M, lookat(az)); row.append(put(cv2.resize(img, (320, 240), interpolation=cv2.INTER_AREA), f'{nm} az{int(np.degrees(az))}'))
    sheet.append(np.concatenate(row[:6], 1)); sheet.append(np.concatenate(row[6:], 1))
cv2.imencode('.png', cv2.cvtColor(np.concatenate(sheet, 0), cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, f'orbit{SUF}.png'))
# ghost / floater check on the orbit: alpha mass far from the product centre projection and the share of alpha<0.5 'holes' inside the silhouette (no photo GT here: novel views)
for nm, M in maps.items():
    gh = []; hole = []
    for az in azs:
        cam = lookat(az); img, al, _ = g.render(M, cam); pc = cam['Rcw'] @ (meta_c - cam['C']); u = cam['fx'] * pc[0] / pc[2] + cam['cx']; v = cam['fy'] * pc[1] / pc[2] + cam['cy']
        yy, xx = np.mgrid[:g.EH, :g.EW]; far = ((xx - u) ** 2 + (yy - v) ** 2) > (0.45 * cam['fx'] * 0.55 / pc[2]) ** 2; gh.append(float(al[far].mean()))
    print(nm, 'orbit: mean alpha outside a 0.55 m-wide disc around the product centre = %.4f (floaters/ghost proxy)' % np.mean(gh))
