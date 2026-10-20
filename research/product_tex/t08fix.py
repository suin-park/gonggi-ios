import sys, os, json, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import t08, h07, cams07, fix06 as F, pipe07 as P

OUT = r'C:\Users\emili\Downloads\product_surface_alignment_20261020'
Lb, La, sc = t08.load_both()
t = time.time(); Lv = P.register_vertex(Lb); print('vertex register sec', round(time.time() - t), flush=True)
Lc = P.register(Lb)   # cell-wise (what 3.0(26) ships), re-run from the restored original geometry
out = {}
for name, L in (('original (restored)', Lb), ('saved 3.0(26) cell-wise', La), ('cell-wise re-run (PC)', Lc), ('vertex-shared (PC)', Lv)):
    out[name] = dict(seam=h07.seam_stats(L), pairs={str(g): v for g, v in h07.pair_stats(L).items()})
    print(name, out[name]['seam'], out[name]['pairs'], flush=True)
json.dump(out, open(os.path.join(OUT, 'metrics_t08_vertex.json'), 'w'), indent=1)
c = cams07.product_center(La); Cs = np.array([l['C'] for l in La]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor))
W, H = 400, 533; fx = 720.37 * H / 960
sets = [('BEFORE (restored)', Lb), ('3.0(26) cell-wise', La), ('FIX shared vertices', Lv)]
Ss = [[F.layer_samples(l) for l in L] for _, L in sets]


def lab(img, t):
    img = np.ascontiguousarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
    cv2.rectangle(img, (0, 0), (img.shape[1], 16), (0, 0, 0), -1); cv2.putText(img, t, (3, 12), 0, 0.4, (255, 255, 255), 1, cv2.LINE_AA)
    return img


rows = []
for pitch, a in ((40, 0), (40, 90), (40, 180), (40, -90), (11.5, 45), (11.5, 135)):
    cam = cams07.orbit(c, R, [a], pitch, fx, W, H)[0]
    rows.append(np.hstack([lab(h07.render(L, S, cam, W, H)[0], f'{n} az{a} p{pitch}') for (n, L), S in zip(sets, Ss)]))
img = np.vstack([np.hstack([rows[i], rows[i + 1]]) for i in (0, 2, 4)])
cv2.imwrite(os.path.join(OUT, 't08_vertex_fix_stills.jpg'), cv2.cvtColor(img, cv2.COLOR_RGB2BGR))
