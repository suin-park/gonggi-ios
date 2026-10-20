"""Selection-switch flicker / seams along a fine continuous rotation (PC reference). Same saved layers before vs after registration.
Per step (0.75 deg): selection set change (count of layers entering/leaving the 8-layer selection), mean |delta luma| over pixels covered in both frames.
A 'pop' is a step whose mean |delta| exceeds 2x the median of the path (rotation parallax is smooth; selection switches show as spikes)."""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, cv2
import h07, cams07, fix06 as F, pipe07 as P

OUT = r'C:\Users\emili\Downloads\product_surface_alignment_20261020'
KM = r'C:\Users\emili\Downloads\테스트_07\product-tex-20261020-070707-product-gs.kmots'
Ls = F.load_kmots(KM); c = cams07.product_center(Ls)
Cs = np.array([l['C'] for l in Ls]); rel, hor, az, pit = cams07.path_stats(Cs, c); R = float(np.median(hor))
Lr = P.register(Ls)
W, H = 320, 240; fx = 720.37 * W / 960
res = {}
for name, L in (('before (saved 3.0(25))', Ls), ('after registration', Lr)):
    S = [F.layer_samples(l) for l in L]
    for pitch in (54, 11.5):
        azs = np.arange(-20, 25, 0.75); prev_sel = None; prev_img = None; prev_A = None; changes = []; diffs = []
        for a in azs:
            cam = cams07.orbit(c, R, [a], pitch, fx, W, H)[0]
            im, A, rgb, z, w, sel = h07.render(L, S, cam, W, H)
            s = set(int(x) for x in sel)
            if prev_sel is not None: changes.append(len(s ^ prev_sel))
            luma = im @ np.array([0.299, 0.587, 0.114], np.float32)
            if prev_img is not None:
                both = (A > 0.5) & (prev_A > 0.5)
                if both.sum() > 500: diffs.append(float(np.abs(luma - prev_img)[both].mean()))
            prev_sel, prev_img, prev_A = s, luma, A
        d = np.array(diffs); md = float(np.median(d))
        res[f'{name} | pitch {pitch}'] = dict(selection_changes_per_step=float(np.mean(changes)), steps_with_change=float(np.mean(np.array(changes) > 0)),
                                              mean_abs_delta=float(d.mean()), median=md, p95=float(np.percentile(d, 95)), max=float(d.max()), pops=int((d > 2 * md).sum()), steps=len(d))
        print(name, pitch, res[f'{name} | pitch {pitch}'], flush=True)
json.dump(res, open(os.path.join(OUT, 'metrics_flicker.json'), 'w'), indent=1)
