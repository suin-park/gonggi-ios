"""Test_08 real saved .kmots (3.0(26)). Panels: [3.0(26) as saved] [shared-vertex registration re-run by the PC reference implementation from the restored original geometry] [pre-registration original].
No depth re-estimation: same layers/textures, same cameras, same resolution. PC reference of the Swift algorithm, NOT the app's own render."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import t08, h07, cams07, fix06 as F, pipe07 as P
OUT = r'C:\Users\emili\Downloads\product_surface_alignment_20261020'
Lb, La, sc = t08.load_both(); Lv = P.register_vertex(Lb, cons=False)
c = cams07.product_center(La); Cs = np.array([l['C'] for l in La]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor))
W, H = 360, 480; fx = 720.37 * H / 960
sets = [('3.0(26) as saved', La), ('FIXED: shared vertices', Lv), ('before registration', Lb)]
Ss = [[F.layer_samples(l) for l in L] for _, L in sets]
def lab(img, t):
    img = np.ascontiguousarray((np.clip(img, 0, 1) * 255).astype(np.uint8)); cv2.rectangle(img, (0, 0), (img.shape[1], 16), (0, 0, 0), -1); cv2.putText(img, t, (3, 12), 0, 0.42, (255, 255, 255), 1, cv2.LINE_AA); return img
def frame(cam, tag): return np.hstack([lab(h07.render(L, S, cam, W, H)[0], n) for (n, L), S in zip(sets, Ss)])
for pitch, name in ((40, 'test08_rotation_pitch40_3.0(26)_vs_fixed.mp4'), (11.5, 'test08_rotation_pitch11_3.0(26)_vs_fixed.mp4')):
    vw = cv2.VideoWriter(os.path.join(OUT, name), cv2.VideoWriter_fourcc(*'mp4v'), 15, (3 * W, H)); azs = np.arange(-180, 180, 5)
    for cam, a in zip(cams07.orbit(c, R, azs, pitch, fx, W, H), azs):
        f = frame(cam, ''); cv2.putText(f, f'az {a:+4d} pitch {pitch}', (3, H - 6), 0, 0.45, (200, 220, 255), 1, cv2.LINE_AA); vw.write(cv2.cvtColor(f, cv2.COLOR_RGB2BGR))
    vw.release(); print('wrote', name, flush=True)
# stills: letters / edge / side
rows = []
for pitch, a in ((40, 20), (40, 160), (40, 90), (40, -100), (25, 60), (25, 200)):
    cam = cams07.orbit(c, R, [a], pitch, fx, W, H)[0]; rows.append(frame(cam, ''))
img = np.vstack([np.hstack([rows[0], rows[1]]) if False else rows[i] for i in range(6)])
cv2.imwrite(os.path.join(OUT, 'test08_compare_3.0(26)_vs_fixed_stills.jpg'), cv2.cvtColor(np.vstack([rows[0], rows[1], rows[2]]), cv2.COLOR_RGB2BGR))
cv2.imwrite(os.path.join(OUT, 'test08_compare_3.0(26)_vs_fixed_stills2.jpg'), cv2.cvtColor(np.vstack([rows[3], rows[4], rows[5]]), cv2.COLOR_RGB2BGR))
