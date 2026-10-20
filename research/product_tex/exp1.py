"""Experiment 1: is the fragmentation 'no surface' or 'surface removed by the >=2-agree rule'? Same layers, same cameras, same selection; only the corroboration rule toggled (need=2 vs need=1)."""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import syn_env as E, h07, cams07, fix06 as F, fix06_final as FF, align07 as A, pipe07 as P

syn = E.Syn(); L0 = syn.build(); sc = P.SC; ph, CV = A.cost_volumes(L0, sc)
L1 = A.consensus_pass(A.apply(L0, A.solve(L0, CV, sc, agg=3, med=3, sigma=1.2)), tau=0.10, min_supp=2, alpha=0.5)
W, H = 320, 240; c = syn.origin; Cs = np.array([f['C'] for f in syn.real]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor)); fx = syn.real[0]['fx'] * W / 960
out = {}
for name, L in (('noisy', L0), ('registered', L1)):
    Sm = [F.layer_samples(l) for l in L]
    for need in (2, 1):
        rows = []
        for pitch in (11.5, 30, 54):
            for cam in cams07.orbit(c, R, np.arange(-180, 180, 30), pitch, fx, W, H):
                gt, z, hit = E.gt_view(syn, cam, W, H)
                ids, rgb, zz = F.render_all(L, cam, W, H, cull=1)
                sel, w, _ = F.coarse_select(L, Sm, cam, W, H, kmax=8, seed=5); sel = np.array(sel)
                im, A_, cnt = FF.compose_new(rgb[sel], zz[sel], w, need=need)
                anyv = np.isfinite(zz[sel]).any(0)                       # some selected layer has a surface here
                r = E.score_view(im, A_, gt, hit)
                if r is None: continue
                inside = hit
                r['removed_surface_exists'] = float((anyv & (A_ < 0.5) & inside).sum() / max(inside.sum(), 1))   # inside GT, a layer saw it, composer dropped it
                r['no_layer_surface'] = float((~anyv & inside).sum() / max(inside.sum(), 1))                      # inside GT, no selected layer has any surface
                r['bg_kept'] = float((A_ > 0.5)[~inside].sum() / max(inside.sum(), 1))                              # kept outside GT (leak / ghost fragments)
                rows.append(r)
        m = {k: float(np.mean([r[k] for r in rows])) for k in rows[0]}
        out[f'{name} need={need}'] = m
        print(f'{name:11s} need={need}', ' '.join(f'{k} {v:.3f}' for k, v in m.items()), flush=True)
json.dump(out, open(r'C:\Users\emili\Downloads\product_surface_alignment_20261020\metrics_exp1_corroboration.json', 'w'), indent=1)
