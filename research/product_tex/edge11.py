"""Outline experiment v3 (synthetic GT, TRUE depth): soft alpha + boundary cells + coverage AA, with and without edge colour extension (background colour in partial-alpha texels
is replaced by the nearest fully covered texel's colour, so coverage blending never darkens/contaminates the contour)."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'edge08.py'), encoding='utf-8').read().split("variants = [")[0]
exec(compile(src, 'edge08_head', 'exec'))


def metrics2(al, im, cov, grgb):
    m = metrics(al, cov)
    band = cv2.dilate(((cov > 0.02) & (cov < 0.98)).astype(np.uint8), np.ones((7, 7), np.uint8)) > 0
    comp = np.clip(im * al[..., None], 0, 1)
    m['band_rgb'] = float(np.abs(comp - grgb)[band].mean())
    return m


variants = [('A current .75 nearest', '0', 0.5, '0', 0.5, False, 0.75, 'nearest'),
            ('B soft cells.25 AA @1.0', '1', 0.25, '0', 0.25, True, 1.0, 'linear'),
            ('B2 + edge colour ext', '1', 0.25, '1', 0.25, True, 1.0, 'linear'),
            ('C2 ext, AA .75 bilinear', '1', 0.25, '1', 0.25, True, 0.75, 'linear'),
            ('D2 ext, no AA (hard .5) @1.0', '1', 0.25, '1', 0.5, False, 1.0, 'nearest'),
            ('E2 ext, AA, thr .4 @1.0', '1', 0.25, '1', 0.4, True, 1.0, 'linear')]
Lc = {}
c = syn.origin; Cs = np.array([f['C'] for f in syn.real]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor)); fx = syn.real[0]['fx'] * W / 960
crops = []
for name, am, mp, ext, thr, aa, scale, up in variants:
    key = (am, mp, ext)
    if key not in Lc: Lc[key] = build(am, mp, ext)
    L = Lc[key]; Sm = [F.layer_samples(l) for l in L]; rows = []
    for pitch in (54, 30):
        for a in range(-150, 180, 60):
            cam = cams07.orbit(c, R, [a], pitch, fx, W, H)[0]; cov, grgb = gt_cov(cam, W, H)
            ws, hs = int(round(W * scale)), int(round(H * scale)); cs = F.Cam(cam.R, cam.C, cam.fx * scale, cam.fy * scale, (cam.cx + .5) * scale - .5, (cam.cy + .5) * scale - .5)
            im, al = render_view(L, Sm, cs, ws, hs, thr, aa); im, al = finish(im, al, scale, up)
            rows.append(metrics2(al, im, cov, grgb))
            if pitch == 54 and a == 30:
                ys, xs = np.nonzero(cov > 0.5); y0, x0 = ys.min(), xs.min(); comp = np.clip(im * al[..., None], 0, 1)
                crop = cv2.resize((comp[y0 + 20:y0 + 120, x0:x0 + 140] * 255).astype(np.uint8), None, fx=4, fy=4, interpolation=cv2.INTER_NEAREST)
                cv2.putText(crop, name, (6, 18), 0, 0.55, (255, 255, 0), 1, cv2.LINE_AA); crops.append(crop)
    m = {k: float(np.mean([r[k] for r in rows])) for k in rows[0]}
    print(f'{name:32s}', ' '.join(f'{k} {v:.3f}' for k, v in m.items()), flush=True)
rows_ = [np.hstack(crops[i:i + 2]) for i in range(0, len(crops), 2)]
cv2.imwrite(r'C:\Users\emili\Downloads\product_surface_alignment_20261020\_probe_edge_syn2.png', cv2.cvtColor(np.vstack(rows_), cv2.COLOR_RGB2BGR))
