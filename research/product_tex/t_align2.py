import sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, h07, align07 as A, fix06 as F
for hm in ('near', 'far'):
    env = h07.Env(hm); Lr = env.build()
    print('== held', hm, 'layers', len(Lr), 'held', sorted(env.held))
    h07.heldout(env, Lr, 'D0 none   ', True)
    for name, kw in (('cons k6 it1', dict(mode='cons')), ('cons k6 it2', dict(mode='cons', iters=2)), ('cons k10 it1', dict(mode='cons', kmax=10)), ('photo+cons', dict(mode='photo+cons'))):
        t = time.time(); L2, st = A.align(Lr, **kw)
        r = h07.heldout(env, L2, name, True)
        print('   pairs', {g: tuple(round(x, 2) for x in v) for g, v in h07.pair_stats(L2).items()}, 'sec', round(time.time() - t), flush=True)
