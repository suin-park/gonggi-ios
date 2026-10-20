import sys, os, pickle, time
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, cv2, h07, cams07, align07 as A, pipe07 as P, fix06 as F
import texsplat as TS
KM = r'C:\Users\emili\Downloads\테스트_07\product-tex-20261020-070707-product-gs.kmots'
Ls = F.load_kmots(KM); c = cams07.product_center(Ls)
Cs = np.array([l['C'] for l in Ls]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor))
ph, CV = A.cost_volumes(Ls, P.SC); pickle.dump(CV, open('cache/real_cv.pkl', 'wb'))
W, H = 320, 240; fx = 720.37 * W / 960
def cover(L, name):
    S = [F.layer_samples(l) for l in L]; out = {}
    for pitch in (54, 11.5):
        cv = []
        for cam in cams07.orbit(c, R, np.arange(-180, 180, 30), pitch, fx, W, H): cv.append(h07.render(L, S, cam, W, H)[1].sum())
        out[pitch] = np.mean(cv)
    print(f'{name:26s} cover@54 {out[54]:.0f} cover@11.5 {out[11.5]:.0f}', flush=True)
cover(Ls, 'saved')
for sg in (0, 1.2):
    S1 = A.solve(Ls, CV, P.SC, agg=3, med=3, sigma=sg); L1 = A.apply(Ls, S1); cover(L1, f'photo sigma {sg}')
    allS = np.concatenate(S1); print('   s distribution: median %.3f  p5 %.3f  p95 %.3f  at-limit %.3f' % (np.median(allS), np.percentile(allS, 5), np.percentile(allS, 95), np.mean((allS < 0.855) | (allS > 1.145))))
    cover(A.consensus_pass(L1, tau=0.10, min_supp=2, alpha=0.5), f'  +cons')
