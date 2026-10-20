import sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np, h07, align07 as A, fix06 as F
cfgs = [('pc base', dict()), ('pc it2', dict(iters=2)), ('pc lam0.3', dict(lam=0.3)), ('pc lam3', dict(lam=3.0)),
        ('pc wide .8-1.2', dict(scales=np.linspace(0.8, 1.2, 21))), ('pc k10', dict(kmax=10)), ('pc conf.01', dict(min_conf=0.01)),
        ('photo only', dict(mode='photo', lam=0.3)), ('pc nosmooth', dict(smooth=False))]
for hm in ('near', 'far'):
    env = h07.Env(hm); Lr = env.build(); print('== held', hm, flush=True)
    for name, kw in cfgs:
        t = time.time(); L2, st = A.align(Lr, **kw); r = h07.heldout(env, L2, name.ljust(16), True); print('    sec', round(time.time() - t), flush=True)
