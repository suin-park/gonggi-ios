import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, cv2, h07, cams07, fix06 as F
KM = r'C:\Users\emili\Downloads\테스트_07\product-tex-20261020-070707-product-gs.kmots'
Ls = F.load_kmots(KM); c = cams07.product_center(Ls)
Cs = np.array([l['C'] for l in Ls]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor))
W, H = 720, 540; fx = 720.37 * W / 960
S = [F.layer_samples(l) for l in Ls]
cam = cams07.orbit(c, R, [100], 54, fx, W, H)[0]
im = h07.render(Ls, S, cam, W, H)[0]
big = cv2.resize((np.clip(im, 0, 1) * 255).astype(np.uint8), None, fx=2, fy=2, interpolation=cv2.INTER_NEAREST)
crop = big[100:500, 500:1100]
cv2.imwrite(r'C:\Users\emili\Downloads\product_surface_alignment_20261020\_probe_edge.png', cv2.cvtColor(crop, cv2.COLOR_RGB2BGR))
