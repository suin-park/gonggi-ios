"""V0 vs V4 at elevations outside the captured band (test_10 ring = 23-37 deg)."""
import os, sys, json
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'a5_lib.py'), encoding='utf-8').read())
s0 = np.load(os.path.join(CD, 'hull_surf_all.npy')); s1 = np.load(os.path.join(CD, 'hull_rel_all_0.03_0.1.npy'))
up = np.array([0, 1, 0.]); D0 = float(np.median([np.linalg.norm(cam0(i)['C'] - ctr) for i in views])); ref = cam(views[0]); ZOOM = 1.6
def look(C, tgt):
    z = tgt - C; z /= np.linalg.norm(z); x = np.cross(-up, z)
    if np.linalg.norm(x) < 1e-6: x = np.array([1., 0, 0])
    x /= np.linalg.norm(x); yv = np.cross(z, x); c = dict(ref); c['C'] = C; c['Rcw'] = np.stack([x, yv, z]); c['fx'] = ref['fx'] * ZOOM; c['fy'] = ref['fy'] * ZOOM; return c
zf0 = zsrc_fn('V0', s0, 'all'); zf4 = zsrc_fn('V2', s1, 'rel0.03_0.1_all')
rows = []; grid = []
for el in (-20, 0, 15, 30, 45, 60, 80):
    line = []
    for a in (0, 90, 180):
        h = np.array([np.sin(np.radians(a)), 0, np.cos(np.radians(a))]); dv = h * np.cos(np.radians(el)) + up * np.sin(np.radians(el)); ct = look(ctr + dv * D0, ctr)
        w = weights_for(ct, views); mx = max(w.values()) if w else 0; w = {k: v / mx for k, v in w.items()} if mx > 0 else {bmcore.ranked(ct, views)[0][1]: 1.0}; r = bmcore.ranked(ct, views); near = r[0][2]
        i0, a0 = frame('V0', ct, w, zf0, s0); i4, a4 = frame('V2', ct, w, zf4, s1)
        rows.append(dict(elev=el, az=a, nearest_deg=round(near, 1))); line.append(np.concatenate([lab(i0, f'V0 el{el} az{a} near{near:.0f}'), lab(i4, 'V4')], 1))
    grid.append(np.concatenate(line, 1)); print(rows[-3:], flush=True)
big = np.concatenate(grid, 0); big = cv2.resize(big, (big.shape[1] // 2, big.shape[0] // 2), interpolation=cv2.INTER_AREA)
cv2.imencode('.png', cv2.cvtColor(big, cv2.COLOR_RGB2BGR))[1].tofile(os.path.join(OUT, 'elev_V0_V4.png')); json.dump(rows, open(os.path.join(OUT, 'elev_rows.json'), 'w'))
