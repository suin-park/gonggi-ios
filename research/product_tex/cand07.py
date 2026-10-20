"""Candidate vs 3.0(25)-style pipeline, regenerated from the SAME test_07 replay (PC depth, not the app's Core ML depth), held-out frames excluded from everything.
OLD  : mask band 2, nearest binary texel alpha, cells >= 50 % product, no edge colour ext, no registration, current compose.
NEW  : mask band 1, soft alpha, cells >= 25 %, edge colour extension, photo registration + consensus.
Eval region fixed (the band-2 product label of each held-out frame) for both; holes count as black."""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import h07, study, fix06 as F, pipe07 as P

OUT = r'C:\Users\emili\Downloads\product_surface_alignment_20261020'
res = {}; crops = []
for hm in ('near', 'far'):
    env = h07.Env(hm); base = list(env.M)
    def setup(band, soft, mp, ext):
        os.environ['ALPHA_SOFT'] = soft; os.environ['MIN_PROD'] = mp; os.environ['EDGE_EXT'] = ext
        env.M = [h07.relabel(m, band, src_band=2) if band != 2 and (m == 1).sum() > 100 else m for m in base]
        env.trust = [bool(env.D['TRUST'][i]) and (env.M[i] == 1).sum() > 100 for i in range(env.n)]
        return env.build()
    Lo = setup(2, '0', '0.5', '0'); Ln = P.register(setup(1, '1', '0.25', '1'))
    ro = h07.heldout(env, Lo, eval_M=base); rn = h07.heldout(env, Ln, eval_M=base)
    res[hm] = {'OLD (3.0(25)-style)': ro, 'NEW candidate': rn}
    print(hm, 'OLD', {k: round(v, 3) for k, v in ro.items()}); print(hm, 'NEW', {k: round(v, 3) for k, v in rn.items()}, flush=True)
    if hm == 'near':
        for i in sorted(env.held)[:3]:
            f = env.fr[i]; cam = env.cam_of(f); W, H = study.EW, study.EH
            gt = cv2.resize(f['img'], (W, H), interpolation=cv2.INTER_AREA)
            ims = []
            for L in (Lo, Ln):
                S = [F.layer_samples(l) for l in L]; im, A_, *_ = h07.render(L, S, cam, W, H); ims.append((np.clip(im, 0, 1) * 255).astype(np.uint8))
            row = np.hstack([gt, ims[0], ims[1]])
            for j, t in enumerate(('photo (held-out)', 'OLD pipeline', 'NEW candidate')): cv2.putText(row, t, (6 + j * W, 16), 0, 0.5, (255, 255, 0), 1, cv2.LINE_AA)
            crops.append(row)
cv2.imwrite(os.path.join(OUT, 'compare_heldout_old_vs_candidate.png'), cv2.cvtColor(np.vstack(crops), cv2.COLOR_RGB2BGR))
json.dump(res, open(os.path.join(OUT, 'metrics_candidate.json'), 'w'), indent=1)
