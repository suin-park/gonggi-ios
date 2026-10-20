import sys, os, time, pickle
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, h07, align07 as A, fix06 as F
scales = np.linspace(0.85, 1.15, 16)
cfgs = [('noagg lam.3 med1', dict(agg=1, med=1)), ('agg3 med3', dict(agg=3, med=3)), ('agg5 med3', dict(agg=5, med=3)), ('agg3 med3 mc.35', dict(agg=3, med=3, max_cost=0.35)),
        ('agg3 med3 lam1', dict(agg=3, med=3, lam=1.0)), ('agg5 med5', dict(agg=5, med=5)), ('agg7 med3', dict(agg=7, med=3))]
for hm in ('near', 'far'):
    env = h07.Env(hm); Lr = env.build(); print('== held', hm, flush=True)
    t = time.time(); ph, CV = A.cost_volumes(Lr, scales); print(' cost volumes sec', round(time.time() - t), flush=True)
    pickle.dump((CV,), open(f'cache/cv_{hm}.pkl', 'wb'))
    for name, kw in cfgs:
        S = A.solve(Lr, CV, scales, **kw); L2 = A.apply(Lr, S)
        h07.heldout(env, L2, name.ljust(18), True)
