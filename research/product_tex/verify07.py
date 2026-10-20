"""Independent re-check of the external CPU diagnosis (adjacent layers projected into 6 views: product-interior depth difference median ~2.8-7.9 cm).
Here: 6 virtual views (azimuth 60 deg apart, capture pitch 54 deg), the 5 layers with the best view score (what the 3.0(24) selection used), each rendered with back-face culling;
pairwise |dz| at pixels where both are valid, pairs closer than 20 cm only (so a different surface hit by one layer does not count as 'mismatch of the same surface').
Reported per view and overall, for the saved layers and after registration. This is NOT a real distance error and NOT the app's max-8 selection."""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import h07, cams07, fix06 as F, pipe07 as P

OUT = r'C:\Users\emili\Downloads\product_surface_alignment_20261020'
KM = r'C:\Users\emili\Downloads\테스트_07\product-tex-20261020-070707-product-gs.kmots'
Ls = F.load_kmots(KM); c = cams07.product_center(Ls)
Cs = np.array([l['C'] for l in Ls]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor))
Lr = P.register(Ls)
W, H = 320, 240; fx = 720.37 * W / 960
res = {}
for name, L in (('saved 3.0(25) layers', Ls), ('after registration', Lr)):
    per = []
    for cam in cams07.orbit(c, R, np.arange(-150, 180, 60), 54, fx, W, H):
        sc = np.array([F.score_of(l, cam) for l in L]); pick = np.argsort(sc)[:5]
        ids, rgb, z = F.render_all(L, cam, W, H, cull=1, only=list(pick))
        diffs = []
        for i in range(5):
            for j in range(i + 1, 5):
                m = np.isfinite(z[i]) & np.isfinite(z[j]); d = np.abs(z[i][m] - z[j][m]); d = d[d < 0.2]; diffs.append(d)
        d = np.concatenate(diffs) if diffs else np.array([np.nan]); per.append(float(np.median(d) * 100))
    res[name] = dict(per_view_median_cm=[round(x, 2) for x in per], min=min(per), max=max(per), mean=float(np.mean(per)))
    print(name, res[name], flush=True)
json.dump(res, open(os.path.join(OUT, 'metrics_external_diag_check.json'), 'w'), indent=1)
