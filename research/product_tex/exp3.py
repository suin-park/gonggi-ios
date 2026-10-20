"""Experiment 3: revisit after a full loop (real test_07 replay, PC pipeline). Held-out frames near the START of the capture (indices 5, 15 and 45 which is near the start in azimuth).
Layers from the first sector only ('right after the first area') vs all other frames ('after coming back'); toggles separate pose/geometry, registration, selection and pixel removal."""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import h07, cams07, fix06 as F, fix06_final as FF, study, pipe07 as P

env = h07.Env('near'); fr = env.fr
Cs = np.array([f['C'] for f in fr]); cen = np.median(np.concatenate([l['corners'].mean(1) for l in env.build()]), 0)
rel, hor, az, pit = cams07.path_stats(Cs, cen)
print('azimuth of held frames', {i: round(float(az[i])) for i in sorted(env.held)}, 'first frames', [round(float(a)) for a in az[:6]], 'last', [round(float(a)) for a in az[-6:]])
EARLY = 20
L_all = env.build()
ids_all = [l['idx'] for l in L_all]
L_early = [l for l in L_all if l['idx'] < EARLY]
L_all_reg = P.register(L_all); L_early_reg = P.register(L_early)
held_eval = [i for i in sorted(env.held) if i < 20 or i >= 40]

def evaluate(L, need=2, restrict_early=False):
    S = [F.layer_samples(l) for l in L]; rows = []
    for i in held_eval:
        f = fr[i]; cam = env.cam_of(f); gt, lab = study.gt_and_labels(f, env.M[i])
        W, H = study.EW, study.EH
        ids, rgb, z = F.render_all(L, cam, W, H, cull=1)
        sel, w, _ = F.coarse_select(L, S, cam, W, H, kmax=8, seed=5)
        if restrict_early:
            keep = [k for k, s_ in enumerate(sel) if L[s_]['idx'] < EARLY]
            if len(keep) >= 2: sel = [sel[k] for k in keep]; w = np.array([w[k] for k in keep])
        sel = np.array(sel); im, A_, cnt = FF.compose_new(rgb[sel], z[sel], w, need=need)
        s = study.score(np.clip(im, 0, 1), A_, gt, lab)
        if s: rows.append(s)
    return {k: float(np.nanmean([r[k] for r in rows])) for k in ('psnr', 'ssim', 'hf_corr', 'psnr_edge', 'hole', 'lpips')}

res = {}
for name, L, kw in (('A first sector only, D0', L_early, {}), ('B all layers (after loop), D0', L_all, {}), ('C all layers, D0, selection limited to first-sector layers', L_all, dict(restrict_early=True)),
                    ('D all layers, D0, corroboration off', L_all, dict(need=1)), ('E first sector only, registered', L_early_reg, {}), ('F all layers, registered', L_all_reg, {}),
                    ('G all layers, registered, corroboration off', L_all_reg, dict(need=1))):
    res[name] = evaluate(L, **kw); print(f'{name:58s}', ' '.join(f'{k} {v:.3f}' for k, v in res[name].items()), flush=True)
json.dump(res, open(r'C:\Users\emili\Downloads\product_surface_alignment_20261020\metrics_exp3_revisit.json', 'w'), indent=1)
