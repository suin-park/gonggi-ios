import os, sys, time, json
os.environ.update(DATA='09', N_FRAMES='118', NPZ_PATH='C:/projects/gonggi-ios-tex3/research/product_tex/cache/t09f_p1_320.npz', APP_LIKE='1', APP_BUDGET='1500', APPOPT='1'); sys.argv = ['x']
import numpy as np
import seqwin as sw
from seqwin import ctx, ColorRun, held, P, g, Refiner
import stlib
Zmax = [float(ctx.D['Z'][i].max()) for i in range(14)]; ZS = [int((ctx.D['ZS'][i] > 0).sum()) for i in range(14)]
print('frames idx:', list(range(14))); print('Z max (m):', [round(z, 2) for z in Zmax]); print('stereo anchor px at 160x120:', ZS); print('held:', [i for i in range(14) if held(i)])
r = ColorRun(ctx, 'B'); r.cfg['ins_budget'] = 10 ** 9; r.th = None; R = Refiner(r.opt); t0 = time.time(); rows = []
for i in range(14):
    if held(i) or ctx.D['Z'][i].max() <= 0: print('idx', i, 'skipped (held or no depth)'); continue
    n0 = r.G.n; ins0 = r.stats['inserted']; s0 = stlib.COUNT['steps']; r.insert(i); r.train_ids.append(i); ins = r.stats['inserted'] - ins0
    if (len(r.train_ids) - 1) % 20 == 1:
        r.val_ids.append(i)
        if len(r.val_ids) > 6: r.val_ids.pop(1)
    if r.G.n > 0:
        for _ in range(r.iters // r.slice_iters): r.optimize_slice()
    pr = 0
    if len(r.train_ids) % 4 == 0: pr = r.prune()
    c = R.refine(r.G, [j for j in r.train_ids if P.mask[j].sum() > 50] or r.train_ids, 1.0, 'win') if r.G.n > 0 else dict(steps=0, window_steps=0)
    rows.append(dict(idx=i, device_id=i + 1, inserted=int(ins), N=int(r.G.n), optimizer_calls=stlib.COUNT['steps'] - s0, rollbacks=int(r.stats['rollbacks']), pruned=int(pr or 0), refine_steps=c['steps'])); print(rows[-1], flush=True)
