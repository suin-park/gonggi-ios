import sys, os, json, time
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, cv2
import h07, cams07, fix06 as F

KM = r'C:\Users\emili\Downloads\테스트_07\product-tex-20261020-070707-product-gs.kmots'
env = h07.Env('near')
Ls = F.load_kmots(KM)
c = cams07.product_center(Ls)
Cs = np.array([l['C'] for l in Ls]); rel, hor, az, pit = cams07.path_stats(Cs, c)
print('center', c.round(3), 'path radius med %.2f' % np.median(hor), 'az range %.0f..%.0f' % (az.min(), az.max()), 'pitch %.0f..%.0f med %.0f' % (pit.min(), pit.max(), np.median(pit)))
print('az sequence', az.round(0)[::4])
Lr = env.build()
print('layers saved', len(Ls), 'regen (held excluded)', len(Lr))
for name, L in (('regen D0', Lr),):
    t = time.time(); r = h07.heldout(env, L, name, True); print(' sec', round(time.time() - t))

W, H = 320, 240
fx = env.fr[0]['fx'] * W / env.fr[0]['img'].shape[1]
azs = np.arange(-180, 180, 30)
print('ghost metric (24->12 azimuths/pitch)  stack = frac of pixels with stacked surfaces (>3cm between contributors); dcol = luma disagreement of same-surface contributors')
for name, L in (('saved .kmots', Ls), ('regen D0', Lr)):
    S = [F.layer_samples(l) for l in L]
    for pitch in (54, 11.5, 30, 75):
        t = time.time(); rs = []
        for cam in cams07.orbit(c, float(np.median(hor)), azs, pitch, fx, W, H):
            g = h07.ghost_at(L, S, cam, W, H)
            if g: rs.append(g)
        print(f' {name:13s} pitch {pitch:5.1f}: stack {np.mean([r["stack"] for r in rs]):.3f} dz {np.mean([r["dz_cm"] for r in rs]):.2f}cm dcol {np.mean([r["dcol"] for r in rs]):.4f} cover {np.mean([r["cover"] for r in rs]):.0f} ({time.time()-t:.0f}s, {len(rs)} views)', flush=True)
