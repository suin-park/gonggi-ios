"""IBR degradation as the nearest captured sources are moved away (held-out frames; sources = non-held frames with index <= checkpoint and |index - v| > k). PC causal depth. Local only."""
import sys, json, numpy as np
sys.path.insert(0, '.')
import ibrbase as ib   # reuses P, ibr(), metrics (prints its own table once)
import gtlib as g
g_ = g
rows = {}
print('\nk (frames excluded around v) | nearest source angle/baseline | product PSNR | filled share of product | eye contrast recovery | edge PSNR   (mean over v=15,25,35)')
for k in (1, 3, 6, 10, 14):
    ps = []; fl = []; rc = []; ed = []; info = []
    for v, ck in ((15, 19), (25, 29), (35, 39)):
        src = [i for i in range(ib.n) if i <= ck and i % 10 != 5 and ib.P.mask[i].sum() > 50 and abs(i - v) > k]
        if not src: continue
        img, fill, used = ib.ibr(v, src); eye = g_.find_eyes(ib.P.gt[v], ib.P.mask[v]); mt = g_.metrics(img, fill.astype(np.float32), ib.P.gt[v], ib.P.mask[v], eye)
        ps.append(mt['product_psnr']); fl.append(float(fill[ib.P.mask[v]].mean())); info.append((used[0][2], used[0][1]))
        if 'recovery' in mt: rc.append(mt['recovery'])
    print(f'{k:3d} | {np.mean([a for a,_ in info]):.0f} deg / {np.mean([b for _,b in info]):.2f} m | {np.mean(ps):.2f} | {np.mean(fl):.2f} | {np.mean(rc) if rc else float("nan"):.2f}')
