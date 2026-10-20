import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import t08, h07, cams07, fix06 as F
Lb, La, sc = t08.load_both(); c = cams07.product_center(La); Cs = np.array([l['C'] for l in La]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor))
W, H = 480, 640; fx = 720.37 * H / 960 * 1.0
Sb = [F.layer_samples(l) for l in Lb]; Sa = [F.layer_samples(l) for l in La]
def lab(img, t):
    img = np.ascontiguousarray((np.clip(img, 0, 1) * 255).astype(np.uint8)); cv2.rectangle(img, (0, 0), (img.shape[1], 18), (0, 0, 0), -1); cv2.putText(img, t, (4, 13), 0, 0.45, (255, 255, 255), 1, cv2.LINE_AA); return img
rows = []
for pitch, azs in ((40, (0, 90, 180, -90)), (11.5, (45, 135))):
    for a in azs:
        cam = cams07.orbit(c, R, [a], pitch, fx, W, H)[0]
        b = h07.render(Lb, Sb, cam, W, H)[0]; a_ = h07.render(La, Sa, cam, W, H)[0]
        rows.append(np.hstack([lab(b, f'BEFORE registration (same device data) az {a} pitch {pitch}'), lab(a_, 'AFTER (as saved by 3.0(26))')]))
cv2.imwrite(r'C:\Users\emili\Downloads\product_surface_alignment_20261020\t08_before_after_stills.jpg', cv2.cvtColor(np.vstack([np.hstack(rows[i:i + 2]) for i in range(0, len(rows), 2)]), cv2.COLOR_RGB2BGR))
