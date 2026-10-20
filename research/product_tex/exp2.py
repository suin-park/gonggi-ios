"""Experiment 2: crossfade of layer weights on selection changes (PC sim, saved test_07 layers registered). 30 fps, 0.75 deg per frame, fade 8 frames (~0.27 s).
Variants: none (current) | fade, zero-weight layers counted in agreement (naive) | fade, layers with weight < 5% of max excluded from agreement.
Metrics: frame-to-frame mean |delta luma| (pops), cover, sharpness vs the no-fade frames, and ghost check = hf correlation of faded frame vs the same view rendered with only the selected layers."""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import h07, cams07, fix06 as F, fix06_final as FF, pipe07 as P

KM = r'C:\Users\emili\Downloads\테스트_07\product-tex-20261020-070707-product-gs.kmots'
Ls = F.load_kmots(KM); c = cams07.product_center(Ls); Cs = np.array([l['C'] for l in Ls]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor))
L = P.register(Ls); S = [F.layer_samples(l) for l in L]
W, H = 320, 240; fx = 720.37 * W / 960; STEPS = 8
res = {}
for pitch in (54, 11.5):
    azs = np.arange(-20, 25, 0.75)
    for name, fade, wmin in (('none (current)', False, 0.0), ('fade, zero-weight counted', True, 0.0), ('fade, weight<5% not counted', True, 0.05)):
        state = {}; prev = None; diffs = []; covers = []; maxw = []
        for a in azs:
            cam = cams07.orbit(c, R, [a], pitch, fx, W, H)[0]
            ids, rgb, z = F.render_all(L, cam, W, H, cull=1)
            sel, w, _ = F.coarse_select(L, S, cam, W, H, kmax=8, seed=5)
            wsel = {int(s): float(x) for s, x in zip(sel, w)}
            if fade:
                for k in list(state):
                    state[k][0] = max(0.0, state[k][0] - 1 / STEPS) if k not in wsel else min(1.0, state[k][0] + 1 / STEPS)
                for k in wsel:
                    if k not in state: state[k] = [1 / STEPS, wsel[k]]
                    state[k][1] = wsel[k]
                state = {k: v for k, v in state.items() if v[0] > 0}
                act = sorted(state, key=lambda k: -(state[k][0] * state[k][1]))[:8]
                idx = np.array(act); ww = np.array([state[k][0] * state[k][1] for k in act], np.float32)
            else:
                idx = np.array(sel); ww = np.array(w, np.float32)
            im, A_, cnt = FF.compose_new(rgb[idx], z[idx], ww, wmin_rel=wmin)
            luma = im @ np.array([0.299, 0.587, 0.114], np.float32)
            if prev is not None:
                both = (A_ > 0.5) & (prev[1] > 0.5)
                if both.sum() > 500: diffs.append(float(np.abs(luma - prev[0])[both].mean()))
            prev = (luma, A_); covers.append(float((A_ > 0.5).sum()))
        d = np.array(diffs); md = float(np.median(d))
        res[f'pitch {pitch} | {name}'] = dict(mean=float(d.mean()), p95=float(np.percentile(d, 95)), max=float(d.max()), pops=int((d > 2 * md).sum()), cover=float(np.mean(covers)))
        print(f'pitch {pitch} {name:30s}', res[f'pitch {pitch} | {name}'], flush=True)
json.dump(res, open(r'C:\Users\emili\Downloads\product_surface_alignment_20261020\metrics_exp2_crossfade.json', 'w'), indent=1)
