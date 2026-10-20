import sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, h07, align07 as A, tsdf07 as T, fix06 as F
for hm in ('near', 'far'):
    env = h07.Env(hm); Lr = env.build(); print('== held', hm, flush=True)
    h07.heldout(env, Lr, 'D0'.ljust(18), True)
    for name, kw in (('tsdf v1 mu6', dict(vox=0.01, mu=0.06)), ('tsdf v1 mu4', dict(vox=0.01, mu=0.04)), ('tsdf v.8 mu8', dict(vox=0.008, mu=0.08))):
        t = time.time(); sc, V = T.fuse_depth(Lr, **kw); L2 = T.apply_scales(Lr, sc)
        fnd = np.mean([f.mean() for _, f in sc]); mv = np.median(np.concatenate([np.abs(s[f] - 1) for s, f in sc]))
        h07.heldout(env, L2, name.ljust(18), True); print('    found %.2f  median|s-1| %.3f  sec %d' % (fnd, mv, time.time() - t), 'pairs', {g: tuple(round(x, 2) for x in v) for g, v in h07.pair_stats(L2).items()}, flush=True)
