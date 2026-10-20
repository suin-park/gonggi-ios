import sys, os, pickle
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, cv2, h07, cams07, align07 as A, fix06 as F
KM = r'C:\Users\emili\Downloads\테스트_07\product-tex-20261020-070707-product-gs.kmots'
Ls = F.load_kmots(KM); c = cams07.product_center(Ls)
Cs = np.array([l['C'] for l in Ls]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor))
W, H = 640, 480; fx = 720.37 * W / 960
variants = {'saved': Ls}
import pipe07 as P
variants['photo+cons'] = P.register(Ls)
variants['+edge damp .7 sigma1.2'] = P.register(Ls, damp=0.7, sigma=1.2)
def lab(img, t):
    img = np.ascontiguousarray((np.clip(img, 0, 1) * 255).astype(np.uint8)); cv2.rectangle(img, (0, 0), (img.shape[1], 18), (0, 0, 0), -1); cv2.putText(img, t, (4, 13), 0, 0.45, (255, 255, 255), 1, cv2.LINE_AA); return img
rows = []
for pitch, azs in ((54, (0, 90)), (11.5, (30, 68))):
    for a in azs:
        cam = cams07.orbit(c, R, [a], pitch, fx, W, H)[0]; ims = []
        for k, L in variants.items():
            S = [F.layer_samples(l) for l in L]
            ims.append(lab(h07.render(L, S, cam, W, H)[0], f'{k} pitch {pitch} az {a}'))
        rows.append(np.hstack(ims))
cv2.imwrite(r'C:\Users\emili\Downloads\product_surface_alignment_20261020\_probe_align.jpg', cv2.cvtColor(np.vstack(rows), cv2.COLOR_RGB2BGR))
